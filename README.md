# AIC8800D80 / 88M80 / AX900 WiFi 6 + Bluetooth USB Adapter Driver for Linux

Linux driver and mode-switch solution for cheap AIC8800D80 / AIC8800M80 USB WiFi 6 + Bluetooth 5.3 adapters sold under names like "WIFI6-BW22", "88M80", "AX900", and many others. These adapters use a fake VID:PID `1111:1111` and appear as a CD-ROM drive instead of a WiFi adapter. This project provides the undocumented SCSI command needed to switch them into WiFi + Bluetooth mode, plus an automated installer that handles the full driver setup.

## Affected USB Adapters / Common Names

These adapters are sold under a wide range of brand names and product listings. If your device uses the AIC8800D80 or AIC8800M80 chipset, this project is for you. Known names include:

- **WIFI6-BW22** / **BW22** -- one of the most common product names on AliExpress and Amazon
- **WIFI6-BW23** / **BW23** -- variant listing, same chipset
- **AX900 WiFi 6 USB Adapter** -- frequently used in marketing titles
- **88M80** -- the USB product string reported by the device itself
- **900Mbps WiFi 6 Bluetooth Adapter** -- generic listing title used by many sellers
- **AIC8800D80** / **AIC8800M80** -- the actual chipset name (rarely shown in product listings)
- Various unbranded "WiFi 6 USB Adapter" and "WiFi 6 + Bluetooth 5.3 USB Dongle" listings on AliExpress, Amazon, Temu, Shopee, and similar marketplaces

The chipset is manufactured by AICSEMI. Sellers almost never mention the chipset name, which makes finding Linux driver support difficult.

## What Problems This Solves

If any of the following describe your situation, you are in the right place:

- **Your adapter shows up as a CD-ROM or storage device**, not as a WiFi adapter. Your file manager may pop open a window showing a virtual drive with Windows drivers on it.
- **`lsusb` shows `1111:1111`** (described as "Pandora International Ltd") instead of a real WiFi adapter VID:PID.
- **WiFi is not detected at all.** There is no `wlan` interface, `ip link` does not show the adapter, and NetworkManager cannot see it.
- **Bluetooth is missing.** `bluetoothctl show` returns nothing, or the Bluetooth controller fails with timeout errors like `Opcode 0x0c03 failed: -110`.
- **Realtek drivers do not work.** You may have tried `rtl8xxxu`, `rtl88x2bu`, or other Realtek drivers because the product listing falsely implied a Realtek chipset. This is not a Realtek device.
- **`usb_modeswitch` does not recognize the device.** The standard `usb_modeswitch` database has no entry for `1111:1111` because the mode-switch command was undocumented until this project reverse-engineered it.
- **The included "driver CD" only has Windows software.** The virtual CD-ROM the device exposes contains a Windows-only installer. There is no Linux support included with the adapter.

## How to Identify Your Adapter

### Step 1: Check lsusb

Plug in the adapter and run:

```bash
lsusb
```

If you see a line like this, your adapter is affected:

```
Bus 001 Device 005: ID 1111:1111 Pandora International Ltd
```

The VID:PID `1111:1111` is a clone/placeholder ID. It is not the real vendor ID. This is the adapter pretending to be a USB mass storage device.

### Step 2: Check the SCSI device name

Run `lsusb -d 1111:1111 -v` (may require `sudo`) and look for the product string. AIC8800D80-based adapters typically report:

```
iProduct     2 88M80
iManufacturer 1 AIC MSC
```

Or the SCSI inquiry name will show as:

```
LGX WIFI6 2.30
```

If you see `88M80`, `AIC MSC`, `aicsemi`, `LGX WIFI6`, or similar strings, your adapter uses the AIC8800D80 chipset and this project will work.

### Step 3: Check dmesg

After plugging in, run:

```bash
dmesg | tail -20
```

You will likely see the device being registered as a USB mass storage device or a SCSI disk (`/dev/sg0` or similar), not as a network adapter.

## Why This Adapter Is Hard to Support on Linux

These adapters use a design pattern sometimes called "ZeroCD" or "fake mass-storage mode." When first plugged in, the AIC8800D80 pretends to be a USB CD-ROM drive with VID:PID `1111:1111`. It contains a virtual disc image with the Windows driver installer. On Windows, a background service (`AicWifiService.exe`) automatically sends a proprietary SCSI command to switch the device into WiFi + Bluetooth mode. Without that command, the device stays in storage mode forever.

On Linux, `usb_modeswitch` handles this pattern for many devices (mostly 3G/4G modems), but it had no entry for `1111:1111` because the mode-switch command was not publicly documented. Standard eject commands, Huawei-style mode-switch sequences, and generic USB control transfers all fail. The device specifically requires a **vendor-specific 16-byte SCSI CDB** (Command Descriptor Block):

```
FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
```

This command was discovered by reverse-engineering `Usb_Driver.dll` from the Windows driver package. See [docs/reverse-engineering-results.md](docs/reverse-engineering-results.md) for full details.

Additionally, the AIC8800D80 Linux driver is not included in the mainline kernel. You need an out-of-tree DKMS driver, and different packagers (Brostrend, Radxa, etc.) ship different configurations -- some with Bluetooth disabled. This project handles all of that automatically.

## Installation

### Quick Install (Recommended)

No prerequisites needed. The script auto-detects your system, installs dependencies, and handles messy environments (broken installs, Radxa `.deb` packages with `_usb` suffix modules, Brostrend packages with BT disabled, etc.).

```bash
git clone https://github.com/olamellberg/AIC8800D80.git
cd AIC8800D80/linux
sudo bash install.sh
```

After installation, **unplug and re-plug the adapter**, then verify:

```bash
lsusb                    # Should show a69c:8d81 (WiFi + BT) or a69c:8d83 (WiFi only)
ip link show wlan1       # WiFi interface (may be wlan0 if no other WiFi adapter)
bluetoothctl show        # Bluetooth controller
```

### What the Installer Does

The `install.sh` script handles the full setup in one run:

- Installs prerequisites (`usb-modeswitch`, `sg3-utils`, build tools, kernel headers, DKMS)
- Auto-installs the AIC8800 DKMS driver from [Radxa source](https://github.com/radxa-pkg/aic8800) if not already present
- Detects and fixes broken or partial installs (Brostrend BT disabled, Radxa `_usb` suffix modules, orphaned DKMS entries)
- Configures `usb_modeswitch` for automatic mode switching on plug-in
- Installs udev rules for automatic driver binding
- Patches the WiFi driver VID:PID table (adds `a69c:8d83`) and rebuilds DKMS
- Builds and installs `aic_btusb` from Radxa source (with BlueZ fix and PID patches)
- Installs modprobe config to prevent the generic `btusb` driver from interfering
- Configures module autoload at boot

### Manual Installation

If you prefer to run each step yourself instead of using the automated installer, see the [Advanced / Manual Setup](#advanced--manual-setup) section below.

## Bluetooth Support

### How Bluetooth Works on AIC8800D80

After mode-switching, the AIC8800D80 exposes a standard Bluetooth USB interface (class `0xE0/0x01/0x01`). However, two separate drivers must cooperate for Bluetooth to work:

1. **`aic_load_fw`** loads the BT firmware patches during the initial firmware upload (at the `a69c:8d80` boot ROM stage). This happens before the device reaches operational mode. The Brostrend DKMS package has this step **disabled** with `#if 0` blocks. You need the [Radxa](https://github.com/radxa-pkg/aic8800) version of `aic_compat_8800d80.c`.

2. **`aic_btusb`** is the Bluetooth HCI driver that registers the controller with BlueZ. It does not load firmware for the D80 variant (unlike the DC variant where `aic_btusb` handles firmware loading).

Three fixes are needed (all handled automatically by `install.sh`):

1. **Enable BT firmware loading in `aic_load_fw`** -- Replace the Brostrend `aic_compat_8800d80.c` with the Radxa version and rebuild DKMS. Without this fix, the device enumerates as `a69c:8d83` (WiFi only, no BT interfaces). With the fix, it enumerates as `a69c:8d81` (WiFi + BT, 3 USB interfaces).

2. **Set CONFIG_BLUEDROID=0** -- The `aic_btusb` driver defaults to Android's BlueDroid stack. On desktop Linux, this must be set to `0` to use BlueZ.

3. **Block generic btusb** -- The generic `btusb` kernel module must be prevented from claiming the device before `aic_btusb` can bind. The installer sets up a modprobe config for this.

See [docs/bluetooth-support.md](docs/bluetooth-support.md) for the full technical architecture.

## Troubleshooting / FAQ

### Why does lsusb show 1111:1111 instead of a WiFi adapter?

The AIC8800D80 starts in fake mass-storage mode with the clone VID:PID `1111:1111`. This is normal before mode-switching. Run the installer (`sudo bash install.sh`) and then unplug/re-plug the adapter. After mode-switching, `lsusb` should show `a69c:8d81` or `a69c:8d83`.

### Why does my adapter show up as a CD-ROM drive?

Same reason as above. The device is in mass-storage mode and needs the proprietary SCSI mode-switch command to activate WiFi and Bluetooth. The installer configures `usb_modeswitch` to send this command automatically on every plug-in.

### Why is WiFi not working after installation?

Check whether mode-switching succeeded:

```bash
lsusb | grep -i "a69c"
```

If you still see `1111:1111`, the mode-switch did not happen. Try unplugging and re-plugging the adapter, then check `dmesg` for errors.

If you see `a69c:8d81` or `a69c:8d83` but no WiFi interface:

```bash
sudo modprobe aic8800_fdrv
ip link
```

### Why is Bluetooth missing or failing with timeout errors?

| Symptom | Cause | Fix |
|---------|-------|-----|
| Device shows as `a69c:8d83` with 1 interface | `aic_load_fw` does not have BT patches enabled | Re-run `install.sh` (it patches `aic_load_fw` automatically) |
| `bluetoothctl show` returns nothing | `aic_btusb` not loaded, or `CONFIG_BLUEDROID=1` | `sudo modprobe aic_btusb` or re-run `install.sh` |
| `Opcode 0x0c03 failed: -110` | Generic `btusb` claimed the device instead of `aic_btusb` | `sudo rmmod btusb && sudo modprobe aic_btusb` |
| `Operation not possible due to RF-kill` | Bluetooth blocked by RF-kill | `sudo rfkill unblock bluetooth && sudo hciconfig hci1 up` |
| `/dev/rtk_btusb` appears instead of `hci0` | `CONFIG_BLUEDROID=1` (Android mode) | Re-run `install.sh` (sets `CONFIG_BLUEDROID=0`) |

### How do I check which driver is bound to the Bluetooth interface?

```bash
sudo dmesg | grep -i 'btusb\|aic_btusb\|hci\|bluetooth'
lsmod | grep bt
lsusb -t    # Shows which driver is bound to each USB interface
```

### Will Realtek drivers work with this adapter?

No. Despite what some product listings imply, the AIC8800D80 is not a Realtek chipset. Realtek drivers (`rtl8xxxu`, `rtl88x2bu`, `rtl8821cu`, etc.) will not detect or work with this device.

### Does this work on other operating systems?

This project focuses on Linux. On Windows, the adapter works out of the box because the Windows driver includes the mode-switch service. On macOS, there is no known driver support.

## Supported Systems

### Tested Configurations

- **Raspberry Pi 3** running Raspberry Pi OS (Debian-based), kernel 6.12, with Brostrend AIC8800 DKMS v1.0.8 (patched with Radxa BT support)
  - **WiFi**: Working -- 802.11ax (WiFi 6), both 2.4 GHz and 5 GHz bands
  - **Bluetooth 5.3**: Working -- `bluetoothctl` sees controller, BLE advertising, central/peripheral roles, BD Address assigned, HCI UP RUNNING, 16 advertising instances

### Expected Compatibility

The installer should work on most Debian-based and Ubuntu-based distributions with kernel 5.x or newer:

- Raspberry Pi OS (Bookworm and later)
- Ubuntu 22.04+
- Debian 12+
- Linux Mint 21+
- Other Debian derivatives with `apt` and DKMS support

Other distributions (Fedora, Arch, etc.) may work with manual setup but are not tested. The core mode-switch mechanism (`usb_modeswitch` + the SCSI command) is distribution-independent.

### Requirements

- Linux kernel 5.x or newer (tested on 6.12)
- USB 2.0 port (the adapter is USB 2.0 High-Speed, 480 Mbps)
- Internet access during installation (to download DKMS driver source and dependencies)

## Device Technical Details

### USB Enumeration Stages

The AIC8800D80 goes through three USB enumeration stages:

```
Stage 0: 1111:1111 (Pandora - Mass Storage / fake CD-ROM)
    | SCSI command: FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
Stage 1: a69c:8d80 (Boot ROM) --> aic_load_fw uploads WiFi + BT firmware
    | firmware loaded, USB soft disconnect
Stage 2: a69c:8d81 (WiFi + Bluetooth operational, Radxa firmware)
         a69c:8d83 (WiFi only, Brostrend firmware without BT patches)
```

### Post Mode-Switch USB Interfaces

| Interface | Class | Purpose | Driver |
|-----------|-------|---------|--------|
| 0 | `0xE0/0x01/0x01` | Bluetooth HCI | `aic_btusb` |
| 1 | Isochronous | Bluetooth SCO/Audio | `aic_btusb` |
| 2 | `0xFF/0xFF/0xFF` | WiFi (vendor-specific) | `aic8800_fdrv` |

### The Mode-Switch SCSI Command

The key discovery of this project: the AIC8800D80 requires a vendor-specific 16-byte SCSI CDB to exit mass-storage mode:

```
FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
```

| Byte | Value | Meaning |
|------|-------|---------|
| 0 | `0xFD` | Vendor-specific SCSI opcode |
| 1-14 | `0x00` | Reserved (all zeros) |
| 15 | `0xF2` | Sub-command: trigger mode switch |

This was extracted by reverse-engineering `Usb_Driver.dll` from the Windows driver package. Standard SCSI eject commands (`START STOP UNIT`, `REZERO`, etc.) do not work. Only this specific vendor command triggers the mode switch. See [docs/reverse-engineering-results.md](docs/reverse-engineering-results.md) for full details.

## Advanced / Manual Setup

If you prefer to run each step manually instead of using `install.sh`:

### Patching aic_load_fw for Bluetooth Support

If using the Brostrend DKMS driver, BT firmware loading is disabled. To fix:

```bash
# Find your DKMS source
ls /usr/src/aic8800-*/aic_load_fw/aic_compat_8800d80.c

# Clone the Radxa source for the fixed file
git clone --depth 1 --filter=blob:none --sparse https://github.com/radxa-pkg/aic8800.git /tmp/radxa-aic
cd /tmp/radxa-aic && git sparse-checkout set src/USB/driver_fw/driver/aic_load_fw

# Replace the file (adjust version as needed)
sudo cp /tmp/radxa-aic/src/USB/driver_fw/driver/aic_load_fw/aic_compat_8800d80.c \
    /usr/src/aic8800-1.0.8/aic_load_fw/aic_compat_8800d80.c

# Rebuild DKMS (CRITICAL - the module will not update without this!)
sudo dkms remove aic8800/1.0.8 -k $(uname -r)
sudo dkms build aic8800/1.0.8 -k $(uname -r)
sudo dkms install aic8800/1.0.8 -k $(uname -r) --force

# Verify BT firmware strings are in the rebuilt module
xz -dc /lib/modules/$(uname -r)/updates/dkms/aic_load_fw.ko.xz | strings | grep fw_adid_8800d80
# Should show: fw_adid_8800d80_u02.bin
```

### Building aic_btusb from Source

If your DKMS driver package does not include `aic_btusb`, use the standalone build script:

```bash
sudo bash linux/build-aic-btusb.sh
```

Or build manually from the [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) repository:

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

### Manual Mode-Switch and Driver Binding

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

The device will disconnect and re-enumerate through the three stages described above.

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

**4. Make persistent (across reboots):**

```bash
# usb_modeswitch config - auto mode-switch on plug-in
sudo cp linux/usb_modeswitch/1111:1111 /etc/usb_modeswitch.d/

# udev rules - triggers mode-switch and driver binding automatically
sudo cp linux/udev/41-aic8800d80-modeswitch.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules

# modprobe config - prevents generic btusb from stealing the BT interface
sudo cp linux/modprobe/aic8800-bt.conf /etc/modprobe.d/
```

## Compatible Driver Sources

The AIC8800 DKMS driver is required. The `install.sh` script auto-installs it from Radxa source if not found. Known sources:

- [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) (recommended -- includes WiFi + Bluetooth support)
- [Brostrend AIC8800 DKMS](https://linux.brostrend.com/) (may have BT disabled; the installer patches this)
- [goecho/aic8800_linux_drvier](https://github.com/goecho/aic8800_linux_drvier)

## Repository Structure

```
AIC8800D80/
├── README.md                          # This file
├── LICENSE                            # MIT
├── linux/
│   ├── install.sh                     # All-in-one installer (WiFi + BT, DKMS patching, aic_btusb build)
│   ├── build-aic-btusb.sh            # Standalone aic_btusb builder (if you only need BT driver)
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
│   ├── bluetooth-support.md           # Detailed BT architecture and troubleshooting
│   └── windows-driver-analysis.md     # Windows DLL/driver analysis
└── windows/
    └── INF/
        ├── aicloadfw.Inf              # Reference: firmware loader INF
        └── aicusbwifi.Inf             # Reference: WiFi driver INF
```

## Contributing

If you have an AIC8800D80 or AIC8800M80 adapter with a different VID:PID, marketing name, or packaging, please open an issue with:

- Output of `lsusb` (before and after mode-switch)
- Output of `lsusb -d 1111:1111 -v` (or your device's VID:PID)
- Your adapter's marketing name and where you bought it
- Your Linux distribution and kernel version

Pull requests are welcome, especially for support on non-Debian distributions.

Whether your adapter is labeled WIFI6-BW22, BW23, AX900, 88M80, AIC8800D80, AIC8800M80, or simply "900Mbps WiFi 6 USB Adapter" from a no-name brand on AliExpress, Amazon, Temu, or Shopee -- if it shows `1111:1111` in `lsusb` and contains an AICSEMI AIC8800D80 chipset, this project provides the Linux driver solution you need.

## License

[MIT](LICENSE) -- The reverse engineering findings, configuration files, and scripts in this repository are freely available. Windows INF files in `windows/` are included as text reference only and remain property of their respective copyright holders.

## Acknowledgments

- The AIC8800D80 Linux driver is maintained by AICSEMI and community contributors
- [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) for the comprehensive driver package with Bluetooth fixes
- [Brostrend](https://linux.brostrend.com/) for packaging the DKMS driver
- The [usb_modeswitch](https://www.draisberghof.de/usb_modeswitch/) project for the mode-switching framework
