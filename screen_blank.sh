#!/bin/bash
set -e

echo "Configuring GNOME screen blank + screen lock..."

sudo mkdir -p /etc/dconf/profile
sudo mkdir -p /etc/dconf/db/local.d/locks

sudo tee /etc/dconf/profile/user > /dev/null <<'EOF'
user-db:user
system-db:local
EOF

sudo tee /etc/dconf/db/local.d/00-screen-blank-lock > /dev/null <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 300

[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 0
EOF

sudo tee /etc/dconf/db/local.d/locks/screen-blank-lock > /dev/null <<'EOF'
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/lock-delay
EOF

sudo dconf update

echo "Done."
echo "Screen will blank after 2 minutes and lock immediately."
echo "Log out and log back in, or reboot."
