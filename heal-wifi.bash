#!/bin/bash
set -euo pipefail

# ===== Configuration =====
SCRIPT_VERSION="1.5"
OTEL_COLLECTOR_HOST="localhost"
OTEL_HTTP_PORT="4318"
WIFI_INTERFACE=""
MODULE_CODE="7921"
MODULE_NAME="mt7921u"
RECOVERY_DELAY=8
# =========================

# Color codes for terminal output
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Logging function with OpenTelemetry support
log() {
    local level="${1^^}"
    local message="$2"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local severity_num=9
    case "$level" in
        DEBUG) severity_num=5 ;;
        INFO) severity_num=9 ;;
        WARN|WARNING) severity_num=13; level="WARN" ;;
        ERROR) severity_num=17 ;;
        FATAL) severity_num=21 ;;
    esac

    # Terminal output
    case "$level" in
        INFO) echo -e "${BLUE}[${timestamp}] [${level}] ${message}${NC}" ;;
        WARN) echo -e "${YELLOW}[${timestamp}] [${level}] ${message}${NC}" ;;
        ERROR|FATAL) echo -e "${RED}[${timestamp}] [${level}] ${message}${NC}" ;;
        *) echo "[${timestamp}] [${level}] ${message}" ;;
    esac

    # Async OpenTelemetry logging (non-blocking)
    if command -v curl >/dev/null 2>&1; then
        (
            safe_msg=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
            payload=$(cat <<EOF
{
  "resourceLogs": [{
    "resource": {
      "attributes": [{
        "key": "service.name",
        "value": { "stringValue": "linux-wifi-adapter-healer" }
      }, {
        "key": "host.name",
        "value": { "stringValue": "$(hostname)" }
      }, {
        "key": "script.version",
        "value": { "stringValue": "${SCRIPT_VERSION}" }
      }, {
        "key": "module.code",
        "value": { "stringValue": "${MODULE_CODE}" }
      }]
    },
    "scopeLogs": [{
      "scope": {
        "name": "wifi-heal",
        "version": "${SCRIPT_VERSION}"
      },
      "logRecords": [{
        "timeUnixNano": "$(date +%s%N)",
        "severityText": "$level",
        "severityNumber": $severity_num,
        "body": { "stringValue": "$safe_msg" },
        "attributes": [
          {"key": "interface.name", "value": {"stringValue": "$WIFI_INTERFACE"}},
          {"key": "module.name", "value": {"stringValue": "$MODULE_NAME"}},
          {"key": "module.code", "value": {"stringValue": "$MODULE_CODE"}},
          {"key": "script.version", "value": {"stringValue": "${SCRIPT_VERSION}"}}
        ]
      }]
    }]
  }]
}
EOF
            )
            curl -sS --max-time 2 -X POST "http://${OTEL_COLLECTOR_HOST}:${OTEL_HTTP_PORT}/v1/logs" \
                -H "Content-Type: application/json" \
                -d "$payload" >/dev/null 2>&1 || true
        ) &
    fi
}

# Root check
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Auto-detect Wi-Fi interface with chipset matching MODULE_CODE
detect_interface() {
    # Method 1: Find interface with MODULE_CODE in driver name using find (robust, no glob issues)
    WIFI_INTERFACE=$(
        find /sys/class/net -maxdepth 1 -name 'wl*' -type l 2>/dev/null | while read -r iface_path; do
            iface_name=$(basename "$iface_path")
            driver_path="$iface_path/device/driver"
            # Skip if driver symlink doesn't exist
            [ -L "$driver_path" ] || continue
            # Get driver name (basename of symlink target)
            driver_name=$(readlink -f "$driver_path" 2>/dev/null | xargs basename 2>/dev/null || true)
            # Check if driver name contains MODULE_CODE
            if echo "$driver_name" | grep -qi "${MODULE_CODE}"; then
                echo "$iface_name"
                exit 0  # Exit the subshell immediately on first match
            fi
        done
    ) || true

    # Method 2: Fallback to first wlan interface if not found by chipset
    if [ -z "$WIFI_INTERFACE" ] || ! ip link show "$WIFI_INTERFACE" &>/dev/null; then
        WIFI_INTERFACE=$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^wl/ {print $2; exit}') || true
    fi

    # Final validation
    if [ -z "$WIFI_INTERFACE" ]; then
        log WARN "No Wi-Fi interface detected!"
        return 1
    fi

    log INFO "Detected Wi-Fi interface: $WIFI_INTERFACE (chipset: ${MODULE_CODE})"
}

# Auto-detect actual module name containing MODULE_CODE (substring search, not regex)
detect_module() {
    # Priority 1: Find base module (without _common suffix) containing MODULE_CODE
    MODULE_NAME=$(lsmod | awk -v code="${MODULE_CODE}" '
        index($1, code) && $1 !~ /_common$/ {print $1; exit}
    ') || true

    # Priority 2: Fall back to any module containing MODULE_CODE
    if [ -z "$MODULE_NAME" ]; then
        MODULE_NAME=$(lsmod | awk -v code="${MODULE_CODE}" '
            index($1, code) {print $1; exit}
        ') || true
    fi

    # Final fallback: use default name
    if [ -z "$MODULE_NAME" ]; then
        log WARN "No module containing '${MODULE_CODE}' detected in lsmod - using fallback name 'mt${MODULE_CODE}u'"
        MODULE_NAME="mt${MODULE_CODE}u"
    else
        log INFO "Detected kernel module: $MODULE_NAME (chipset: ${MODULE_CODE})"
    fi
}

# Check if Wi-Fi is truly connected (multiple methods)
is_wifi_connected() {
    # If interface variable is empty, we cannot check Wi-Fi specifically
    if [ -z "$WIFI_INTERFACE" ]; then
        return 1
    fi

    # Method 1: Check if interface exists and is UP
    if ! ip link show "$WIFI_INTERFACE" &>/dev/null; then
        log DEBUG "Interface $WIFI_INTERFACE does not exist"
        return 1
    fi

    # Method 2: Check BSSID (Access Point MAC) - critical check!
    # If BSSID is empty or all zeros, we're not associated with any AP
    local bssid=$(iwconfig "$WIFI_INTERFACE" 2>/dev/null | grep "Access Point" | awk '{print $6}' | tr '[:upper:]' '[:lower:]')
    if [ -z "$bssid" ] || [ "$bssid" = "not-associated" ] || [ "$bssid" = "00:00:00:00:00:00" ]; then
        log DEBUG "Not associated with any Access Point (BSSID: ${bssid:-empty})"
        return 1
    fi
    log DEBUG "Associated with BSSID: $bssid"

    # Method 3: Check signal quality
    local signal=$(iwconfig "$WIFI_INTERFACE" 2>/dev/null | grep "Signal level" | sed 's/.*Signal level=\(-*[0-9]*\).*/\1/')
    if [ -n "$signal" ] && [ "$signal" -le -90 ]; then
        log DEBUG "Signal too weak: ${signal} dBm"
        return 1
    fi

    # Method 4: Check if we have an IP address
    if ! ip -4 addr show "$WIFI_INTERFACE" 2>/dev/null | grep -q "inet "; then
        log DEBUG "No IPv4 address assigned"
        return 1
    fi

    # Method 5: Check gateway reachability (ping default gateway)
    local gateway=$(ip route show default dev "$WIFI_INTERFACE" 2>/dev/null | awk '{print $3}')
    if [ -n "$gateway" ]; then
        if ! ping -c 1 -W 2 "$gateway" >/dev/null 2>&1; then
            log DEBUG "Gateway $gateway not responding"
            return 1
        fi
        log DEBUG "Gateway $gateway is reachable"
    fi

    # Method 6: NetworkManager active connection (additional check)
    if nmcli -t -f TYPE,STATE connection show --active 2>/dev/null | grep -q "^wifi:connected$"; then
        return 0
    fi

    # If we passed BSSID and gateway checks, consider it connected
    log DEBUG "Wi-Fi appears to be properly connected"
    return 0
}

# Check general internet connectivity (ping test)
check_internet_access() {
    log DEBUG "Checking internet connectivity..."

    # Try to ping Cloudflare and Google DNS (non-blocking, 2 attempts)
    if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 || \
        ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log INFO "Internet connection is active"
        return 0
    else
        log WARN "No internet connectivity detected"
        return 1
    fi
}

# Main recovery sequence
perform_recovery() {
    log WARN "Wi-Fi disconnected - starting recovery sequence for chipset ${MODULE_CODE}"

    # Diagnostic: show current module state
    log DEBUG "Current module state: $(lsmod | grep -i "${MODULE_CODE}" || echo 'not found in lsmod')"

    log INFO "Step 1: Disabling Wi-Fi radio via nmcli"
    timeout 5 nmcli radio wifi off || log WARN "nmcli radio off failed (continuing)"

    log INFO "Step 2: Blocking Wi-Fi via rfkill"
    timeout 5 rfkill block wifi || log WARN "rfkill block failed (continuing)"

    log INFO "Step 3: Killing nm-applet"
    killall nm-applet 2>/dev/null && log INFO "nm-applet killed" || log INFO "nm-applet not running"

    log INFO "Step 4: Stopping NetworkManager"
    timeout 10 systemctl stop NetworkManager || log ERROR "Failed to stop NetworkManager (continuing anyway)"

    log INFO "Step 5: Stopping wpa_supplicant"
    timeout 5 systemctl stop wpa_supplicant 2>/dev/null || log WARN "wpa_supplicant stop failed (continuing)"

    log INFO "Step 6: Triggering udev events"
    timeout 5 udevadm trigger --attr-match=subsystem=net || log WARN "udevadm trigger failed (continuing)"

    # Critical step: Remove module (try both ways, ignore errors if module not loaded)
    log INFO "Step 7: Removing kernel module '$MODULE_NAME' (chipset ${MODULE_CODE})"
    if ! timeout 10 rmmod -f "$MODULE_NAME" 2>/dev/null; then
        log DEBUG "rmmod failed - trying modprobe -r"
        timeout 10 modprobe -r "$MODULE_NAME" 2>/dev/null || log WARN "Module removal failed (continuing anyway)"
    fi

    sleep 3  # Critical pause for hardware reset

    log INFO "Step 8: Reloading kernel module '$MODULE_NAME'"
    if ! timeout 15 modprobe "$MODULE_NAME"; then
        log FATAL "CRITICAL: Failed to reload module '$MODULE_NAME' - hardware may be unresponsive"
        return 1
    fi

    log INFO "Step 9: Restarting NetworkManager"
    if ! timeout 15 systemctl restart NetworkManager; then
        log ERROR "NetworkManager restart failed"
        return 1
    fi

    log INFO "Step 10: Enabling Wi-Fi radio"
    if ! timeout 10 nmcli radio wifi on; then
        log ERROR "Failed to enable Wi-Fi radio"
        return 1
    fi

    log INFO "Waiting $RECOVERY_DELAY seconds for connection to stabilize..."
    sleep $RECOVERY_DELAY

    # Verify recovery success
    if [ -n "$WIFI_INTERFACE" ] && is_wifi_connected; then
        log INFO "Wi-Fi recovery successful - connection restored (chipset ${MODULE_CODE}, script v${SCRIPT_VERSION})"
        return 0
    elif check_internet_access; then
        log INFO "Recovery completed - internet connectivity verified (chipset ${MODULE_CODE}, script v${SCRIPT_VERSION})"
        return 0
    else
        log ERROR "Recovery sequence completed but connection not restored"
        log DEBUG "Current interface state: $(ip link show $WIFI_INTERFACE 2>/dev/null || echo 'interface missing')"
        return 1
    fi
}

# Main execution
main() {
    log INFO "=== Wi-Fi Adapter Healer Started (v${SCRIPT_VERSION}) ==="
    log INFO "Target chipset code: ${MODULE_CODE}"

    # Try to detect interface (may fail if adapter frozen)
    if ! detect_interface; then
        log WARN "Interface detection failed - checking internet connectivity before recovery"
        # If no interface BUT internet exists → exit (using other connection)
        if check_internet_access; then
            log INFO "Internet is working via other interface - no recovery needed"
            exit 0
        fi
        # If no interface AND no internet → proceed with recovery
        log WARN "No internet access detected - proceeding with module-level recovery"
    fi

    detect_module

    log INFO "Checking Wi-Fi connectivity status..."
    if [ -n "$WIFI_INTERFACE" ] && is_wifi_connected; then
        log INFO "Wi-Fi is connected - no action required (script v${SCRIPT_VERSION})"
        exit 0
    fi

    log WARN "Wi-Fi is disconnected - initiating recovery for chipset ${MODULE_CODE}"

    if perform_recovery; then
        exit 0
    else
        log FATAL "Recovery failed - manual intervention may be required (script v${SCRIPT_VERSION})"
        exit 1
    fi
}

# Trap cleanup
trap 'log INFO "Script terminated by signal (v${SCRIPT_VERSION})"' SIGINT SIGTERM

# Execute
main "$@"