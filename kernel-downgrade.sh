#!/usr/bin/env bash
#
# kernel-downgrade.sh
# Downgrade an Ubuntu box from a problematic kernel (e.g. 7.x) to a known-good
# 6.x kernel, set it as the GRUB default, and optionally hold it so apt/unattended
# upgrades won't pull the newer kernel back in.
#
# Usage:
#   sudo ./kernel-downgrade.sh downgrade              # install + set-default + hold 6.8.0-40 (the default target), in one shot
#   sudo ./kernel-downgrade.sh downgrade 6.8.0-45      # same, but for a different version
#   sudo ./kernel-downgrade.sh list                    # show installed + available kernels
#   sudo ./kernel-downgrade.sh install 6.8.0-40         # install a specific 6.x kernel version
#   sudo ./kernel-downgrade.sh set-default 6.8.0-40      # make it the GRUB default boot entry
#   sudo ./kernel-downgrade.sh hold                       # pin current (running) kernel, block newer ones
#   sudo ./kernel-downgrade.sh unhold                      # remove the hold
#   sudo ./kernel-downgrade.sh purge 7.x-version            # remove the bad kernel entirely (after reboot-verified)
#
# Change the default target by editing TARGET_KERNEL below, or set it inline:
#   TARGET_KERNEL=6.8.0-45 sudo -E ./kernel-downgrade.sh downgrade
#
# Safe to re-run; every step checks state before acting.

set -euo pipefail

# Default target kernel version. Override per-run with: TARGET_KERNEL=6.x.x-xx ./kernel-downgrade.sh downgrade
TARGET_KERNEL="${TARGET_KERNEL:-6.8.0-40}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

CMD="${1:-}"
ARG="${2:-$TARGET_KERNEL}"

log() { echo -e "[kernel-downgrade] $*"; }

list_kernels() {
  log "Installed kernel images:"
  dpkg --list | grep -E '^ii  linux-image-[0-9]' | awk '{print $2, $3}'
  echo
  log "Currently running kernel: $(uname -r)"
  echo
  log "Available in apt cache (candidates you can install):"
  apt-cache search '^linux-image-[0-9]' | sort
}

install_kernel() {
  local ver="$1"
  [[ -z "$ver" ]] && { echo "Usage: $0 install <kernel-version>"; exit 1; }

  local pkg="linux-image-generic-hwe-$(lsb_release -rs 2>/dev/null || echo '')"
  # Prefer exact package name if user passed one matching apt cache
  if apt-cache show "linux-image-${ver}-generic" &>/dev/null; then
    pkg="linux-image-${ver}-generic"
  elif apt-cache show "linux-image-${ver}" &>/dev/null; then
    pkg="linux-image-${ver}"
  else
    log "Could not find an exact apt package for version '${ver}'."
    log "Try 'apt-cache search linux-image-${ver}' to find the right name,"
    log "or if it's no longer in the repo, download the .deb pair from:"
    log "  https://kernel.ubuntu.com/mainline/ or your internal package mirror."
    exit 1
  fi

  log "Installing ${pkg} (and matching headers if available)..."
  apt-get update -y
  apt-get install -y "${pkg}" "linux-headers-${ver}-generic" 2>/dev/null || \
    apt-get install -y "${pkg}"

  log "Installed. Run '$0 set-default ${ver}' next, then reboot."
}

set_default_kernel() {
  local ver="$1"
  [[ -z "$ver" ]] && { echo "Usage: $0 set-default <kernel-version>"; exit 1; }

  local menu_entry
  menu_entry=$(awk -F"'" '/menuentry / {print $2}' /boot/grub/grub.cfg | grep -i "${ver}" | grep -vi recovery | head -n1)

  if [[ -z "$menu_entry" ]]; then
    log "Couldn't find a GRUB menu entry matching '${ver}'."
    log "Available entries:"
    awk -F"'" '/menuentry / {print $2}' /boot/grub/grub.cfg
    exit 1
  fi

  # Advanced options entries are nested, e.g. "Advanced options...>Ubuntu, with Linux 6.8.0-40"
  local full_id="Advanced options for Ubuntu>${menu_entry}"

  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="'"${full_id}"'"/' /etc/default/grub
  sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub 2>/dev/null || true

  update-grub
  log "Default boot entry set to: ${menu_entry}"
  log "Reboot now, or run 'reboot' when ready."
}

hold_kernel() {
  local running
  running=$(uname -r)
  local pkg="linux-image-${running}"
  apt-mark hold "${pkg}" 2>/dev/null || true
  apt-mark hold "linux-headers-${running}" 2>/dev/null || true
  apt-mark hold linux-generic linux-image-generic linux-headers-generic 2>/dev/null || true
  log "Held: ${pkg} and generic metapackages (prevents apt from upgrading past this kernel)."
  log "Current holds:"
  apt-mark showhold
}

unhold_kernel() {
  apt-mark unhold linux-generic linux-image-generic linux-headers-generic 2>/dev/null || true
  for p in $(apt-mark showhold | grep '^linux-'); do
    apt-mark unhold "$p"
  done
  log "Removed kernel holds."
}

purge_kernel() {
  local ver="$1"
  [[ -z "$ver" ]] && { echo "Usage: $0 purge <kernel-version>"; exit 1; }
  local running
  running=$(uname -r)
  if [[ "$running" == *"$ver"* ]]; then
    log "Refusing to purge the currently running kernel (${running}). Reboot into the target kernel first."
    exit 1
  fi
  log "Purging kernel ${ver}..."
  apt-get purge -y "linux-image-${ver}-generic" "linux-headers-${ver}-generic" "linux-modules-${ver}-generic" 2>/dev/null || \
    apt-get purge -y "linux-image-${ver}" "linux-headers-${ver}"
  update-grub
  log "Purged. Run 'apt autoremove -y' if you also want to clean up dangling deps."
}

downgrade_default() {
  local ver="$1"
  log "Target kernel: ${ver}"

  if uname -r | grep -q "${ver}"; then
    log "Already running ${ver}. Nothing to install."
  else
    install_kernel "${ver}"
  fi

  set_default_kernel "${ver}"
  hold_kernel

  echo
  log "Done. Reboot now to boot into ${ver}:"
  log "  sudo reboot"
  log "After reboot, confirm with: uname -r"
}

case "$CMD" in
  downgrade)    downgrade_default "$ARG" ;;
  list)         list_kernels ;;
  install)      install_kernel "$ARG" ;;
  set-default)  set_default_kernel "$ARG" ;;
  hold)         hold_kernel ;;
  unhold)       unhold_kernel ;;
  purge)        purge_kernel "$ARG" ;;
  *)
    echo "Usage: $0 {downgrade [ver]|list|install <ver>|set-default <ver>|hold|unhold|purge <ver>}"
    echo "  downgrade with no arg uses default target: ${TARGET_KERNEL}"
    exit 1
    ;;
esac
