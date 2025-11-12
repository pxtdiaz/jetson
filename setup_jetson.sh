#!/usr/bin/env bash
# setup_jetson.sh — Post-flash setup for Jetson (JP6 / L4T r36.x)
# Safe against PackageKit/apt locks, with retries and logging.

set -euo pipefail

# ---------- config ----------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PIN_SCRIPT="${SCRIPT_DIR}/scripts/pin_to_dock.sh"              # optional
TERMINAL_FONT_SCRIPT="${SCRIPT_DIR}/scripts/set_terminal_font.sh"  # optional
VSCODE_SCRIPT="${SCRIPT_DIR}/scripts/install_vscode.sh"        # optional but supported

LOG_DIR="$(pwd)"
LOG_FILE="${LOG_DIR}/setup_jetson_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE" && chmod 644 "$LOG_FILE"

# Noninteractive apt
export DEBIAN_FRONTEND=noninteractive
APT_GET="sudo -E apt-get -o Dpkg::Options::=--force-confold -y"
APT_UPDATE="sudo -E apt-get update -y"

# ---------- logging ----------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

# ---------- helpers ----------
stop_updaters() {
  log "Stopping PackageKit and apt timers..."
  sudo systemctl stop packagekit.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  sudo systemctl kill --kill-who=all packagekit 2>/dev/null || true
  sudo pkill -9 packagekitd 2>/dev/null || true
}

start_updaters() {
  log "Re-starting PackageKit timers (optional)..."
  sudo systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  sudo systemctl start packagekit.service 2>/dev/null || true
}

wait_for_apt() {
  # wait until dpkg/apt locks are free
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    log "Waiting for apt/dpkg lock..."
    sleep 3
  done
}

unlock_apt() {
  log "Clearing stale apt/dpkg locks if any..."
  sudo pkill -9 apt apt-get dpkg 2>/dev/null || true
  sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock || true
  sudo dpkg --configure -a || true
  sudo $APT_GET -f install || true
}

apt_retry() {
  # usage: apt_retry install pkg1 pkg2 ...
  local tries=5
  local delay=4
  local cmd="$1"; shift
  for attempt in $(seq 1 $tries); do
    wait_for_apt
    if sudo -E apt-get -y "$cmd" "$@" >>"$LOG_FILE" 2>&1; then
      log "apt $cmd succeeded on attempt $attempt: $*"
      return 0
    fi
    log "apt $cmd failed (attempt $attempt/$tries). Retrying in ${delay}s..."
    sleep $delay
    delay=$((delay*2))
    unlock_apt
  done
  log "ERROR: apt $cmd failed after $tries attempts: $*"
  exit 1
}

run_if_present() {
  local label="$1"; local script="$2"; shift 2
  if [[ -f "$script" ]]; then
    chmod +x "$script" || true
    log "Running $label: $script"
    sudo bash "$script" "$@" >>"$LOG_FILE" 2>&1 || { log "WARN: $label failed"; return 1; }
    log "$label finished"
  else
    log "INFO: $label script not found ($script). Skipping."
  fi
}

# ---------- main ----------
log "Starting Jetson setup. Log: $LOG_FILE"

stop_updaters
trap 'start_updaters; log "Finished (trap)."' EXIT

unlock_apt
wait_for_apt
log "Updating package lists..."
$APT_UPDATE >>"$LOG_FILE" 2>&1 || true
apt_retry update

# --- basic tools you likely want available ---
apt_retry install curl ca-certificates gnupg lsb-release software-properties-common

# --- Chromium (prefer snap path on 22.04; fallback to transitional apt) ---
log "Installing Chromium..."
if command -v snap >/dev/null 2>&1; then
  # Ensure snapd is running
  sudo systemctl start snapd.socket snapd.service 2>/dev/null || true
  if ! snap list chromium >/dev/null 2>&1; then
    sudo snap install chromium >>"$LOG_FILE" 2>&1 || {
      log "snap chromium failed; trying apt transitional package..."
      apt_retry install chromium-browser
    }
  else
    log "Chromium snap already installed."
  fi
else
  log "snap not available; using apt transitional package..."
  apt_retry install chromium-browser
fi

# --- Python/pip and jetson-stats (jtop) ---
log "Installing python3-pip..."
apt_retry install python3-pip
log "Installing/Updating jetson-stats (jtop)..."
sudo -H pip3 install -U jetson-stats >>"$LOG_FILE" 2>&1 || log "WARN: jetson-stats install failed"
# jtop service (optional): sudo systemctl restart jtop.service

# --- Upgrade base packages (optional but recommended on fresh flash) ---
log "Upgrading system packages..."
apt_retry dist-upgrade
apt_retry autoremove
apt_retry autoclean

# --- Optional: pin Terminal to dock / set font ---
run_if_present "Pin Terminal to dock" "$PIN_SCRIPT" org.gnome.Terminal.desktop
run_if_present "Set Terminal font" "$TERMINAL_FONT_SCRIPT" "16"

# --- VS Code install (your helper handles keys/repos/arm64 .deb) ---
run_if_present "Visual Studio Code install" "$VSCODE_SCRIPT"

# --- Post steps and reboot suggestion ---
if [[ -f /var/run/reboot-required ]]; then
  log "Reboot required. Recommending reboot."
  echo
  echo ">>> Setup complete. A reboot is required. Reboot now? (y/N)"
  read -r ans
  if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
    log "Rebooting..."
    start_updaters
    sudo reboot
  fi
else
  log "Setup complete. Reboot recommended for jtop/Chromium/snap to settle."
fi

log "All done."

