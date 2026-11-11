// loader.efi: installed as \EFI\BOOT\BOOTAA64.EFI on the install media and the Windows ESP. Starts
// \EFI\Macaroon\framebuffer.efi from the same volume, then Windows Boot Manager, kept as \EFI\BOOT\windows.efi.
// Written for Macaroon from the UEFI 2.x specification.

#include "efi.h"

static EFI_GUID LoadedImageGuid = {0x5b1b31a1, 0x9562, 0x11d2, {0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
static EFI_GUID DevicePathGuid = {0x09576e91, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
static EFI_BOOT_SERVICES *BS;

static UINTN NodeSize(EFI_DEVICE_PATH *p) { return p->Length[0] | (p->Length[1] << 8); }

// LoadImage for `path` on the volume `volume`: the volume's device path + a file path node + end
static EFI_STATUS Load(EFI_HANDLE parent, EFI_HANDLE volume, const CHAR16 *path, EFI_HANDLE *out) {
  EFI_DEVICE_PATH *base;
  if (EFI_ERROR(BS->HandleProtocol(volume, &DevicePathGuid, (VOID **)&base))) return EFI_NOT_FOUND;
  UINTN baseSize = 0, pathSize = 2;
  for (EFI_DEVICE_PATH *p = base; p->Type != 0x7f; p = (EFI_DEVICE_PATH *)((UINT8 *)p + NodeSize(p))) baseSize += NodeSize(p);
  for (const CHAR16 *c = path; *c; c++) pathSize += 2;
  UINTN node = 4 + pathSize;
  UINT8 *dp;
  if (EFI_ERROR(BS->AllocatePool(EfiBootServicesData, baseSize + node + 4, (VOID **)&dp))) return EFI_NOT_FOUND;
  memcpy(dp, base, baseSize);
  UINT8 *f = dp + baseSize;
  f[0] = 4; f[1] = 4; f[2] = node & 0xff; f[3] = node >> 8;
  memcpy(f + 4, path, pathSize);
  f += node;
  f[0] = 0x7f; f[1] = 0xff; f[2] = 4; f[3] = 0;
  EFI_STATUS s = BS->LoadImage(FALSE, parent, (EFI_DEVICE_PATH *)dp, NULL, 0, out);
  BS->FreePool(dp);
  return s;
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st) {
  BS = st->BootServices;
  EFI_LOADED_IMAGE *self;
  if (EFI_ERROR(BS->HandleProtocol(image, &LoadedImageGuid, (VOID **)&self))) return EFI_LOAD_ERROR;

  EFI_HANDLE driver, bootmgr;
  if (!EFI_ERROR(Load(image, self->DeviceHandle, L"\\EFI\\Macaroon\\framebuffer.efi", &driver))) BS->StartImage(driver, NULL, NULL);

  EFI_STATUS s = Load(image, self->DeviceHandle, L"\\EFI\\BOOT\\windows.efi", &bootmgr);
  return EFI_ERROR(s) ? s : BS->StartImage(bootmgr, NULL, NULL);
}
