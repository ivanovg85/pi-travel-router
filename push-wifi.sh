#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# push-wifi.sh — Push venue WiFi credentials to the Pi travel router
#
# Run this in Termux while your phone is connected to the Pi's hotspot.
#
# Usage:
#   push-wifi [SSID] [--country COUNTRY] [--status] [--list-countries] [--scan]
#
# Examples:
#   push-wifi                           # prompts for SSID and password
#   push-wifi --scan                    # scan for networks and pick one
#   push-wifi "Hotel WiFi"              # prompts for password only
#   push-wifi "Hotel WiFi" --country DE # connect VPN to Germany
#   push-wifi --status                  # show current router status
#   push-wifi --list-countries          # list available VPN countries
# =============================================================================

PI_HOST="192.168.10.1"
PI_USER="georgi"
PI_PORT="22"
REMOTE_SCRIPT="/home/georgi/pi-travel-router/configure-location.sh"

# ---- helpers ----------------------------------------------------------------

die() { echo "Error: $*" >&2; exit 1; }

ssh_pi() {
    ssh -q \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -p "$PI_PORT" \
        "${PI_USER}@${PI_HOST}" \
        "$@"
}

scan_networks() {
    command -v termux-wifi-scaninfo >/dev/null 2>&1 || {
        echo "Error: termux-wifi-scaninfo not found. Install Termux:API app and run: pkg install termux-api" >&2
        return 1
    }

    echo "Scanning for WiFi networks..."
    local scan_result
    scan_result=$(termux-wifi-scaninfo 2>/dev/null) || {
        echo "Error: WiFi scan failed. Make sure location is enabled." >&2
        return 1
    }

    # Parse JSON array and extract SSIDs with signal strength, filter duplicates and travel-pi
    # Format: ssid (signal dBm)
    local networks
    networks=$(printf '%s' "$scan_result" | \
        grep -oE '"ssid": *"[^"]*"|"level": *-?[0-9]+' | \
        paste - - | \
        sed 's/"ssid": *"\([^"]*\)".*"level": *\(-\?[0-9]*\)/\1|\2/' | \
        grep -v '^travel-pi|' | \
        grep -v '^|' | \
        sort -t'|' -k2 -rn | \
        awk -F'|' '!seen[$1]++ {print $1 "|" $2}')

    [[ -z "$networks" ]] && {
        echo "No networks found (other than travel-pi)." >&2
        return 1
    }

    echo
    echo "Available networks:"
    local i=1
    local ssid_list=()
    while IFS='|' read -r ssid signal; do
        printf "  %d) %s (signal: %s dBm)\n" "$i" "$ssid" "$signal"
        ssid_list+=("$ssid")
        ((i++))
    done <<< "$networks"

    echo
    local selection
    read -r -p "Select network [1-$((i-1))]: " selection

    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -ge "$i" ]]; then
        echo "Invalid selection." >&2
        return 1
    fi

    printf '%s' "${ssid_list[$((selection-1))]}"
}

# ---- argument parsing -------------------------------------------------------

SSID=""
COUNTRY=""
STATUS_ONLY=0
LIST_COUNTRIES=0
SCAN_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --country|-c)
            [[ -n "$2" ]] || die "--country requires a value"
            COUNTRY="$2"
            shift 2
            ;;
        --status|-s)
            STATUS_ONLY=1
            shift
            ;;
        --list-countries|-l)
            LIST_COUNTRIES=1
            shift
            ;;
        --scan)
            SCAN_MODE=1
            shift
            ;;
        --help|-h)
            sed -n '2,/^####/p' "$0" | grep '^#' | sed 's/^# *//'
            exit 0
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            [[ -z "$SSID" ]] || die "Unexpected argument: $1"
            SSID="$1"
            shift
            ;;
    esac
done

# ---- quick commands (no credentials needed) ---------------------------------

if [[ "$LIST_COUNTRIES" == 1 ]]; then
    echo "Fetching VPN country list from Pi..."
    ssh_pi "sudo $REMOTE_SCRIPT --list-countries"
    exit
fi

if [[ "$STATUS_ONLY" == 1 ]]; then
    echo "Fetching Pi router status..."
    ssh_pi "router-status"
    exit
fi

# ---- collect SSID -----------------------------------------------------------

if [[ "$SCAN_MODE" == 1 ]]; then
    SSID=$(scan_networks) || exit 1
    echo
    echo "Selected: \"$SSID\""
elif [[ -z "$SSID" ]]; then
    read -r -p "Venue WiFi SSID: " SSID
fi

[[ -n "$SSID" ]] || die "SSID is required"

# ---- collect password -------------------------------------------------------

read -r -s -p "Password for '$SSID': " PASSWORD
echo  # newline after silent input

[[ -n "$PASSWORD" ]] || die "Password is required"

# ---- verify Pi is reachable before sending credentials ----------------------

echo
echo "Connecting to Pi at $PI_HOST..."
if ! ssh_pi "true" 2>/dev/null; then
    echo
    echo "Cannot reach Pi at $PI_HOST."
    echo "Make sure your phone is connected to the Pi's hotspot, then retry."
    exit 1
fi

# ---- build and run remote command -------------------------------------------

# Use printf %q for shell-safe escaping of SSID, password, and country
SSID_Q=$(printf '%q' "$SSID")
PASS_Q=$(printf '%q' "$PASSWORD")

CMD="sudo $REMOTE_SCRIPT $SSID_Q $PASS_Q"
if [[ -n "$COUNTRY" ]]; then
    COUNTRY_Q=$(printf '%q' "$COUNTRY")
    CMD="$CMD --country $COUNTRY_Q"
fi

echo "Configuring Pi for: \"$SSID\""
[[ -n "$COUNTRY" ]] && echo "VPN country: $COUNTRY"
echo

ssh_pi "$CMD"
