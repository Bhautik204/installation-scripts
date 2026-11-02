#!/bin/bash
# Block USB mass storage (pen drives, external disks, card readers).
# Keyboard, mouse and charging keep working.
# Usage: sudo ./usb-lock.sh [disable|enable]   (default: disable)

set -e
[ "$EUID" -eq 0 ] || { echo "Run as root: sudo $0 [disable|enable]"; exit 1; }

MODPROBE=/etc/modprobe.d/disable-usb-storage.conf
UDEV=/etc/udev/rules.d/99-block-usb-storage.rules

case "${1:-disable}" in
  disable)
    cat > "$MODPROBE" <<'EOF'
blacklist usb-storage
blacklist uas
install usb-storage /bin/false
install uas /bin/false
EOF

    # Deauthorize any USB interface of class 08 (mass storage) as soon as it appears
    cat > "$UDEV" <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTR{bInterfaceClass}=="08", ATTR{authorized}="0"
EOF

    udevadm control --reload-rules
    modprobe -r uas usb_storage 2>/dev/null || echo "Module in use (drive mounted?) - will be blocked after reboot."
    update-initramfs -u >/dev/null
    echo "USB storage DISABLED. HID (keyboard/mouse) and charging unaffected."
    ;;

  enable)
    rm -f "$MODPROBE" "$UDEV"
    udevadm control --reload-rules
    update-initramfs -u >/dev/null
    modprobe usb_storage
    echo "USB storage ENABLED."
    ;;

  *)
    echo "Usage: sudo $0 [disable|enable]"; exit 1 ;;
esac
