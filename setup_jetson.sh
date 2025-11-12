#!/usr/bin/env bash
# setup_jetson.sh — JetPack 6 (L4T r36.x) post-flash setup that avoids snap Chromium issues.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------- paths (optional helpers) ----------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PIN_SCRIPT="${SCRIPT_DIR}/scripts/pin_to_dock.sh"                 # optional
TERMINAL_FONT_SCRIPT="${SCRIPT_DIR}/scripts/set_terminal_font.sh" # optional
VSCODE_SCRIPT="${SCRIPT_DIR}/scripts/install_vscode.sh"           # optional

# ---------- logging ----------
LOG_FILE="$(pwd)/setup_jetson_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE" && chmod 644 "$LOG_FILE"
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

# ---------- apt helpers ----------
stop_updaters(){
  sudo systemctl stop packagekit.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  sudo systemctl kill --kill-who=all packagekit 2>/dev/null || true
  sudo pkill -9 packagekitd 2>/dev/null || true
}
start_updaters(){
  sudo systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  sudo systemctl start packagekit.service 2>/dev/null || true
}
wait_for_apt(){
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    log "Waiting for apt/dpkg lock..."
    sleep 3
  done
}
unlock_apt(){
  sudo pkill -9 apt apt-get dpkg 2>/dev/null || true
  sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock || true
  sudo dpkg --configure -a || true
  sudo apt-get -y -f install || true
}
apt_retry(){
  local op="$1"; shift
  local tries=5; local delay=4
  for n in $(seq 1 $tries); do
    wait_for_apt
    if sudo -E apt-get -y "$op" "$@" >>"$LOG_FILE" 2>&1; then
      log "apt $op ok: $*"
      return 0
    fi
    log "apt $op failed (try $n/$tries). retry in ${delay}s..."
    sleep $delay; delay=$((delay*2)); unlock_apt
  done
  log "ERROR: apt $op failed after $tries attempts: $*"; exit 1
}

run_if_present(){
  local label="$1" script="$2"; shift 2 || true
  if [[ -f "$script" ]]; then
    chmod +x "$script" || true
    log "Running $label: $script"
    sudo bash "$script" "$@" >>"$LOG_FILE" 2>&1 || log "WARN: $label failed"
  else
    log "INFO: $label script not found ($script). Skipping."
  fi
}

# ---------- main ----------
log "Starting Jetson setup. Log: $LOG_FILE"
trap 'start_updaters; log "Finished (trap)."' EXIT
stop_updaters; unlock_apt

log "Update package lists..."
apt_retry update
apt_retry install curl ca-certificates gnupg lsb-release software-properties-common

# ---- Browser via Flatpak (avoid snap Chromium on JP6) ----
# refs: JetsonHacks + NVIDIA forum discuss snapd 2.70 breakage on Jetson
log "Installing Flatpak + Flathub..."
apt_retry install flatpak
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >>"$LOG_FILE" 2>&1 || true

log "Installing Chromium from Flathub (no snap)..."
sudo flatpak install -y flathub org.chromium.Chromium >>"$LOG_FILE" 2>&1
# optional desktop integration (first run will add menu entry)
# run with: flatpak run org.chromium.Chromium

# ---- Python/pip + jtop ----
log "Installing python3-pip..."
apt_retry install python3-pip
log "Installing/Updating jetson-stats (jtop)..."
sudo -H pip3 install -U jetson-stats >>"$LOG_FILE" 2>&1 || log "WARN: jetson-stats install failed"

# ---- System upgrade (optional but recommended) ----
log "Upgrading system packages..."
apt_retry dist-upgrade
apt_retry autoremove
apt_retry autoclean

# ---- Optional desktop niceties ----
run_if_present "Pin Terminal to dock" "$PIN_SCRIPT" org.gnome.Terminal.desktop
run_if_present "Set Terminal font" "$TERMINAL_FONT_SCRIPT" "16"
run_if_present "Visual Studio Code install" "$VSCODE_SCRIPT"

# ---- Done ----
if [[ -f /var/run/reboot-required ]]; then
  log "Reboot required. Reboot now? (y/N)"
  read -r ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] && { start_updaters; sudo reboot; }
else
  log "Setup complete. Reboot recommended."
fi

