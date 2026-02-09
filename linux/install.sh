#!/bin/bash
# install.sh - All-in-one installer for AIC8800D80 "Pandora" (1111:1111) USB WiFi + Bluetooth
#
# This single script handles EVERYTHING:
#   1. Install prerequisites (usb-modeswitch, sg3-utils, build tools, kernel headers, dkms, curl)
#   2. DKMS driver setup (auto-install from Radxa source, or patch existing Brostrend/Radxa)
#   3. usb_modeswitch config for automatic mode switching
#   4. udev rules to trigger mode switch and driver binding on plug-in
#   5. Build and install aic_btusb from Radxa source
#   6. modprobe config (btusb conflict resolution)
#   7. Module autoload at boot
#   8. Reload modules and verify
#
# Works on:
#   - Fresh systems with no AIC8800 driver installed
#   - Systems with Brostrend DKMS (patches BT support in)
#   - Systems with Radxa .deb packages (removes _usb suffix modules, reinstalls correctly)
#   - Messy environments with broken/partial installs
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
RADXA_DIR="/tmp/radxa-aic-$$"

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
TOTAL=8

###############################################################################
# Shared Radxa clone helper
###############################################################################
ensure_radxa_clone() {
    if [ ! -d "$RADXA_DIR" ]; then
        echo "  -> Cloning Radxa aic8800 source (sparse)..."
        git clone --depth 1 --filter=blob:none --sparse \
            https://github.com/radxa-pkg/aic8800.git "$RADXA_DIR" 2>&1
        cd "$RADXA_DIR"
        git sparse-checkout set \
            src/USB/driver_fw/drivers/aic8800/aic_load_fw \
            src/USB/driver_fw/drivers/aic8800/aic8800_fdrv \
            src/USB/driver_fw/drivers/aic_btusb \
            src/USB/driver_fw/driver/aic_load_fw \
            src/USB/driver_fw/fw/aic8800D80 \
            debian/patches 2>&1
        cd - >/dev/null
        echo "  -> Radxa source ready at $RADXA_DIR"
    fi
}

###############################################################################
# Step 1: Install prerequisites
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Installing prerequisites...${NC}"

PKGS_NEEDED=""
command -v usb_modeswitch &>/dev/null || PKGS_NEEDED="$PKGS_NEEDED usb-modeswitch usb-modeswitch-data"
command -v sg_raw &>/dev/null         || PKGS_NEEDED="$PKGS_NEEDED sg3-utils"
command -v git &>/dev/null            || PKGS_NEEDED="$PKGS_NEEDED git"
command -v make &>/dev/null           || PKGS_NEEDED="$PKGS_NEEDED build-essential"
command -v dkms &>/dev/null           || PKGS_NEEDED="$PKGS_NEEDED dkms"
command -v curl &>/dev/null           || PKGS_NEEDED="$PKGS_NEEDED curl"
[ -d "/lib/modules/$KVER/build" ]     || PKGS_NEEDED="$PKGS_NEEDED linux-headers-$KVER"

if [ -n "$PKGS_NEEDED" ]; then
    echo "  -> Installing:$PKGS_NEEDED"
    apt-get update -qq && apt-get install -y $PKGS_NEEDED
else
    echo "  -> All prerequisites already installed."
fi
STEP=$((STEP + 1))

###############################################################################
# Step 2: DKMS Driver Setup
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] DKMS driver setup...${NC}"

# 2a. Unload modules early — before any changes
echo "  -> Unloading AIC modules..."
rmmod btusb 2>/dev/null || true
rmmod aic_btusb 2>/dev/null || true
rmmod aic8800_fdrv 2>/dev/null || true
rmmod aic_load_fw 2>/dev/null || true
rmmod aic8800_fdrv_usb 2>/dev/null || true
rmmod aic_load_fw_usb 2>/dev/null || true

# 2b. Detect current state
echo "  -> Detecting current DKMS state..."
DKMS_STATE="NONE"
DKMS_SRC=""
DKMS_VER=""
NEED_DKMS_REBUILD=0

# Check DKMS registrations
DKMS_ENTRIES=$(dkms status 2>/dev/null | grep -i aic8800 || true)
if [ -n "$DKMS_ENTRIES" ]; then
    echo "  -> DKMS entries found:"
    echo "$DKMS_ENTRIES" | while read -r line; do echo "     $line"; done
fi

# Check for _usb suffix modules (Radxa .deb install)
if dkms status 2>/dev/null | grep -qi 'aic8800.*usb'; then
    DKMS_STATE="RADXA_USB"
    echo -e "  -> ${CYAN}Detected: Radxa .deb install (_usb suffix modules)${NC}"
elif dpkg -l 2>/dev/null | grep -q 'aic8800-usb-dkms'; then
    DKMS_STATE="RADXA_USB"
    echo -e "  -> ${CYAN}Detected: Radxa .deb package (aic8800-usb-dkms)${NC}"
fi

# Check source directories
if [ "$DKMS_STATE" = "NONE" ]; then
    for d in /usr/src/aic8800-*/aic_load_fw; do
        if [ -d "$d" ]; then
            DKMS_SRC="$(dirname "$d")"
            DKMS_VER=$(basename "$DKMS_SRC" | sed 's/aic8800-//')
            break
        fi
    done

    if [ -n "$DKMS_SRC" ]; then
        # Check if this is our previous install
        if [ "$DKMS_VER" = "radxa" ]; then
            DKMS_STATE="OUR_INSTALL"
            echo -e "  -> ${GREEN}Detected: Previous install by this script (aic8800/radxa)${NC}"
        # Check for Brostrend (BT disabled with #if 0)
        elif [ -f "$DKMS_SRC/aic_load_fw/aic_compat_8800d80.c" ] && \
             grep -q '#if 0' "$DKMS_SRC/aic_load_fw/aic_compat_8800d80.c"; then
            DKMS_STATE="BROSTREND"
            echo -e "  -> ${CYAN}Detected: Brostrend DKMS (BT disabled with #if 0)${NC}"
        elif [ -n "$DKMS_ENTRIES" ]; then
            # Has DKMS source and entries, but not Brostrend or ours — could be working Radxa source build
            DKMS_STATE="OUR_INSTALL"
            echo -e "  -> ${GREEN}Detected: Existing DKMS install (aic8800/$DKMS_VER)${NC}"
        else
            # Source dir exists but no DKMS entry — broken
            DKMS_STATE="BROKEN"
            echo -e "  -> ${YELLOW}Detected: Broken state (source dir exists but no DKMS entry)${NC}"
        fi
    else
        # No source dir — check if there are stale DKMS entries
        if [ -n "$DKMS_ENTRIES" ]; then
            DKMS_STATE="BROKEN"
            echo -e "  -> ${YELLOW}Detected: Broken state (DKMS entries but no source dir)${NC}"
        fi
    fi
fi

echo "  -> State: $DKMS_STATE"

# 2c. Clean up broken state
if [ "$DKMS_STATE" = "BROKEN" ]; then
    echo -e "  -> ${YELLOW}Cleaning up broken DKMS state...${NC}"

    # Remove all aic8800 DKMS entries
    for entry in $(dkms status 2>/dev/null | grep -i aic8800 | sed 's/,.*//; s/ //g'); do
        pkg=$(echo "$entry" | cut -d/ -f1)
        ver=$(echo "$entry" | cut -d/ -f2 | cut -d: -f1)
        echo "     Removing DKMS: $pkg/$ver"
        dkms remove "$pkg/$ver" --all 2>/dev/null || true
    done

    # Remove orphaned DKMS source dirs
    for d in /usr/src/aic8800-*/; do
        if [ -d "$d" ]; then
            echo "     Removing orphaned source: $d"
            rm -rf "$d"
        fi
    done

    # Remove stale module files
    for mod in aic_load_fw aic8800_fdrv aic_load_fw_usb aic8800_fdrv_usb; do
        find "/lib/modules/$KVER/" -name "${mod}.ko*" -exec rm -f {} \; 2>/dev/null || true
    done

    DKMS_STATE="NONE"
    DKMS_SRC=""
    DKMS_VER=""
    echo "  -> Cleanup complete, proceeding with fresh install."
fi

# 2f. Handle Radxa .deb install (must come before NONE check since it transitions to NONE)
if [ "$DKMS_STATE" = "RADXA_USB" ]; then
    echo -e "  -> ${CYAN}Removing Radxa .deb packages (_usb suffix incompatible)...${NC}"
    echo "     Our setup requires Brostrend-compatible module names (no _usb suffix)."

    # Purge Radxa DKMS package
    if dpkg -l 2>/dev/null | grep -q 'aic8800-usb-dkms'; then
        echo "     Purging aic8800-usb-dkms..."
        dpkg --purge aic8800-usb-dkms 2>/dev/null || true
    fi

    # Purge Radxa firmware package
    if dpkg -l 2>/dev/null | grep -q 'aic8800-firmware'; then
        echo "     Purging aic8800-firmware..."
        dpkg --purge aic8800-firmware 2>/dev/null || true
    fi

    # Clean up any remaining DKMS entries
    for entry in $(dkms status 2>/dev/null | grep -i aic8800 | sed 's/,.*//; s/ //g'); do
        pkg=$(echo "$entry" | cut -d/ -f1)
        ver=$(echo "$entry" | cut -d/ -f2 | cut -d: -f1)
        echo "     Removing DKMS: $pkg/$ver"
        dkms remove "$pkg/$ver" --all 2>/dev/null || true
    done

    # Remove orphaned source and module files
    for d in /usr/src/aic8800*/; do
        [ -d "$d" ] && rm -rf "$d"
    done
    for mod in aic_load_fw_usb aic8800_fdrv_usb aic_load_fw aic8800_fdrv; do
        find "/lib/modules/$KVER/" -name "${mod}.ko*" -exec rm -f {} \; 2>/dev/null || true
    done

    DKMS_STATE="NONE"
    DKMS_SRC=""
    DKMS_VER=""
    echo "  -> Radxa .deb packages removed, proceeding with fresh install."
fi

# 2d. Fresh install from Radxa source
if [ "$DKMS_STATE" = "NONE" ]; then
    echo -e "  -> ${CYAN}Installing DKMS driver from Radxa source...${NC}"
    ensure_radxa_clone

    DKMS_SRC="/usr/src/aic8800-radxa"
    DKMS_VER="radxa"

    # Remove any previous attempt
    rm -rf "$DKMS_SRC"
    mkdir -p "$DKMS_SRC"

    # Copy driver source — try both possible paths in Radxa repo
    for base in \
        "$RADXA_DIR/src/USB/driver_fw/drivers/aic8800" \
        "$RADXA_DIR/src/USB/driver_fw/driver"; do
        if [ -d "$base/aic_load_fw" ]; then
            cp -r "$base/aic_load_fw" "$DKMS_SRC/aic_load_fw"
            echo "     Copied aic_load_fw source"
        fi
        if [ -d "$base/aic8800_fdrv" ]; then
            cp -r "$base/aic8800_fdrv" "$DKMS_SRC/aic8800_fdrv"
            echo "     Copied aic8800_fdrv source"
        fi
    done

    # Verify we got both modules
    if [ ! -d "$DKMS_SRC/aic_load_fw" ] || [ ! -d "$DKMS_SRC/aic8800_fdrv" ]; then
        echo -e "${RED}  -> ERROR: Could not find driver source in Radxa repo.${NC}"
        echo "  -> Expected aic_load_fw and aic8800_fdrv directories."
        exit 1
    fi

    # Generate Brostrend-compatible dkms.conf
    cat > "$DKMS_SRC/dkms.conf" << 'DKMS_EOF'
PACKAGE_NAME="aic8800"
PACKAGE_VERSION="radxa"

MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/aic8800/radxa/build/aic_load_fw modules && make -C ${kernel_source_dir} M=${dkms_tree}/aic8800/radxa/build/aic8800_fdrv modules"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/aic8800/radxa/build/aic_load_fw clean; make -C ${kernel_source_dir} M=${dkms_tree}/aic8800/radxa/build/aic8800_fdrv clean"

BUILT_MODULE_NAME[0]="aic_load_fw"
BUILT_MODULE_LOCATION[0]="aic_load_fw"
DEST_MODULE_LOCATION[0]="/updates/dkms"

BUILT_MODULE_NAME[1]="aic8800_fdrv"
BUILT_MODULE_LOCATION[1]="aic8800_fdrv"
DEST_MODULE_LOCATION[1]="/updates/dkms"

AUTOINSTALL="yes"
DKMS_EOF
    echo "     Generated dkms.conf (Brostrend-compatible naming)"

    # Copy firmware files
    FW_SRC="$RADXA_DIR/src/USB/driver_fw/fw/aic8800D80"
    FW_DEST="/lib/firmware/aic8800D80"
    if [ -d "$FW_SRC" ]; then
        mkdir -p "$FW_DEST"
        cp -v "$FW_SRC"/*.bin "$FW_DEST/" 2>/dev/null || true
        echo "     Copied firmware to $FW_DEST/"
    else
        echo -e "  -> ${YELLOW}Warning: Firmware source not found at $FW_SRC${NC}"
        echo "     Firmware may need to be installed separately."
    fi

    # Apply kernel compat patches from debian/patches/
    PATCH_DIR="$RADXA_DIR/debian/patches"
    SERIES_FILE="$PATCH_DIR/series"
    if [ -f "$SERIES_FILE" ]; then
        echo "     Applying kernel compatibility patches..."
        while IFS= read -r patch_name; do
            # Skip empty lines and comments
            [ -z "$patch_name" ] && continue
            [[ "$patch_name" =~ ^# ]] && continue

            PATCH_FILE="$PATCH_DIR/$patch_name"
            [ ! -f "$PATCH_FILE" ] && continue

            # Only apply patches relevant to aic_load_fw or aic8800_fdrv
            if grep -qE 'aic_load_fw|aic8800_fdrv' "$PATCH_FILE" 2>/dev/null; then
                echo "     Applying: $patch_name"
                # Patches are relative to the Radxa repo root, we need to adjust strip level
                # The patches target paths like src/USB/driver_fw/drivers/aic8800/aic_load_fw/...
                # or src/USB/driver_fw/driver/aic_load_fw/...
                # We need to strip down to the module dir level
                # Try -p6 first (src/USB/driver_fw/drivers/aic8800/), then -p5 (src/USB/driver_fw/driver/)
                cd "$DKMS_SRC"
                if ! patch -p6 --forward --ignore-whitespace --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
                    if ! patch -p5 --forward --ignore-whitespace --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
                        echo "       (skipped - does not apply at -p5 or -p6)"
                        cd - >/dev/null
                        continue
                    else
                        patch -p5 --forward --ignore-whitespace < "$PATCH_FILE" 2>&1 || true
                    fi
                else
                    patch -p6 --forward --ignore-whitespace < "$PATCH_FILE" 2>&1 || true
                fi
                cd - >/dev/null
            fi
        done < "$SERIES_FILE"
    fi

    # Register with DKMS
    echo "     Registering with DKMS..."
    dkms add aic8800/radxa 2>/dev/null || true
    NEED_DKMS_REBUILD=1
    echo -e "  -> ${GREEN}DKMS source installed at $DKMS_SRC${NC}"
fi

# 2e. Patch existing Brostrend DKMS
if [ "$DKMS_STATE" = "BROSTREND" ]; then
    echo -e "  -> ${CYAN}Patching Brostrend DKMS for Bluetooth support...${NC}"
    ensure_radxa_clone

    COMPAT_FILE="$DKMS_SRC/aic_load_fw/aic_compat_8800d80.c"

    # Find Radxa version of aic_compat_8800d80.c
    RADXA_COMPAT=""
    for path in \
        "$RADXA_DIR/src/USB/driver_fw/driver/aic_load_fw/aic_compat_8800d80.c" \
        "$RADXA_DIR/src/USB/driver_fw/drivers/aic8800/aic_load_fw/aic_compat_8800d80.c"; do
        if [ -f "$path" ]; then
            RADXA_COMPAT="$path"
            break
        fi
    done

    if [ -n "$RADXA_COMPAT" ]; then
        cp "$RADXA_COMPAT" "$COMPAT_FILE"
        echo -e "  -> ${GREEN}Replaced aic_compat_8800d80.c with Radxa version (BT enabled)${NC}"
        NEED_DKMS_REBUILD=1
    else
        echo -e "${RED}  -> ERROR: Could not find Radxa aic_compat_8800d80.c${NC}"
        echo "  -> Sparse checkout may have failed. Check network connectivity."
        exit 1
    fi
fi

# 2g. Skip if already installed by us
if [ "$DKMS_STATE" = "OUR_INSTALL" ]; then
    echo -e "  -> ${GREEN}Already installed by this script.${NC}"

    # Verify BT firmware strings present in compiled module
    MODULE_PATH="/lib/modules/$KVER/updates/dkms/aic_load_fw.ko"
    MODULE_XZ="${MODULE_PATH}.xz"
    BT_OK=0
    if [ -f "$MODULE_XZ" ]; then
        if xz -dc "$MODULE_XZ" 2>/dev/null | strings | grep -q 'fw_adid_8800d80'; then
            BT_OK=1
        fi
    elif [ -f "$MODULE_PATH" ]; then
        if strings "$MODULE_PATH" | grep -q 'fw_adid_8800d80'; then
            BT_OK=1
        fi
    fi

    if [ "$BT_OK" = "1" ]; then
        echo "  -> Verified: BT firmware strings present in compiled module."
    else
        echo -e "  -> ${YELLOW}BT firmware strings NOT found in compiled module — rebuilding.${NC}"
        NEED_DKMS_REBUILD=1
    fi
fi

# 2h. Common: Patch WiFi VID:PID (add a69c:8d83 if not present)
if [ -n "$DKMS_SRC" ]; then
    WIFI_SRC="$DKMS_SRC/aic8800_fdrv/aicwf_usb.c"
    if [ -f "$WIFI_SRC" ]; then
        if grep -q "0xa69c.*0x8d83\|USB_PRODUCT_ID_AIC8800M80_CUS1" "$WIFI_SRC"; then
            echo "  -> WiFi driver already has a69c:8d83 in USB ID table."
        else
            echo -e "  -> ${CYAN}Patching WiFi driver to add a69c:8d83...${NC}"
            sed -i '/USB_DEVICE_ID_AIC_8800D80/a\\t{USB_DEVICE(0xa69c, 0x8d83)},   /* Pandora clone post-switch */' "$WIFI_SRC"
            echo "  -> Added a69c:8d83 to WiFi USB ID table."
            NEED_DKMS_REBUILD=1
        fi
    fi
fi

# 2i. Rebuild DKMS (if any patches were applied or fresh install)
if [ "$NEED_DKMS_REBUILD" = "1" ] && [ -n "$DKMS_VER" ]; then
    echo -e "  -> ${CYAN}Rebuilding DKMS module...${NC}"

    echo "     Removing old DKMS build..."
    dkms remove "aic8800/$DKMS_VER" -k "$KVER" 2>/dev/null || true

    # Re-add if it was removed
    dkms add "aic8800/$DKMS_VER" 2>/dev/null || true

    echo "     Building DKMS module..."
    if dkms build "aic8800/$DKMS_VER" -k "$KVER"; then
        echo "     Installing DKMS module..."
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
elif [ "$NEED_DKMS_REBUILD" = "0" ]; then
    echo "  -> No DKMS patches needed, skipping rebuild."
fi

# 2j. Verify firmware files exist
echo "  -> Verifying firmware files..."
FW_DEST="/lib/firmware/aic8800D80"
FW_FILES="fmacfw_8800d80_u02.bin fw_adid_8800d80_u02.bin fw_patch_8800d80_u02.bin fw_patch_table_8800d80_u02.bin"
FW_MISSING=0
for fw in $FW_FILES; do
    if [ ! -f "$FW_DEST/$fw" ]; then
        FW_MISSING=1
        echo -e "  -> ${YELLOW}Missing: $FW_DEST/$fw${NC}"
    fi
done

if [ "$FW_MISSING" = "1" ]; then
    echo "  -> Copying firmware from Radxa source..."
    ensure_radxa_clone
    FW_SRC="$RADXA_DIR/src/USB/driver_fw/fw/aic8800D80"
    if [ -d "$FW_SRC" ]; then
        mkdir -p "$FW_DEST"
        cp -v "$FW_SRC"/*.bin "$FW_DEST/" 2>/dev/null || true
        echo -e "  -> ${GREEN}Firmware files installed.${NC}"
    else
        echo -e "  -> ${YELLOW}Warning: Firmware source not found in Radxa repo.${NC}"
        echo "  -> The driver may not work without firmware files."
    fi
else
    echo -e "  -> ${GREEN}All firmware files present.${NC}"
fi
STEP=$((STEP + 1))

###############################################################################
# Step 3: Install usb_modeswitch config
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Installing usb_modeswitch config...${NC}"
mkdir -p /etc/usb_modeswitch.d
cp "$SCRIPT_DIR/usb_modeswitch/1111_1111" "/etc/usb_modeswitch.d/1111:1111"
echo "  -> /etc/usb_modeswitch.d/1111:1111"
STEP=$((STEP + 1))

###############################################################################
# Step 4: Install udev rules
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Installing udev rules (WiFi + Bluetooth)...${NC}"
cp "$SCRIPT_DIR/udev/41-aic8800d80-modeswitch.rules" /etc/udev/rules.d/
udevadm control --reload-rules
echo "  -> /etc/udev/rules.d/41-aic8800d80-modeswitch.rules"
echo "  -> udev rules reloaded"
STEP=$((STEP + 1))

###############################################################################
# Step 5: Build and install aic_btusb
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Building aic_btusb Bluetooth driver...${NC}"

if modinfo aic_btusb &>/dev/null 2>&1; then
    echo "  -> aic_btusb module already installed."
    echo -e "  -> ${YELLOW}Rebuilding anyway to ensure latest patches...${NC}"
fi

ensure_radxa_clone

WORK_DIR="/tmp/aic_btusb_build_$$"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Copy aic_btusb source from shared Radxa clone
BTUSB_SRC=""
for path in \
    "$RADXA_DIR/src/USB/driver_fw/drivers/aic_btusb" \
    "$RADXA_DIR/src/USB/driver_fw/driver/aic_btusb"; do
    if [ -d "$path" ]; then
        BTUSB_SRC="$path"
        break
    fi
done

if [ -z "$BTUSB_SRC" ]; then
    echo -e "${RED}  -> ERROR: Could not find aic_btusb source in Radxa repo.${NC}"
    exit 1
fi

cp -r "$BTUSB_SRC" "$WORK_DIR/aic_btusb_src"
cd "$WORK_DIR/aic_btusb_src"
echo "  -> Source ready at $WORK_DIR/aic_btusb_src"

# Apply Radxa kernel compatibility patches (-p6 strip level)
echo "  -> Applying compatibility patches..."
PATCH_DIR="$RADXA_DIR/debian/patches"
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
# Step 6: Install modprobe config (btusb conflict resolution)
###############################################################################
echo -e "${GREEN}[$STEP/$TOTAL] Installing modprobe config (btusb conflict resolution)...${NC}"
mkdir -p /etc/modprobe.d
cp "$SCRIPT_DIR/modprobe/aic8800-bt.conf" /etc/modprobe.d/
echo "  -> /etc/modprobe.d/aic8800-bt.conf"
echo "  -> Generic btusb will defer to aic_btusb for AIC devices"
STEP=$((STEP + 1))

###############################################################################
# Step 7: Configure module autoload at boot
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
# Step 8: Reload modules and verify
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

# Cleanup Radxa clone
rm -rf "$RADXA_DIR"

echo
echo "=========================================="
echo -e "${GREEN} Installation complete!${NC}"
echo "=========================================="
echo
echo "What was installed:"
echo "  - DKMS driver (aic_load_fw + aic8800_fdrv with BT enabled)"
echo "  - Firmware files in /lib/firmware/aic8800D80/"
echo "  - usb_modeswitch config (auto mode-switch on plug-in)"
echo "  - udev rules (auto driver binding)"
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
