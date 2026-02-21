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

`configure_nordvpn()` is interactive — it reads a NordVPN access token from stdin. The script reboots automatically at the end.

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
- `PHONE_HOTSPOT_SSID` / `PHONE_HOTSPOT_PASSWORD` — your phone's hotspot credentials; set a fixed SSID in your phone's hotspot settings so it's always predictable. Leave password empty for open networks.

## Known Issues and Gotchas

### `setup.sh` validates interfaces before installing the driver

`validate_config()` (called first in `main()`) checks that both `AP_INTERFACE` and `WAN_INTERFACE` exist via `ip link show`. However, `install_wan_driver()` (which installs the RTL8852AU DKMS driver) runs later. If the USB WiFi adapter has no driver yet, `wlan1` won't exist and `setup.sh` will abort before installing the driver.

**Fix:** Install the DKMS driver manually before running `setup.sh`, then reboot:

```bash
sudo apt-get install -y dkms build-essential git bc   # bc is also required but often missing
sudo git clone --depth=1 https://github.com/lwfinger/rtl8852au.git /usr/src/rtl8852au-1.15.0.1
sudo dkms add rtl8852au/1.15.0.1
sudo dkms build rtl8852au/1.15.0.1   # takes a few minutes
sudo dkms install rtl8852au/1.15.0.1 --force
sudo reboot   # IMPORTANT: reboot so the driver loads before the device enumerates
```

After reboot, verify `wlan1` appears with `ip link show` before running `setup.sh`. The `setup.sh` `install_wan_driver()` function will skip reinstallation if DKMS already shows the module as installed.

### RTL8852AU USB adapter (TP-Link TX20U) — INCOMPATIBLE with kernel 6.12

**Final status: Abandoned.** The TP-Link TX20U (USB ID `35bc:0100`) does not work on Raspberry Pi OS Bookworm with kernel 6.12. Replace it with a known Linux-compatible adapter.

**Root cause (fully traced):** The driver loads and `rtw_dev_probe` is called, but `rtw_phl_init` fails with `RTW_PHL_STATUS_HAL_INIT_FAILURE (status=3)`. Inside: `rtw_hal_mac_init` → `mac_ax_ops_init` → `get_mac_8852a_adapter` returns NULL → error `MACADAPTER=7`. Firmware init (`phl_fw_init`) succeeds — the failure is in the MAC hardware abstraction layer. This is a kernel 6.12 incompatibility in the `lwfinger/rtl8852au` driver.

**Observable symptoms (with debug logging enabled):**
```
PHL: [MAC] [ERR]Get MAC adapter
PHL: ERROR rtw_hal_mac_init: halmac_init_adapter fail!(status=7-Can not get MAC adapter)
RTW: ERROR rtw_hw_init - rtw_phl_init failed status(3)
```
Without debug logging, the driver fails silently: `lsusb` shows the device, `lsmod` shows the module, but no `wlan1` appears.

**History of approaches tried (for reference):**
- Preloading via `/etc/modules-load.d/rtl8852au.conf` — solved the race condition but not the deeper HAL failure
- Manual bind, `new_id`, `authorized` sysfs power-cycle — all failed (ENODEV or probe error)
- Enabling `CONFIG_RTW_DEBUG=y` in the DKMS Makefile to surface the actual error message

### Debugging the RTL8852AU driver

**ftrace — verify whether probe is being called:**
```bash
echo function > /sys/kernel/debug/tracing/current_tracer
echo "usb_probe_interface usb_match_one_id_intf rtw_dev_probe" > /sys/kernel/debug/tracing/set_ftrace_filter
echo > /sys/kernel/debug/tracing/trace
echo 1 > /sys/kernel/debug/tracing/tracing_on
# ... trigger the event (e.g., replug or reboot) ...
cat /sys/kernel/debug/tracing/trace
echo 0 > /sys/kernel/debug/tracing/tracing_on
echo nop > /sys/kernel/debug/tracing/current_tracer
```

**Enabling driver debug output** — all `RTW_INFO`/`RTW_ERR`/`RTW_PRINT` are no-ops by default. To enable:
```bash
sudo sed -i 's/^CONFIG_RTW_DEBUG = 0/CONFIG_RTW_DEBUG = y/' /usr/src/rtl8852au-1.15.0.1/Makefile
# Also raise log level to 4 to see RTW_INFO (default 3 only shows RTW_ERR and above):
sudo sed -i 's/^CONFIG_RTW_LOG_LEVEL = 3/CONFIG_RTW_LOG_LEVEL = 4/' /usr/src/rtl8852au-1.15.0.1/Makefile
sudo modprobe -r 8852au
sudo dkms build rtl8852au/1.15.0.1 --force
sudo dkms install rtl8852au/1.15.0.1 --force
sudo modprobe 8852au
# Now trigger probe and check dmesg for "RTW: ..." lines
```

Log level mapping (defined in `include/rtw_debug.h`): `_DRV_ALWAYS_=1`, `_DRV_ERR_=2`, `_DRV_WARNING_=3`, `_DRV_INFO_=4`, `_DRV_DEBUG_=5`.

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
