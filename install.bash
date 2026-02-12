#!/bin/bash
set -euo pipefail

# ===== Configuration =====
SCRIPT_NAME="wifi-adapter-healer"
SYSTEMD_SERVICE="${SCRIPT_NAME}.service"
SYSTEMD_TIMER="${SCRIPT_NAME}.timer"
SYSTEMD_PATH="/etc/systemd/system"
DEFAULT_INTERVAL="1min"
# =========================

# Color codes
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

log() {
  local level="$1"
  local msg="$2"
  case "$level" in
    INFO) echo -e "${BLUE}[INFO]${NC} $msg" ;;
    WARN) echo -e "${YELLOW}[WARN]${NC} $msg" ;;
    ERROR) echo -e "${RED}[ERROR]${NC} $msg" ;;
    SUCCESS) echo -e "${GREEN}[OK]${NC} $msg" ;;
  esac
}

# Parse arguments
HEAL_SCRIPT=""
INTERVAL="${DEFAULT_INTERVAL}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--script)
      HEAL_SCRIPT="$2"
      shift 2
      ;;
    -i|--interval)
      INTERVAL="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [OPTIONS]

Install wifi-adapter-healer as systemd timer.

Options:
  -s, --script PATH    Path to healer script (default: heal-wifi.bash in same dir)
  -i, --interval TIME  Run interval (systemd format: 30s, 1min, 5m; default: 1min)
  -h, --help           Show this help message

Examples:
  $0
  $0 -s /w/linux-wifi-adapter-healer.sh -i 2min
  $0 --script ./my-healer.sh --interval 30s
EOF
      exit 0
      ;;
    *)
      log ERROR "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Root check
if [ "$EUID" -ne 0 ]; then
  log ERROR "This installer must be run as root (use sudo)"
  exit 1
fi

# Determine heal script path (default: heal-wifi.bash in same dir as installer)
if [ -z "$HEAL_SCRIPT" ]; then
  INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  HEAL_SCRIPT="${INSTALLER_DIR}/heal-wifi.bash"
  log INFO "Using default heal script: ${HEAL_SCRIPT}"
else
  # Resolve absolute path
  HEAL_SCRIPT="$(readlink -f "$HEAL_SCRIPT")"
  log INFO "Using custom heal script: ${HEAL_SCRIPT}"
fi

# Validate heal script exists
if [ ! -f "$HEAL_SCRIPT" ]; then
  log ERROR "Heal script not found: ${HEAL_SCRIPT}"
  exit 1
fi

# Make heal script executable
if [ ! -x "$HEAL_SCRIPT" ]; then
  log INFO "Adding executable permission to heal script"
  chmod +x "$HEAL_SCRIPT"
fi

# Validate interval format (simple check for systemd time spec)
if ! echo "$INTERVAL" | grep -Eq '^[0-9]+(s|m|min|h|d)$'; then
  log ERROR "Invalid interval format: '${INTERVAL}' (use: 30s, 1min, 5m, 1h)"
  exit 1
fi

# Backup existing units if present
for unit in "${SYSTEMD_SERVICE}" "${SYSTEMD_TIMER}"; do
  if [ -f "${SYSTEMD_PATH}/${unit}" ]; then
    BACKUP="${SYSTEMD_PATH}/${unit}.backup.$(date +%Y%m%d_%H%M%S)"
    log WARN "Backing up existing ${unit} to ${BACKUP}"
    cp "${SYSTEMD_PATH}/${unit}" "${BACKUP}"
  fi
done

# Create service file
log INFO "Creating systemd service: ${SYSTEMD_SERVICE}"
cat > "${SYSTEMD_PATH}/${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Wi-Fi Adapter Healer — automatic recovery for frozen Wi-Fi adapters
Documentation=file://${HEAL_SCRIPT}
After=network.target NetworkManager.service local-fs.target
ConditionPathExists=${HEAL_SCRIPT}
ConditionPathIsExecutable=${HEAL_SCRIPT}

[Service]
Type=oneshot
User=root
Group=root
ExecStart=${HEAL_SCRIPT}
StandardOutput=journal
StandardError=journal
TimeoutSec=60
LockPersonality=yes
Restart=no
EOF

# Create timer file
log INFO "Creating systemd timer: ${SYSTEMD_TIMER}"
cat > "${SYSTEMD_PATH}/${SYSTEMD_TIMER}" <<EOF
[Unit]
Description=Run Wi-Fi adapter healer every ${INTERVAL}
Requires=${SYSTEMD_SERVICE}

[Timer]
OnBootSec=60s
OnUnitActiveSec=${INTERVAL}
Persistent=true
RandomizedDelaySec=10

[Install]
WantedBy=timers.target
EOF

# Reload systemd
log INFO "Reloading systemd configuration"
systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null

# Enable and start timer
log INFO "Enabling and starting ${SYSTEMD_TIMER}"
systemctl enable --now "${SYSTEMD_TIMER}" >/dev/null

# Verify installation
if systemctl is-active --quiet "${SYSTEMD_TIMER}"; then
  log SUCCESS "Installation completed successfully!"
  echo
  log INFO "Service: ${SYSTEMD_SERVICE}"
  log INFO "Timer:   ${SYSTEMD_TIMER}"
  log INFO "Interval: ${INTERVAL}"
  log INFO "Heal script: ${HEAL_SCRIPT}"
  echo
  log INFO "Next run:"
  systemctl list-timers | grep -E "${SCRIPT_NAME}" | awk '{print "  " $2 " (in " $3 ")"}'
  echo
  log INFO "View logs:"
  echo "  journalctl -u ${SYSTEMD_SERVICE} -f"
else
  log ERROR "Timer failed to start!"
  systemctl status "${SYSTEMD_TIMER}" --no-pager || true
  exit 1
fi