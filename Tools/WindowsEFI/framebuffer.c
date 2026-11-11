// framebuffer.efi: UEFI boot service driver giving Windows a linear framebuffer on Virtualization.framework.
//
// Apple's firmware exposes the virtio GPU as a Blt-only graphics output (no FrameBufferBase). Windows Boot
// Manager and the kernel's boot display write straight to the framebuffer address the firmware reports, so the
// first pixel lands at address 0 and the VM dies with "internal virtualization error". This driver reserves a
// RAM framebuffer, reports it in every graphics output's mode, and a timer copies changed rows to the GPU with
// its original Blt. Copying ends at ExitBootServices; Windows' virtio GPU driver (viogpudo) takes over later.
//
// It also registers itself as Driver#### with a file-only device path, so the firmware loads it on every boot
// from whichever volume has \EFI\Macaroon\framebuffer.efi (the install media first, then the Windows ESP) even
// after Windows puts its own boot entry first.
//
// Written for Macaroon from the UEFI 2.x specification.

#include "efi.h"

#define MAX_WIDTH 1920
#define MAX_HEIGHT 1200
#define FB_BYTES (MAX_WIDTH * MAX_HEIGHT * 4)
#define MAX_OUTPUTS 8
#define OPTION_NUMBER 0x4D41 // Driver4D41
#define TICK_100NS 330000    // 33 ms

static EFI_GUID GopGuid = {0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}};
static EFI_GUID DevicePathGuid = {0x09576e91, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
static EFI_GUID ExitBootServicesGuid = {0x27abf055, 0xb1b8, 0x4c26, {0x80, 0x48, 0x74, 0x8f, 0x37, 0xba, 0xa2, 0xdf}};
static EFI_GUID GlobalGuid = {0x8be4df61, 0x93ca, 0x11d2, {0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c}};
static EFI_GUID MarkerGuid = {0x6d61636f, 0x726f, 0x6e46, {0x42, 0x2d, 0x4d, 0x61, 0x63, 0x61, 0x72, 0x6f}};

static CHAR16 FilePath[] = L"\\EFI\\Macaroon\\framebuffer.efi";
static CHAR16 Description[] = L"Macaroon framebuffer";

static EFI_BOOT_SERVICES *BS;
static UINT8 *Fb, *Shadow;
static EFI_GOP *Gpu;
static EFI_GOP_BLT GpuBlt;
static BOOLEAN Live, Busy;
static EFI_EVENT Timer;
static VOID *NotifyKey;

static struct { EFI_GOP *gop; EFI_GOP_SET_MODE setMode; EFI_GOP_QUERY_MODE queryMode; } Hooked[MAX_OUTPUTS];
static UINTN HookedCount;

static BOOLEAN Fits(const EFI_GOP_MODE_INFO *info) {
  return Fb && info && info->HorizontalResolution <= MAX_WIDTH && info->VerticalResolution <= MAX_HEIGHT;
}

static UINTN W(VOID) { return Gpu->Mode->Info->HorizontalResolution; }
static UINTN H(VOID) { return Gpu->Mode->Info->VerticalResolution; }

static VOID Describe(EFI_GOP_MODE_INFO *info) {
  info->PixelFormat = PixelBlueGreenRedReserved8BitPerColor;
  info->RedMask = info->GreenMask = info->BlueMask = info->ReservedMask = 0;
  info->PixelsPerScanLine = info->HorizontalResolution;
}

// Every hooked output (the GPU's and the console splitter's) reports the RAM framebuffer
static VOID Advertise(VOID) {
  for (UINTN i = 0; i < HookedCount; i++) {
    EFI_GOP_MODE *mode = Hooked[i].gop->Mode;
    if (!mode || !Fits(mode->Info)) continue;
    Describe(mode->Info);
    mode->FrameBufferBase = (EFI_PHYSICAL_ADDRESS)(UINTN)Fb;
    mode->FrameBufferSize = (UINTN)mode->Info->HorizontalResolution * mode->Info->VerticalResolution * 4;
  }
}

static BOOLEAN RowChanged(UINTN y) {
  const UINT64 *a = (const UINT64 *)(Fb + y * W() * 4), *b = (const UINT64 *)(Shadow + y * W() * 4);
  for (UINTN i = 0; i < W() / 2; i++) if (a[i] != b[i]) return TRUE;
  return FALSE;
}

// Pushes each run of changed rows in [from, to) to the GPU
static VOID Flush(UINTN from, UINTN to) {
  if (!Live || Busy || !Fits(Gpu->Mode->Info)) return;
  Busy = TRUE;
  UINTN stride = W() * 4;
  if (to > H()) to = H();
  for (UINTN y = from; y < to;) {
    if (!RowChanged(y)) { y++; continue; }
    UINTN start = y;
    while (y < to && RowChanged(y)) y++;
    if (!EFI_ERROR(GpuBlt(Gpu, (UINT32 *)Fb, EfiBltBufferToVideo, 0, start, 0, start, W(), y - start, stride)))
      memcpy(Shadow + start * stride, Fb + start * stride, (y - start) * stride);
  }
  Busy = FALSE;
}

static VOID OnTick(EFI_EVENT e, VOID *c) { if (Gpu) Flush(0, H()); }
static VOID OnExitBootServices(EFI_EVENT e, VOID *c) { Live = FALSE; }

static int Find(EFI_GOP *gop) {
  for (UINTN i = 0; i < HookedCount; i++) if (Hooked[i].gop == gop) return (int)i;
  return -1;
}

static EFI_STATUS HookQueryMode(EFI_GOP *gop, UINT32 n, UINTN *size, EFI_GOP_MODE_INFO **info) {
  int i = Find(gop);
  if (i < 0) return EFI_INVALID_PARAMETER;
  EFI_STATUS s = Hooked[i].queryMode(gop, n, size, info);
  if (!EFI_ERROR(s) && info && Fits(*info)) Describe(*info);
  return s;
}

static EFI_STATUS HookSetMode(EFI_GOP *gop, UINT32 n) {
  int i = Find(gop);
  if (i < 0) return EFI_INVALID_PARAMETER;
  if (Fb) { // refuse modes larger than the framebuffer
    EFI_GOP_MODE_INFO *info;
    UINTN size;
    if (EFI_ERROR(Hooked[i].queryMode(gop, n, &size, &info))) return EFI_UNSUPPORTED;
    BOOLEAN ok = Fits(info);
    BS->FreePool(info);
    if (!ok) return EFI_UNSUPPORTED;
  }
  EFI_STATUS s = Hooked[i].setMode(gop, n);
  if (!EFI_ERROR(s) && Fb) {
    Advertise();
    memset(Fb, 0, FB_BYTES);
    memset(Shadow, 0xff, FB_BYTES); // repaint everything next tick
  }
  return s;
}

// Firmware drawing goes through the RAM framebuffer too, so it stays the one source of truth
static EFI_STATUS HookBlt(EFI_GOP *gop, UINT32 *buf, UINTN op, UINTN sx, UINTN sy, UINTN dx, UINTN dy, UINTN w, UINTN h, UINTN delta) {
  if (!Fits(Gpu->Mode->Info)) return GpuBlt(gop, buf, op, sx, sy, dx, dy, w, h, delta);
  if (w == 0 || h == 0) return EFI_SUCCESS;
  UINTN stride = W() * 4, bstride = delta ? delta : w * 4;
  BOOLEAN srcOK = sx + w <= W() && sy + h <= H(), dstOK = dx + w <= W() && dy + h <= H();
  switch (op) {
    case EfiBltVideoFill:
      if (!buf || !dstOK) return EFI_INVALID_PARAMETER;
      for (UINTN r = 0; r < h; r++) {
        UINT32 *line = (UINT32 *)(Fb + (dy + r) * stride) + dx;
        for (UINTN x = 0; x < w; x++) line[x] = *buf;
      }
      break;
    case EfiBltVideoToBltBuffer:
      if (!buf || !srcOK) return EFI_INVALID_PARAMETER;
      for (UINTN r = 0; r < h; r++) memcpy((UINT8 *)buf + (dy + r) * bstride + dx * 4, Fb + (sy + r) * stride + sx * 4, w * 4);
      return EFI_SUCCESS;
    case EfiBltBufferToVideo:
      if (!buf || !dstOK) return EFI_INVALID_PARAMETER;
      for (UINTN r = 0; r < h; r++) memcpy(Fb + (dy + r) * stride + dx * 4, (UINT8 *)buf + (sy + r) * bstride + sx * 4, w * 4);
      break;
    case EfiBltVideoToVideo:
      if (!srcOK || !dstOK) return EFI_INVALID_PARAMETER;
      if (dy > sy) { for (UINTN r = h; r-- > 0;) memmove(Fb + (dy + r) * stride + dx * 4, Fb + (sy + r) * stride + sx * 4, w * 4); }
      else { for (UINTN r = 0; r < h; r++) memmove(Fb + (dy + r) * stride + dx * 4, Fb + (sy + r) * stride + sx * 4, w * 4); }
      break;
    default:
      return EFI_INVALID_PARAMETER;
  }
  Flush(dy, dy + h);
  return EFI_SUCCESS;
}

// Above the cap the firmware may be in a huge mode (8192x4320); switch to the largest one within it
static BOOLEAN Cap(UINTN i) {
  EFI_GOP *gop = Hooked[i].gop;
  if (Fits(gop->Mode->Info)) return TRUE;
  UINT32 best = gop->Mode->MaxMode;
  UINT64 bestArea = 0;
  for (UINT32 m = 0; m < gop->Mode->MaxMode; m++) {
    EFI_GOP_MODE_INFO *info;
    UINTN size;
    if (EFI_ERROR(Hooked[i].queryMode(gop, m, &size, &info))) continue;
    UINT64 area = (UINT64)info->HorizontalResolution * info->VerticalResolution;
    if (Fits(info) && area > bestArea) { best = m; bestArea = area; }
    BS->FreePool(info);
  }
  return best < gop->Mode->MaxMode && !EFI_ERROR(Hooked[i].setMode(gop, best)) && Fits(gop->Mode->Info);
}

static VOID Hook(EFI_HANDLE handle) {
  EFI_GOP *gop = NULL;
  VOID *path = NULL;
  if (EFI_ERROR(BS->HandleProtocol(handle, &GopGuid, (VOID **)&gop)) || !gop || Find(gop) >= 0 || HookedCount == MAX_OUTPUTS) return;
  UINTN i = HookedCount++;
  Hooked[i].gop = gop;
  Hooked[i].setMode = gop->SetMode;
  Hooked[i].queryMode = gop->QueryMode;
  gop->SetMode = HookSetMode;
  gop->QueryMode = HookQueryMode;

  BOOLEAN bltOnly = gop->Mode && gop->Mode->Info && (gop->Mode->FrameBufferBase == 0 || gop->Mode->Info->PixelFormat == PixelBltOnly);
  BOOLEAN isDevice = !EFI_ERROR(BS->HandleProtocol(handle, &DevicePathGuid, &path)) && path;
  if (!Gpu && bltOnly && isDevice && Cap(i)) {
    Gpu = gop;
    GpuBlt = gop->Blt;
    gop->Blt = HookBlt;
    Live = TRUE;
    BS->SetTimer(Timer, TimerPeriodic, TICK_100NS);
  }
  Advertise();
}

static VOID OnNewGop(EFI_EVENT e, VOID *c) {
  EFI_HANDLE *handles;
  UINTN n;
  while (!EFI_ERROR(BS->LocateHandleBuffer(3 /* ByRegisterNotify */, NULL, NotifyKey, &n, &handles))) {
    for (UINTN i = 0; i < n; i++) Hook(handles[i]);
    BS->FreePool(handles);
  }
}

// Driver4D41 = { LOAD_OPTION_ACTIVE, path length, Description, FilePath node, end node }; added to DriverOrder
static VOID Register(EFI_RUNTIME_SERVICES *rt) {
  enum { NODE = 4 + sizeof(FilePath), LIST = NODE + 4 };
  UINT8 opt[4 + 2 + sizeof(Description) + LIST], *p = opt;
  UINT32 attrs = LOAD_OPTION_ACTIVE;
  UINT16 list = LIST;
  memcpy(p, &attrs, 4); p += 4;
  memcpy(p, &list, 2); p += 2;
  memcpy(p, Description, sizeof(Description)); p += sizeof(Description);
  p[0] = 4; p[1] = 4; p[2] = NODE & 0xff; p[3] = NODE >> 8; // media device path, file path
  memcpy(p + 4, FilePath, sizeof(FilePath)); p += NODE;
  p[0] = 0x7f; p[1] = 0xff; p[2] = 4; p[3] = 0;             // end of path

  UINT32 va = EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS;
  CHAR16 name[] = L"Driver0000";
  for (int i = 0; i < 4; i++) name[6 + i] = L"0123456789ABCDEF"[(OPTION_NUMBER >> (12 - 4 * i)) & 0xf];

  UINT8 old[sizeof(opt)];
  UINTN size = sizeof(old);
  BOOLEAN same = !EFI_ERROR(rt->GetVariable(name, &GlobalGuid, NULL, &size, old)) && size == sizeof(opt);
  for (UINTN i = 0; same && i < sizeof(opt); i++) same = old[i] == opt[i];
  if (!same && EFI_ERROR(rt->SetVariable(name, &GlobalGuid, va, sizeof(opt), opt))) return;

  UINT16 order[64];
  size = sizeof(order);
  EFI_STATUS s = rt->GetVariable(L"DriverOrder", &GlobalGuid, NULL, &size, order);
  if (s == EFI_NOT_FOUND) size = 0;
  else if (EFI_ERROR(s)) return;
  UINTN n = size / 2;
  for (UINTN i = 0; i < n; i++) if (order[i] == OPTION_NUMBER) return;
  if (n == 64) return;
  order[n++] = OPTION_NUMBER;
  rt->SetVariable(L"DriverOrder", &GlobalGuid, va, n * 2, order);
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st) {
  BS = st->BootServices;
  VOID *marker;
  if (!EFI_ERROR(BS->LocateProtocol(&MarkerGuid, NULL, &marker))) { // already resident
    Register(st->RuntimeServices);
    return EFI_ALREADY_STARTED;
  }

  EFI_PHYSICAL_ADDRESS address;
  if (EFI_ERROR(BS->AllocatePages(AllocateAnyPages, EfiReservedMemoryType, (FB_BYTES + 4095) / 4096, &address))) return EFI_LOAD_ERROR;
  if (EFI_ERROR(BS->AllocatePool(EfiBootServicesData, FB_BYTES, (VOID **)&Shadow))) return EFI_LOAD_ERROR;
  Fb = (UINT8 *)(UINTN)address;
  memset(Fb, 0, FB_BYTES);
  memset(Shadow, 0xff, FB_BYTES);

  if (EFI_ERROR(BS->CreateEvent(EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnTick, NULL, &Timer))) return EFI_LOAD_ERROR;
  EFI_EVENT ebs, gopEvent;
  BS->CreateEventEx(EVT_NOTIFY_SIGNAL, TPL_NOTIFY, OnExitBootServices, NULL, &ExitBootServicesGuid, &ebs);

  // Listen before looking so no output slips through; as a Driver#### option we load before any exists
  if (!EFI_ERROR(BS->CreateEvent(EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnNewGop, NULL, &gopEvent)))
    BS->RegisterProtocolNotify(&GopGuid, gopEvent, &NotifyKey);
  EFI_HANDLE *handles;
  UINTN n;
  if (!EFI_ERROR(BS->LocateHandleBuffer(ByProtocol, &GopGuid, NULL, &n, &handles))) {
    for (UINTN i = 0; i < n; i++) Hook(handles[i]);
    BS->FreePool(handles);
  }

  EFI_HANDLE h = NULL;
  BS->InstallProtocolInterface(&h, &MarkerGuid, EFI_NATIVE_INTERFACE, NULL);
  Register(st->RuntimeServices);
  return EFI_SUCCESS;
}
