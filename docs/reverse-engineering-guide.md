# Reverse Engineering Guide: USB Mode-Switch Devices

How we reverse-engineered the mode-switch command for the AIC8800D80 "Pandora" (1111:1111) adapter. This guide can help with similar devices that need a proprietary command to switch from USB mass storage to their actual function.

## Device Information

| Property | Value |
|----------|-------|
| **Model** | WIFI6-BW22 |
| **Product String** | 88M80 |
| **Manufacturer (USB)** | AIC |
| **USB VID:PID** | `1111:1111` (Pandora International Ltd. - clone ID) |
| **Chipset** | AICSEMI AIC8800D80 (Wi-Fi 6 + BT 5.3 SoC) |
| **SCSI Name** | LGX WIFI6 2.30 |
| **bcdDevice** | 10.01 |
| **USB Speed** | 480 Mbps (High-Speed USB 2.0) |

### USB Descriptors in Mass Storage Mode

```
Configuration 1:
  Interface 0:
    bInterfaceClass:    0x08 (Mass Storage)
    bInterfaceSubClass: 0x06 (SCSI Transparent)
    bInterfaceProtocol: 0x50 (Bulk-Only Transport / BBB)
    Endpoints:
      EP 0x01 OUT (Bulk) - host -> device
      EP 0x81 IN  (Bulk) - device -> host
```

---

## The Problem

The device enumerates as **USB Mass Storage** with VID:PID `1111:1111` instead of as a WiFi+Bluetooth adapter. It presents itself as a virtual CD-ROM drive ("ZeroCD") without actual media. It needs to be mode-switched to WiFi/BT mode where it re-enumerates with a different VID:PID.

### Normal AIC8800 mode-switch flow (does NOT work for this clone)

```
1. Device plugged in  →  VID a69c, PID 57xx  (Mass Storage, virtual CD)
2. usb_modeswitch -KQ -v a69c -p 57xx    (SCSI Eject)
3. Device disconnects + re-enumerates  →  VID a69c, PID 8d80  (Boot ROM)
4. aic_load_fw driver binds, loads firmware
5. Device re-enumerates  →  VID 368b, PID 8d83  (WiFi+BT mode)
6. aic8800_fdrv binds  →  wlan0 + hci0 available
```

Our clone stays stuck at step 1-2 - it ignores all standard mode-switch commands.

---

## What We Tried (ALL FAILED)

### 1. usb_modeswitch (standard SCSI)
```bash
sudo usb_modeswitch -K -v 1111 -p 1111          # StandardEject
sudo usb_modeswitch -H -v 1111 -p 1111          # Huawei-style switch
sudo usb_modeswitch -u 2 -v 1111 -p 1111        # SetConfiguration (error -5)
sudo usb_modeswitch -R -v 1111 -p 1111          # USB Reset
```
**Result:** StandardEject accepted (SCSI OK), but device does not re-enumerate. Huawei no effect. SetConfiguration error -5.

### 2. eject and sg commands
```bash
echo "1-1.3:1.0" | sudo tee /sys/bus/usb/drivers/usb-storage/bind
eject /dev/sda
sudo sg_start --stop /dev/sda
sudo sg_raw /dev/sda 01 00 00 00 00 00    # REZERO UNIT
```
**Result:** `eject` accepted but device stays. `sg_start --stop` no effect. `sg_raw 01` (REZERO) gives "Illegal Request".

### 3. USB vendor control transfers (pyusb)
```python
import usb.core
dev = usb.core.find(idVendor=0x1111, idProduct=0x1111)

# Tested requests:
dev.ctrl_transfer(0x40, 0x01, 0x0000, 0x0000, b'')  # ACCEPTED (ret=0)
dev.ctrl_transfer(0x40, 0x04, 0x0000, 0x0000, b'')  # Pipe error (STALL)
dev.ctrl_transfer(0xC0, 0x01, 0x0000, 0x0000, 64)   # Pipe error
dev.ctrl_transfer(0x40, 0x01, 0x0001, 0x0000, b'')  # TIMEOUT (10s)
dev.ctrl_transfer(0x40, 0xAA, 0x0000, 0x0000, b'')  # Pipe error
```
**Result:** Only vendor request 0x01 with wValue=0 accepted. With wValue=1 it times out (10s) - the device *tries* to do something but doesn't complete. No mode-switch after USB reset.

### 4. USB port power cycle
```bash
echo "1-1.3" | sudo tee /sys/bus/usb/drivers/usb/unbind
sleep 2
echo "1-1.3" | sudo tee /sys/bus/usb/drivers/usb/bind
```
**Result:** Device re-enumerates as same 1111:1111.

### 5. Modified AIC8800 driver (direct binding)
Modified the `aic_load_fw` driver to accept 1111:1111 and treat it as AIC8800D80.

**Result:** Driver binds successfully! But firmware upload fails with `err:-32 EPIPE` (Broken Pipe) - endpoints speak SCSI protocol, not AIC firmware protocol. The device must be mode-switched first.

---

## What Worked: Reverse Engineering the Windows Driver

### Step 1: Get the Windows Driver Package

The Windows installer (NSIS-based, ~2.6 MB) contained:
- `tool/AicWifiService.exe` - Delphi Windows service
- `tool/Usb_Driver.dll` - The mode-switch library (from "hippo_lib" project)
- `tool/devcon.exe` - Microsoft device console utility
- `driversfiles/` - INF + SYS files for multiple Windows versions

### Step 2: Analyze the DLL Exports

Using `dumpbin` or similar PE analysis tools on `Usb_Driver.dll`:

| Export | Purpose |
|--------|---------|
| `GetHippo` | Device status query |
| `SendCMD` | Sends SCSI command via DeviceIoControl |
| `Set_CS1_0` | Mode-switch trigger |
| `UKeySCListDevs` | Enumerate USB storage devices |
| `UniSCConnectDev` | Connect to specific USB device |

Key observation: The DLL imports `DeviceIoControl` but NOT `WinUsb*` functions. This means it uses **SCSI pass-through**, not direct USB control transfers.

### Step 3: Binary Analysis of Set_CS1_0

Using a disassembler (Ghidra, IDA, etc.) on the `Set_CS1_0` function at file offset 0x37A0:

1. Allocates 16-byte buffer on stack
2. Zeros it with SSE instructions (`xorps xmm0,xmm0` + `movaps`)
3. Sets byte[0] = 0xFD and byte[15] = 0xF2
4. Calls `SendCMD` which wraps `IOCTL_SCSI_PASS_THROUGH` (0x0004D004)

This gave us the exact CDB:
```
FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
```

### Step 4: Confirm on Linux

```bash
sudo sg_raw /dev/sg0 fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f2
# SCSI Status: Good
# Device immediately re-enumerates as a69c:8d80
```

---

## Methodology for Similar Devices

If you have a USB device that needs a proprietary mode-switch command:

### 1. Find the Windows Driver Package

Look for the Windows installer/driver. Common locations:
- Manufacturer website
- Virtual CD-ROM on the device itself (if accessible)
- Driver download sites (verify authenticity)

### 2. Identify the Mode-Switch Component

In the driver package, look for:
- DLLs with exports related to USB, SCSI, device control
- Services that run at startup (check INF files for service definitions)
- Executables that interact with USB devices

### 3. Analyze the Binary

Use tools like:
- **PE analysis:** `dumpbin /exports`, CFF Explorer, PE-bear
- **Strings:** Look for IOCTL codes, USB-related strings, SCSI commands
- **Disassembly:** Ghidra (free), IDA, Binary Ninja
- **USB capture:** Wireshark + USBPcap on Windows

### 4. Look for These Patterns

- **SCSI pass-through:** `DeviceIoControl` with IOCTL `0x0004D004`
- **WinUSB control transfer:** `WinUsb_ControlTransfer` calls
- **Direct USB control:** `DeviceIoControl` with `IOCTL_USB_*` codes
- **Vendor-specific SCSI opcodes:** CDB byte 0 in range 0xC0-0xFF

### 5. Test on Linux

- **SCSI commands:** `sg_raw /dev/sgX <cdb bytes>`
- **USB control transfers:** Python + pyusb `ctrl_transfer()`
- **Bulk SCSI (CBW):** `usb_modeswitch` with `MessageContent`

---

## Wireshark USB Capture (Alternative Method)

If binary analysis is too difficult, capture the USB traffic during Windows driver installation:

1. Install Wireshark with USBPcap on Windows
2. Start capture on USBPcap interface
3. Plug in the device
4. Run the Windows driver installer
5. Stop capture after device switches to WiFi mode

### Useful Wireshark Filters

```
# Filter by device address
usb.addr == "X.Y.0"

# USB Mass Storage traffic
usbms

# USB control transfers
usb.transfer_type == 0x02 && usb.endpoint_address == 0x00

# Vendor-specific SCSI commands (look for opcodes 0xC0-0xFF)
scsi.cdb.opcode >= 0xc0
```

Look for the last SCSI command or USB control transfer sent before the device disconnects and re-enumerates with a new VID:PID.

---

## References

- [AIC8800D80 Data Sheet](https://dl.radxa.com/zero3/docs/hw/3w/AIC8800D80_DataSheet_v0.1.pdf)
- [Brostrend AIC8800 DKMS driver](https://linux.brostrend.com/)
- [goecho/aic8800_linux_drvier (GitHub)](https://github.com/goecho/aic8800_linux_drvier)
- [radxa-pkg/aic8800 (GitHub)](https://github.com/radxa-pkg/aic8800)
- [morrownr/USB-WiFi Issue #680](https://github.com/morrownr/USB-WiFi/issues/680) - Fenvi AX286 AIC8800DC
- [USBPcap](https://desowin.org/usbpcap/) - USB packet capture for Windows
- [Wireshark USB capture wiki](https://wiki.wireshark.org/CaptureSetup/USB)
