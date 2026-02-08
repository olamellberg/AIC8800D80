# AIC8800D80 USB WiFi 6 Adapter - Linux Mode-Switch Fix

Get cheap AIC8800D80-based USB WiFi 6 adapters (sold as "WIFI6-BW22", "88M80", etc.) working on Linux.

These adapters use a clone VID:PID `1111:1111` ("Pandora") and show up as a fake CD-ROM drive instead of a WiFi adapter. They need a **vendor-specific SCSI command** to switch to WiFi mode - a command that was undocumented until this project reverse-engineered it from the Windows driver.

## Quick Start (Linux)

### Automated Install

```bash
git clone https://github.com/olamellberg/AIC8800D80.git
cd AIC8800D80/linux
sudo bash install.sh
```

This installs everything needed: usb_modeswitch config, udev rule, and driver VID:PID fix.

### Manual Steps

**1. Mode-switch the device** (one-time test):

```bash
# Install prerequisites
sudo apt install sg3-utils usb-modeswitch

# Bind the device to usb-storage (if not already bound)
# Replace 1-1.3:1.0 with your device's USB path (check dmesg)
echo "1-1.3:1.0" | sudo tee /sys/bus/usb/drivers/usb-storage/bind

# Send the mode-switch command
sudo sg_raw /dev/sg0 fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f2
```

The device will disconnect and re-enumerate through 3 stages:

```
Stage 0: 1111:1111 (Pandora - Mass Storage / fake CD-ROM)
    | sg_raw FD...F2
Stage 1: a69c:8d80 (Boot ROM) --> aic_load_fw uploads firmware
    | firmware loaded, USB soft disconnect
Stage 2: a69c:8d83 (WiFi + Bluetooth operational)
```

**2. Bind the WiFi driver:**

```bash
sudo modprobe aic8800_fdrv
echo 'a69c 8d83' | sudo tee /sys/bus/usb/drivers/aic8800_fdrv/new_id
```

**3. Verify:**

```bash
ip link show wlan1    # Should show the new WiFi interface
sudo iw wlan1 scan    # Should list nearby networks
```

### Make It Persistent (Across Reboots)

Copy the config files from this repo:

```bash
# usb_modeswitch config - auto mode-switch on plug-in
sudo cp linux/usb_modeswitch/1111:1111 /etc/usb_modeswitch.d/

# udev rule - triggers mode-switch automatically
sudo cp linux/udev/41-aic8800d80-modeswitch.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules

# Driver VID:PID fix (if using DKMS aic8800 driver)
# See linux/patches/ for the kernel driver patch
```

## The Mode-Switch Command

The key discovery: the device requires a **16-byte vendor-specific SCSI CDB** (Command Descriptor Block) sent via SCSI pass-through:

```
FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
```

| Byte | Value | Meaning |
|------|-------|---------|
| 0 | `0xFD` | Vendor-specific SCSI opcode |
| 1-14 | `0x00` | Reserved (all zeros) |
| 15 | `0xF2` | Sub-command: trigger mode switch |

This was extracted by reverse-engineering `Usb_Driver.dll` from the Windows driver package. The `Set_CS1_0` function builds this CDB and sends it via `IOCTL_SCSI_PASS_THROUGH`. Standard SCSI eject commands do **not** work - only this specific vendor command triggers the mode switch.

See [docs/reverse-engineering-results.md](docs/reverse-engineering-results.md) for the full technical details.

## Background

### The Problem

Many cheap AIC8800D80 WiFi 6 USB adapters from Chinese OEMs use the clone VID:PID `1111:1111` (registered to "Pandora International Ltd") instead of the real AIC VID. When plugged in, they appear as a USB Mass Storage device (virtual CD-ROM, "ZeroCD") rather than a WiFi adapter.

On Windows, a background service (`AicWifiService.exe`) automatically sends the proprietary mode-switch command. On Linux, `usb_modeswitch` doesn't have a config for `1111:1111` because the command was undocumented.

### What Didn't Work

Before finding the correct command, we tried:
- `usb_modeswitch -K` (StandardEject) - accepted but no mode switch
- `usb_modeswitch -H` (Huawei-style) - no effect
- `eject /dev/sda` - accepted but device stays in storage mode
- USB vendor control transfers (pyusb) - request 0x01 accepted but no switch
- Direct `aic_load_fw` driver binding - binds but firmware upload fails (EPIPE)
- Various SCSI commands (REZERO, START STOP UNIT) - rejected

The device specifically requires SCSI opcode `0xFD` with byte 15 set to `0xF2`.

### Device Identification

| Property | Value |
|----------|-------|
| **Chipset** | AICSEMI AIC8800D80 (Wi-Fi 6 + BT 5.3 SoC) |
| **USB VID:PID** | `1111:1111` (clone ID, "Pandora International Ltd") |
| **SCSI Name** | LGX WIFI6 2.30 |
| **Product String** | 88M80 |
| **Marketed As** | WIFI6-BW22, various no-name brands |
| **USB Speed** | 480 Mbps (High-Speed USB 2.0) |

### Post Mode-Switch VID:PIDs

| Stage | VID:PID | Purpose |
|-------|---------|---------|
| 0 (Storage) | `1111:1111` | Fake CD-ROM, needs mode-switch |
| 1 (Boot ROM) | `a69c:8d80` | Firmware loader (`aic_load_fw`) binds |
| 2 (Operational) | `a69c:8d83` | WiFi + BT adapter (`aic8800_fdrv`) binds |

### Known Affected Adapters

If your adapter shows `1111:1111` in `lsusb` and the SCSI name includes "WIFI6" or "LGX", this fix likely applies. Known marketing names include:
- WIFI6-BW22
- 88M80
- Various AliExpress/Amazon "WiFi 6 USB Adapter" listings

### Compatible Linux Drivers

The AIC8800 DKMS driver is required. Known sources:
- [Brostrend AIC8800 DKMS](https://linux.brostrend.com/) (recommended)
- [goecho/aic8800_linux_drvier](https://github.com/goecho/aic8800_linux_drvier)
- [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800)

## Repo Structure

```
AIC8800D80/
├── README.md                          # This file
├── LICENSE                            # MIT
├── linux/
│   ├── install.sh                     # Automated install script
│   ├── usb_modeswitch/
│   │   └── 1111_1111                  # usb_modeswitch config (install as 1111:1111)
│   ├── udev/
│   │   └── 41-aic8800d80-modeswitch.rules  # udev rule
│   └── patches/
│       └── aic8800_fdrv-add-a69c-8d83.patch # Driver VID:PID patch
├── docs/
│   ├── reverse-engineering-results.md # Full RE findings
│   ├── reverse-engineering-guide.md   # How to RE similar devices
│   └── windows-driver-analysis.md     # Windows DLL/driver analysis
└── windows/
    └── INF/
        ├── aicloadfw.Inf              # Reference: firmware loader INF
        └── aicusbwifi.Inf             # Reference: WiFi driver INF
```

## Tested On

- **Raspberry Pi 3** running Raspberry Pi OS (Debian-based), kernel 6.x, with Brostrend AIC8800 DKMS v1.0.8
- WiFi scan confirmed working, 802.11ax (WiFi 6) supported
- Both 2.4 GHz and 5 GHz bands operational

## Contributing

If you have an AIC8800D80 adapter with a different VID:PID or marketing name, please open an issue with:
- Output of `lsusb` (before and after mode-switch)
- Output of `lsusb -d 1111:1111 -v` (or your device's VID:PID)
- Your adapter's marketing name and where you bought it

## License

[MIT](LICENSE) - The reverse engineering findings, configuration files, and scripts in this repository are freely available. Windows INF files in `windows/` are included as text reference only and remain property of their respective copyright holders.

## Acknowledgments

- The AIC8800D80 Linux driver is maintained by AICSEMI and community contributors
- [Brostrend](https://linux.brostrend.com/) for packaging the DKMS driver
- The `usb_modeswitch` project for the mode-switching framework
