#!/usr/bin/env bash
# ==============================================================================
# Ubuntu Developer Environment Setup Script
# Installs essential build tools, Git, Node.js, Docker, and VS Code.
# ==============================================================================

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
success() { echo -e "\e[1;32m[OK]\e[0m    $*"; }
error()   { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || error "Please run as root: sudo bash $0"
}

# ── Steps ─────────────────────────────────────────────────────────────────────
require_root

info "Updating and upgrading system packages..."
apt-get update && apt-get upgrade -y
success "System packages updated."

info "Installing system essentials..."
apt-get install -y \
  build-essential \
  curl \
  wget \
  git \
  software-properties-common \
  apt-transport-https \
  ca-certificates \
  gnupg \
  lsb-release \
  htop \
  tree \
  unzip
success "Essentials installed."

info "Setting up Node.js (LTS v20)..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.p/nodesource.list >/dev/null || \
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y nodejs
success "Node.js $(node -v) and npm $(npm -v) installed."

info "Setting up Docker & Docker Compose..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
success "Docker installed. (Version: $(docker --version))"

info "Setting up VS Code..."
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
rm -f packages.microsoft.gpg
apt-get update
apt-get install -y code
success "VS Code installed."

echo ""
echo -e "\e[1;32m══════════════════════════════════════════\e[0m"
echo -e "\e[1;32m  Dev Environment Installed Successfully! \e[0m"
echo -e "\e[1;32m══════════════════════════════════════════\e[0m"
echo ""
echo "Installed components:"
echo " - Essentials (build-essential, curl, wget, git, htop, tree)"
echo " - Node.js $(node -v)"
echo " - Docker $(docker --version)"
echo " - VS Code $(code --version | head -n 1)"
echo ""
echo "Next steps:"
echo " 1. Configure git:"
echo "    git config --global user.name \"Your Name\""
echo "    git config --global user.email \"your.email@example.com\""
echo " 2. Add your non-root user to the Docker group if desired:"
echo "    sudo usermod -aG docker \$USER"
echo ""
