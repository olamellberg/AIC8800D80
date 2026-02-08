# Windows Driver Analysis

Analysis of the Windows driver components for the AIC8800D80 USB WiFi adapter.

## NSIS Installer

- **Size:** ~2.6 MB
- **Format:** NSIS (Nullsoft Scriptable Install System)
- **Contents:**
  - `$PLUGINSDIR/` — NSIS plugins (nsDialogs, nsExec, System), DPInst32/64, DevManView
  - `driversfiles/` — win10_x64, win10_x86, win7_x64, win7_x86 (aicloadfw + aicusbwifi)
  - `tool/` — AicWifiService.exe, devcon.exe, DevManView.exe, Phys.exe, Usb_Driver.dll

---

## Usb_Driver.dll

The critical component that performs the USB mode switch.

| Property | Value |
|----------|-------|
| **Format** | PE32 (32-bit x86), ~1.9 MB |
| **PDB Path** | `E:\project\hippo_lib\Usb_Driver\bin\Win32\Release\Usb_Driver.pdb` |
| **Project** | "hippo_lib" |

### Exported Functions

| Export | RVA | Purpose |
|--------|-----|---------|
| `GetHippo` | 0x000043E0 | Device status query (SCSI opcode FD, sub-command F3) |
| `SendCMD` | 0x00004420 | Sends SCSI command via DeviceIoControl with retry logic |
| `Set_CS1_0` | 0x000043A0 | **Mode-switch trigger** (SCSI opcode FD, sub-command F2) |
| `UKeySCListDevs` | 0x00003FF0 | Enumerates USB storage devices |
| `UniSCConnectDev` | 0x00003FC0 | Connects to a specific USB device |

### Device Discovery

The DLL finds the target device by scanning for USB storage devices:

- Enumerates `\\?\USBSTOR#CDROM` and `\\?\USBSTOR#DISK` device interfaces
- Matches devices with revision string `REV_2.30`
- Opens via drive letter (`\\.\A:`) or device interface path
- Accesses `SYSTEM\MountedDevices` registry key for drive letter mapping

### Device Interface GUIDs Used

| GUID | Interface |
|------|-----------|
| `{53F56307-B6BF-11D0-94F2-00A0C91EFB8B}` | GUID_DEVINTERFACE_DISK |
| `{53F56308-B6BF-11D0-94F2-00A0C91EFB8B}` | GUID_DEVINTERFACE_CDROM |

### Win32 API Imports (Key)

**File/Device I/O:**
- `CreateFileA`, `CreateFileW` — Open device handle
- `DeviceIoControl` — Send SCSI pass-through IOCTL
- `ReadFile`, `WriteFile` — Data transfer

**Device Enumeration:**
- `SetupDiGetClassDevsA` — Enumerate device classes
- `SetupDiEnumDeviceInterfaces` — Iterate interfaces
- `SetupDiGetDeviceInterfaceDetailA` — Get device path

**NOT imported:** `WinUsb_*`, `GetOverlappedResult`, `CancelIo`
(Synchronous SCSI pass-through only, no WinUSB)

### SCSI Pass-Through Details

Uses `IOCTL_SCSI_PASS_THROUGH` (0x0004D004) with:
- 592-byte buffer for SCSI_PASS_THROUGH structure
- 16-byte CDB copied via SSE `movups` instruction
- Synchronous operation (no overlapped I/O)
- Checks `ScsiStatus == 0` for success

---

## AicWifiService.exe

The Windows service that orchestrates the mode switch.

| Property | Value |
|----------|-------|
| **Format** | Borland Delphi Windows Service, ~433 KB |
| **Service Name** | `AicWifiService` |
| **Code Signing** | GlobalSign EV CodeSigning, Shenzhen, Guangdong (China) |

### Operational Flow

1. Runs as Windows Service named `AicWifiService`
2. Loads `Usb_Driver.dll` and calls `UKeySCListDevs` to enumerate USB devices
3. Connects to the AIC8800D80 via `UniSCConnectDev` (SCSI pass-through to USB CDROM)
4. Calls `Set_CS1_0()` to send the mode-switch SCSI command
5. Ejects the USB storage device via `EjectUSB` function
6. Runs `devcon.exe rescan` to re-enumerate USB hardware
7. Copies driver INF files to system directories
8. Uses IP Helper APIs to verify the network adapter is functioning

### Key Functions

| Function | Purpose |
|----------|---------|
| `EjectUSB` | Ejects the USB CD-ROM/storage device |
| `CopyInfToAppDir` | Copies driver INF to application directory |
| `CopyInfToInfDir` | Copies driver INF to Windows INF directory |
| `tmr1Timer` | Timer 1 — periodic USB device check |
| `tmr2Timer` | Timer 2 — secondary periodic task |

---

## aicloadfw.sys (Firmware Loader Kernel Driver)

| Property | Value |
|----------|-------|
| **Format** | PE32+ (x64), ~1.1 MB, WDF/KMDF kernel driver |
| **PDB Path** | `E:\code\8820\WifiDriverWindows\aicloadfw\sys\x64\Debug\aicloadfw.pdb` |
| **Source Files** | `device.c`, `Driver.c` |
| **Based On** | Microsoft OSR USB-FX2 WDF sample driver |

### Target Device

- `USB\VID_A69C&PID_8d80` only (boot ROM mode, after mode-switch)
- Does NOT target `1111:1111` — mode switch must happen before this driver binds

### AIC Bluetooth Firmware Structures

```
AICBT_PT_TAG       — Patch Tag marker
AICBT_TRAP_T       — Trap table
AICBT_PATCH_TB4    — Patch table (type B4)
AICBT_PATCH_TAF    — Patch table (type AF)
AICBT_MODE_T       — Mode type
AICBT_POWER_ON     — Power-on marker
AICBT_VER_INFO     — Version info
AICBT_PINF_T       — Patch info type
```

---

## aicloadfw.Inf (Firmware Loader INF)

| Property | Value |
|----------|-------|
| **Class** | Aic (custom device class) |
| **ClassGUID** | {3e050da3-b774-70be-9d3c-b043ec9e6e92} |
| **Target** | `USB\VID_A69C&PID_8d80` |
| **KMDF Version** | 1.15 (Win10), 1.11 (Win7) |
| **OtaKey** | `d3ce088cfa29e92ee5b88a4ae0123c72069fc840` |

---

## aicusbwifi.Inf (WiFi NDIS Driver INF)

| Property | Value |
|----------|-------|
| **Class** | Net (802.11 Wireless) |
| **ClassGUID** | {4d36e972-e325-11ce-bfc1-08002be10318} |
| **Provider** | iGrentech |
| **Driver Version** | 6.40.60.210 (2024-08-31) |
| **OtaKey** | `da681918c11078801e432552b70bd4a95fad9b6d` |

### Supported Devices

| VID | PID | Description |
|-----|-----|-------------|
| A69C | 8801 | AIC USB WiFi |
| A69C | 8d81 | AIC8800D80 USB WiFi (MI_02) |
| A69C | 8d83 | AIC8800D80 USB WiFi |
| A69C | 88DC-88DE | AIC88DC USB WiFi |
| 368b | 8d81 | Wifi6 802.11ax USB Adapter (MI_02) |
| 368b | 8d83-8d86 | AIC8800D80 USB WiFi |
| 368b | 8d88 | UGREEN Wi-Fi 6 USB Adapter |
| 368b | 88DF | AIC88DC USB WiFi |
| 2604 | 0013-001E | Wireless LAN WIFI 6 / Tenda |
| 2604 | 001F-0020 | Tenda WiFi 6 |
| 2357 | 014E | TP-LINK |
| 2357 | 014B | MERCURY |
| 2357 | 014F | FAST |
| 2357 | 0147 | TP-LINK Wireless N |

### WiFi Modes

802.11a/b/g/n/ac/ax (full WiFi 6) — configurable via driver settings.
