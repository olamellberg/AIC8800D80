# AIC8800D80 Bluetooth Support - Complete Guide

Getting Bluetooth 5.3 working on cheap AIC8800D80 "Pandora" clone adapters (VID:PID `1111:1111`) on Linux.

## Architecture Overview

The AIC8800D80 is a combo WiFi 6 + Bluetooth 5.3 SoC. Three kernel modules work together:

| Module | Role | When |
|--------|------|------|
| `aic_load_fw` | Uploads WiFi + BT firmware to chip during boot ROM stage | Device at `a69c:8d80` |
| `aic8800_fdrv` | WiFi driver (vendor-specific interface) | Device at `a69c:8d81` |
| `aic_btusb` | Bluetooth HCI driver (registers with BlueZ) | Device at `a69c:8d81` |

### USB Enumeration Stages

```
Stage 0: 1111:1111  (Pandora - Mass Storage / fake CD-ROM)
    | usb_modeswitch sends SCSI CDB: FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
Stage 1: a69c:8d80  (Boot ROM)
    | aic_load_fw uploads: BT patches + WiFi firmware
    | Device soft-disconnects and re-enumerates
Stage 2: a69c:8d81  (Operational - WiFi + Bluetooth)
```

### Post-Switch USB Interfaces (PID 0x8d81)

| Interface | Class | Purpose | Driver |
|-----------|-------|---------|--------|
| 0 | `0xE0/0x01/0x01` (Wireless/BT) | Bluetooth HCI | `aic_btusb` |
| 1 | `0xE0/0x01/0x01` (Wireless/BT) | Bluetooth SCO/Audio | `aic_btusb` |
| 2 | `0xFF/0xFF/0xFF` (Vendor Specific) | WiFi | `aic8800_fdrv` |

> **Note:** If the device enumerates as `a69c:8d83` with only 1 interface (WiFi), it means the BT firmware was NOT loaded by `aic_load_fw`. See [Fixing aic_load_fw](#fixing-aic_load_fw-for-bt-support) below.

## Key Discovery: D80 vs DC Bluetooth Loading

This was the hardest part to figure out. The AIC8800 driver family supports two chip variants (DC and D80) with **fundamentally different** Bluetooth firmware loading:

| | AIC8800DC | AIC8800D80 |
|---|-----------|------------|
| **BT firmware loaded by** | `aic_btusb` (via HCI commands after probe) | `aic_load_fw` (during initial firmware upload) |
| **`aic_btusb` calls `download_patch`?** | Yes | No - must skip |
| **BT firmware path** | `/lib/firmware/aic8800DC/` | `/lib/firmware/aic8800D80/` |
| **Operational PID** | `0x88dc` | `0x8d81` |

The `aic_btusb` driver's source code only has firmware tables for DC (`fw_8800dc[]`). For D80, the BT firmware is already loaded by `aic_load_fw`, so `aic_btusb` just needs to register the HCI device without attempting firmware download.

## BT Firmware Files (loaded by aic_load_fw)

These files must exist in `/lib/firmware/aic8800D80/`:

| File | Size | Purpose |
|------|------|---------|
| `fw_patch_table_8800d80_u02.bin` | 1,280 bytes | BT patch table (loaded first, contains addresses) |
| `fw_adid_8800d80_u02.bin` | 1,708 bytes | BT ADID (Address ID) data |
| `fw_patch_8800d80_u02.bin` | 32,192 bytes | BT firmware patch |
| `fw_patch_8800d80_u02_ext0.bin` | 13,788 bytes | BT extended patch data |
| `fmacfw_8800d80_u02.bin` | 349,096 bytes | WiFi firmware (loaded after BT) |

The firmware files come from the [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) package. The Brostrend DKMS package (v1.0.8) includes these files but the loading code is disabled.

## What Needs Fixing

### 1. Fixing aic_load_fw for BT Support

**The Problem:** The Brostrend DKMS driver (`aic8800-1.0.8`) has Bluetooth patch loading **disabled** in `aic_compat_8800d80.c` using `#if 0` preprocessor guards. The compiled module doesn't even contain the BT firmware filename strings.

**The Fix:** Replace `aic_compat_8800d80.c` with the version from [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) which has BT loading enabled, then **rebuild DKMS**.

```bash
# 1. Get the Radxa version of the file
git clone --depth 1 --filter=blob:none --sparse https://github.com/radxa-pkg/aic8800.git /tmp/radxa-aic
cd /tmp/radxa-aic
git sparse-checkout set src/USB/driver_fw/driver/aic_load_fw

# 2. Replace the file in DKMS source (adjust version as needed)
sudo cp /tmp/radxa-aic/src/USB/driver_fw/driver/aic_load_fw/aic_compat_8800d80.c \
    /usr/src/aic8800-1.0.8/aic_load_fw/aic_compat_8800d80.c

# 3. CRITICAL: Rebuild DKMS (the module won't update without this!)
KVER=$(uname -r)
sudo dkms remove aic8800/1.0.8 -k "$KVER"
sudo dkms build aic8800/1.0.8 -k "$KVER"
sudo dkms install aic8800/1.0.8 -k "$KVER" --force

# 4. Verify the rebuilt module contains BT firmware strings
xz -dc /lib/modules/$KVER/updates/dkms/aic_load_fw.ko.xz | strings | grep fw_adid_8800d80
# Expected output: fw_adid_8800d80_u02.bin
# If missing, the rebuild didn't work - check dkms status
```

**How to verify it worked:** After reloading the module and re-plugging the adapter:
- `lsusb` should show `a69c:8d81` (not `8d83`)
- `lsusb -t` should show 3 interfaces (not 1)
- `dmesg` should show BT firmware being uploaded:
  ```
  ### Upload fw_patch_table_8800d80_u02.bin fw_patch_table, size=1280
  ### Upload fw_adid_8800d80_u02.bin firmware, @ = 201940  size=1708
  ### Upload fw_patch_8800d80_u02.bin firmware, @ = 1e0000  size=32192
  ### Upload fw_patch_8800d80_u02_ext0.bin firmware, @ = 20b43c  size=13788
  ### Upload fmacfw_8800d80_u02.bin firmware, @ = 120000  size=349096
  ```

### 2. Building and Installing aic_btusb

The Brostrend DKMS package doesn't include the `aic_btusb` module at all. Build it from the Radxa source:

```bash
sudo bash build-aic-btusb.sh
```

This script:
1. Clones the Radxa aic_btusb source
2. Applies kernel compatibility patches (strip level `-p6`)
3. Sets `CONFIG_BLUEDROID=0` (BlueZ mode instead of Android BlueDroid)
4. Adds PID `0x8d83` to the USB ID table (for Brostrend firmware compatibility)
5. Builds and installs the module
6. Installs modprobe config to prevent generic `btusb` from stealing the device

### 3. Preventing Generic btusb Conflict

Linux's built-in `btusb` driver matches any USB device with Bluetooth interface class (`0xE0/0x01/0x01`). It will claim the AIC8800 BT interface but doesn't know how to initialize it, causing `HCI_Reset timeout` errors.

The modprobe config (`/etc/modprobe.d/aic8800-bt.conf`) ensures `aic_btusb` loads first:

```
softdep btusb pre: aic_btusb
alias usb:v0A69Cp8D81d*dc*dsc*dp*icE0isc01ip01in* aic_btusb
alias usb:v0A69Cp8D83d*dc*dsc*dp*icE0isc01ip01in* aic_btusb
```

## Quick Install

The all-in-one `install.sh` script handles everything automatically: DKMS patching, aic_btusb build, modprobe config, and module autoload.

```bash
git clone https://github.com/olamellberg/AIC8800D80.git
cd AIC8800D80/linux
sudo bash install.sh
```

The script will:
1. Install prerequisites (usb-modeswitch, sg3-utils, build tools, kernel headers)
2. Set up usb_modeswitch config and udev rules
3. Patch `aic_load_fw` for BT firmware loading (replace Brostrend's disabled version with Radxa's)
4. Patch WiFi driver VID:PID table and rebuild DKMS
5. Build and install `aic_btusb` (with BlueZ fix + PID patches)
6. Install modprobe config and module autoload

After the script completes, unplug and re-plug the adapter:

```bash
lsusb                    # Should show a69c:8d81
lsusb -t                 # Should show 3 interfaces
hciconfig -a             # Should show hci1 (or hci0 if no onboard BT)
bluetoothctl show        # Should show the AIC controller
```

For manual step-by-step instructions, see the individual sections below or [build-aic-btusb.sh](../linux/build-aic-btusb.sh) for standalone aic_btusb building.

## Troubleshooting

### Device shows as a69c:8d83 with only 1 interface

**Cause:** `aic_load_fw` is not loading BT firmware patches. The Brostrend DKMS has BT disabled.

**Fix:** Re-run `sudo bash install.sh` (it patches aic_load_fw automatically), or manually replace `aic_compat_8800d80.c` with the Radxa version and rebuild DKMS. See [Fixing aic_load_fw](#fixing-aic_load_fw-for-bt-support).

**Verify:** Check if the compiled module has BT firmware strings:
```bash
xz -dc /lib/modules/$(uname -r)/updates/dkms/aic_load_fw.ko.xz | strings | grep fw_adid_8800d80
```
If this returns nothing, the module was not rebuilt properly.

### bluetoothctl shows nothing / no hci device

**Cause:** `aic_btusb` not loaded, or `CONFIG_BLUEDROID=1` (Android mode).

**Fix:**
```bash
# Check if aic_btusb is loaded
lsmod | grep aic_btusb

# If not, load it
sudo modprobe aic_btusb

# If loaded but no hci device, check CONFIG_BLUEDROID
strings /lib/modules/$(uname -r)/kernel/drivers/bluetooth/aic_btusb.ko | grep BLUEDROID
# Rebuild with CONFIG_BLUEDROID=0 if needed
```

### Opcode 0x0c03 failed: -110 (HCI_Reset timeout)

**Cause:** Generic `btusb` claimed the device instead of `aic_btusb`.

**Fix:**
```bash
sudo rmmod btusb
sudo modprobe aic_btusb
# Install modprobe config to prevent recurrence:
sudo cp linux/modprobe/aic8800-bt.conf /etc/modprobe.d/
```

### Operation not possible due to RF-kill

**Fix:**
```bash
sudo rfkill unblock bluetooth
sudo hciconfig hci1 up
```

### download_data: rcv_hci_evt err -110 (during aic_btusb probe)

**Cause:** `aic_btusb` is trying to download BT patches via HCI, but D80 doesn't support this. The BT firmware should already be loaded by `aic_load_fw`.

**Fix:** Use the unmodified `aic_btusb` from Radxa - it correctly skips `download_patch` for D80. If you patched `aic_btusb` to enable download for D80, revert that change.

### fw_config: Failed to receive hci event, errno -71

**Cause:** The device was in a stale state from a previous firmware load. The BT controller from the previous session is not responsive.

**Fix:** Physically unplug and re-plug the USB adapter, or trigger a USB reset:
```bash
# Find the USB port (check dmesg for the port path)
echo "1-1.3" | sudo tee /sys/bus/usb/drivers/usb/unbind
sleep 2
echo "1-1.3" | sudo tee /sys/bus/usb/drivers/usb/bind
```

## Hardware Details

| Property | Value |
|----------|-------|
| **Chipset** | AICSEMI AIC8800D80 (Wi-Fi 6 + BT 5.3 SoC) |
| **chip_id** | 7 (`CHIP_REV_U03`), uses u02 firmware files |
| **Firmware version** | `di Mar 14 2025 12:03:17 - g5c3af771` (Radxa) |
| **BT BD Address** | Assigned by firmware (e.g., `68:8F:C9:95:6D:A9`) |
| **BT Features** | BLE, BR/EDR, ISO (CIS central/peripheral), 16 advertising instances |
| **BT Roles** | Central, Peripheral |
| **USB Speed** | 480 Mbps (High-Speed USB 2.0) |

### Chip Revision Constants

The chip_id register uses a bitmask scheme:

| Constant | Value | Firmware suffix |
|----------|-------|-----------------|
| `CHIP_REV_U01` | `0x1` | (none) |
| `CHIP_REV_U02` | `0x3` | `_u02` |
| `CHIP_REV_U03` | `0x7` | `_u02` (uses u02 firmware) |
| `CHIP_REV_U04` | `0xf` | `_u04` |
| `CHIP_REV_U05` | `0x1f` | `_u05` |

Our adapter reports `chip_id=7` (`CHIP_REV_U03`) but uses `_u02` firmware files.

## Tested Configuration

- **Hardware:** Raspberry Pi 3 Model B
- **OS:** Raspberry Pi OS (Debian-based)
- **Kernel:** 6.12.62+rpt-rpi-v8 (aarch64)
- **DKMS:** Brostrend aic8800 v1.0.8 (patched with Radxa `aic_compat_8800d80.c`)
- **aic_btusb:** Built from radxa-pkg/aic8800 with `CONFIG_BLUEDROID=0`
- **Result:** WiFi and Bluetooth both operational

## Files in This Repository

| File | Purpose |
|------|---------|
| `linux/install.sh` | All-in-one installer (mode-switch, udev, DKMS patching, aic_btusb build, BT config) |
| `linux/build-aic-btusb.sh` | Standalone aic_btusb builder (if you only need the BT driver) |
| `linux/udev/41-aic8800d80-modeswitch.rules` | udev rules for auto mode-switch and driver binding |
| `linux/modprobe/aic8800-bt.conf` | Prevent generic btusb from claiming AIC devices |
| `linux/usb_modeswitch/1111_1111` | usb_modeswitch config with vendor SCSI CDB |
| `linux/patches/aic_btusb-use-bluez.patch` | CONFIG_BLUEDROID fix patch |
| `linux/patches/aic_btusb-add-a69c-8d83.patch` | PID 0x8d83 patch for aic_btusb |
| `linux/patches/aic8800_fdrv-add-a69c-8d83.patch` | PID 0x8d83 patch for WiFi driver |
