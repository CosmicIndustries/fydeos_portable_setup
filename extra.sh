#!/usr/bin/env bash
# extra.sh — Collated FydeOS portable USB enhancements
# - LUKS persistent partition
# - overlayfs for /home
# - tmpfs + flush
# - zram swap
# - atomic rsync snapshots
# - udev/systemd hotplug for persistence mount -> run metadata script
# - bare git dotfiles repo with deploy hook
# - compressed USB image backup/restore helper
# - adb over network helper
# - CI skeleton scaffold
#
# Usage: sudo ./extra.sh <component>
# components: all | luks | overlay | tmpfs | zram | snapshots | hotplug | dotfiles | backup | adb | ci | verify
#
# READ: Edit VARIABLES below to match your device/paths before running.
set -euo pipefail
IFS=$'\n\t'

LOGFILE="/var/log/extra_sh.log"
exec 3>&1 1>>"$LOGFILE" 2>&1

# --- Variables (EDIT THESE) ---
USB_PERSIST_DEV="/dev/sdb2"            # Partition to convert to LUKS persistent (destructive)
USB_PERSIST_LABEL="FYDE_PERSIST"       # Label to detect in udev rules
MAPPER_NAME="fyde_persist"             # cryptsetup mapper name
MOUNT_POINT="/mnt/usb_persist"         # persistent mountpoint
CHRONOS_USER="chronos"                 # username to chown persistent dirs
METADATA_SCRIPT="/home/chronos/scripts/metadata_cleaner.py"  # metadata script to run on hotplug
USB_BOOT_DEV="/dev/sdb"                # whole USB device for imaging (used by backup)
DOTFILES_DIR="/home/chronos/.cfg"      # bare repo path
RSYNC_KEEP=14                          # keep last N snapshots
ZRAM_DEV_COUNT=1
TMPFS_TMP_SIZE="256M"
TMPFS_VARLOG_SIZE="128M"
TMPFS_VARCACHE_SIZE="128M"
RSYNC_SOURCE="/home/chronos"
BACKUP_DIR="$MOUNT_POINT/backups"
CI_SCAFFOLD_DIR="/home/chronos/fydeos_overlay_ci"
# --- End editable vars ---

# internal
TIMESTAMP() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "$(TIMESTAMP) $*" >&3; echo "$(TIMESTAMP) $*" >>"$LOGFILE"; }
err() { echo "$(TIMESTAMP) ERROR: $*" >&3; echo "$(TIMESTAMP) ERROR: $*" >>"$LOGFILE"; }

trap 'err "Script aborted at line $LINENO"; exit 1' ERR INT TERM

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root. Use sudo."
    exit 2
  fi
}

check_tools() {
  local missing=()
  for t in cryptsetup rsync smartctl udevadm systemctl git pv dd gzip adb; do
    if ! command -v "$t" >/dev/null 2>&1; then
      missing+=("$t")
    fi
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    err "Missing required tools: ${missing[*]}. Install them in the Linux container or host (apt install ...)."
    # we don't exit automatically for more flexibility
  fi
}

confirm() {
  local prompt="$1"; shift
  echo
  read -p "$prompt Type 'YES' to continue: " CONF
  if [ "$CONF" != "YES" ]; then
    echo "Aborted by user."
    exit 3
  fi
}

remount_root_rw() {
  log "Remounting root filesystem as read-write..."
  if mount | grep -q ' on / type '; then
    mount -o remount,rw /
    log "Root remounted rw."
  else
    err "Unable to detect root mount; skipping remount."
  fi
}

# ----------------------------
# 1) LUKS encryption of persistence partition
# ----------------------------
task_luks() {
  require_root
  check_tools
  if [ ! -b "$USB_PERSIST_DEV" ]; then
    err "Persistence device '$USB_PERSIST_DEV' not found or not a block device."
    exit 4
  fi

  echo
  echo ">> LUKS setup will DESTROY ALL DATA on $USB_PERSIST_DEV"
  confirm "Confirm you want to format $USB_PERSIST_DEV as LUKS."

  remount_root_rw

  # optional header wipe
  read -p "Wipe first 4MiB of $USB_PERSIST_DEV before formatting? (y/N): " wipe
  if [ "${wipe,,}" = "y" ]; then
    log "Wiping header on $USB_PERSIST_DEV (first 4MiB)..."
    dd if=/dev/zero of="$USB_PERSIST_DEV" bs=1M count=4 conv=fsync status=progress
  fi

  log "Creating LUKS2 container..."
  cryptsetup luksFormat --type luks2 "$USB_PERSIST_DEV"
  log "Opening LUKS container as /dev/mapper/$MAPPER_NAME..."
  cryptsetup open "$USB_PERSIST_DEV" "$MAPPER_NAME"
  log "Formatting mapped device as ext4..."
  mkfs.ext4 -L "$USB_PERSIST_LABEL" /dev/mapper/"$MAPPER_NAME"

  log "Creating mount point $MOUNT_POINT and mounting..."
  mkdir -p "$MOUNT_POINT"
  mount /dev/mapper/"$MAPPER_NAME" "$MOUNT_POINT"
  mkdir -p "$MOUNT_POINT"/{upper,work,tmpfiles,snapshots,backups}
  chown -R "$CHRONOS_USER":"$CHRONOS_USER" "$MOUNT_POINT"
  log "LUKS persistence partition created and mounted at $MOUNT_POINT."
  echo
  echo "To open later: sudo cryptsetup open $USB_PERSIST_DEV $MAPPER_NAME && sudo mount /dev/mapper/$MAPPER_NAME $MOUNT_POINT"
}

# ----------------------------
# 2) overlayfs setup for /home
# ----------------------------
task_overlay() {
  require_root
  check_tools
  if [ ! -d "$MOUNT_POINT" ]; then
    err "Persistent mountpoint $MOUNT_POINT not present. Mount or run luks task first."
    exit 5
  fi

  local script="/usr/local/bin/mount_persist_overlay.sh"
  log "Writing overlay mount script to $script"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -e
PERSIST="${MOUNT_POINT}"
UP_HOME="\${PERSIST}/upper_home"
WORK_HOME="\${PERSIST}/work_home"
MERGE_HOME="/home"

mkdir -p "\$UP_HOME" "\$WORK_HOME"
if mount | grep -q "\$MERGE_HOME .*overlay"; then
  echo "Overlay already mounted on \$MERGE_HOME"
  exit 0
fi
mount -t overlay overlay -o lowerdir=/home,upperdir="\$UP_HOME",workdir="\$WORK_HOME" "\$MERGE_HOME"
EOF
  chmod +x "$script"
  log "Creating systemd unit mount-overlay.service"
  cat >/etc/systemd/system/mount-overlay.service <<'EOF'
[Unit]
Description=Mount overlayfs for /home using USB persistence
After=local-fs.target
Requires=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mount_persist_overlay.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable mount-overlay.service || true
  log "Overlayfs setup installed. Start it with: systemctl start mount-overlay.service"
}

# ----------------------------
# 3) tmpfs setup + flush
# ----------------------------
task_tmpfs() {
  require_root
  check_tools
  log "Configuring tmpfs entries in /etc/fstab (backing up /etc/fstab to /etc/fstab.bak)"
  cp /etc/fstab /etc/fstab.bak || true

  # add entries if missing
  add_fstab_entry() {
    local entry="$1"
    if ! grep -Fq "$entry" /etc/fstab; then
      echo "$entry" >> /etc/fstab
      log "Appended to /etc/fstab: $entry"
    else
      log "fstab entry already exists: $entry"
    fi
  }

  add_fstab_entry "tmpfs   /tmp           tmpfs   mode=1777,size=${TMPFS_TMP_SIZE} 0 0"
  add_fstab_entry "tmpfs   /var/log       tmpfs   mode=0755,size=${TMPFS_VARLOG_SIZE}  0 0"
  add_fstab_entry "tmpfs   /var/cache     tmpfs   mode=0755,size=${TMPFS_VARCACHE_SIZE}  0 0"

  # create flush script
  local flush="/usr/local/sbin/flush_tmpfs.sh"
  log "Writing flush script to $flush"
  cat >"$flush" <<'EOF'
#!/usr/bin/env bash
set -e
PERSIST="${MOUNT_POINT}"
SNAPROOT="${MOUNT_POINT}/snapshots"
mkdir -p "${SNAPROOT}"
TIMESTAMP=$(date +%Y%m%d-%H%M)
DEST="${SNAPROOT}/${TIMESTAMP}"
mkdir -p "${DEST}"
# Persist logs & selected configs
rsync -a --delete /var/log "${DEST}/var_log/" || true
rsync -a --delete /home/chronos/.config "${DEST}/home_config/" || true
# rotate: keep latest N snapshots (handled by snapshots cleanup)
EOF
  # replace placeholder MOUNT_POINT inside flush script
  sed -i "s|\${MOUNT_POINT}|${MOUNT_POINT}|g" "$flush"
  chmod +x "$flush"
  # install cron.daily symlink
  ln -sf "$flush" /etc/cron.daily/flush_tmpfs || true
  log "tmpfs entries configured and flush script installed at $flush (cron.daily)."
  log "Note: reboot required to mount tmpfs entries, or mount manually."
}

# ----------------------------
# 4) zram swap setup
# ----------------------------
task_zram() {
  require_root
  check_tools
  local setup="/usr/local/bin/setup_zram.sh"
  log "Writing zram setup script to $setup"
  cat >"$setup" <<'EOF'
#!/usr/bin/env bash
set -e
NUM=${ZRAM_DEV_COUNT}
modprobe zram num_devices=$NUM || exit 1
for i in $(seq 0 $((NUM-1))); do
  DEV="/dev/zram${i}"
  # set compression
  if [ -w "/sys/block/zram${i}/comp_algorithm" ]; then
    echo lz4 > /sys/block/zram${i}/comp_algorithm || true
  fi
  # size = half RAM
  RAM=$(awk '/Mem:/ {print $2}' /proc/meminfo)
  # Mem total in KB -> convert to bytes and half it
  let SIZE_BYTES=(RAM*1024)/2
  echo $SIZE_BYTES > /sys/block/zram${i}/disksize
  mkswap ${DEV}
  swapon ${DEV}
done
EOF
  # substitute ZRAM_DEV_COUNT variable
  sed -i "s/\${ZRAM_DEV_COUNT}/${ZRAM_DEV_COUNT}/g" "$setup" || true
  chmod +x "$setup"

  cat >/etc/systemd/system/zram.service <<'EOF'
[Unit]
Description=Configure zram devices

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup_zram.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable zram.service || true
  log "zram service created (/etc/systemd/system/zram.service). Start with: systemctl start zram.service"
}

# ----------------------------
# 5) rsync snapshots (atomic incremental)
# ----------------------------
task_snapshots() {
  require_root
  check_tools
  mkdir -p "$BACKUP_DIR"
  local script="/usr/local/bin/rsync_snapshots.sh"
  log "Writing rsync snapshot script to $script"
  cat >"$script" <<'EOF'
#!/usr/bin/env bash
set -e
SRC="${RSYNC_SOURCE}"
DEST="${BACKUP_DIR}"
KEEP=${RSYNC_KEEP}
mkdir -p "$DEST"
TS=$(date +%Y%m%d-%H%M)
mkdir -p "${DEST}/${TS}"
LAST=$(ls -1t "$DEST" 2>/dev/null | head -n1 || true)
if [ -n "$LAST" ]; then
  rsync -a --delete --link-dest="$DEST/$LAST" "$SRC/" "$DEST/$TS/"
else
  rsync -a "$SRC/" "$DEST/$TS/"
fi
# rotate
cd "$DEST"
ls -1t | tail -n +$((KEEP+1)) | xargs -r rm -rf
EOF
  # replace placeholders
  sed -i "s|\${RSYNC_SOURCE}|${RSYNC_SOURCE}|g" "$script" || true
  sed -i "s|\${BACKUP_DIR}|${BACKUP_DIR}|g" "$script" || true
  sed -i "s|\${RSYNC_KEEP}|${RSYNC_KEEP}|g" "$script" || true
  chmod +x "$script"
  ln -sf "$script" /etc/cron.daily/rsync_snapshots || true
  log "Rsync snapshots script installed and linked to /etc/cron.daily/rsync_snapshots"
}

# ----------------------------
# 6) udev + systemd hotplug -> run metadata script
# ----------------------------
task_hotplug() {
  require_root
  check_tools
  local udev_rule="/etc/udev/rules.d/99-fyde-persist.rules"
  local systemd_template="/etc/systemd/system/fyde-persist-mounted@.service"
  local on_mounted="/usr/local/bin/on_persist_mounted.sh"

  log "Writing udev rule to $udev_rule"
  cat >"$udev_rule" <<EOF
ENV{ID_FS_LABEL}=="${USB_PERSIST_LABEL}", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}="fyde-persist-mounted@%k.service"
EOF

  log "Writing systemd template to $systemd_template"
  cat >"$systemd_template" <<'EOF'
[Unit]
Description=Run metadata sync when persistence %i is added
After=dev-%i.device

[Service]
Type=oneshot
ExecStart=/usr/local/bin/on_persist_mounted.sh /dev/%i
EOF

  log "Writing on_persist_mounted script to $on_mounted"
  cat >"$on_mounted" <<EOF
#!/usr/bin/env bash
set -e
PDEV="\$1"
MOUNTPOINT="${MOUNT_POINT}"
# Wait a beat
sleep 1
# Try to open crypt container (if encrypted)
if cryptsetup status "${MAPPER_NAME}" >/dev/null 2>&1; then
  logmsg="cryptsetup already open"
else
  cryptsetup open "\$PDEV" "${MAPPER_NAME}" || true
fi
# try mapped device first
if [ -b "/dev/mapper/${MAPPER_NAME}" ]; then
  DEV="/dev/mapper/${MAPPER_NAME}"
else
  DEV="\$PDEV"
fi
mkdir -p "\$MOUNTPOINT"
mount "\$DEV" "\$MOUNTPOINT" || true
# run metadata script if exists
if [ -x "${METADATA_SCRIPT}" ]; then
  su - ${CHRONOS_USER} -c "${METADATA_SCRIPT} >> /home/${CHRONOS_USER}/logs/metadata_run.log 2>&1" || true
fi
EOF

  # substitute placeholders in on_mounted (MAPPER_NAM
