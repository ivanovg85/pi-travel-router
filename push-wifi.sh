#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# push-wifi.sh — Push venue WiFi credentials to the Pi travel router
#
# Run this in Termux while your phone is connected to the Pi's hotspot.
#
# Usage:
#   push-wifi [SSID] [--country COUNTRY] [--status] [--list-countries]
#
# Examples:
#   push-wifi                           # prompts for SSID and password
#   push-wifi "Hotel WiFi"              # prompts for password only
#   push-wifi "Hotel WiFi" --country DE # connect VPN to Germany
#   push-wifi --status                  # show current router status
#   push-wifi --list-countries          # list available VPN countries
#
# Auto-detection: if Termux:API is installed and your phone was recently
# connected to the venue WiFi, the SSID may be pre-filled automatically.
# =============================================================================

PI_HOST="192.168.10.1"
PI_USER="pi"
PI_PORT="22"
REMOTE_SCRIPT="/home/pi/configure-location.sh"

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

detect_ssid() {
    command -v termux-wifi-connectioninfo >/dev/null 2>&1 || return 1
    local info ssid
    info=$(termux-wifi-connectioninfo 2>/dev/null) || return 1
    # Parse "ssid": "SomeName"  (handles both with and without quotes around value)
    ssid=$(printf '%s' "$info" | grep -o '"ssid": *"[^"]*"' | sed 's/.*"ssid": *"\(.*\)"/\1/')
    # Skip "<unknown ssid>" which Android returns when permission not granted
    [[ "$ssid" == "<unknown ssid>" || -z "$ssid" ]] && return 1
    printf '%s' "$ssid"
}

# ---- argument parsing -------------------------------------------------------

SSID=""
COUNTRY=""
STATUS_ONLY=0
LIST_COUNTRIES=0

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

if [[ -z "$SSID" ]]; then
    detected=$(detect_ssid 2>/dev/null)
    if [[ -n "$detected" ]]; then
        echo "Detected WiFi: \"$detected\""
        read -r -p "Use this SSID? [Y/n] " yn
        case "$yn" in
            [Nn]*) ;;
            *) SSID="$detected" ;;
        esac
    fi
fi

if [[ -z "$SSID" ]]; then
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
