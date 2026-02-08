# AIC8800D80 Reverse Engineering Results

## How the Windows Driver Chain Works

```
┌─────────────────────────────────────────────────────────────┐
│ STAGE 0: Device plugged in as Mass Storage (VID:PID 1111:1111)
│          Shows as USBSTOR\CDROM with REV_2.30              │
└──────────────────────┬──────────────────────────────────────┘
                       │
    ┌──────────────────▼──────────────────────┐
    │ AicWifiService.exe (Delphi Windows Svc) │
    │  1. Loads Usb_Driver.dll                │
    │  2. UKeySCListDevs() → find USBSTOR dev │
    │  3. UniSCConnectDev() → open device     │
    │  4. Set_CS1_0() or SendCMD()            │
    │     → IOCTL_SCSI_PASS_THROUGH (0x4D004) │
    │     → Sends vendor SCSI CDB to device   │
    │  5. EjectUSB()                          │
    │  6. devcon.exe rescan                   │
    └──────────────────┬──────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│ STAGE 1: Device re-enumerates as A69C:8D80                  │
│          aicloadfw.sys binds (WDF kernel driver)            │
│          Loads firmware via USB vendor control transfers     │
│          Writes memory blocks to chip addresses             │
│          "DBG: FW started"                                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│ STAGE 2: Device re-enumerates as A69C:8D81 or A69C:8D83    │
│          3 USB interfaces: BT HCI + BT SCO + WLAN(0xFF)    │
│          aicusbwifi.sys binds → WiFi works                  │
│          Endpoints: EP1/EP2/EP4 bulk for WLAN               │
│                     EP3/EP4 for BT                          │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Discovery: The Mode-Switch Mechanism

**`Usb_Driver.dll`** (from the "hippo_lib" project) is the smoking gun:

| Finding | Detail |
|---------|--------|
| **Method** | `IOCTL_SCSI_PASS_THROUGH` (0x0004D004) via `DeviceIoControl` |
| **NOT WinUSB** | Does NOT use USB control transfers directly |
| **Device matching** | Finds USBSTOR\CDROM devices with revision `REV_2.30` |
| **Key export** | `SendCMD` — sends the SCSI command |
| **Key export** | `Set_CS1_0` — the actual mode-switch trigger |
| **Device access** | Opens via `\\.\A:` drive letter or `\\?\USBSTOR#CDROM` path |

The mode switch is a **vendor-specific SCSI command** sent through the mass storage interface — NOT a USB control transfer. The device needs a **specific SCSI CDB** (Command Descriptor Block), not a generic eject.

---

## The Exact Mode-Switch SCSI Command

### Binary Analysis of Usb_Driver.dll

The `Set_CS1_0` function at RVA 0x43A0 (file offset 0x37A0) sends a **16-byte vendor-specific SCSI CDB** via `IOCTL_SCSI_PASS_THROUGH` (0x0004D004):

### Mode-Switch CDB (Command Descriptor Block) — 16 bytes

```
FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
```

| Byte | Value | Meaning |
|------|-------|---------|
| 0 | `0xFD` | Vendor-specific SCSI opcode (range 0xC0-0xFF) |
| 1-14 | `0x00` | All zeros (reserved/padding) |
| 15 | `0xF2` | Sub-command identifier for mode switch |

### SCSI_PASS_THROUGH Structure Parameters

| Field | Value | Notes |
|-------|-------|-------|
| Length | 0x2C (44) | sizeof(SCSI_PASS_THROUGH) for 32-bit |
| PathId | 0 | |
| TargetId | 0 | |
| Lun | 0 | |
| CdbLength | 0x10 (16) | 16-byte CDB |
| SenseInfoLength | 0x18 (24) | 24-byte sense buffer |
| DataIn | 0 | SCSI_IOCTL_DATA_OUT (no data phase) |
| DataTransferLength | 0 | No data transferred |
| TimeoutValue | 20 | 20 seconds |
| DataBufferOffset | 0x50 | |
| SenseInfoOffset | 0x30 | |

### Call Chain (from binary analysis)

1. **`Set_CS1_0(handle)`** at file offset `0x37A0`:
   - Allocates 16-byte CDB on stack
   - Zeros it with `xorps xmm0,xmm0` + `movaps`
   - Sets `CDB[0] = 0xFD`, `CDB[15] = 0xF2`
   - Calls `SendCMD` with DataIn=0, DataLen=0, timeout=20

2. **`SendCMD`** at file offset `0x3820`:
   - Wraps the inner SCSI function with retry logic
   - Up to 3 retries with 150ms delay on transient errors
   - Passes parameters via `__thiscall` convention (ecx=handle, edx=CDB ptr)

3. **Inner SCSI function** at file offset `0x1D80` (RVA 0x2980):
   - Builds a `SCSI_PASS_THROUGH` structure on the stack (592-byte buffer)
   - Copies the 16-byte CDB into `SPT.Cdb[16]` using `movups` (SSE copy)
   - Calls `DeviceIoControl(hDevice, 0x0004D004, spt, 0x250, spt, data_len+0x50, &bytes, NULL)`
   - Checks `ScsiStatus == 0` for success

### Second Command: GetHippo (Device Query)

The `GetHippo` function at RVA 0x43E0 (file offset 0x37E0) sends a status query:

```
FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F3
```

- Same opcode `0xFD`, but sub-command `0xF3` instead of `0xF2`
- Direction: `SCSI_IOCTL_DATA_IN` (reads 5 bytes back from device)
- Likely queries device status or firmware identification

### Key Confirmation

- Only **two** call sites to `SendCMD` exist in the entire DLL (`Set_CS1_0` and `GetHippo`)
- Only **one** call site to the inner SCSI function exists (from `SendCMD`)
- No CBW/USBC bulk transfer wrappers were found — the DLL uses only Windows SCSI passthrough IOCTL
- No other vendor SCSI opcodes were found in the binary beyond `0xFD`

---

## Linux Solution

### Option 1: sg_raw (Direct SCSI command — simplest)

```bash
# Bind to usb-storage first if needed:
echo "1-1.3:1.0" | sudo tee /sys/bus/usb/drivers/usb-storage/bind
# Wait for /dev/sg0 to appear, then:
sudo sg_raw /dev/sg0 fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f2
```

### Option 2: usb_modeswitch config

Create `/etc/usb_modeswitch.d/1111:1111`:
```
DefaultVendor=0x1111
DefaultProduct=0x1111
TargetVendor=0xa69c
TargetProduct=0x8d80
MessageContent="55534243123456780000000000001000fd000000000000000000000000000000f200000000000000000000000000000000"
```

The MessageContent wraps the CDB in a 31-byte CBW (Command Block Wrapper):
```
Bytes  0-3:  55534243          (USBC signature)
Bytes  4-7:  12345678          (Tag — arbitrary)
Bytes  8-11: 00000000          (DataTransferLength = 0)
Byte   12:   00                (Flags = OUT)
Byte   13:   00                (LUN = 0)
Byte   14:   10                (CBLength = 16)
Bytes 15-30: fd00...00f2       (The 16-byte CDB)
```

### Option 3: Python with pyusb (bulk endpoint)

```python
import usb.core, struct

dev = usb.core.find(idVendor=0x1111, idProduct=0x1111)
if dev:
    dev.set_configuration()
    cdb = bytes([0xFD] + [0]*14 + [0xF2])
    cbw = struct.pack('<4sIIBBB', b'USBC', 0x12345678, 0, 0x00, 0, 16) + cdb
    dev.write(0x01, cbw)  # Send CBW to bulk OUT endpoint
```

### After mode-switch succeeds

Device re-enumerates as `A69C:8D80`. Then the existing Linux `aic_load_fw` + `aic8800_fdrv` DKMS driver handles Stages 1 to 2 automatically (firmware load, then WiFi+BT operational).

---

## Confirmed Working

### Test Results on Raspberry Pi 3

**Mode-switch: SUCCESS**

```
$ sudo sg_raw /dev/sg0 fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f2
SCSI Status: Good
```

**Result:** Device re-enumerated through the full 3-stage boot:

```
Stage 0: 1111:1111 (Pandora Mass Storage)
    ↓ sg_raw FD...F2
Stage 1: a69c:8d80 (boot ROM) — aic_load_fw binds, uploads fmacfw_8800d80_u02.bin
    ↓ firmware loaded, USB soft disconnect
Stage 2: a69c:8d83 (AICSemi AIC 8800D80) — WiFi operational
```

**Driver binding note:** The `aic8800_fdrv` module has `a69c:8d83` mapped under `USB_VENDOR_ID_AIC_V2` (0x368B) only, not under `USB_VENDOR_ID_AIC` (0xA69C). The device enumerates as `a69c:8d83`, so it doesn't auto-bind without a fix.

**Runtime fix:**
```bash
sudo modprobe aic8800_fdrv
echo 'a69c 8d83' | sudo tee /sys/bus/usb/drivers/aic8800_fdrv/new_id
```

**After fix: wlan1 interface created successfully!**

```
4: wlan1: <NO-CARRIER,BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    link/ether 68:8f:c9:95:6d:a8 brd ff:ff:ff:ff:ff:ff
```

- Driver: `aic8800_fdrv` bound to `a69c:8d83`
- WiFi 6: HT + VHT + HE (802.11ax) supported
- Channels: 1-14 (2.4 GHz) + 36-165 (5 GHz)
- WiFi scan: working (SSIDs visible)

---

## USB Interface Layout (Post Mode-Switch, Operational)

**3 interfaces:**

```
Interface #0 (BT HCI):   Class=0xE0/0x01/0x01 (Bluetooth/Wireless Controller)
  EP4 IN  INTERRUPT  MaxPkt=64   — BT HCI Event
  EP1 IN  BULK       MaxPkt=512  — BT ACL RX
  EP2 OUT BULK       MaxPkt=512  — BT ACL TX

Interface #1 (BT SCO/ISO): Class=0xE0/0x01/0x01, Alt settings 0-5
  EP3 IN  ISOC  — Alt0=0, Alt1=9, Alt2=17, Alt3=25, Alt4=33, Alt5=49 bytes
  EP3 OUT ISOC  — matching sizes

Interface #2 (WLAN):     Class=0xFF/0xFF/0xFF (Vendor-Specific)
  EP1 OUT BULK  MaxPkt=512  — WLAN TX data
  EP2 IN  BULK  MaxPkt=512  — WLAN RX data
  EP4 OUT BULK  MaxPkt=512  — WLAN TX control/msg
```

---

## aicloadfw.sys Details (Windows Kernel Firmware Loader)

- **Format:** PE32+ (x64), 1.1 MB, WDF/KMDF kernel driver
- **PDB Path:** `E:\code\8820\WifiDriverWindows\aicloadfw\sys\x64\Debug\aicloadfw.pdb`
- **Based on:** Microsoft OSR USB-FX2 WDF sample driver

### Embedded USB Descriptors (Post-Switch Device)

| # | VID | PID | Date | Notes |
|---|-----|-----|------|-------|
| 1 | 0xA69C | 0x8801 | 2019-02-27 | Older/alternate chip variant |
| 2 | 0xA69C | 0x8D81 | 2022-01-03 | Newer chip variant |
| 3 | 0xA69C | 0x8D81 | 2022-01-03 | "AIC 8800D80" string descriptor |

### Firmware Loading Protocol

- Uses USB vendor control transfers: `UAUD VENDOR REQ: idx=0x%04x val=0x%04x req=0x%02x type=0x%02x len=%u`
- Writes memory blocks: `Writing memory block [0x%08x ~ 0x%08x]`
- BT firmware: `rwnx_plat_bt_load_adid`, `rwnx_plat_bt_load_patch`, `fw_patch_table_upload`
- Lifecycle: `fw stop` → `driver start` → `Start app: %08x` → `DBG: FW started`
- USB soft disconnect: `usb sftdiscon delay %d`
- VID/PID read at runtime: `get vid %x, pid %x`

### Chip Register Addresses

```
0x40320500 - 0x40320560  (WLAN MAC/Baseband registers)
0x40328528 - 0x4032853c  (RF/calibration registers)
0x40343004              (System/power register)
0x40500020              (VID/PID config)
0x40700000              (VID/PID config)
```
