# Travel Router Usage Guide

This guide covers daily operation, configuration, and troubleshooting for your Raspberry Pi travel router.

## Quick Reference

| Task | Command |
|------|---------|
| Check router status | `router-status` |
| Connect to venue WiFi | `sudo ./configure-location.sh "SSID" "password"` |
| Connect with VPN country | `sudo ./configure-location.sh "SSID" "password" --country Germany` |
| Revert to phone hotspot | `sudo nmcli con delete venue-wifi` |
| Check VPN status | `nordvpn status` |
| List VPN countries | `sudo ./configure-location.sh --list-countries` |

## Daily Workflow

### At a New Venue (Hotel, Cafe, etc.)

1. Turn on your phone's hotspot (SSID must match `PHONE_HOTSPOT_SSID` in config.env)
2. Power on the Pi — it auto-connects to your phone hotspot via `wlan1`
3. Connect your laptop/phone to the `travel-pi` WiFi network
4. SSH into the Pi:
   ```bash
   ssh georgi@192.168.10.1
   ```
5. Configure the venue WiFi:
   ```bash
   cd ~/pi-travel-router
   sudo ./configure-location.sh "Hotel WiFi Name" "password"
   ```
6. Once connected, you can turn off your phone hotspot — the Pi now uses venue WiFi

### Switching Venues

Just run `configure-location.sh` again with the new credentials. It automatically replaces the old venue WiFi profile.

### Reverting to Phone Hotspot

If you need to switch back to phone hotspot (e.g., leaving the venue):

```bash
sudo nmcli con delete venue-wifi
```

The Pi will automatically reconnect to your phone hotspot (if it's on).

## NordVPN Kill Switch

The kill switch blocks all internet traffic if VPN disconnects, preventing IP leaks. However, it can also block DHCP on the AP, making SSH access impossible when VPN is down.

### Check Current Status

```bash
nordvpn settings
```

Look for `Kill Switch: enabled` or `Kill Switch: disabled`.

### Enable Kill Switch

```bash
sudo nordvpn set killswitch on
```

Use this when you want maximum privacy and the VPN is already connected.

### Disable Kill Switch

```bash
sudo nordvpn set killswitch off
```

Use this if you need to SSH into the Pi but VPN isn't connected (e.g., initial setup at a new location).

### Recommended Approach

- Keep kill switch **off** by default (this is the current setup)
- This ensures you can always SSH into the Pi to configure WAN
- Trade-off: brief IP exposure if VPN drops (it reconnects automatically)

## Checking Status

### Full Router Status

```bash
router-status
```

This shows VPN status, network interfaces, IP addresses, routing, and connected clients.

### VPN Status Only

```bash
nordvpn status
```

### Network Interfaces

```bash
nmcli dev status
```

Expected output:
```
DEVICE    TYPE      STATE         CONNECTION
wlan0     wifi      connected     travel-router-ap
wlan1     wifi      connected     venue-wifi (or phone-hotspot)
nordlynx  wireguard connected     nordlynx
```

### Active Connections

```bash
nmcli con show --active
```

### Check Your Public IP

```bash
curl ifconfig.me
```

This should show the VPN server's IP, not your real IP.

## Troubleshooting

### "Network is unreachable" when trying to SSH

**Cause:** Your device isn't getting an IP address from the Pi's DHCP server.

**Fix:**
1. Connect a monitor/keyboard to the Pi
2. Disable the kill switch:
   ```bash
   sudo nordvpn set killswitch off
   ```
3. Restart the AP:
   ```bash
   sudo nmcli con down travel-router-ap
   sudo nmcli con up travel-router-ap
   ```
4. Reconnect to `travel-pi` and try SSH again

### wlan1 Not Found

**Cause:** USB WiFi adapter isn't recognized.

**Checks:**
```bash
# See if the system detects the USB device
lsusb

# List all network interfaces
ip link show

# Check for wlan1 specifically
ip link show wlan1
```

**Fixes:**
- Ensure the USB adapter is firmly plugged in
- Try a different USB port (prefer USB 3.0 ports)
- Reboot the Pi with the adapter plugged in:
  ```bash
  sudo reboot
  ```

### wlan1 Exists but is DOWN

```bash
# Bring the interface up
sudo ip link set wlan1 up

# Check status again
ip link show wlan1
```

### Can't Connect to Venue WiFi

**Check what networks are visible:**
```bash
sudo nmcli dev wifi list ifname wlan1
```

**Common issues:**
- Wrong SSID (check for typos, spaces, capitalization)
- Wrong password
- Network requires captive portal (web login) — not supported
- Network uses enterprise authentication (WPA2-Enterprise) — not supported
- 5GHz network and adapter only supports 2.4GHz

**Try connecting manually:**
```bash
sudo nmcli dev wifi connect "SSID" password "password" ifname wlan1
```

### VPN Won't Connect

**Check VPN status:**
```bash
nordvpn status
```

**Check if logged in:**
```bash
nordvpn account
```

**If not logged in:**
```bash
sudo nordvpn login --token YOUR_TOKEN
```

**Try reconnecting:**
```bash
sudo nordvpn disconnect
sudo nordvpn connect
```

**Try a different country:**
```bash
sudo nordvpn connect Germany
```

### AP Clients Have No Internet

**Verify the traffic path:**
```bash
# Check VPN is connected
nordvpn status

# Check routing
ip route show default

# Check IP forwarding is enabled
cat /proc/sys/net/ipv4/ip_forward
# Should output: 1

# Check iptables rules
sudo iptables -L FORWARD -n -v
sudo iptables -t nat -L POSTROUTING -n -v
```

**Restart the VPN:**
```bash
sudo nordvpn disconnect
sudo nordvpn connect
```

### SSH Connection Refused

**Check SSH is running:**
```bash
sudo systemctl status ssh
```

**Check the SSH port** (default is 22, but may be changed in config.env):
```bash
grep Port /etc/ssh/sshd_config.d/99-travelrouter.conf
```

**Connect with the correct port:**
```bash
ssh -p PORT georgi@192.168.10.1
```

### Lost SSH Access Completely

If you can't SSH in and don't have a monitor:

1. Power off the Pi
2. Remove the SD card and mount it on another computer
3. Edit files directly on the SD card if needed
4. Or re-flash and start fresh with Raspberry Pi Imager

## Network Profiles

The Pi uses NetworkManager with these connection profiles on `wlan1`:

| Profile | Priority | Purpose |
|---------|----------|---------|
| `venue-wifi` | 50 | Current hotel/venue WiFi |
| `phone-hotspot` | 10 | Fallback to your phone |

Higher priority connects first. When you delete `venue-wifi`, it falls back to `phone-hotspot`.

**List all profiles:**
```bash
nmcli con show
```

**Delete a profile:**
```bash
sudo nmcli con delete "profile-name"
```

## Useful Commands

```bash
# See connected AP clients
arp -n

# Watch network traffic
sudo tcpdump -i wlan0

# Check WiFi signal strength
iwconfig wlan1

# Scan for available networks
sudo nmcli dev wifi list ifname wlan1

# Check regulatory domain
iw reg get

# View system logs
journalctl -u NetworkManager -f
journalctl -u nordvpnd -f
```

## File Locations

| File | Purpose |
|------|---------|
| `~/pi-travel-router/config.env` | Configuration variables |
| `~/pi-travel-router/configure-location.sh` | Venue WiFi setup script |
| `/etc/sysctl.d/99-travelrouter.conf` | IP forwarding settings |
| `/etc/ssh/sshd_config.d/99-travelrouter.conf` | SSH hardening |
| `/usr/local/bin/router-status` | Status check script |
