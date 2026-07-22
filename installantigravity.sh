#!/usr/bin/env bash
# ==============================================================================
# Antigravity IDE Installer
# Version: 2.1.1-6123990880747520 (linux-x64)
# ==============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
DOWNLOAD_URL="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.1.1-6123990880747520/linux-x64/Antigravity%20IDE.tar.gz"
ARCHIVE_NAME="Antigravity IDE.tar.gz"
INSTALL_DIR="/opt/antigravity-ide"
BIN_LINK="/usr/local/bin/antigravity-ide"
DESKTOP_FILE="/usr/share/applications/antigravity-ide.desktop"
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

info "Downloading Antigravity IDE..."
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
mkdir -p "$INSTALL_DIR"
cp -a "$DOWNLOAD_DIR/Antigravity IDE/." "$INSTALL_DIR/"
success "Files copied."

info "Setting sandbox permissions..."
chown root:root "$INSTALL_DIR/chrome-sandbox"
chmod 4755      "$INSTALL_DIR/chrome-sandbox"
success "Sandbox permissions set."

info "Creating symlink at $BIN_LINK..."
ln -sf "$INSTALL_DIR/antigravity-ide" "$BIN_LINK"
success "Symlink created."

info "Creating desktop entry..."
cat > "$DESKTOP_FILE" << 'EOF'
[Desktop Entry]
Version=1.0
Name=Antigravity IDE
GenericName=IDE
Comment=Google Antigravity IDE
Exec=/opt/antigravity-ide/antigravity-ide %F
Icon=/opt/antigravity-ide/resources/app/resources/linux/code.png
Terminal=false
Type=Application
Categories=Development;IDE;
StartupNotify=true
StartupWMClass=antigravity-ide
MimeType=application/x-antigravity-workspace;
Keywords=antigravity;ide;google;
EOF
chmod 644 "$DESKTOP_FILE"
success "Desktop entry created."

info "Updating desktop database..."
update-desktop-database /usr/share/applications
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
success "Desktop database updated."

echo ""
echo -e "\e[1;32m══════════════════════════════════════════\e[0m"
echo -e "\e[1;32m  Antigravity IDE installed successfully! \e[0m"
echo -e "\e[1;32m══════════════════════════════════════════\e[0m"
echo ""
echo "  Launch from terminal : antigravity-ide"
echo "  Launch from desktop  : Search 'Antigravity IDE' in your app menu"
echo ""