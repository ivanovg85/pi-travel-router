#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Termux setup for Pi travel router management
# Run this ONCE in Termux on your phone after installing Termux.
#
# Prerequisites:
#   1. Install Termux from F-Droid (not Google Play - that version is outdated)
#   2. Install Termux:API from F-Droid (same source as Termux)
#   3. Transfer this script to your phone and run it, OR paste and run directly:
#      pkg install curl && bash <(curl -sL <URL>)
# =============================================================================

set -e

PI_HOST="192.168.10.1"
PI_USER="pi"
PI_PORT="22"
SCRIPT_DIR="$HOME/.local/bin"

echo "=== Pi Travel Router — Termux Setup ==="
echo

# Install required packages
echo "[1/4] Installing packages..."
pkg update -y -q
pkg install -y openssh

echo "[2/4] Installing optional Termux:API (for auto-detecting WiFi SSID)..."
pkg install -y termux-api 2>/dev/null || echo "  (skipped — install Termux:API app from F-Droid for auto-detect)"

# Set up SSH key
echo
echo "[3/4] SSH key setup"
echo "  You need the private key that matches the public key you loaded onto"
echo "  the Pi via Raspberry Pi Imager."
echo
echo "  Options:"
echo "    a) I'll paste the private key content now"
echo "    b) The key is already at ~/.ssh/id_ed25519 (skip this step)"
echo "    c) Generate a new key (you'll need to add it to the Pi separately)"
echo
read -r -p "  Choice [a/b/c]: " KEY_CHOICE

mkdir -p ~/.ssh
chmod 700 ~/.ssh

case "$KEY_CHOICE" in
    a|A)
        echo "  Paste your private key below, then press Ctrl-D on a blank line:"
        echo "  (The key starts with -----BEGIN ... PRIVATE KEY-----)"
        cat > ~/.ssh/id_ed25519
        chmod 600 ~/.ssh/id_ed25519
        echo "  Key saved to ~/.ssh/id_ed25519"
        ;;
    b|B)
        if [ -f ~/.ssh/id_ed25519 ]; then
            echo "  Found existing key at ~/.ssh/id_ed25519"
        elif [ -f ~/.ssh/id_rsa ]; then
            echo "  Found existing key at ~/.ssh/id_rsa"
        else
            echo "  WARNING: No key found at ~/.ssh/id_ed25519 or ~/.ssh/id_rsa"
        fi
        ;;
    c|C)
        echo "  Generating new ED25519 key..."
        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "termux-pi-router"
        echo
        echo "  *** ADD THIS PUBLIC KEY TO THE PI ***"
        echo "  From your computer, run:"
        echo
        echo "    ssh pi@<PI_IP> 'echo \"$(cat ~/.ssh/id_ed25519.pub)\" >> ~/.ssh/authorized_keys'"
        echo
        echo "  Or, if the Pi AP is up and password auth is still enabled:"
        echo "    ssh-copy-id -i ~/.ssh/id_ed25519.pub -p $PI_PORT $PI_USER@$PI_HOST"
        echo
        read -r -p "  Press Enter once the public key is added to the Pi..."
        ;;
esac

# Write SSH client config
cat > ~/.ssh/config << EOF
Host pi-router
    HostName $PI_HOST
    User $PI_USER
    Port $PI_PORT
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    ConnectTimeout 10
EOF
chmod 600 ~/.ssh/config
echo
echo "  SSH config written: 'ssh pi-router' will connect to the Pi"

# Install push-wifi.sh
echo
echo "[4/4] Installing push-wifi.sh..."
mkdir -p "$SCRIPT_DIR"

# Download or copy push-wifi.sh
if [ -f "$(dirname "$0")/push-wifi.sh" ]; then
    cp "$(dirname "$0")/push-wifi.sh" "$SCRIPT_DIR/push-wifi"
    chmod +x "$SCRIPT_DIR/push-wifi"
elif command -v curl >/dev/null 2>&1; then
    echo "  push-wifi.sh not found alongside this script."
    echo "  Copy push-wifi.sh to $SCRIPT_DIR/push-wifi manually."
else
    echo "  Copy push-wifi.sh to $SCRIPT_DIR/push-wifi manually."
fi

# Add SCRIPT_DIR to PATH if not already there
if ! grep -q "$SCRIPT_DIR" ~/.bashrc 2>/dev/null; then
    echo "export PATH=\"$SCRIPT_DIR:\$PATH\"" >> ~/.bashrc
fi

echo
echo "=== Setup complete ==="
echo
echo "Connect your phone to the Pi hotspot (SSID: from config.env), then:"
echo
echo "  push-wifi 'Hotel WiFi Name' --country Germany"
echo "  push-wifi --status"
echo "  push-wifi --list-countries"
echo
echo "Or test SSH connection now (make sure phone is on Pi's hotspot first):"
echo "  ssh pi-router"
