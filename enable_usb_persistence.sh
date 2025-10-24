#!/bin/bash

# Define variables
USB_LABEL="YourDriveLabel"  # Replace with your USB drive's label
MOUNT_POINT="/mnt/usb"
UDEV_RULES_PATH="/etc/udev/rules.d/99-usb-persistent-mount.rules"
SYSTEMD_SERVICE_PATH="/etc/systemd/system/usb-persistence.service"

# Function to identify the USB device by its label
identify_usb_device() {
  local device
  device=$(lsblk -o NAME,LABEL | grep "$USB_LABEL" | awk '{print $1}')
  if [ -z "$device" ]; then
    echo "Error: USB device with label '$USB_LABEL' not found."
    exit 1
  fi
  echo "/dev/$device"
}

# Step 1: Create a udev rule for persistent mounting
create_udev_rule() {
  cat <<EOF | sudo tee "$UDEV_RULES_PATH" > /dev/null
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", ENV{ID_FS_LABEL}=="$USB_LABEL", RUN+="/usr/bin/mkdir -p $MOUNT_POINT", RUN+="/usr/bin/mount -o rw,uid=1000,gid=1000 /dev/%k $MOUNT_POINT"
ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", ENV{ID_FS_LABEL}=="$USB_LABEL", RUN+="/usr/bin/umount $MOUNT_POINT", RUN+="/usr/bin/rmdir $MOUNT_POINT"
EOF
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  echo "Udev rule created and applied."
}

# Step 2: Enable USB persistence across reboots
enable_usb_persistence() {
  local device
  device=$(identify_usb_device)
  echo 1 | sudo tee "/sys/bus/usb/devices/$(basename "$device")/power/persist" > /dev/null
  echo "USB persistence enabled for $device."
}

# Step 3: Create a systemd service to handle mounting on boot
create_systemd_service() {
  cat <<EOF | sudo tee "$SYSTEMD_SERVICE_PATH" > /dev/null
[Unit]
Description=Mount USB drive with label $USB_LABEL
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/mount -o rw,uid=1000,gid=1000 $(identify_usb_device) $MOUNT_POINT
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable usb-persistence.service
  sudo systemctl start usb-persistence.service
  echo "Systemd service created and started."
}

# Main execution
create_udev_rule
enable_usb_persistence
create_systemd_service

echo "USB persistence setup completed successfully."
