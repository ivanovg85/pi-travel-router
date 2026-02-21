#!/usr/bin/env bash
# =============================================================================
# Travel Router — Location Configuration Script
# Run at each new location to connect the Pi to local WiFi and activate VPN.
#
# Usage:
#   sudo ./configure-location.sh "WiFi Network Name" "wifi_password"
#   sudo ./configure-location.sh "WiFi Network Name" "wifi_password" --country Germany
#   sudo ./configure-location.sh --list-countries
#   sudo ./configure-location.sh --status
#
# From your phone via SSH:
#   ssh travelpi "sudo /home/pi/configure-location.sh 'Hotel WiFi' 'pass123'"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

TIMEOUT_WIFI=30     # Seconds to wait for WiFi association
TIMEOUT_INTERNET=20 # Seconds to wait for internet connectivity

# --- Helpers -----------------------------------------------------------------

log()     { echo "[INFO]  $*"; }
ok()      { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
die()     { echo "[ERROR] $*" >&2; exit 1; }
progress(){ echo -n "[....] $*"; }
done_ok() { echo " done"; }

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root: sudo $0"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "config.env not found at $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

# --- Usage / Help ------------------------------------------------------------

usage() {
    cat << EOF
Usage:
  sudo $0 "SSID" "password" [--country <name>]
  sudo $0 --status
  sudo $0 --list-countries
  sudo $0 --help

Options:
  "SSID"              Hotel/venue WiFi network name
  "password"          Hotel/venue WiFi password
  --country <name>    VPN country (e.g., Germany, Netherlands, Japan)
                      Overrides NORDVPN_COUNTRY from config.env for this session
  --status            Show current router status and exit
  --list-countries    List available NordVPN countries and exit
  --help              Show this help

Examples:
  sudo $0 "Hilton_Guest" "welcome123"
  sudo $0 "Marriott_WiFi" "hotel2024" --country Netherlands
  sudo $0 --status

EOF
}

# --- Status ------------------------------------------------------------------

show_status() {
    echo ""
    echo "=== Travel Router Status ==="
    echo ""

    # VPN status
    echo "--- VPN ---"
    if command -v nordvpn &>/dev/null; then
        nordvpn status
    else
        echo "NordVPN not installed"
    fi
    echo ""

    # Network interfaces
    echo "--- Interfaces ---"
    nmcli dev status
    echo ""

    # IP addresses (simplified)
    echo "--- IP Addresses ---"
    ip addr show | grep -E '(^[0-9]+:|inet (?!127))' | grep -v 'inet6'
    echo ""

    # Active routes
    echo "--- Default Route ---"
    ip route show default
    echo ""

    # Internet reachability test
    echo "--- Internet Check ---"
    if curl -s --max-time 5 https://checkip.amazonaws.com &>/dev/null; then
        local public_ip
        public_ip=$(curl -s --max-time 5 https://checkip.amazonaws.com)
        echo "  Reachable — Public IP: $public_ip"
    else
        echo "  No internet access"
    fi
    echo ""
}

# --- Connect to Venue WiFi ---------------------------------------------------

connect_wan() {
    local ssid="$1"
    local password="$2"

    log "Connecting $WAN_INTERFACE to '$ssid'..."

    # Remove any existing connection for this interface to start clean
    # This prevents credential caching issues
    local existing_con
    existing_con=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
        | grep ":$WAN_INTERFACE$" | cut -d: -f1 || true)
    if [[ -n "$existing_con" ]]; then
        nmcli con down "$existing_con" &>/dev/null || true
    fi

    # Delete any saved connection with the same name to avoid conflicts
    nmcli con delete "venue-wifi" &>/dev/null || true

    # Connect to the venue WiFi
    # nmcli creates and activates the connection profile in one step
    if ! nmcli dev wifi connect "$ssid" \
            password "$password" \
            ifname "$WAN_INTERFACE" \
            name "venue-wifi" \
            &>/dev/null; then
        die "Failed to connect to '$ssid'. Check the SSID and password."
    fi

    # Give venue-wifi higher autoconnect priority than phone-hotspot (10) so
    # the Pi reconnects to hotel WiFi on reboot rather than falling back to phone
    nmcli con modify "venue-wifi" connection.autoconnect-priority 50 &>/dev/null || true

    # Wait for the connection to associate and get an IP
    progress "Waiting for WiFi association"
    local elapsed=0
    while ! nmcli -t -f DEVICE,STATE dev | grep -q "^${WAN_INTERFACE}:connected$"; do
        sleep 1
        elapsed=$((elapsed + 1))
        echo -n "."
        if [[ $elapsed -ge $TIMEOUT_WIFI ]]; then
            echo ""
            die "Timed out waiting for $WAN_INTERFACE to connect to '$ssid'"
        fi
    done
    done_ok

    local wan_ip
    wan_ip=$(ip -4 addr show "$WAN_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    ok "Connected to '$ssid' — local IP: ${wan_ip:-unknown}"
}

# --- Wait for Internet Connectivity ------------------------------------------

wait_for_internet() {
    # NordVPN kill switch blocks all outbound traffic from the Pi while VPN is
    # disconnected. A curl check here would time out on every run. Skip it when
    # kill switch is active — connect_vpn() will fail with a clear error if the
    # venue WiFi genuinely has no internet.
    if nordvpn settings 2>/dev/null | grep -qi "Kill Switch: enabled"; then
        log "Skipping internet check (NordVPN kill switch active)"
        return 0
    fi

    progress "Waiting for internet connectivity"
    local elapsed=0
    while ! curl -s --max-time 3 https://checkip.amazonaws.com &>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        echo -n "."
        if [[ $elapsed -ge $TIMEOUT_INTERNET ]]; then
            echo ""
            warn "Internet not reachable after ${TIMEOUT_INTERNET}s. Continuing anyway."
            return 1
        fi
    done
    done_ok
    return 0
}

# --- Connect VPN -------------------------------------------------------------

connect_vpn() {
    local country="$1"

    log "Connecting NordVPN ($country)..."

    # Check NordVPN daemon is running
    if ! systemctl is-active --quiet nordvpnd; then
        log "Starting NordVPN daemon..."
        systemctl start nordvpnd
        sleep 2
    fi

    # Check if already logged in
    if ! nordvpn account &>/dev/null 2>&1; then
        die "NordVPN is not logged in. Run 'nordvpn login --token <token>' first."
    fi

    # Disconnect first if already connected (ensures we use the new country)
    if nordvpn status 2>/dev/null | grep -q "Connected"; then
        nordvpn disconnect &>/dev/null || true
        sleep 2
    fi

    # Connect to specified country
    if nordvpn connect "$country"; then
        ok "VPN connected ($country)"
    else
        warn "Could not connect VPN to '$country'. Trying default server..."
        nordvpn connect || die "VPN connection failed completely. Check 'nordvpn status'."
    fi

    # Show the public IP through VPN
    sleep 2  # Brief pause for routes to stabilize
    local vpn_ip
    vpn_ip=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo "unknown")
    ok "VPN active — public IP: $vpn_ip"
}

# --- Verify AP is Still Running ----------------------------------------------

verify_ap() {
    if nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep -q "travel-router-ap:$AP_INTERFACE"; then
        ok "Hotspot '$AP_SSID' is active on $AP_INTERFACE"
    else
        warn "Hotspot appears to be down. Restarting..."
        nmcli con up "travel-router-ap" \
            || warn "Could not restart hotspot. Check 'nmcli con show travel-router-ap'"
    fi
}

# --- Verify Forwarding Rules Are Active --------------------------------------

verify_forwarding() {
    # Ensure IP forwarding is on (it may reset after updates on some systems)
    if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
        warn "IP forwarding was disabled, re-enabling..."
        sysctl -w net.ipv4.ip_forward=1
    fi
}

# --- Main --------------------------------------------------------------------

main() {
    require_root
    load_config

    # Parse arguments
    local ssid=""
    local password=""
    local vpn_country="${NORDVPN_COUNTRY}"

    case "${1:-}" in
        --help | -h)
            usage
            exit 0
            ;;
        --status)
            show_status
            exit 0
            ;;
        --list-countries)
            nordvpn countries
            exit 0
            ;;
        "")
            usage
            die "No arguments provided. Provide WiFi SSID and password."
            ;;
        *)
            ssid="${1:-}"
            password="${2:-}"
            [[ -n "$ssid" ]]     || die "SSID cannot be empty"
            [[ -n "$password" ]] || die "Password cannot be empty"

            # Parse optional flags
            shift 2
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --country)
                        [[ -n "${2:-}" ]] || die "--country requires a value"
                        vpn_country="$2"
                        shift 2
                        ;;
                    *)
                        warn "Unknown option: $1 (ignored)"
                        shift
                        ;;
                esac
            done
            ;;
    esac

    log ""
    log "=============================================="
    log " Configuring for new location"
    log "=============================================="
    log " Venue WiFi   : $ssid"
    log " WAN interface: $WAN_INTERFACE"
    log " VPN country  : $vpn_country"
    log "=============================================="
    log ""

    connect_wan "$ssid" "$password"
    wait_for_internet || true
    connect_vpn "$vpn_country"
    verify_ap
    verify_forwarding

    log ""
    ok "=============================================="
    ok " Location configured successfully!"
    ok "=============================================="
    ok " Your devices on '$AP_SSID' now have"
    ok " VPN-protected internet access."
    ok ""
    ok " Run 'router-status' or '$0 --status'"
    ok " to check the router state at any time."
    ok "=============================================="
    log ""
}

main "$@"
