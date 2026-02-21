#!/usr/bin/env bash
# =============================================================================
# Travel Router — Initial Setup Script
# Run once after first boot on the Raspberry Pi.
#
# Usage:
#   sudo ./setup.sh            # Full setup (USB adapter must be plugged in)
#   sudo ./setup.sh --no-wan   # Partial setup without USB adapter — skips
#                              # WAN interface check and phone hotspot config.
#                              # Use this to prepare the Pi before the adapter
#                              # arrives. Re-run without --no-wan to finish.
#
# Prerequisites:
#   - Raspberry Pi OS Lite 64-bit (Bookworm)
#   - Edit config.env before running
#   - Pi must have internet access during setup (Ethernet recommended)
#   - Your SSH public key must already be in ~/.ssh/authorized_keys
#     (done automatically if you set it in Raspberry Pi Imager)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# --- Helpers -----------------------------------------------------------------

log()  { echo "[INFO]  $*"; }
ok()   { echo "[OK]    $*"; }
warn() { echo "[WARN]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root: sudo $0"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "config.env not found at $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log "Loaded config from $CONFIG_FILE"
}

confirm() {
    local prompt="$1"
    read -rp "$prompt [y/N] " answer
    [[ "${answer,,}" == "y" ]]
}

# --- Validation --------------------------------------------------------------

validate_config() {
    local skip_wan="${1:-}"
    log "Validating configuration..."

    [[ -n "${AP_SSID:-}" ]]          || die "AP_SSID is not set in config.env"
    [[ -n "${AP_PASSWORD:-}" ]]      || die "AP_PASSWORD is not set in config.env"
    [[ ${#AP_PASSWORD} -ge 8 ]]      || die "AP_PASSWORD must be at least 8 characters"
    [[ -n "${AP_INTERFACE:-}" ]]     || die "AP_INTERFACE is not set in config.env"
    [[ -n "${WAN_INTERFACE:-}" ]]    || die "WAN_INTERFACE is not set in config.env"
    [[ "${AP_INTERFACE}" != "${WAN_INTERFACE}" ]] \
        || die "AP_INTERFACE and WAN_INTERFACE must be different"
    [[ -n "${NORDVPN_COUNTRY:-}" ]]  || die "NORDVPN_COUNTRY is not set in config.env"

    # Check interfaces exist
    ip link show "$AP_INTERFACE" &>/dev/null \
        || die "AP_INTERFACE '$AP_INTERFACE' not found. Run 'ip link show' to list interfaces."

    if [[ "$skip_wan" == "skip_wan" ]]; then
        warn "Skipping WAN interface check (--no-wan mode)"
    else
        ip link show "$WAN_INTERFACE" &>/dev/null \
            || die "WAN_INTERFACE '$WAN_INTERFACE' not found. Is the USB adapter plugged in?"
    fi

    ok "Configuration is valid"
}

# --- System Update -----------------------------------------------------------

update_system() {
    log "Updating system packages..."
    apt-get update -qq
    apt-get upgrade -y -qq
    ok "System updated"
}

# --- Install Packages --------------------------------------------------------

install_packages() {
    log "Installing required packages..."

    local packages=(
        iw                      # Wireless interface configuration
        wireless-tools          # iwconfig, iwlist
        rfkill                  # Unblock WiFi if soft-blocked
        iptables                # Firewall and NAT
        iptables-persistent     # Persist iptables rules across reboots
        netfilter-persistent    # Service to load saved iptables rules
        nftables                # Modern iptables alternative (useful for debugging)
        dnsutils                # dig, nslookup for debugging
        curl                    # For NordVPN installer
        net-tools               # ifconfig, netstat
        dkms                    # Auto-rebuild kernel modules on updates
        build-essential         # Compiler toolchain for driver builds
        bc                      # Required by some DKMS driver Makefiles
        git                     # Clone driver source
        # Note: kernel headers are pre-installed on Pi OS Bookworm (kernel 6.x).
        # The old "raspberrypi-kernel-headers" package does not exist on kernel 6.12.
    )

    # Silence the iptables-persistent interactive prompt
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections

    apt-get install -y -qq "${packages[@]}"
    ok "Packages installed"
}

# --- Verify WAN Adapter -------------------------------------------------------
#
# The BrosTrend WiFi 6E AXE3000 uses an in-kernel driver — no DKMS needed.
# validate_config() already confirmed $WAN_INTERFACE exists, so this is just
# a confirmation step. If you ever swap adapters, plug it in and reboot before
# running setup.sh so the interface is visible here.

install_wan_driver() {
    ok "WAN interface $WAN_INTERFACE is up — no driver install needed"
}

# --- Configure AP (Hotspot) --------------------------------------------------

configure_ap() {
    log "Configuring access point on $AP_INTERFACE..."

    # Set regulatory country code so the AP broadcasts on legal channels
    iw reg set "$AP_COUNTRY_CODE"

    # Unblock WiFi in case rfkill is blocking it
    rfkill unblock wifi || true

    # Remove any existing hotspot connection profile to start fresh
    nmcli con delete "travel-router-ap" &>/dev/null || true

    # Create the AP connection profile
    # ipv4.method shared tells NetworkManager to:
    #   1. Assign AP_IP to the interface
    #   2. Start a built-in DHCP server for clients
    #   3. Set up iptables NAT masquerading for clients
    nmcli con add \
        type wifi \
        ifname "$AP_INTERFACE" \
        con-name "travel-router-ap" \
        ssid "$AP_SSID" \
        mode ap \
        ipv4.addresses "${AP_IP}/24" \
        ipv4.method shared \
        ipv6.method disabled \
        802-11-wireless.band "$AP_BAND" \
        802-11-wireless.channel "$AP_CHANNEL" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$AP_PASSWORD" \
        connection.autoconnect yes \
        connection.autoconnect-priority 100

    # Bring up the AP connection
    nmcli con up "travel-router-ap" || warn "Could not bring up AP now; it will start on next boot"

    ok "Hotspot configured: SSID='$AP_SSID', IP=$AP_IP"
}

# --- Configure IP Forwarding -------------------------------------------------

configure_ip_forwarding() {
    log "Enabling IP forwarding..."

    # Enable immediately
    sysctl -w net.ipv4.ip_forward=1

    # Persist across reboots
    local sysctl_conf="/etc/sysctl.d/99-travelrouter.conf"
    cat > "$sysctl_conf" << 'EOF'
# Travel Router: enable IPv4 forwarding for routing AP clients
net.ipv4.ip_forward=1

# Disable IPv6 forwarding (we only route IPv4)
net.ipv6.conf.all.forwarding=0
EOF

    ok "IP forwarding enabled"
}

# --- Configure iptables Forwarding Rules -------------------------------------

configure_iptables() {
    log "Configuring iptables forwarding rules..."

    # NetworkManager's 'ipv4.method shared' already sets up MASQUERADE for the AP.
    # We add explicit FORWARD rules to ensure traffic flows AP → WAN interface
    # and AP → VPN tunnel (nordlynx). These rules are needed because NordVPN's
    # kill switch uses its own FORWARD DROP rules, and we must explicitly permit
    # forwarded traffic from the AP subnet.

    local ap_subnet="$AP_SUBNET"

    # Flush existing FORWARD rules in our custom chain (idempotent)
    iptables -F FORWARD 2>/dev/null || true

    # Allow established/related connections back to AP clients
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow new connections from AP clients going out (to VPN or WAN)
    iptables -A FORWARD -s "$ap_subnet" -j ACCEPT

    # Drop everything else forwarded (default deny)
    iptables -A FORWARD -j DROP

    # NAT masquerade for WAN interface (fallback when VPN is off)
    # NordVPN adds its own MASQUERADE rule for nordlynx when it connects
    iptables -t nat -A POSTROUTING -s "$ap_subnet" -o "$WAN_INTERFACE" -j MASQUERADE

    # Save rules so they persist across reboots
    netfilter-persistent save
    ok "iptables rules configured and saved"
}

# --- Install NordVPN ---------------------------------------------------------

install_nordvpn() {
    log "Installing NordVPN..."

    if command -v nordvpn &>/dev/null; then
        warn "NordVPN is already installed ($(nordvpn --version))"
        return
    fi

    # Official NordVPN installer — supports ARM64 (Raspberry Pi 4 with 64-bit OS)
    curl -sSf https://downloads.nordvpn.com/apps/linux/install.sh | sh

    # Add pi user to the nordvpn group so they can run nordvpn without sudo
    usermod -aG nordvpn pi

    ok "NordVPN installed"
}

# --- Configure NordVPN -------------------------------------------------------

configure_nordvpn() {
    log "Configuring NordVPN..."

    # The nordvpn daemon must be running for configuration
    systemctl enable --now nordvpnd

    # Set VPN technology (nordlynx = WireGuard-based, faster)
    nordvpn set technology "$NORDVPN_TECHNOLOGY"

    # Kill switch: drops all internet traffic if VPN disconnects
    # This prevents your real IP from leaking when the VPN drops
    nordvpn set killswitch on

    # Routing: allows devices connected to the Pi (AP clients) to have their
    # traffic routed through NordVPN, not just the Pi's own traffic
    nordvpn set routing on

    # Allow AP subnet to still be reachable even with kill switch on
    # This ensures you can still SSH into the Pi when VPN is disconnected
    nordvpn whitelist add subnet "$AP_SUBNET"

    # Allow LAN discovery (access Pi from local network)
    nordvpn set lan-discovery on

    # Set default VPN country
    nordvpn set defaults &>/dev/null || true  # Reset any previous settings

    local nordvpn_token="${NORDVPN_TOKEN:-}"

    if [[ -n "$nordvpn_token" ]]; then
        log "Using NordVPN token from config.env"
    else
        log ""
        log "========================================================"
        log " NordVPN Authentication Required"
        log "========================================================"
        log " No NORDVPN_TOKEN found in config.env."
        log " Get one at: my.nordaccount.com"
        log "   → Services → NordVPN → Set up NordVPN manually"
        log "   → Generate new token"
        log "========================================================"
        log ""
        read -rp "Paste your NordVPN access token: " nordvpn_token
        [[ -n "$nordvpn_token" ]] || die "No token provided, cannot authenticate NordVPN"
    fi

    nordvpn login --token "$nordvpn_token" \
        || die "NordVPN login failed. Check your token and try again."

    # Connect to the configured country
    log "Connecting to NordVPN ($NORDVPN_COUNTRY)..."
    nordvpn connect "$NORDVPN_COUNTRY" \
        || warn "Initial VPN connection failed. Run 'nordvpn connect' manually after setup."

    ok "NordVPN configured (country: $NORDVPN_COUNTRY)"
}

# --- Configure Phone Hotspot as Fallback WAN ---------------------------------

configure_phone_hotspot() {
    [[ -n "${PHONE_HOTSPOT_SSID:-}" ]] || { log "PHONE_HOTSPOT_SSID not set, skipping"; return; }

    log "Configuring phone hotspot as fallback WAN..."

    # Remove any existing profile to start fresh
    nmcli con delete "phone-hotspot" &>/dev/null || true

    if [[ -n "${PHONE_HOTSPOT_PASSWORD:-}" ]]; then
        nmcli con add \
            type wifi \
            ifname "$WAN_INTERFACE" \
            con-name "phone-hotspot" \
            ssid "$PHONE_HOTSPOT_SSID" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$PHONE_HOTSPOT_PASSWORD" \
            connection.autoconnect yes \
            connection.autoconnect-priority 10
    else
        nmcli con add \
            type wifi \
            ifname "$WAN_INTERFACE" \
            con-name "phone-hotspot" \
            ssid "$PHONE_HOTSPOT_SSID" \
            connection.autoconnect yes \
            connection.autoconnect-priority 10
    fi

    ok "Phone hotspot profile saved (SSID: '$PHONE_HOTSPOT_SSID')"
    ok "wlan1 will auto-connect to your phone when no venue WiFi is configured"
}

# --- Harden SSH --------------------------------------------------------------

harden_ssh() {
    log "Hardening SSH configuration..."

    local ssh_config="/etc/ssh/sshd_config.d/99-travelrouter.conf"

    cat > "$ssh_config" << EOF
# Travel Router SSH hardening
Port $SSH_PORT
PermitRootLogin no
MaxAuthTries 3
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF

    if [[ "${SSH_DISABLE_PASSWORD:-yes}" == "yes" ]]; then
        # Verify the user has an authorized key before disabling password auth
        local auth_keys="/home/pi/.ssh/authorized_keys"
        if [[ -s "$auth_keys" ]]; then
            echo "PasswordAuthentication no" >> "$ssh_config"
            echo "KbdInteractiveAuthentication no" >> "$ssh_config"
            ok "Password authentication disabled (SSH key required)"
        else
            warn "No SSH authorized_keys found for user 'pi'!"
            warn "Password authentication NOT disabled to avoid locking you out."
            warn "Add your SSH key to /home/pi/.ssh/authorized_keys and re-run, or"
            warn "manually add: 'PasswordAuthentication no' to $ssh_config"
        fi
    fi

    systemctl reload ssh

    ok "SSH hardened (port $SSH_PORT)"
}

# --- Configure Systemd Services ----------------------------------------------

configure_services() {
    log "Enabling services..."

    systemctl enable NetworkManager
    systemctl enable nordvpnd
    systemctl enable netfilter-persistent

    ok "Services enabled for auto-start on boot"
}

# --- Create Status Check Script ----------------------------------------------

create_status_script() {
    log "Creating status check script..."

    cat > /usr/local/bin/router-status << 'STATUSEOF'
#!/usr/bin/env bash
echo "=== Travel Router Status ==="
echo ""
echo "--- VPN ---"
nordvpn status
echo ""
echo "--- Network Interfaces ---"
nmcli dev status
echo ""
echo "--- IP Addresses ---"
ip addr show | grep -E '(^[0-9]+:|inet )'
echo ""
echo "--- Default Route ---"
ip route show default
echo ""
echo "--- Connected AP Clients ---"
arp -n | grep -v incomplete | tail -n +2 || echo "None"
STATUSEOF

    chmod +x /usr/local/bin/router-status
    ok "Status script created: run 'router-status' to check everything"
}

# --- Main --------------------------------------------------------------------

main() {
    local no_wan=0
    for arg in "$@"; do
        [[ "$arg" == "--no-wan" ]] && no_wan=1
    done

    require_root
    load_config
    [[ "$no_wan" == 1 ]] && validate_config skip_wan || validate_config

    log ""
    log "=============================================="
    log " Travel Router Initial Setup"
    [[ "$no_wan" == 1 ]] && log " Mode: --no-wan (WAN steps skipped)"
    log "=============================================="
    log " AP interface  : $AP_INTERFACE"
    log " WAN interface : $WAN_INTERFACE"
    log " Hotspot SSID  : $AP_SSID"
    log " Hotspot IP    : $AP_IP"
    log " VPN country   : $NORDVPN_COUNTRY"
    log "=============================================="
    log ""

    confirm "Proceed with setup?" || { log "Aborted."; exit 0; }

    update_system
    install_packages
    if [[ "$no_wan" == 0 ]]; then
        install_wan_driver
    fi
    configure_ap
    if [[ "$no_wan" == 0 ]]; then
        configure_phone_hotspot
    fi
    configure_ip_forwarding
    configure_iptables
    install_nordvpn
    configure_nordvpn
    harden_ssh
    configure_services
    create_status_script

    log ""
    ok "=============================================="
    if [[ "$no_wan" == 1 ]]; then
        ok " Partial setup complete (--no-wan)!"
        ok "=============================================="
        ok ""
        ok " WAN adapter steps were skipped."
        ok " Once the BrosTrend adapter arrives:"
        ok "   1. Plug it in and reboot"
        ok "   2. Verify: ip link show wlan1"
        ok "   3. Re-run: sudo ./setup.sh"
    else
        ok " Setup complete!"
        ok "=============================================="
        ok ""
        ok " Your hotspot '$AP_SSID' is now active."
        ok " Connect your phone to '$AP_SSID' and SSH"
        ok " to $AP_IP to manage the router."
        ok ""
        ok " At each new location, run:"
        ok "   sudo ./configure-location.sh 'WiFiName' 'password'"
    fi
    ok ""
    ok " Rebooting in 10 seconds..."
    ok "=============================================="

    sleep 10
    reboot
}

main "$@"
