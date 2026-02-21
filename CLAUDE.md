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
| `termux-setup.sh` | One-time setup for Termux on Android phone (run once on the phone) |
| `push-wifi.sh` | Push venue WiFi credentials from phone to Pi (daily use from Termux) |

### `setup.sh` execution order

`main()` calls these functions in sequence:
`validate_config` → `update_system` → `install_packages` → `install_wan_driver` → `configure_ap` → `configure_phone_hotspot` → `configure_ip_forwarding` → `configure_iptables` → `install_nordvpn` → `configure_nordvpn` → `harden_ssh` → `configure_services` → `create_status_script` → reboot

`configure_nordvpn()` uses `NORDVPN_TOKEN` from `config.env` if set, otherwise prompts interactively. The script reboots automatically at the end.

`create_status_script()` installs `/usr/local/bin/router-status` (the `router-status` command available after setup).

### `configure-location.sh` execution order

`main()` calls: `connect_wan` → `wait_for_internet` → `connect_vpn` → `verify_ap` → `verify_forwarding`

`connect_wan()` deletes any existing `venue-wifi` NM profile before creating a fresh one — this prevents stale credential issues.

## Common Commands (run on the Pi as root)

```bash
# Deploy files from your phone/computer to the Pi
scp config.env setup.sh configure-location.sh pi@<PI_IP>:~/

# One-time initial setup (prompts for NordVPN token, then reboots)
sudo ./setup.sh

# At each new location (phone hotspot must be on so Pi has internet first)
sudo ./configure-location.sh "Hotel WiFi Name" "password"
sudo ./configure-location.sh "Hotel WiFi Name" "password" --country Germany
sudo ./configure-location.sh --status
sudo ./configure-location.sh --list-countries

# Revert to phone hotspot (between venues)
sudo nmcli con delete venue-wifi

# Check overall router status (installed by setup.sh)
router-status

# Direct VPN/network inspection
nordvpn status
nmcli dev status
ip route show default
```

## Architecture Details

### Networking stack

- **NetworkManager** manages both interfaces. Named connection profiles on `wlan1` and their autoconnect priorities:
  - `venue-wifi` (priority 50) — hotel/venue WiFi, created by `configure-location.sh`
  - `phone-hotspot` (priority 10) — phone's hotspot, fallback when no venue WiFi is configured
  - `travel-router-ap` (priority 100) — the AP on `wlan0`, always active
- **IP forwarding** (`net.ipv4.ip_forward=1`) is persisted in `/etc/sysctl.d/99-travelrouter.conf`.
- **iptables** rules in the FORWARD chain allow AP subnet traffic through while dropping everything else. NAT MASQUERADE is set on `WAN_INTERFACE` as a fallback; NordVPN adds its own MASQUERADE on `nordlynx` when connected.
- **NordVPN kill switch** blocks all internet if VPN drops. The AP subnet (`192.168.10.0/24`) is whitelisted so SSH to the Pi remains accessible even when VPN is down. The kill switch also means `wait_for_internet` in `configure-location.sh` skips its curl check when kill switch is active (it would always time out otherwise).

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
- `NORDVPN_TOKEN` — NordVPN access token for non-interactive setup. If set, `configure_nordvpn()` uses it silently; if absent, it prompts interactively. Get one at `my.nordaccount.com → Services → NordVPN → Set up NordVPN manually`.
- `PHONE_HOTSPOT_SSID` / `PHONE_HOTSPOT_PASSWORD` — your phone's hotspot credentials; set a fixed SSID in your phone's hotspot settings so it's always predictable. Leave password empty for open networks.

## Known Issues and Gotchas

### USB WiFi adapter must be plugged in before running `setup.sh`

`validate_config()` checks that `WAN_INTERFACE` (`wlan1`) exists via `ip link show` and aborts if it doesn't. Plug in the USB adapter and reboot before running `setup.sh`, then verify:

```bash
ip link show wlan1
```

The current adapter is a **BrosTrend WiFi 6E AXE3000**, which uses an in-kernel driver and requires no additional setup.

### Kernel headers on kernel 6.12

On Raspberry Pi OS Bookworm with kernel 6.12, headers are pre-installed. The old `raspberrypi-kernel-headers` package does not exist. Verify headers are present with:

```bash
ls /lib/modules/$(uname -r)/build/Makefile
```

`setup.sh` does not install `raspberrypi-kernel-headers` — this was a known bug that has been fixed.

## Termux Phone Workflow

`termux-setup.sh` and `push-wifi.sh` let you manage the router from an Android phone running [Termux](https://f-droid.org/en/packages/com.termux/).

### One-time phone setup

1. Install Termux and Termux:API from F-Droid (not Google Play)
2. Transfer `termux-setup.sh` to the phone (e.g. via `adb push` or a shared folder)
3. Run it in Termux:

```bash
bash termux-setup.sh
```

The script: installs `openssh` + `termux-api`, sets up your SSH key (paste / use existing / generate), writes `~/.ssh/config` with a `pi-router` host alias, and installs `push-wifi` to `~/.local/bin`.

**SSH key**: The key used must match the public key loaded onto the Pi via Raspberry Pi Imager. The Pi's AP IP is `192.168.10.1`, port 22.

### Daily use

**Recommended workflow at each new venue:**

1. Turn on your phone's hotspot (SSID must match `PHONE_HOTSPOT_SSID` in `config.env`)
2. Pi boots and `wlan1` auto-connects to your phone hotspot → NordVPN connects
3. Connect your phone to the Pi's AP (`na-ji4ka`)
4. Run `push-wifi` to switch the Pi to hotel WiFi:

```bash
# Push venue WiFi credentials (prompts for SSID and password)
push-wifi

# Specify SSID on the command line
push-wifi "Hotel WiFi"

# Specify SSID and VPN country
push-wifi "Hotel WiFi" --country Germany

# Show current router status
push-wifi --status

# List available VPN countries
push-wifi --list-countries
```

`push-wifi` auto-detects the SSID of your current WiFi connection via `termux-wifi-connectioninfo` (requires the Termux:API app). It SSHes to `192.168.10.1` and runs `sudo /home/pi/configure-location.sh` with the provided credentials.

**To revert to phone hotspot** (e.g. between venues): delete the venue WiFi profile on the Pi and NetworkManager falls back automatically:

```bash
ssh pi-router "sudo nmcli con delete venue-wifi"
```

### Notes

- `push-wifi` uses `printf '%q'` for safe shell-escaping of SSID and password before passing them over SSH
- `configure-location.sh` must exist at `/home/pi/configure-location.sh` on the Pi (deployed via `scp`)
- You can also SSH directly: `ssh pi-router`

## Prerequisites

- Raspberry Pi OS Lite 64-bit (Bookworm)
- USB WiFi adapter plugged in (appears as `wlan1`) — required for dual-radio operation
- NordVPN access token from `my.nordaccount.com → Services → NordVPN → Set up NordVPN manually`
- SSH public key pre-loaded via Raspberry Pi Imager before first boot
