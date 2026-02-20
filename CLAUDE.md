# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash scripts to configure a Raspberry Pi 4 as a portable travel router. The Pi runs a personal WiFi hotspot (AP mode on built-in `wlan0`) while connecting to venue WiFi via a USB adapter (`wlan1`), routing all traffic through NordVPN.

**Traffic flow:** Client devices → `wlan0` (AP) → `nordlynx` VPN tunnel → `wlan1` (hotel WiFi) → Internet

## Files

| File | Purpose |
|------|---------|
| `config.env` | All user-configurable settings — edit this first |
| `setup.sh` | One-time setup, run once on the Pi after first boot |
| `configure-location.sh` | Run at each new location to switch venue WiFi and reconnect VPN |

## Common Commands (run on the Pi as root)

```bash
# Deploy files from your phone/computer to the Pi
scp config.env setup.sh configure-location.sh pi@<PI_IP>:~/

# Edit settings before setup
nano ~/config.env

# One-time initial setup (prompts for NordVPN token, then reboots)
sudo ./setup.sh

# At each new location
sudo ./configure-location.sh "Hotel WiFi Name" "password"
sudo ./configure-location.sh "Hotel WiFi Name" "password" --country Germany
sudo ./configure-location.sh --status
sudo ./configure-location.sh --list-countries

# Check overall router status (installed by setup.sh)
router-status

# Direct VPN/network inspection
nordvpn status
nmcli dev status
ip route show default
```

## Architecture Details

### Networking stack

- **NetworkManager** manages both interfaces. The AP connection profile is named `travel-router-ap`; the venue WiFi profile is `venue-wifi`.
- **IP forwarding** (`net.ipv4.ip_forward=1`) is persisted in `/etc/sysctl.d/99-travelrouter.conf`.
- **iptables** rules in the FORWARD chain allow AP subnet traffic through while dropping everything else. NAT MASQUERADE is set on `WAN_INTERFACE` as a fallback; NordVPN adds its own MASQUERADE on `nordlynx` when connected.
- **NordVPN kill switch** blocks all internet if VPN drops. The AP subnet (`192.168.10.0/24`) is whitelisted so SSH to the Pi remains accessible even when VPN is down.

### Key NordVPN settings applied in `setup.sh`

```
technology nordlynx        # WireGuard-based, faster than OpenVPN
killswitch on
routing on                 # Routes AP client traffic through VPN, not just Pi's own traffic
lan-discovery on
whitelist subnet 192.168.10.0/24   # Keep SSH accessible when VPN is down
```

### SSH hardening

`setup.sh` writes `/etc/ssh/sshd_config.d/99-travelrouter.conf`. Password auth is disabled only if `/home/pi/.ssh/authorized_keys` already exists (safety check). SSH port is configurable via `SSH_PORT` in `config.env`.

### `config.env` variables to know

- `AP_INTERFACE` / `WAN_INTERFACE` — verify with `ip link show` on the Pi before first run
- `AP_BAND` — `"bg"` (2.4 GHz) or `"a"` (5 GHz)
- `NORDVPN_TECHNOLOGY` — `nordlynx` (default/recommended) or `openvpn_udp`/`openvpn_tcp` for restrictive networks

## Prerequisites

- Raspberry Pi OS Lite 64-bit (Bookworm)
- USB WiFi adapter plugged in (appears as `wlan1`) — required for dual-radio operation
- NordVPN access token from `my.nordaccount.com → Services → NordVPN → Set up NordVPN manually`
- SSH public key pre-loaded via Raspberry Pi Imager before first boot
