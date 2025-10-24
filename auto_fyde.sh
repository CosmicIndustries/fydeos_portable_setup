#!/usr/bin/env bash
# auto_fyde.sh — morphogenic, adaptive FydeOS setup installer
# Author: Dinadeyohvsgi
set -euo pipefail
IFS=$'\n\t'

LOGFILE="$HOME/fydeos_portable_setup/auto_fyde.log"
mkdir -p "$(dirname "$LOGFILE")"
exec 3>&1 1>>"$LOGFILE" 2>&1

echo "[*] Starting morphogenic FydeOS installer..."

# -------------------------------
# 1) Detect environment
# -------------------------------
USER_DETECT=$(whoami)
CHRONOS_USER=${USER_DETECT:-chronos}
echo "[*] Using user: $CHRONOS_USER"

USB_BOOT_DEV=$(lsblk -dpno NAME,RM,SIZE | awk '$2==1 {print $1}' | sort -r -k2 | head -n1)
echo "[*] Detected USB boot device: $USB_BOOT_DEV"

USB_PERSIST_DEV=$(blkid -o device -t TYPE=ext4 | grep "$USB_BOOT_DEV" | head -n1)
USB_PERSIST_DEV=${USB_PERSIST_DEV:-$USB_BOOT_DEV}
echo "[*] Candidate persistence partition: $USB_PERSIST_DEV"

MOUNT_POINT="/mnt/fyde_usb"
mkdir -p "$MOUNT_POINT"

MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_MB=$((MEM_KB/1024))
CPU_CORES=$(nproc)
ZRAM_DEV_COUNT=$((CPU_CORES < 2 ? 1 : CPU_CORES/2))
echo "[*] Memory: ${MEM_MB}MB, CPU cores: $CPU_CORES, zram devices: $ZRAM_DEV_COUNT"

# -------------------------------
# 2) Generate per-system config
# -------------------------------
CONFIG_FILE="$HOME/fydeos_portable_setup/extra_config.sh"
cat >"$CONFIG_FILE" <<EOF
USB_PERSIST_DEV="$USB_PERSIST_DEV"
USB_BOOT_DEV="$USB_BOOT_DEV"
CHRONOS_USER="$CHRONOS_USER"
MOUNT_POINT="$MOUNT_POINT"
ZRAM_DEV_COUNT=$ZRAM_DEV_COUNT
TMPFS_TMP_SIZE="256M"
TMPFS_VARLOG_SIZE="128M"
TMPFS_VARCACHE_SIZE="128M"
RSYNC_KEEP=14
EOF
echo "[*] Generated system-specific config at $CONFIG_FILE"

# Inject into extra.sh
EXTRA_SH="$HOME/fydeos_portable_setup/extra.sh"
if grep -q "### AUTO-INJECT CONFIG START ###" "$EXTRA_SH"; then
    sed -i "/### AUTO-INJECT CONFIG START ###/,/### AUTO-INJECT CONFIG END ###/c\\
$(sed 's/$/\\n/' "$CONFIG_FILE")" "$EXTRA_SH"
else
    echo -e "\n### AUTO-INJECT CONFIG START ###\n$(cat "$CONFIG_FILE")\n### AUTO-INJECT CONFIG END ###" >> "$EXTRA_SH"
fi
echo "[*] extra.sh variables updated."

# -------------------------------
# 3) Non-destructive tasks first
# -------------------------------
echo "[*] Running safe tasks..."
sudo "$EXTRA_SH" verify || true
sudo "$EXTRA_SH" tmpfs
sudo "$EXTRA_SH" snapshots
sudo "$EXTRA_SH" dotfiles
sudo "$EXTRA_SH" adb
sudo "$EXTRA_SH" ci

# -------------------------------
# 4) Destructive tasks (LUKS / restore) with confirmation
# -------------------------------
read -p "Do you want to setup LUKS persistence now? (y/N): " LUKS_CONFIRM
if [[ "${LUKS_CONFIRM,,}" == "y" ]]; then
    echo "[*] LUKS setup will destroy data on $USB_PERSIST_DEV"
    sudo "$EXTRA_SH" luks
fi

read -p "Do you want to restore USB backup now? (y/N): " RESTORE_CONFIRM
if [[ "${RESTORE_CONFIRM,,}" == "y" ]]; then
    read -p "Enter backup image path: " IMG_PATH
    if [ -f "$IMG_PATH" ]; then
        sudo /usr/local/bin/usb_image_restore.sh "$IMG_PATH"
    else
        echo "Backup image not found: $IMG_PATH"
    fi
fi

# -------------------------------
# 5) Optional overlayfs & hotplug
# -------------------------------
read -p "Do you want to install overlayfs for /home? (y/N): " OVERLAY_CONFIRM
if [[ "${OVERLAY_CONFIRM,,}" == "y" ]]; then
    sudo "$EXTRA_SH" overlay
fi

read -p "Do you want to install USB hotplug hooks? (y/N): " HOTPLUG_CONFIRM
if [[ "${HOTPLUG_CONFIRM,,}" == "y" ]]; then
    sudo "$EXTRA_SH" hotplug
fi

echo "[*] Morphogenic installer finished. Review logs: $LOGFILE"
echo "[*] Reboot recommended to apply tmpfs, zram, and overlay changes."
