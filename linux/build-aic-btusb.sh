#!/bin/bash
# Build and install aic_btusb for AIC8800D80 Bluetooth on Raspberry Pi
#
# IMPORTANT: For D80, the BT firmware is loaded by aic_load_fw (not aic_btusb).
# You MUST have the Radxa version of aic_load_fw with BT support enabled.
# If using Brostrend DKMS, replace aic_compat_8800d80.c with the Radxa version
# and rebuild DKMS: sudo dkms remove/build/install aic8800/<version>
#
# Run as: sudo bash build-aic-btusb.sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=========================================="
echo " AIC8800D80 Bluetooth Driver Builder"
echo "=========================================="
echo

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Run as root (sudo).${NC}"
    exit 1
fi

KVER=$(uname -r)
echo "Kernel: $KVER"
echo

# Check kernel headers
if [ ! -d "/lib/modules/$KVER/build" ]; then
    echo -e "${YELLOW}Kernel headers not found. Installing...${NC}"
    apt-get update && apt-get install -y "linux-headers-$KVER"
fi

WORK_DIR="/tmp/aic_btusb_build"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Step 1: Clone radxa-pkg/aic8800 (sparse checkout for speed)
echo -e "${GREEN}[1/6] Cloning aic_btusb source...${NC}"
git clone --depth 1 --filter=blob:none --sparse https://github.com/radxa-pkg/aic8800.git 2>&1
cd aic8800
git sparse-checkout set src/USB/driver_fw/drivers/aic_btusb debian/patches 2>&1
cd ..

# Copy the aic_btusb source to work area
cp -r aic8800/src/USB/driver_fw/drivers/aic_btusb "$WORK_DIR/aic_btusb_src"
cd "$WORK_DIR/aic_btusb_src"

echo "  -> Source copied to $WORK_DIR/aic_btusb_src"
echo "  -> Files: $(ls)"

# Step 2: Apply Radxa patches for kernel compatibility
echo -e "${GREEN}[2/6] Applying compatibility patches...${NC}"

PATCH_DIR="$WORK_DIR/aic8800/debian/patches"

# Apply aic_btusb build fix patches (-p6 strip level from inside aic_btusb dir)
for patch_name in fix-aic_btusb.patch fix-aic_btusb-implicit-declare-compat_ptr.patch; do
    PATCH_FILE="$PATCH_DIR/$patch_name"
    if [ -f "$PATCH_FILE" ]; then
        echo "  -> Applying $patch_name..."
        patch -p6 --forward --ignore-whitespace < "$PATCH_FILE" 2>&1 || echo "  -> (already applied or N/A)"
    fi
done

# Step 3: Apply BlueZ fix (CONFIG_BLUEDROID: 1 -> 0)
echo -e "${GREEN}[3/6] Applying BlueZ fix (CONFIG_BLUEDROID=0)...${NC}"
# Fix both #ifdef branches (UBUNTU and non-UBUNTU)
# Use precise match to avoid mangling comments
if grep -q 'BLUEDROID        1' aic_btusb.h; then
    sed -i 's/BLUEDROID        1/BLUEDROID        0/g' aic_btusb.h
    echo "  -> CONFIG_BLUEDROID changed from 1 to 0"
else
    echo "  -> Already set to 0"
fi

# Verify
echo "  -> Current setting:"
grep -n 'CONFIG_BLUEDROID' aic_btusb.h | head -4

# Step 4: Add Pandora clone PIDs to USB ID table
echo -e "${GREEN}[4/6] Adding Pandora clone PIDs...${NC}"

# PID 0x8d83: Brostrend firmware post-switch (WiFi-only mode, no BT interfaces)
if grep -q '0x8d83' aic_btusb.c; then
    echo "  -> PID 0x8d83 already in table"
else
    sed -i '/USB_PRODUCT_ID_AIC8800D80.*0xe0.*0x01.*0x01/a\\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDOR_ID_AIC, 0x8d83, 0xe0, 0x01, 0x01)},   /* Pandora clone: a69c:8d83 */' aic_btusb.c
    echo "  -> Added PID 0x8d83 (Brostrend firmware)"
fi

# PID 0x8d81 is already in the table as USB_PRODUCT_ID_AIC8800D80
echo "  -> PID 0x8d81 already in table (USB_PRODUCT_ID_AIC8800D80)"

# Verify
echo "  -> USB ID table entries for 8d8x:"
grep '0x8d8' aic_btusb.c | head -5

# Step 5: Build
echo -e "${GREEN}[5/6] Building aic_btusb module...${NC}"
make KDIR="/lib/modules/$KVER/build" CONFIG_PLATFORM_UBUNTU=y 2>&1
echo
if [ -f "aic_btusb.ko" ]; then
    echo -e "  -> ${GREEN}Build successful!${NC} aic_btusb.ko created"
    ls -la aic_btusb.ko
else
    echo -e "  -> ${RED}Build failed!${NC}"
    exit 1
fi

# Step 6: Install
echo -e "${GREEN}[6/6] Installing module...${NC}"

# Install module
MODDIR="/lib/modules/$KVER/kernel/drivers/bluetooth"
mkdir -p "$MODDIR"
cp aic_btusb.ko "$MODDIR/"
depmod -a "$KVER"
echo "  -> Installed to $MODDIR/aic_btusb.ko"
echo "  -> depmod updated"

# Install modprobe config
cat > /etc/modprobe.d/aic8800-bt.conf << 'MODPROBE_EOF'
# AIC8800D80 Bluetooth - prevent generic btusb from claiming the device
softdep btusb pre: aic_btusb
alias usb:v0A69Cp8D81d*dc*dsc*dp*icE0isc01ip01in* aic_btusb
alias usb:v0A69Cp8D83d*dc*dsc*dp*icE0isc01ip01in* aic_btusb
MODPROBE_EOF
echo "  -> /etc/modprobe.d/aic8800-bt.conf installed"

# Add to modules-load.d for boot persistence
mkdir -p /etc/modules-load.d
if ! grep -qs 'aic_btusb' /etc/modules-load.d/aic8800.conf 2>/dev/null; then
    echo "aic_btusb" >> /etc/modules-load.d/aic8800.conf
    echo "  -> Added to /etc/modules-load.d/aic8800.conf"
fi

echo
echo "=========================================="
echo -e "${GREEN} Build and install complete!${NC}"
echo "=========================================="
echo
echo "Now loading aic_btusb..."

# Unload btusb if it claimed our device
rmmod btusb 2>/dev/null || true

# Load aic_btusb
modprobe aic_btusb 2>&1 || insmod aic_btusb.ko 2>&1
echo

# Try binding to the device (both possible PIDs)
for PID in 8d81 8d83; do
    echo "a69c $PID" > /sys/bus/usb/drivers/aic_btusb/new_id 2>/dev/null || true
done
sleep 2

# Unblock rfkill if needed
rfkill unblock bluetooth 2>/dev/null || true
hciconfig hci1 up 2>/dev/null || true
sleep 1

# Check result
echo
echo "=== Results ==="
echo "Loaded modules:"
lsmod | grep -iE 'aic|bt' || echo "(none)"
echo
echo "HCI devices:"
hciconfig -a 2>&1
echo
echo "USB driver binding:"
lsusb -t 2>&1
echo
echo "bluetoothctl:"
echo "show" | timeout 3 bluetoothctl 2>&1 | head -10 || true
echo
echo "dmesg (last BT-related messages):"
dmesg | grep -iE 'aic_btusb|btusb|hci|bluetooth' | tail -15
echo
echo -e "${YELLOW}NOTE: For D80, BT firmware is loaded by aic_load_fw (not aic_btusb).${NC}"
echo -e "${YELLOW}If BT doesn't work, ensure aic_load_fw has Radxa BT support enabled.${NC}"
echo -e "${YELLOW}See README.md for details on patching aic_load_fw.${NC}"
