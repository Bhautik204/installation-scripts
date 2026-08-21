#!/usr/bin/env bash
# ==============================================================================
# Postman Installer for Ubuntu (tar.gz version)
# ==============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
DOWNLOAD_URL="https://dl.pstmn.io/download/latest/linux64"
ARCHIVE_NAME="postman-linux-x64.tar.gz"
INSTALL_DIR="/opt/Postman"
BIN_LINK="/usr/local/bin/postman"

# Primary desktop directory (Ubuntu standard) and user-specified location
DESKTOP_DIR="/usr/share/applications"
USER_DESKTOP_DIR="/usr/share/appliacation"

DOWNLOAD_DIR="$(mktemp -d)"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
success() { echo -e "\e[1;32m[OK]\e[0m    $*"; }
error()   { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || error "Please run as root: sudo bash $0"
}

cleanup() {
  info "Cleaning up temporary files..."
  rm -rf "$DOWNLOAD_DIR"
}
trap cleanup EXIT

# ── Steps ─────────────────────────────────────────────────────────────────────
require_root

info "Downloading Postman..."
curl -fL --progress-bar \
  "$DOWNLOAD_URL" \
  -o "$DOWNLOAD_DIR/$ARCHIVE_NAME" \
  || error "Download failed. Check your internet connection."
success "Download complete."

info "Extracting archive..."
tar -xzf "$DOWNLOAD_DIR/$ARCHIVE_NAME" -C "$DOWNLOAD_DIR" \
  || error "Extraction failed."
success "Extraction complete."

info "Installing to $INSTALL_DIR..."
# Remove any existing installation to avoid conflicts
if [ -d "$INSTALL_DIR" ]; then
  info "Removing existing Postman installation..."
  rm -rf "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"
cp -a "$DOWNLOAD_DIR/Postman/." "$INSTALL_DIR/"
success "Files copied."

info "Creating symlink at $BIN_LINK..."
ln -sf "$INSTALL_DIR/Postman" "$BIN_LINK"
success "Symlink created."

info "Creating desktop entry..."
write_desktop_entry() {
  local target_dir="$1"
  local target_file="${target_dir}/postman.desktop"
  
  mkdir -p "$target_dir"
  cat > "$target_file" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Postman
Icon=/opt/Postman/app/resources/app/assets/icon.png
Exec=/opt/Postman/Postman %U
Comment=Postman Desktop App
Categories=Development;Utility;
Terminal=false
StartupWMClass=Postman
EOF
  chmod 644 "$target_file"
}

# Write to standard Ubuntu desktop entry directory
write_desktop_entry "$DESKTOP_DIR"
success "Desktop entry created at $DESKTOP_DIR/postman.desktop."

# Also write to the user-specified /usr/share/appliacation path
write_desktop_entry "$USER_DESKTOP_DIR"
success "Desktop entry created at $USER_DESKTOP_DIR/postman.desktop (user-specified)."

info "Updating desktop database..."
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
update-desktop-database "$USER_DESKTOP_DIR" 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
success "Desktop database updated."

echo ""
echo -e "\e[1;32m══════════════════════════════════════════\e[0m"
echo -e "\e[1;32m     Postman installed successfully!      \e[0m"
echo -e "\e[1;32m══════════════════════════════════════════\e[0m"
echo ""
echo "  Launch from terminal : postman"
echo "  Launch from desktop  : Search 'Postman' in your app menu"
echo ""
