#!/bin/bash
# fydeos_portable_setup.sh — bootstrap & optimization for FydeOS live USB
# Author: Dinadeyohvsgi (adjust as needed)
# Usage: On boot, Ctrl+Alt+T → shell → sudo -i → run this script

set -e
echo "=== FydeOS Portable Setup Starting ==="

# 1) Remount root filesystem as read-write (required for many tweaks)
echo "-- Remounting root filesystem (/) as rw"
mount -o remount,rw /

# 2) Set strong password for default user (chronos) or create custom user
echo "-- Setting password for user chronos"
passwd chronos

# 3) Disable unused services – example: Bluetooth (if you won’t use it)
echo "-- Disabling bluetooth.service"
systemctl disable bluetooth.service
systemctl mask bluetooth.service

# 4) Mount USB/target storage with noatime/nodiratime to reduce write overhead
USB_DEV="/dev/sdb1"
MOUNT_POINT="/mnt/usb"
if [ -b "${USB_DEV}" ]; then
  echo "-- Preparing USB mount ${USB_DEV} at ${MOUNT_POINT}"
  mkdir -p "${MOUNT_POINT}"
  echo "${USB_DEV}   ${MOUNT_POINT}   ext4   defaults,noatime,nodiratime   0 2" >> /etc/fstab
  mount -o remount,noatime,nodiratime "${MOUNT_POINT}"
else
  echo "-- Warning: USB device ${USB_DEV} not detected. Skipping fstab entry."
fi

# 5) Disable automatic media/file scanning in FydeOS to save I/O & battery
CFG_FILE="/etc/opt/fydeos/maintenance.conf"
if [ -f "${CFG_FILE}" ]; then
  echo "-- Disabling media file scanning"
  sed -i 's/^enable_media_scanner=true/enable_media_scanner=false/' "${CFG_FILE}"
else
  echo "-- Warning: config file ${CFG_FILE} not found. Skipping."
fi

# 6) Setup weekly cleanup & your metadata-script cronjob
echo "-- Installing cron job for weekly cleanup & metadata sync"
cat << 'EOF' > /etc/cron.weekly/portable_cleanup.sh
#!/bin/bash
# Weekly cleanup & script run
/usr/bin/python3 /home/chronos/scripts/metadata_cleaner.py >> /home/chronos/logs/metadata_cleanup.log 2>&1
# Truncate logs older than 30 days
find /var/log -type f -name "*.log" -mtime +30 -exec truncate -s 0 {} \;
EOF
chmod +x /etc/cron.weekly/portable_cleanup.sh

# 7) Install your custom scripts directory and dotfiles
echo "-- Installing scripts & dotfiles"
mkdir -p /home/chronos/scripts /home/chronos/logs
cp -r ~/my_dotfiles /home/chronos/my_dotfiles
cp -r ~/my_scripts /home/chronos/scripts
chown -R chronos:chronos /home/chronos/scripts /home/chronos/my_dotfiles /home/chronos/logs

# 8) Automatic updates – ensure FydeOS updates are enabled (via GUI) & add reminder script
echo "-- Scheduling update-check reminder"
cat << 'EOF' > /etc/cron.weekly/notify_update_check.sh
#!/bin/bash
echo "Reminder: Check for FydeOS system update manually." | wall
EOF
chmod +x /etc/cron.weekly/notify_update_check.sh

# 9) Monitor USB health – simple check at login
echo "-- Installing USB health check at login"
cat << 'EOF' >> /home/chronos/.bashrc
echo "=== USB Health Check ==="
smartctl -H /dev/sdb | grep "PASSED" || echo "Warning: USB health check failed!"
EOF

# 10) Final message & reboot
echo "=== Setup complete. Please reboot to apply changes. ==="
