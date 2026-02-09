# AIC8800D80 USB WiFi 6 + Bluetooth 5.3 Adapter - Linux Support

Get cheap AIC8800D80-based USB WiFi 6 + Bluetooth adapters (sold as "WIFI6-BW22", "88M80", etc.) working on Linux.

These adapters use a clone VID:PID `1111:1111` ("Pandora") and show up as a fake CD-ROM drive instead of a WiFi/BT adapter. They need a **vendor-specific SCSI command** to switch to operational mode - a command that was undocumented until this project reverse-engineered it from the Windows driver.

## Quick Start (Linux)

### Automated Install

```bash
git clone https://github.com/olamellberg/AIC8800D80.git
cd AIC8800D80/linux
sudo bash install.sh
```

This installs everything needed: usb_modeswitch config, udev rules, driver VID:PID fixes, Bluetooth driver patches, and btusb conflict resolution.

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
Stage 1: a69c:8d80 (Boot ROM) --> aic_load_fw uploads WiFi + BT firmware
    | firmware loaded, USB soft disconnect
Stage 2: a69c:8d81 (WiFi + Bluetooth operational, Radxa firmware)
         a69c:8d83 (WiFi only, Brostrend firmware without BT patches)
```

**2. Bind the WiFi driver:**

```bash
sudo modprobe aic8800_fdrv
echo 'a69c 8d83' | sudo tee /sys/bus/usb/drivers/aic8800_fdrv/new_id
```

**3. Bind the Bluetooth driver:**

```bash
sudo modprobe aic_btusb
echo 'a69c 8d83' | sudo tee /sys/bus/usb/drivers/aic_btusb/new_id
```

**4. Verify:**

```bash
# WiFi
ip link show wlan1    # Should show the new WiFi interface
sudo iw wlan1 scan    # Should list nearby networks

# Bluetooth
bluetoothctl show     # Should show the BT controller
bluetoothctl scan on  # Should find nearby BT devices
```

### Make It Persistent (Across Reboots)

Copy the config files from this repo:

```bash
# usb_modeswitch config - auto mode-switch on plug-in
sudo cp linux/usb_modeswitch/1111:1111 /etc/usb_modeswitch.d/

# udev rules - triggers mode-switch and driver binding automatically
sudo cp linux/udev/41-aic8800d80-modeswitch.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules

# modprobe config - prevents generic btusb from stealing the BT interface
sudo cp linux/modprobe/aic8800-bt.conf /etc/modprobe.d/

# Driver VID:PID fixes (if using DKMS aic8800 driver)
# See linux/patches/ for the kernel driver patches
```

## Bluetooth Support

### The Problem

After mode-switching, the AIC8800D80 exposes a standard Bluetooth USB interface (class `0xE0/0x01/0x01`). Linux's built-in `btusb` driver sees this and claims it, but doesn't know how to initialize the AIC8800 Bluetooth controller. This causes:

```
Bluetooth: hci0: Opcode 0x0c03 failed: -110
```

(HCI_Reset command timeout)

### The Solution

The AIC8800D80 requires **two** drivers working together for Bluetooth:

1. **`aic_load_fw`** - Loads the BT firmware patches during initial firmware upload (8d80 boot ROM stage). This is critical: the Brostrend DKMS package has BT patch loading **disabled** with `#if 0` blocks. You need the [Radxa](https://github.com/radxa-pkg/aic8800) version of `aic_compat_8800d80.c` which enables BT.

2. **`aic_btusb`** - The BT HCI driver that registers the Bluetooth controller with BlueZ. It does NOT load firmware for D80 (unlike the DC variant) - `aic_load_fw` handles that.

Three fixes are needed:

1. **`aic_load_fw` BT patch loading** - Replace the Brostrend `aic_compat_8800d80.c` with the Radxa version and rebuild DKMS. Without this, the device enumerates as `a69c:8d83` (WiFi only, no BT interfaces). With the fix, it enumerates as `a69c:8d81` (WiFi + BT, 3 interfaces).

2. **CONFIG_BLUEDROID fix** - The `aic_btusb` driver defaults to Android's BlueDroid stack (`CONFIG_BLUEDROID=1`). On desktop Linux, this must be set to `0` to use BlueZ.

3. **btusb conflict** - The generic `btusb` module must be prevented from claiming the device before `aic_btusb` can bind.

The `install.sh` script handles fixes 2-3. Fix 1 requires patching the DKMS source.

### Patching aic_load_fw for BT Support

If using the Brostrend DKMS driver, BT patch loading is disabled. To fix:

```bash
# Find your DKMS source
ls /usr/src/aic8800-*/aic_load_fw/aic_compat_8800d80.c

# Clone the Radxa source for the fixed file
git clone --depth 1 --filter=blob:none --sparse https://github.com/radxa-pkg/aic8800.git /tmp/radxa-aic
cd /tmp/radxa-aic && git sparse-checkout set src/USB/driver_fw/driver/aic_load_fw

# Replace the file (adjust version as needed)
sudo cp /tmp/radxa-aic/src/USB/driver_fw/driver/aic_load_fw/aic_compat_8800d80.c \
    /usr/src/aic8800-1.0.8/aic_load_fw/aic_compat_8800d80.c

# Rebuild DKMS (CRITICAL - the module won't update without this!)
sudo dkms remove aic8800/1.0.8 -k $(uname -r)
sudo dkms build aic8800/1.0.8 -k $(uname -r)
sudo dkms install aic8800/1.0.8 -k $(uname -r) --force

# Verify BT firmware strings are in the rebuilt module
xz -dc /lib/modules/$(uname -r)/updates/dkms/aic_load_fw.ko.xz | strings | grep fw_adid_8800d80
# Should show: fw_adid_8800d80_u02.bin
```

### Building aic_btusb from Source

If your DKMS driver package doesn't include `aic_btusb`, use the automated build script:

```bash
sudo bash linux/build-aic-btusb.sh
```

Or build manually from the [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) repo:

```bash
git clone --recurse-submodules https://github.com/radxa-pkg/aic8800.git
cd aic8800/src/USB/driver_fw/drivers/aic_btusb

# Apply the BlueZ fix before building
sed -i 's/BLUEDROID        1/BLUEDROID        0/g' aic_btusb.h

# Build and install
make KDIR=/lib/modules/$(uname -r)/build CONFIG_PLATFORM_UBUNTU=y
sudo cp aic_btusb.ko /lib/modules/$(uname -r)/kernel/drivers/bluetooth/
sudo depmod -a
```

### Troubleshooting Bluetooth

| Symptom | Cause | Fix |
|---------|-------|-----|
| Device shows as `a69c:8d83` with 1 interface | `aic_load_fw` doesn't have BT patches enabled | Patch `aic_compat_8800d80.c` with Radxa version, rebuild DKMS |
| `bluetoothctl show` shows nothing | `aic_btusb` not loaded or `CONFIG_BLUEDROID=1` | Rebuild with `CONFIG_BLUEDROID=0`, run `sudo modprobe aic_btusb` |
| `Opcode 0x0c03 failed: -110` | Generic `btusb` claimed the device | `sudo rmmod btusb && sudo modprobe aic_btusb` |
| `Operation not possible due to RF-kill` | RF-kill blocking BT | `sudo rfkill unblock bluetooth && sudo hciconfig hci1 up` |
| `/dev/rtk_btusb` appears instead of `hci0` | `CONFIG_BLUEDROID=1` (Android mode) | Rebuild with `CONFIG_BLUEDROID=0` |

Check driver binding status:
```bash
sudo dmesg | grep -i 'btusb\|aic_btusb\|hci\|bluetooth'
lsmod | grep bt
lsusb -t    # Shows which driver is bound to each interface
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

### Post Mode-Switch USB Interfaces

| Stage | VID:PID | Purpose |
|-------|---------|---------|
| 0 (Storage) | `1111:1111` | Fake CD-ROM, needs mode-switch |
| 1 (Boot ROM) | `a69c:8d80` | Firmware loader (`aic_load_fw`) binds |
| 2 (Operational) | `a69c:8d83` | WiFi + BT composite device |

Stage 2 USB composite device interfaces:

| Interface | Class | Purpose | Driver |
|-----------|-------|---------|--------|
| 0 | `0xE0/0x01/0x01` | Bluetooth HCI | `aic_btusb` |
| 1 | Isochronous | Bluetooth SCO/Audio | `aic_btusb` |
| 2 | `0xFF/0xFF/0xFF` | WiFi (vendor-specific) | `aic8800_fdrv` |

### Known Affected Adapters

If your adapter shows `1111:1111` in `lsusb` and the SCSI name includes "WIFI6" or "LGX", this fix likely applies. Known marketing names include:
- WIFI6-BW22
- 88M80
- Various AliExpress/Amazon "WiFi 6 USB Adapter" listings

### Compatible Linux Drivers

The AIC8800 DKMS driver is required. Known sources:
- [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) (recommended - includes WiFi + Bluetooth)
- [Brostrend AIC8800 DKMS](https://linux.brostrend.com/)
- [goecho/aic8800_linux_drvier](https://github.com/goecho/aic8800_linux_drvier)

## Repo Structure

```
AIC8800D80/
├── README.md                          # This file
├── LICENSE                            # MIT
├── linux/
│   ├── install.sh                     # Automated install script (WiFi + BT)
│   ├── build-aic-btusb.sh            # Build aic_btusb from radxa source
│   ├── usb_modeswitch/
│   │   └── 1111_1111                  # usb_modeswitch config (install as 1111:1111)
│   ├── udev/
│   │   └── 41-aic8800d80-modeswitch.rules  # udev rules (mode-switch + driver binding)
│   ├── modprobe/
│   │   └── aic8800-bt.conf            # Prevent generic btusb from claiming AIC device
│   └── patches/
│       ├── aic8800_fdrv-add-a69c-8d83.patch # WiFi driver VID:PID patch
│       ├── aic_btusb-use-bluez.patch        # BT driver: BlueDroid -> BlueZ
│       └── aic_btusb-add-a69c-8d83.patch    # BT driver VID:PID patch
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

- **Raspberry Pi 3** running Raspberry Pi OS (Debian-based), kernel 6.12, with Brostrend AIC8800 DKMS v1.0.8 (patched with Radxa BT support)
- **WiFi**: Working - 802.11ax (WiFi 6), both 2.4 GHz and 5 GHz bands
- **Bluetooth 5.3**: Working - `bluetoothctl` sees controller, BLE advertising, central/peripheral roles
  - BD Address assigned, HCI UP RUNNING, 16 advertising instances
  - Requires patched `aic_load_fw` (Radxa `aic_compat_8800d80.c`) + `aic_btusb` with `CONFIG_BLUEDROID=0`

## Contributing

If you have an AIC8800D80 adapter with a different VID:PID or marketing name, please open an issue with:
- Output of `lsusb` (before and after mode-switch)
- Output of `lsusb -d 1111:1111 -v` (or your device's VID:PID)
- Your adapter's marketing name and where you bought it

## License

[MIT](LICENSE) - The reverse engineering findings, configuration files, and scripts in this repository are freely available. Windows INF files in `windows/` are included as text reference only and remain property of their respective copyright holders.

## Acknowledgments

- The AIC8800D80 Linux driver is maintained by AICSEMI and community contributors
- [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) for the comprehensive driver package with Bluetooth fixes
- [Brostrend](https://linux.brostrend.com/) for packaging the DKMS driver
- The `usb_modeswitch` project for the mode-switching framework
