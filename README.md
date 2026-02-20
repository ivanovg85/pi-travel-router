# Raspberry Pi Travel Router

A portable travel router using a Raspberry Pi 4 with NordVPN, controlled headlessly from an Android phone via SSH.

## Hardware Requirements

| Item | Purpose |
|------|---------|
| Raspberry Pi 4 (8 GB) | The router itself |
| MicroSD card (16 GB+) | OS storage |
| USB-C power supply | Power |
| **USB WiFi adapter (802.11ac/ax)** | WAN — connects to hotel/venue WiFi |
| Phone with Termux | SSH client for configuration |

> **Important:** A USB WiFi adapter is required. The Pi's built-in WiFi (`wlan0`) runs your personal hotspot (AP mode). The USB adapter (`wlan1`) connects to the venue's WiFi (client/STA mode). Running both roles on a single radio is unreliable.
>
> Recommended adapters: TP-Link Archer T3U, Alfa AWUS036AXML, or any adapter with Linux AP mode support.

---

## Architecture

```
[ Hotel/Venue WiFi ]
        |
   [ wlan1 - USB dongle, STA mode ]
        |
   [ Raspberry Pi 4 ]
        |  NordVPN tunnel (nordlynx)
        |  iptables NAT + forwarding
        |
   [ wlan0 - built-in, AP mode ]
        |
   [ Your devices: phone, laptop, etc. ]
        SSID: MyTravelPi (configurable)
        IP range: 192.168.10.0/24
```

All traffic from your devices is routed through NordVPN before reaching the internet.

---

## Files

```
pi-setup/
├── README.md               # This file
├── config.env              # Your personal settings — edit this first
├── setup.sh                # One-time initial setup (run once on the Pi)
└── configure-location.sh   # Run at each new location to switch networks
```

---

## Step 1: Flash the SD Card

Use **Raspberry Pi Imager** to flash **Raspberry Pi OS Lite (64-bit)** (Bookworm).

In the **OS Customisation** screen (gear icon or "Edit Settings"):

**General tab:**
- Hostname: `travelpi` (or anything you prefer)
- Username: `pi`
- Password: set a strong password (needed for initial SSH)

**Services tab:**
- Enable SSH: **Allow public-key authentication only**
- Paste your phone's SSH public key (see Step 2 below)

Write the image to the SD card and insert it into the Pi.

---

## Step 2: Generate an SSH Key on Your Phone

Install **Termux** from [F-Droid](https://f-droid.org/packages/com.termux/) (recommended over Play Store).

```bash
# In Termux on your Samsung S24 Ultra

pkg update && pkg install openssh

# Generate a key (press Enter to accept defaults, set a passphrase for security)
ssh-keygen -t ed25519 -C "S24Ultra-TravelPi"

# Display your public key — copy this entire line
cat ~/.ssh/id_ed25519.pub
```

Paste this public key into Raspberry Pi Imager's "Authorised Keys" field in Step 1.

**Create an SSH config for convenience:**

```bash
mkdir -p ~/.ssh
cat >> ~/.ssh/config << 'EOF'

Host travelpi
    HostName 192.168.10.1
    User pi
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
EOF
```

Once configured, you can connect simply with: `ssh travelpi`

---

## Step 3: Initial Pi Setup

1. Connect the USB WiFi adapter to the Pi
2. Connect the Pi to power
3. On your phone, connect to the Pi's initial network
   *(On first boot, the Pi will be accessible only via Ethernet or if you pre-configured WiFi in the Imager)*
4. Copy the setup files to the Pi:

   ```bash
   # From Termux — replace 192.168.1.X with the Pi's IP on your local network
   scp -i ~/.ssh/id_ed25519 config.env setup.sh configure-location.sh pi@192.168.1.X:~/
   ```

5. SSH into the Pi and run the setup:

   ```bash
   ssh pi@192.168.1.X

   # On the Pi:
   nano ~/config.env      # Edit your settings (SSID, password, etc.)
   chmod +x setup.sh configure-location.sh
   sudo ./setup.sh
   ```

6. The script will prompt you to authenticate with NordVPN. Have your **NordVPN access token** ready:
   - Log into [my.nordaccount.com](https://my.nordaccount.com)
   - Go to **Services → NordVPN → Set up NordVPN manually → Generate token**

7. After setup completes, the Pi will reboot and broadcast your personal hotspot.

---

## Step 4: At Each New Location

1. Connect your phone to the Pi's hotspot (SSID: `MyTravelPi` by default)
2. SSH into the Pi:

   ```bash
   ssh travelpi
   # Or: ssh pi@192.168.10.1
   ```

3. Run the location configuration script:

   ```bash
   # Provide the venue's WiFi credentials
   sudo ./configure-location.sh "Hotel WiFi Name" "hotel_password"

   # Optionally change the VPN country
   sudo ./configure-location.sh "Hotel WiFi Name" "hotel_password" --country Germany
   ```

4. Wait ~30 seconds, then your devices connected to `MyTravelPi` will have VPN-protected internet.

---

## Connecting Other Devices

Connect any device (laptop, tablet, etc.) to your personal hotspot:
- **SSID**: `MyTravelPi` (or whatever you set in `config.env`)
- **Password**: as set in `config.env`
- **Gateway / Pi's IP**: `192.168.10.1`

All traffic is automatically routed through NordVPN.

---

## Troubleshooting

**Can't SSH into the Pi:**
- Ensure you're connected to `MyTravelPi` hotspot, not the hotel WiFi
- Try `ssh pi@192.168.10.1` explicitly
- Check if the Pi's LED is steady (booted) vs flashing (still booting)

**No internet on connected devices:**
- Run `sudo ./configure-location.sh` again
- Check NordVPN status: `nordvpn status`
- Check hotel WiFi connection: `nmcli dev status`

**VPN disconnected (kill switch active):**
- All internet is blocked until VPN reconnects (by design)
- Reconnect: `sudo nordvpn connect`
- Or re-run `configure-location.sh`

**Check current status:**
```bash
ssh travelpi
nordvpn status                 # VPN connection status
nmcli dev status               # Network interfaces
ip route                       # Routing table
```
