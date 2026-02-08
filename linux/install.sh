#!/bin/bash
# install.sh - Set up AIC8800D80 "Pandora" (1111:1111) USB WiFi adapter on Linux
#
# This script installs:
#   1. usb_modeswitch config for automatic mode switching
#   2. udev rule to trigger mode switch on plug-in
#   3. Dynamic VID:PID fix for aic8800_fdrv driver binding
#
# Prerequisites:
#   - usb_modeswitch package installed
#   - sg3-utils package installed (for manual testing)
#   - AIC8800 DKMS driver installed (aic_load_fw + aic8800_fdrv)
#
# Usage: sudo bash install.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo " AIC8800D80 Pandora (1111:1111) Installer"
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
    echo "See: https://linux.brostrend.com/ or https://github.com/goecho/aic8800_linux_drvier"
    echo
fi

# Step 1: Install usb_modeswitch config
echo -e "${GREEN}[1/3] Installing usb_modeswitch config...${NC}"
mkdir -p /etc/usb_modeswitch.d
cp "$SCRIPT_DIR/usb_modeswitch/1111_1111" "/etc/usb_modeswitch.d/1111:1111"
echo "  -> /etc/usb_modeswitch.d/1111:1111"

# Step 2: Install udev rule
echo -e "${GREEN}[2/3] Installing udev rule...${NC}"
cp "$SCRIPT_DIR/udev/41-aic8800d80-modeswitch.rules" /etc/udev/rules.d/
udevadm control --reload-rules
echo "  -> /etc/udev/rules.d/41-aic8800d80-modeswitch.rules"
echo "  -> udev rules reloaded"

# Step 3: Patch driver if DKMS source exists
echo -e "${GREEN}[3/3] Checking driver VID:PID table...${NC}"

DRIVER_SRC="/usr/src/aic8800-1.0.8/aic8800_fdrv/aicwf_usb.c"
if [ -f "$DRIVER_SRC" ]; then
    if grep -q "0xa69c.*0x8d83\|USB_PRODUCT_ID_AIC8800M80_CUS1" "$DRIVER_SRC"; then
        echo "  -> Driver already has a69c:8d83 in USB ID table."
    else
        echo "  -> Patching driver source to add a69c:8d83..."
        # Find the USB ID table and add our entry
        sed -i '/USB_DEVICE_ID_AIC_8800D80/a\\t{USB_DEVICE(0xa69c, 0x8d83)},   /* Pandora clone post-switch */' "$DRIVER_SRC"
        echo "  -> Rebuilding DKMS module..."
        if dkms build aic8800/1.0.8 && dkms install aic8800/1.0.8 --force; then
            echo "  -> DKMS rebuild successful!"
        else
            echo -e "${YELLOW}  -> DKMS rebuild failed. Using dynamic new_id fallback (udev rule).${NC}"
        fi
    fi
else
    echo "  -> DKMS source not found at $DRIVER_SRC"
    echo "  -> The udev rule will use 'new_id' to bind the driver dynamically."
fi

echo
echo "=========================================="
echo -e "${GREEN} Installation complete!${NC}"
echo "=========================================="
echo
echo "Next steps:"
echo "  1. Unplug and re-plug the WiFi adapter"
echo "  2. Check with: lsusb"
echo "     - Should briefly show 1111:1111, then switch to a69c:8d80, then a69c:8d83"
echo "  3. Check with: ip link"
echo "     - Should show a new wlan interface"
echo "  4. Connect to WiFi: sudo nmcli device wifi connect 'YourSSID' password 'YourPass'"
echo
echo "Manual test (if auto mode-switch doesn't trigger):"
echo "  sudo sg_raw /dev/sg0 fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f2"
echo
