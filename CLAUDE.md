# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash scripts to configure a Raspberry Pi 4 as a portable travel router. The Pi runs a personal WiFi hotspot (AP mode on built-in `wlan0`) while connecting to venue WiFi via a USB adapter (`wlan1`), routing all traffic through NordVPN.

**Traffic flow:** Client devices → `wlan0` (AP) → `nordlynx` VPN tunnel → `wlan1` (hotel WiFi) → Internet

## Files

| File | Purpose |
|------|---------|
| `config.env` | All user-configurable settings — edit this first (gitignored) |
| `config.env.example` | Template for `config.env` — copy and fill in secrets |
| `setup.sh` | One-time setup, run once on the Pi after first boot |
| `configure-location.sh` | Run at each new location to switch venue WiFi and reconnect VPN |
| `termux-setup.sh` | One-time setup for Termux on Android phone (run once on the phone) |
| `push-wifi.sh` | Push venue WiFi credentials from phone to Pi (daily use from Termux) |
| `USAGE.md` | User guide: daily workflow, troubleshooting, disaster recovery |
| `PI_IMAGER_SETTINGS.md` | Raspberry Pi Imager settings for flashing a fresh SD card |

### `setup.sh` execution order

`main()` calls these functions in sequence:
`validate_config` → `update_system` → `install_packages` → `install_wan_driver` → `install_nordvpn` → `configure_nordvpn` → `configure_ap` → `configure_phone_hotspot` → `configure_ip_forwarding` → `configure_iptables` → `harden_ssh` → `configure_services` → `create_status_script` → reboot

NordVPN is installed and configured **before** `configure_ap` so that internet access (via home WiFi or Ethernet) is still available when the NordVPN installer runs. This means Ethernet is not required during setup — home WiFi alone is sufficient.

`configure_nordvpn()` uses `NORDVPN_TOKEN` from `config.env` if set, otherwise prompts interactively. The script reboots automatically at the end.

`--no-wan` flag skips `install_wan_driver` and `configure_phone_hotspot`, and bypasses the `wlan1` existence check in `validate_config`. Use this to prepare the Pi before the USB adapter arrives. When the adapter arrives, just plug it in and run `configure-location.sh` as normal — no need to re-run `setup.sh`.

`create_status_script()` installs `/usr/local/bin/router-status` (the `router-status` command available after setup).

### `configure-location.sh` execution order

`main()` calls: `ensure_phone_hotspot` → `connect_wan` → `wait_for_internet` → `connect_vpn` → `verify_ap` → `verify_forwarding`

`ensure_phone_hotspot()` is a transparent one-time step: creates the `phone-hotspot` NM profile on `wlan1` if it doesn't exist yet (e.g. first run after adapter arrives following a `--no-wan` setup). Subsequent runs detect the existing profile and skip it.

`connect_wan()` deletes any existing `venue-wifi` NM profile before creating a fresh one — this prevents stale credential issues.

## Common Commands (run on the Pi as root)

```bash
# Deploy files from your phone/computer to the Pi
scp config.env setup.sh configure-location.sh georgi@<PI_IP>:~/pi-travel-router/

# One-time initial setup (prompts for NordVPN token, then reboots)
sudo ./setup.sh

# Prepare Pi before USB adapter arrives (skips WAN steps, safe to re-run)
sudo ./setup.sh --no-wan

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
- **NordVPN kill switch** is disabled by default so DHCP works on the AP even when VPN is disconnected (allows SSH access to configure WAN without a monitor). If enabled, it blocks all internet if VPN drops — the AP subnet (`192.168.10.0/24`) is whitelisted so SSH remains accessible, but DHCP can still be affected.

### Key NordVPN settings applied in `setup.sh`

```
technology nordlynx        # WireGuard-based, faster than OpenVPN
killswitch off             # Disabled so DHCP works on AP when VPN is disconnected
routing on                 # Routes AP client traffic through VPN, not just Pi's own traffic
lan-discovery on           # CRITICAL: without this, NordVPN's nftables drops AP client traffic
whitelist subnet 192.168.10.0/24   # Keep SSH accessible when VPN is down
```

`nordvpn set defaults` is called **first** in `configure_nordvpn()` to clear stale settings, then all desired settings are applied. Order matters — calling `set defaults` after the other settings would reset them all.

### How NordVPN's firewall actually works (nftables)

NordVPN uses **nftables** (not just iptables) for its firewall. Key tables it manages:
- `ip mangle` — PREROUTING drops traffic from `wlan0`/`eth0` that doesn't match private subnets or carry fwmark `0xe1f1`. **`lan-discovery on` is required** to add the `ip saddr 192.168.0.0/16 iifname "wlan0" accept` rules that let AP client traffic through.
- Policy routing: fwmark `0xe1f1` is used to exempt NordVPN daemon traffic from the VPN tunnel (to avoid routing loops). All other traffic (no fwmark) is sent to routing table 205 → `nordlynx` default route → through the VPN.

**NetworkManager**, not NordVPN or iptables, handles MASQUERADE for AP clients via the `nm-shared-wlan0` nftables table it creates when `ipv4.method shared` is active:
```
ip saddr 192.168.10.0/24 ip daddr != 192.168.10.0/24 masquerade
```
This rule automatically covers whatever interface AP traffic exits on (nordlynx when VPN is up, WAN interface when VPN is down). No manual iptables MASQUERADE rules for the AP subnet are needed.

### SSH hardening

`setup.sh` writes `/etc/ssh/sshd_config.d/99-travelrouter.conf`. Password auth is disabled only if `/home/georgi/.ssh/authorized_keys` already exists (safety check). SSH port is configurable via `SSH_PORT` in `config.env`.

### `config.env` variables to know

- `AP_INTERFACE` / `WAN_INTERFACE` — verify with `ip link show` on the Pi before first run
- `AP_BAND` — `"bg"` (2.4 GHz) or `"a"` (5 GHz)
- `AP_CHANNEL` — channel number; use 1/6/11 for 2.4 GHz, 36/40/44/48/149/153/157/161 for 5 GHz
- `AP_COUNTRY_CODE` — ISO 3166-1 alpha-2 country code for regulatory WiFi compliance (e.g. `"US"`, `"BG"`)
- `NORDVPN_TECHNOLOGY` — `nordlynx` (default/recommended) or `openvpn_udp`/`openvpn_tcp` for restrictive networks
- `NORDVPN_TOKEN` — NordVPN access token for non-interactive setup. If set, `configure_nordvpn()` uses it silently; if absent, it prompts interactively. Get one at `my.nordaccount.com → Services → NordVPN → Set up NordVPN manually`.
- `PHONE_HOTSPOT_SSID` / `PHONE_HOTSPOT_PASSWORD` — your phone's hotspot credentials; set a fixed SSID in your phone's hotspot settings so it's always predictable. Leave password empty for open networks.
- `SSH_PORT` — SSH port; change from 22 to reduce scan noise, but **also update `push-wifi.sh` and `termux-setup.sh`** (see below)
- `SSH_DISABLE_PASSWORD` — `"yes"` (default) disables password login once an authorized key is detected; set to `"no"` to skip
- `DHCP_RANGE_START` / `DHCP_RANGE_END` / `DHCP_LEASE_TIME` — defined in `config.env.example` but **not used by any script**; NetworkManager's `ipv4.method shared` handles DHCP automatically

## Known Issues and Gotchas

### Username `georgi` is hardcoded

The Pi username is hardcoded as `georgi` in several places and is **not** a `config.env` variable. If the Pi username differs, update all of:
- `setup.sh`: `usermod -aG nordvpn georgi` and `harden_ssh()` → `/home/georgi/.ssh/authorized_keys`
- `push-wifi.sh`: `PI_USER="georgi"` and `REMOTE_SCRIPT="/home/georgi/pi-travel-router/configure-location.sh"`
- `termux-setup.sh`: `PI_USER="georgi"`

### `push-wifi.sh` and `termux-setup.sh` hardcode Pi connection details

`PI_HOST`, `PI_USER`, and `PI_PORT` are set at the top of both `push-wifi.sh` and `termux-setup.sh` — they are **not** read from `config.env`. If you change `SSH_PORT` in `config.env`, you must also update `PI_PORT` in these two files manually.

### Scripts use `set -euo pipefail`

All scripts exit immediately on any unhandled error (unset variable, failed command, failed pipe). When modifying scripts, every command that may legitimately fail should be guarded with `|| true` or explicit error handling.

### `configure-location.sh` does not support open venue WiFi

The script requires a non-empty password (`[[ -n "$password" ]] || die "Password cannot be empty"`). To connect to an open (passwordless) network, connect via `nmcli` directly instead.

### USB WiFi adapter must be plugged in for full setup

`validate_config()` checks that `WAN_INTERFACE` (`wlan1`) exists via `ip link show` and aborts if it doesn't. The current adapter is a **BrosTrend WiFi 6E AXE3000** — in-kernel driver, no extra setup needed.

**If the adapter isn't available yet:** run `sudo ./setup.sh --no-wan` to do everything except the WAN steps. When the adapter arrives, plug it in — no reboot needed. Connect your phone to the `travel-pi` AP and run `push-wifi` (or `configure-location.sh`) as normal. The phone hotspot fallback profile is created automatically on the first run.

**If running full setup:** plug in the adapter and verify before running:

```bash
ip link show wlan1
```

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

```bash
# Scan for available networks and pick one (recommended)
push-wifi --scan

# Specify SSID on the command line
push-wifi "Hotel WiFi"

# Specify SSID and VPN country
push-wifi "Hotel WiFi" --country Germany

# Show current router status
push-wifi --status

# List available VPN countries
push-wifi --list-countries
```

`push-wifi --scan` uses `termux-wifi-scaninfo` to list visible networks (even while connected to travel-pi), lets you pick one, then prompts for the password. It SSHes to `192.168.10.1` and runs `configure-location.sh` with the credentials.

`push-wifi` uses `printf '%q'` for safe shell-escaping of SSID and password before passing them over SSH.

**To revert to phone hotspot** (e.g. between venues):

```bash
ssh pi-router "sudo nmcli con delete venue-wifi"
```

## Disaster Recovery

If the router needs to be rebuilt from scratch:

1. Flash SD card using settings in `PI_IMAGER_SETTINGS.md`
2. Boot Pi and SSH in via home WiFi
3. Clone repo: `git clone https://github.com/ivanovg85/pi-travel-router.git`
4. Copy template: `cp config.env.example config.env`
5. Fill in secrets: `AP_PASSWORD`, `NORDVPN_TOKEN`, `PHONE_HOTSPOT_SSID`/`PASSWORD`
6. Run: `sudo ./setup.sh`

**What to back up:** `config.env`, SSH private key, NordVPN token

See `USAGE.md` for detailed recovery steps and troubleshooting.

## Prerequisites

- Raspberry Pi OS Lite 64-bit (Bookworm)
- **BrosTrend WiFi 6E AXE3000** USB adapter plugged in (appears as `wlan1`) — required for full setup; use `--no-wan` to prepare the Pi before it arrives
- NordVPN access token — set `NORDVPN_TOKEN` in `config.env` (get one at `my.nordaccount.com → Services → NordVPN → Set up NordVPN manually`)
- SSH public key pre-loaded via Raspberry Pi Imager before first boot
- Phone hotspot SSID and password set in `config.env` (`PHONE_HOTSPOT_SSID` / `PHONE_HOTSPOT_PASSWORD`)
- Home WiFi or Ethernet connection to the Pi during setup
