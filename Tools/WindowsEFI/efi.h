// The handful of UEFI 2.x definitions framebuffer.c and loader.c use, written from the specification.
#pragma once

typedef unsigned char UINT8;
typedef unsigned short UINT16;
typedef unsigned int UINT32;
typedef unsigned long long UINT64;
typedef UINT64 UINTN;
typedef UINT16 CHAR16;
typedef UINT8 BOOLEAN;
typedef void VOID;
typedef UINTN EFI_STATUS;
typedef VOID *EFI_HANDLE;
typedef VOID *EFI_EVENT;
typedef UINT64 EFI_PHYSICAL_ADDRESS;
typedef UINTN EFI_TPL;

#define EFIAPI
#define TRUE 1
#define FALSE 0
#define NULL ((VOID *)0)

#define EFI_ERROR_BIT (1ULL << 63)
#define EFI_ERROR(s) (((EFI_STATUS)(s)) & EFI_ERROR_BIT)
#define EFI_SUCCESS 0
#define EFI_LOAD_ERROR (EFI_ERROR_BIT | 1)
#define EFI_INVALID_PARAMETER (EFI_ERROR_BIT | 2)
#define EFI_UNSUPPORTED (EFI_ERROR_BIT | 3)
#define EFI_NOT_FOUND (EFI_ERROR_BIT | 14)
#define EFI_ALREADY_STARTED (EFI_ERROR_BIT | 20)

typedef struct { UINT32 Data1; UINT16 Data2; UINT16 Data3; UINT8 Data4[8]; } EFI_GUID;
typedef struct { UINT64 Signature; UINT32 Revision; UINT32 HeaderSize; UINT32 CRC32; UINT32 Reserved; } EFI_TABLE_HEADER;
typedef struct { UINT8 Type; UINT8 SubType; UINT8 Length[2]; } EFI_DEVICE_PATH;

#define EVT_TIMER 0x80000000
#define EVT_NOTIFY_SIGNAL 0x00000200
#define TPL_CALLBACK 8
#define TPL_NOTIFY 16
#define TimerPeriodic 1
#define AllocateAnyPages 0
#define EfiReservedMemoryType 0
#define EfiBootServicesData 4
#define ByProtocol 2
#define EFI_NATIVE_INTERFACE 0
#define EFI_VARIABLE_NON_VOLATILE 1
#define EFI_VARIABLE_BOOTSERVICE_ACCESS 2
#define EFI_VARIABLE_RUNTIME_ACCESS 4
#define LOAD_OPTION_ACTIVE 1

typedef VOID (*EFI_EVENT_NOTIFY)(EFI_EVENT, VOID *);

typedef struct {
  EFI_TABLE_HEADER Hdr;
  VOID *RaiseTPL, *RestoreTPL;
  EFI_STATUS (*AllocatePages)(UINTN Type, UINTN MemoryType, UINTN Pages, EFI_PHYSICAL_ADDRESS *Memory);
  VOID *FreePages, *GetMemoryMap;
  EFI_STATUS (*AllocatePool)(UINTN PoolType, UINTN Size, VOID **Buffer);
  EFI_STATUS (*FreePool)(VOID *Buffer);
  EFI_STATUS (*CreateEvent)(UINT32 Type, EFI_TPL Tpl, EFI_EVENT_NOTIFY Notify, VOID *Context, EFI_EVENT *Event);
  EFI_STATUS (*SetTimer)(EFI_EVENT Event, UINTN Type, UINT64 TriggerTime);
  VOID *WaitForEvent, *SignalEvent, *CloseEvent, *CheckEvent;
  EFI_STATUS (*InstallProtocolInterface)(EFI_HANDLE *Handle, EFI_GUID *Protocol, UINTN InterfaceType, VOID *Interface);
  VOID *ReinstallProtocolInterface, *UninstallProtocolInterface;
  EFI_STATUS (*HandleProtocol)(EFI_HANDLE Handle, EFI_GUID *Protocol, VOID **Interface);
  VOID *Reserved;
  EFI_STATUS (*RegisterProtocolNotify)(EFI_GUID *Protocol, EFI_EVENT Event, VOID **Registration);
  VOID *LocateHandle, *LocateDevicePath, *InstallConfigurationTable;
  EFI_STATUS (*LoadImage)(BOOLEAN BootPolicy, EFI_HANDLE Parent, EFI_DEVICE_PATH *Path, VOID *Source, UINTN SourceSize, EFI_HANDLE *Image);
  EFI_STATUS (*StartImage)(EFI_HANDLE Image, UINTN *ExitDataSize, CHAR16 **ExitData);
  VOID *Exit, *UnloadImage, *ExitBootServices, *GetNextMonotonicCount, *Stall, *SetWatchdogTimer;
  VOID *ConnectController, *DisconnectController, *OpenProtocol, *CloseProtocol, *OpenProtocolInformation, *ProtocolsPerHandle;
  EFI_STATUS (*LocateHandleBuffer)(UINTN SearchType, EFI_GUID *Protocol, VOID *SearchKey, UINTN *Count, EFI_HANDLE **Buffer);
  EFI_STATUS (*LocateProtocol)(EFI_GUID *Protocol, VOID *Registration, VOID **Interface);
  VOID *InstallMultipleProtocolInterfaces, *UninstallMultipleProtocolInterfaces, *CalculateCrc32, *CopyMem, *SetMem;
  EFI_STATUS (*CreateEventEx)(UINT32 Type, EFI_TPL Tpl, EFI_EVENT_NOTIFY Notify, const VOID *Context, const EFI_GUID *Group, EFI_EVENT *Event);
} EFI_BOOT_SERVICES;

typedef struct {
  EFI_TABLE_HEADER Hdr;
  VOID *GetTime, *SetTime, *GetWakeupTime, *SetWakeupTime, *SetVirtualAddressMap, *ConvertPointer;
  EFI_STATUS (*GetVariable)(CHAR16 *Name, EFI_GUID *Vendor, UINT32 *Attributes, UINTN *Size, VOID *Data);
  VOID *GetNextVariableName;
  EFI_STATUS (*SetVariable)(CHAR16 *Name, EFI_GUID *Vendor, UINT32 Attributes, UINTN Size, VOID *Data);
} EFI_RUNTIME_SERVICES;

typedef struct {
  EFI_TABLE_HEADER Hdr;
  CHAR16 *FirmwareVendor;
  UINT32 FirmwareRevision;
  EFI_HANDLE ConsoleInHandle;
  VOID *ConIn;
  EFI_HANDLE ConsoleOutHandle;
  VOID *ConOut;
  EFI_HANDLE StandardErrorHandle;
  VOID *StdErr;
  EFI_RUNTIME_SERVICES *RuntimeServices;
  EFI_BOOT_SERVICES *BootServices;
} EFI_SYSTEM_TABLE;

typedef struct {
  UINT32 Revision;
  EFI_HANDLE ParentHandle;
  EFI_SYSTEM_TABLE *SystemTable;
  EFI_HANDLE DeviceHandle;
} EFI_LOADED_IMAGE;

// Graphics output protocol
enum { PixelRedGreenBlueReserved8BitPerColor, PixelBlueGreenRedReserved8BitPerColor, PixelBitMask, PixelBltOnly };
enum { EfiBltVideoFill, EfiBltVideoToBltBuffer, EfiBltBufferToVideo, EfiBltVideoToVideo };

typedef struct {
  UINT32 Version, HorizontalResolution, VerticalResolution, PixelFormat;
  UINT32 RedMask, GreenMask, BlueMask, ReservedMask;
  UINT32 PixelsPerScanLine;
} EFI_GOP_MODE_INFO;

typedef struct {
  UINT32 MaxMode, Mode;
  EFI_GOP_MODE_INFO *Info;
  UINTN SizeOfInfo;
  EFI_PHYSICAL_ADDRESS FrameBufferBase;
  UINTN FrameBufferSize;
} EFI_GOP_MODE;

typedef struct EFI_GOP EFI_GOP;
typedef EFI_STATUS (*EFI_GOP_QUERY_MODE)(EFI_GOP *, UINT32, UINTN *, EFI_GOP_MODE_INFO **);
typedef EFI_STATUS (*EFI_GOP_SET_MODE)(EFI_GOP *, UINT32);
typedef EFI_STATUS (*EFI_GOP_BLT)(EFI_GOP *, UINT32 *, UINTN, UINTN, UINTN, UINTN, UINTN, UINTN, UINTN, UINTN);
struct EFI_GOP {
  EFI_GOP_QUERY_MODE QueryMode;
  EFI_GOP_SET_MODE SetMode;
  EFI_GOP_BLT Blt;
  EFI_GOP_MODE *Mode;
};

// Freestanding: clang may still emit calls to these
static inline VOID *Copy(VOID *dst, const VOID *src, UINTN n) {
  UINT8 *d = dst;
  const UINT8 *s = src;
  if (d < s) { while (n--) *d++ = *s++; } else { d += n; s += n; while (n--) *--d = *--s; }
  return dst;
}
VOID *memcpy(VOID *d, const VOID *s, UINTN n) { return Copy(d, s, n); }
VOID *memmove(VOID *d, const VOID *s, UINTN n) { return Copy(d, s, n); }
VOID *memset(VOID *d, int c, UINTN n) { UINT8 *p = d; while (n--) *p++ = (UINT8)c; return d; }
