#!/bin/bash
# install.sh - Set up AIC8800D80 "Pandora" (1111:1111) USB WiFi + Bluetooth adapter on Linux
#
# This script installs:
#   1. usb_modeswitch config for automatic mode switching
#   2. udev rules to trigger mode switch and driver binding on plug-in
#   3. Dynamic VID:PID fix for aic8800_fdrv driver binding (WiFi)
#   4. Bluetooth support: aic_btusb patches, btusb conflict resolution
#
# Prerequisites:
#   - usb_modeswitch package installed
#   - sg3-utils package installed (for manual testing)
#   - AIC8800 DKMS driver installed (aic_load_fw + aic8800_fdrv + aic_btusb)
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

echo "=========================================="
echo " AIC8800D80 Pandora (1111:1111) Installer"
echo "       WiFi + Bluetooth Support"
echo "=========================================="
echo

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (sudo).${NC}"
    exit 1
fi

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v usb_modeswitch &> /dev/null; then
    echo -e "${YELLOW}usb_modeswitch not found. Installing...${NC}"
    apt-get update && apt-get install -y usb-modeswitch usb-modeswitch-data
fi

if ! command -v sg_raw &> /dev/null; then
    echo -e "${YELLOW}sg3-utils not found. Installing...${NC}"
    apt-get update && apt-get install -y sg3-utils
fi

if ! modinfo aic8800_fdrv &> /dev/null 2>&1; then
    echo -e "${YELLOW}Warning: aic8800_fdrv kernel module not found.${NC}"
    echo "You need the AIC8800 DKMS driver installed for WiFi to work."
    echo "Recommended: https://github.com/radxa-pkg/aic8800"
    echo
fi

if ! modinfo aic_btusb &> /dev/null 2>&1; then
    echo -e "${YELLOW}Warning: aic_btusb kernel module not found.${NC}"
    echo "You need the AIC8800 Bluetooth DKMS driver for Bluetooth to work."
    echo "Recommended: https://github.com/radxa-pkg/aic8800"
    echo "  git clone --recurse-submodules https://github.com/radxa-pkg/aic8800.git"
    echo "  cd aic8800/src/USB/driver_fw/drivers/aic_btusb"
    echo "  make && sudo make install"
    echo
    BT_MODULE_MISSING=1
fi

STEP=1
TOTAL=6

# Step 1: Install usb_modeswitch config
echo -e "${GREEN}[$STEP/$TOTAL] Installing usb_modeswitch config...${NC}"
mkdir -p /etc/usb_modeswitch.d
cp "$SCRIPT_DIR/usb_modeswitch/1111_1111" "/etc/usb_modeswitch.d/1111:1111"
echo "  -> /etc/usb_modeswitch.d/1111:1111"
STEP=$((STEP + 1))

# Step 2: Install udev rules (WiFi + Bluetooth)
echo -e "${GREEN}[$STEP/$TOTAL] Installing udev rules (WiFi + Bluetooth)...${NC}"
cp "$SCRIPT_DIR/udev/41-aic8800d80-modeswitch.rules" /etc/udev/rules.d/
udevadm control --reload-rules
echo "  -> /etc/udev/rules.d/41-aic8800d80-modeswitch.rules"
echo "  -> udev rules reloaded"
STEP=$((STEP + 1))

# Step 3: Patch WiFi driver if DKMS source exists
echo -e "${GREEN}[$STEP/$TOTAL] Checking WiFi driver VID:PID table...${NC}"

DRIVER_SRC="/usr/src/aic8800-1.0.8/aic8800_fdrv/aicwf_usb.c"
if [ -f "$DRIVER_SRC" ]; then
    if grep -q "0xa69c.*0x8d83\|USB_PRODUCT_ID_AIC8800M80_CUS1" "$DRIVER_SRC"; then
        echo "  -> Driver already has a69c:8d83 in USB ID table."
    else
        echo "  -> Patching driver source to add a69c:8d83..."
        # Find the USB ID table and add our entry
        sed -i '/USB_DEVICE_ID_AIC_8800D80/a\\t{USB_DEVICE(0xa69c, 0x8d83)},   /* Pandora clone post-switch */' "$DRIVER_SRC"
        WIFI_PATCHED=1
    fi
else
    echo "  -> DKMS source not found at $DRIVER_SRC"
    echo "  -> The udev rule will use 'new_id' to bind the driver dynamically."
fi
STEP=$((STEP + 1))

# Step 4: Patch Bluetooth driver (CONFIG_BLUEDROID + VID:PID)
echo -e "${GREEN}[$STEP/$TOTAL] Checking Bluetooth driver...${NC}"

# Search for aic_btusb source in common DKMS locations
BT_SRC=""
for src_dir in /usr/src/aic8800-*/aic_btusb /usr/src/aic8800-*/drivers/aic_btusb; do
    if [ -d "$src_dir" ]; then
        BT_SRC="$src_dir"
        break
    fi
done

if [ -n "$BT_SRC" ]; then
    echo "  -> Found aic_btusb source at: $BT_SRC"

    # Patch CONFIG_BLUEDROID: 1 -> 0 (BlueZ instead of BlueDroid)
    BT_HEADER="$BT_SRC/aic_btusb.h"
    if [ -f "$BT_HEADER" ]; then
        if grep -q '#define CONFIG_BLUEDROID.*1' "$BT_HEADER"; then
            echo -e "  -> ${CYAN}Patching CONFIG_BLUEDROID: 1 -> 0 (switching to BlueZ)${NC}"
            sed -i '/#ifdef CONFIG_PLATFORM_UBUNTU/{n;s/#define CONFIG_BLUEDROID.*1/#define CONFIG_BLUEDROID        0/}' "$BT_HEADER"
            BT_PATCHED=1
        else
            echo "  -> CONFIG_BLUEDROID already set to 0 (BlueZ mode)."
        fi
    fi

    # Add a69c:8d83 to btusb_table if not present
    BT_SOURCE="$BT_SRC/aic_btusb.c"
    if [ -f "$BT_SOURCE" ]; then
        if grep -q '0x8d83' "$BT_SOURCE"; then
            echo "  -> Driver already has a69c:8d83 in BT USB ID table."
        else
            echo -e "  -> ${CYAN}Adding a69c:8d83 to BT USB ID table...${NC}"
            sed -i '/USB_PRODUCT_ID_AIC8800D80.*0xe0.*0x01.*0x01/a\\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDOR_ID_AIC, 0x8d83, 0xe0, 0x01, 0x01)},   /* Pandora clone: a69c:8d83 */' "$BT_SOURCE"
            BT_PATCHED=1
        fi
    fi

    # Rebuild DKMS if we patched anything
    if [ "$BT_PATCHED" = "1" ] || [ "$WIFI_PATCHED" = "1" ]; then
        echo "  -> Rebuilding DKMS module..."
        DKMS_VER=$(ls -1 /usr/src/ | grep '^aic8800-' | sed 's/aic8800-//' | head -1)
        if [ -n "$DKMS_VER" ] && dkms build "aic8800/$DKMS_VER" && dkms install "aic8800/$DKMS_VER" --force; then
            echo "  -> DKMS rebuild successful!"
        else
            echo -e "${YELLOW}  -> DKMS rebuild failed. You may need to rebuild manually.${NC}"
            echo "  -> The udev rules will use 'new_id' as a fallback."
        fi
    fi
else
    echo "  -> aic_btusb DKMS source not found."
    echo "  -> Patches in linux/patches/ can be applied manually."
    echo "  -> The udev rule will attempt dynamic binding via 'new_id'."
fi
STEP=$((STEP + 1))

# Step 5: Install modprobe config (btusb conflict resolution)
echo -e "${GREEN}[$STEP/$TOTAL] Installing modprobe config (btusb conflict resolution)...${NC}"
mkdir -p /etc/modprobe.d
cp "$SCRIPT_DIR/modprobe/aic8800-bt.conf" /etc/modprobe.d/
echo "  -> /etc/modprobe.d/aic8800-bt.conf"
echo "  -> Generic btusb will defer to aic_btusb for AIC devices"
STEP=$((STEP + 1))

# Step 6: Ensure aic_btusb loads at boot
echo -e "${GREEN}[$STEP/$TOTAL] Configuring module autoload...${NC}"
if [ "$BT_MODULE_MISSING" != "1" ]; then
    mkdir -p /etc/modules-load.d
    if ! grep -qs 'aic_btusb' /etc/modules-load.d/aic8800.conf 2>/dev/null; then
        echo "aic_btusb" >> /etc/modules-load.d/aic8800.conf
        echo "  -> Added aic_btusb to /etc/modules-load.d/aic8800.conf"
    else
        echo "  -> aic_btusb already in modules-load.d"
    fi
else
    echo -e "  -> ${YELLOW}Skipped (aic_btusb module not installed yet)${NC}"
fi

echo
echo "=========================================="
echo -e "${GREEN} Installation complete!${NC}"
echo "=========================================="
echo
echo "Next steps:"
echo "  1. Unplug and re-plug the WiFi/BT adapter"
echo "  2. Check WiFi:"
echo "     lsusb                              # Should show a69c:8d83"
echo "     ip link show wlan1                  # WiFi interface"
echo "  3. Check Bluetooth:"
echo "     bluetoothctl show                   # Should show the BT controller"
echo "     bluetoothctl scan on                # Scan for BT devices"
echo
echo "Troubleshooting Bluetooth:"
echo "  - If 'bluetoothctl show' shows nothing:"
echo "      sudo dmesg | grep -i 'btusb\|aic_btusb\|hci'    # Check driver binding"
echo "      lsmod | grep bt                                   # Check loaded modules"
echo "  - If generic btusb claimed the device (HCI_Reset timeout):"
echo "      sudo rmmod btusb && sudo modprobe aic_btusb       # Rebind"
echo "  - If aic_btusb is not installed, build it from:"
echo "      https://github.com/radxa-pkg/aic8800"
echo
echo "Manual mode-switch test (if auto doesn't trigger):"
echo "  sudo sg_raw /dev/sg0 fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f2"
echo
