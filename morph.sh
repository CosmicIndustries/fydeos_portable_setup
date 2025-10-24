#!/usr/bin/env bash
# morph.sh — Generate system-specific extra.sh config & optionally run tasks
set -euo pipefail
IFS=$'\n\t'

LOGFILE="$HOME/fydeos_portable_setup/morph.log"
mkdir -p "$(dirname "$LOGFILE")"
exec 3>&1 1>>"$LOGFILE" 2>&1

echo "[*] Starting morphogenic detection..."

# 1) Detect main user (chronos default fallback)
USER_DETECT=$(whoami)
CHRONOS_USER=${USER_DETECT:-chronos}
echo "[*] Using user: $CHRONOS_USER"

# 2) Detect live USB device (largest removable block device not mounted)
USB_BOOT_DEV=$(lsblk -dpno NAME,RM,SIZE | awk '$2==1 {print $1}' | sort -r -k2 | head -n1)
echo "[*] Detected USB boot device: $USB_BOOT_DEV"

# 3) Find persistent partition (by label or ext4 filesystem on USB)
USB_PERSIST_DEV=$(blkid -o device -t TYPE=ext4 | grep "$USB_BOOT_DEV" | head -n1)
if [ -z "$USB_PERSIST_DEV" ]; then
  USB_PERSIST_DEV="$USB_BOOT_DEV" # fallback to whole device
fi
echo "[*] Persistence partition candidate: $USB_PERSIST_DEV"

# 4) Mount point detection
MOUNT_POINT="/mnt/fyde_usb"
mkdir -p "$MOUNT_POINT"

# 5) Memory & CPU detection
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_MB=$((MEM_KB/1024))
CPU_CORES=$(nproc)
ZRAM_DEV_COUNT=$((CPU_CORES < 2 ? 1 : CPU_CORES/2))
echo "[*] Detected memory: ${MEM_MB}MB, CPU cores: $CPU_CORES, zram devices: $ZRAM_DEV_COUNT"

# 6) Generate extra.sh variables dynamically
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

# 7) Inject config into extra.sh
EXTRA_SH="$HOME/fydeos_portable_setup/extra.sh"
if grep -q "### AUTO-INJECT CONFIG START ###" "$EXTRA_SH"; then
    sed -i "/### AUTO-INJECT CONFIG START ###/,/### AUTO-INJECT CONFIG END ###/c\\
$(sed 's/$/\\n/' "$CONFIG_FILE")" "$EXTRA_SH"
else
    echo -e "\n### AUTO-INJECT CONFIG START ###\n$(cat "$CONFIG_FILE")\n### AUTO-INJECT CONFIG END ###" >> "$EXTRA_SH"
fi
echo "[*] extra.sh variables updated."

# 8) Dry-run verification
echo "[*] Running safe verification..."
sudo "$EXTRA_SH" verify

echo "[*] Morphogenic setup complete. Review logs: $LOGFILE"
