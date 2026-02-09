#!/bin/bash
# install.sh - All-in-one installer for AIC8800D80 "Pandora" (1111:1111) USB WiFi + Bluetooth
#
# This single script handles EVERYTHING:
#   1. Install prerequisites (usb-modeswitch, sg3-utils, build tools, kernel headers)
#   2. usb_modeswitch config for automatic mode switching
#   3. udev rules to trigger mode switch and driver binding on plug-in
#   4. Patch aic_load_fw for BT firmware loading (Radxa aic_compat_8800d80.c)
#   5. Patch WiFi driver VID:PID table (add a69c:8d83)
#   6. Rebuild DKMS with all patches
#   7. Build and install aic_btusb from Radxa source
#   8. modprobe config (btusb conflict resolution)
#   9. Module autoload at boot
#  10. Reload modules and verify
#
# Prerequisites:
#   - AIC8800 DKMS driver installed (Brostrend or Radxa)
#     Recommended source: https://github.com/radxa-pkg/aic8800
#
# Usage: sudo bash install.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KVER=$(uname -r)

echo "=========================================="
echo " AIC8800D80 Pandora (1111:1111) Installer"
echo "       WiFi + Bluetooth - All-in-One"
echo "=========================================="
echo
echo "Kernel: $KVER"
echo

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (sudo).${NC}"
    exit 1
fi

STEP=1
TOTAL=10

###############################################################################
# Step 1: Install prerequisites
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Installing prerequisites...${NC}"

PKGS_NEEDED=""
command -v usb_modeswitch &>/dev/null || PKGS_NEEDED="$PKGS_NEEDED usb-modeswitch usb-modeswitch-data"
command -v sg_raw &>/dev/null         || PKGS_NEEDED="$PKGS_NEEDED sg3-utils"
command -v git &>/dev/null            || PKGS_NEEDED="$PKGS_NEEDED git"
command -v make &>/dev/null           || PKGS_NEEDED="$PKGS_NEEDED build-essential"
[ -d "/lib/modules/$KVER/build" ]     || PKGS_NEEDED="$PKGS_NEEDED linux-headers-$KVER"

if [ -n "$PKGS_NEEDED" ]; then
    echo "  -> Installing:$PKGS_NEEDED"
    apt-get update -qq && apt-get install -y $PKGS_NEEDED
else
    echo "  -> All prerequisites already installed."
fi
STEP=$((STEP + 1))

###############################################################################
# Step 2: Install usb_modeswitch config
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Installing usb_modeswitch config...${NC}"
mkdir -p /etc/usb_modeswitch.d
cp "$SCRIPT_DIR/usb_modeswitch/1111_1111" "/etc/usb_modeswitch.d/1111:1111"
echo "  -> /etc/usb_modeswitch.d/1111:1111"
STEP=$((STEP + 1))

###############################################################################
# Step 3: Install udev rules
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Installing udev rules (WiFi + Bluetooth)...${NC}"
cp "$SCRIPT_DIR/udev/41-aic8800d80-modeswitch.rules" /etc/udev/rules.d/
udevadm control --reload-rules
echo "  -> /etc/udev/rules.d/41-aic8800d80-modeswitch.rules"
echo "  -> udev rules reloaded"
STEP=$((STEP + 1))

###############################################################################
# Step 4: Patch aic_load_fw for BT firmware loading
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Patching aic_load_fw for Bluetooth support...${NC}"

# Find DKMS source directory
DKMS_SRC=""
for d in /usr/src/aic8800-*/aic_load_fw; do
    if [ -d "$d" ]; then
        DKMS_SRC="$(dirname "$d")"
        break
    fi
done

if [ -z "$DKMS_SRC" ]; then
    echo -e "${RED}  -> ERROR: No AIC8800 DKMS source found in /usr/src/${NC}"
    echo "  -> You need the AIC8800 DKMS driver installed first."
    echo "  -> Install from: https://github.com/radxa-pkg/aic8800"
    echo "  ->            or: https://linux.brostrend.com/"
    echo
    echo "  -> After installing the DKMS driver, re-run this script."
    exit 1
fi

DKMS_VER=$(basename "$DKMS_SRC" | sed 's/aic8800-//')
echo "  -> Found DKMS source: $DKMS_SRC (version $DKMS_VER)"

COMPAT_FILE="$DKMS_SRC/aic_load_fw/aic_compat_8800d80.c"
NEED_DKMS_REBUILD=0

# Check if BT loading is disabled (Brostrend has #if 0 around BT code)
if [ -f "$COMPAT_FILE" ] && grep -q '#if 0' "$COMPAT_FILE"; then
    echo -e "  -> ${CYAN}BT firmware loading is DISABLED (Brostrend #if 0 found)${NC}"
    echo "  -> Fetching Radxa version with BT enabled..."

    RADXA_DIR="/tmp/radxa-aic-$$"
    rm -rf "$RADXA_DIR"
    git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/radxa-pkg/aic8800.git "$RADXA_DIR" 2>&1
    cd "$RADXA_DIR"
    git sparse-checkout set src/USB/driver_fw/driver/aic_load_fw 2>&1
    cd - >/dev/null

    RADXA_COMPAT="$RADXA_DIR/src/USB/driver_fw/driver/aic_load_fw/aic_compat_8800d80.c"
    if [ -f "$RADXA_COMPAT" ]; then
        cp "$RADXA_COMPAT" "$COMPAT_FILE"
        echo -e "  -> ${GREEN}Replaced aic_compat_8800d80.c with Radxa version (BT enabled)${NC}"
        NEED_DKMS_REBUILD=1
    else
        echo -e "${RED}  -> ERROR: Could not find Radxa aic_compat_8800d80.c${NC}"
        echo "  -> Sparse checkout may have failed. Check network connectivity."
        exit 1
    fi
    rm -rf "$RADXA_DIR"
else
    echo "  -> aic_compat_8800d80.c already has BT loading enabled (no #if 0 found)."
fi
STEP=$((STEP + 1))

###############################################################################
# Step 5: Patch WiFi driver VID:PID table (add a69c:8d83)
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Checking WiFi driver VID:PID table...${NC}"

WIFI_SRC="$DKMS_SRC/aic8800_fdrv/aicwf_usb.c"
if [ -f "$WIFI_SRC" ]; then
    if grep -q "0xa69c.*0x8d83\|USB_PRODUCT_ID_AIC8800M80_CUS1" "$WIFI_SRC"; then
        echo "  -> Driver already has a69c:8d83 in USB ID table."
    else
        echo -e "  -> ${CYAN}Patching driver source to add a69c:8d83...${NC}"
        sed -i '/USB_DEVICE_ID_AIC_8800D80/a\\t{USB_DEVICE(0xa69c, 0x8d83)},   /* Pandora clone post-switch */' "$WIFI_SRC"
        echo "  -> Added a69c:8d83 to WiFi USB ID table."
        NEED_DKMS_REBUILD=1
    fi
else
    echo "  -> WiFi driver source not found at $WIFI_SRC"
    echo "  -> The udev rule will use 'new_id' to bind the driver dynamically."
fi
STEP=$((STEP + 1))

###############################################################################
# Step 6: Rebuild DKMS
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Rebuilding DKMS module...${NC}"

if [ "$NEED_DKMS_REBUILD" = "1" ]; then
    echo "  -> Removing old DKMS build..."
    dkms remove "aic8800/$DKMS_VER" -k "$KVER" 2>/dev/null || true

    echo "  -> Building DKMS module..."
    if dkms build "aic8800/$DKMS_VER" -k "$KVER"; then
        echo "  -> Installing DKMS module..."
        dkms install "aic8800/$DKMS_VER" -k "$KVER" --force
        echo -e "  -> ${GREEN}DKMS rebuild successful!${NC}"

        # Verify BT firmware strings in compiled module
        MODULE_PATH="/lib/modules/$KVER/updates/dkms/aic_load_fw.ko"
        MODULE_XZ="${MODULE_PATH}.xz"
        if [ -f "$MODULE_XZ" ]; then
            if xz -dc "$MODULE_XZ" | strings | grep -q 'fw_adid_8800d80'; then
                echo -e "  -> ${GREEN}Verified: BT firmware strings present in aic_load_fw.ko${NC}"
            else
                echo -e "  -> ${YELLOW}Warning: BT firmware strings NOT found in module${NC}"
                echo "  -> The DKMS rebuild may not have picked up the patched file."
            fi
        elif [ -f "$MODULE_PATH" ]; then
            if strings "$MODULE_PATH" | grep -q 'fw_adid_8800d80'; then
                echo -e "  -> ${GREEN}Verified: BT firmware strings present in aic_load_fw.ko${NC}"
            else
                echo -e "  -> ${YELLOW}Warning: BT firmware strings NOT found in module${NC}"
            fi
        fi
    else
        echo -e "${RED}  -> DKMS build failed!${NC}"
        echo "  -> Check kernel headers: apt install linux-headers-$KVER"
        exit 1
    fi
else
    echo "  -> No DKMS patches needed, skipping rebuild."
fi
STEP=$((STEP + 1))

###############################################################################
# Step 7: Build and install aic_btusb
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Building aic_btusb Bluetooth driver...${NC}"

if modinfo aic_btusb &>/dev/null 2>&1; then
    echo "  -> aic_btusb module already installed."
    echo -e "  -> ${YELLOW}Rebuilding anyway to ensure latest patches...${NC}"
fi

WORK_DIR="/tmp/aic_btusb_build_$$"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "  -> Cloning Radxa aic_btusb source..."
git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/radxa-pkg/aic8800.git "$WORK_DIR/aic8800" 2>&1
cd "$WORK_DIR/aic8800"
git sparse-checkout set src/USB/driver_fw/drivers/aic_btusb debian/patches 2>&1
cd "$WORK_DIR"

cp -r "$WORK_DIR/aic8800/src/USB/driver_fw/drivers/aic_btusb" "$WORK_DIR/aic_btusb_src"
cd "$WORK_DIR/aic_btusb_src"
echo "  -> Source ready at $WORK_DIR/aic_btusb_src"

# Apply Radxa kernel compatibility patches (-p6 strip level)
echo "  -> Applying compatibility patches..."
PATCH_DIR="$WORK_DIR/aic8800/debian/patches"
for patch_name in fix-aic_btusb.patch fix-aic_btusb-implicit-declare-compat_ptr.patch; do
    PATCH_FILE="$PATCH_DIR/$patch_name"
    if [ -f "$PATCH_FILE" ]; then
        echo "     $patch_name"
        patch -p6 --forward --ignore-whitespace < "$PATCH_FILE" 2>&1 || echo "     (already applied or N/A)"
    fi
done

# Fix CONFIG_BLUEDROID: 1 -> 0 (BlueZ instead of Android BlueDroid)
echo "  -> Setting CONFIG_BLUEDROID=0 (BlueZ mode)..."
if grep -q 'BLUEDROID        1' aic_btusb.h; then
    sed -i 's/BLUEDROID        1/BLUEDROID        0/g' aic_btusb.h
    echo "     Changed from 1 to 0"
else
    echo "     Already set to 0"
fi

# Add PID 0x8d83 to USB ID table (Brostrend firmware compatibility)
echo "  -> Adding PID 0x8d83 to USB ID table..."
if grep -q '0x8d83' aic_btusb.c; then
    echo "     Already present"
else
    sed -i '/USB_PRODUCT_ID_AIC8800D80.*0xe0.*0x01.*0x01/a\\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDOR_ID_AIC, 0x8d83, 0xe0, 0x01, 0x01)},   /* Pandora clone: a69c:8d83 */' aic_btusb.c
    echo "     Added"
fi

# Build
echo "  -> Building..."
make KDIR="/lib/modules/$KVER/build" CONFIG_PLATFORM_UBUNTU=y 2>&1

if [ ! -f "aic_btusb.ko" ]; then
    echo -e "${RED}  -> Build failed! aic_btusb.ko not created.${NC}"
    exit 1
fi
echo -e "  -> ${GREEN}Build successful!${NC}"

# Install
MODDIR="/lib/modules/$KVER/kernel/drivers/bluetooth"
mkdir -p "$MODDIR"
cp aic_btusb.ko "$MODDIR/"
depmod -a "$KVER"
echo "  -> Installed to $MODDIR/aic_btusb.ko"
echo "  -> depmod updated"

# Cleanup
cd /
rm -rf "$WORK_DIR"
STEP=$((STEP + 1))

###############################################################################
# Step 8: Install modprobe config (btusb conflict resolution)
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Installing modprobe config (btusb conflict resolution)...${NC}"
mkdir -p /etc/modprobe.d
cp "$SCRIPT_DIR/modprobe/aic8800-bt.conf" /etc/modprobe.d/
echo "  -> /etc/modprobe.d/aic8800-bt.conf"
echo "  -> Generic btusb will defer to aic_btusb for AIC devices"
STEP=$((STEP + 1))

###############################################################################
# Step 9: Configure module autoload at boot
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Configuring module autoload...${NC}"
mkdir -p /etc/modules-load.d
if ! grep -qs 'aic_btusb' /etc/modules-load.d/aic8800.conf 2>/dev/null; then
    echo "aic_btusb" >> /etc/modules-load.d/aic8800.conf
    echo "  -> Added aic_btusb to /etc/modules-load.d/aic8800.conf"
else
    echo "  -> aic_btusb already in modules-load.d"
fi
STEP=$((STEP + 1))

###############################################################################
# Step 10: Reload modules and verify
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Reloading modules...${NC}"

# Unload old modules
rmmod btusb 2>/dev/null || true
rmmod aic_btusb 2>/dev/null || true
rmmod aic8800_fdrv 2>/dev/null || true
rmmod aic_load_fw 2>/dev/null || true

# Reload
modprobe aic_load_fw 2>/dev/null || true
modprobe aic_btusb 2>&1 || true

# Try binding to device (both possible PIDs)
for PID in 8d81 8d83; do
    echo "a69c $PID" > /sys/bus/usb/drivers/aic_btusb/new_id 2>/dev/null || true
done

rfkill unblock bluetooth 2>/dev/null || true
hciconfig hci1 up 2>/dev/null || true
sleep 1

echo
echo "=========================================="
echo -e "${GREEN} Installation complete!${NC}"
echo "=========================================="
echo
echo "What was installed:"
echo "  - usb_modeswitch config (auto mode-switch on plug-in)"
echo "  - udev rules (auto driver binding)"
echo "  - aic_load_fw patched for BT firmware loading"
echo "  - WiFi driver VID:PID fix (a69c:8d83)"
echo "  - aic_btusb built and installed (BlueZ mode)"
echo "  - modprobe config (btusb conflict prevention)"
echo "  - Module autoload at boot"
echo
echo "Next steps:"
echo "  1. Unplug and re-plug the WiFi/BT adapter"
echo "  2. Check WiFi:  ip link show wlan1"
echo "  3. Check BT:    bluetoothctl show"
echo
echo "=== Current Status ==="
echo "Loaded modules:"
lsmod | grep -iE 'aic|bt' || echo "  (none - re-plug adapter to trigger)"
echo
echo "HCI devices:"
hciconfig -a 2>&1 || true
echo
echo "Troubleshooting:"
echo "  sudo dmesg | grep -i 'btusb\|aic_btusb\|hci\|bluetooth'"
echo "  lsmod | grep bt"
echo "  lsusb -t"
echo
