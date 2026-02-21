# Raspberry Pi Imager Settings

Use these settings when flashing a fresh SD card with Raspberry Pi Imager for disaster recovery.

## OS Selection

- **Operating System:** Raspberry Pi OS Lite (64-bit)
  - Navigate to: Raspberry Pi OS (other) → Raspberry Pi OS Lite (64-bit)
  - Do NOT use the Desktop version — Lite is sufficient and lighter

## OS Customisation Settings

Click the gear icon (⚙️) or "Edit Settings" after selecting the OS.

### General

| Setting | Value |
|---------|-------|
| Set hostname | `travel-pi` |
| Set username and password | ✅ Enabled |
| Username | `georgi` |
| Password | *(your password — keep it secure)* |
| Configure wireless LAN | ✅ Enabled (for initial setup only) |
| Wireless LAN country | `BG` |
| Set locale settings | ✅ Enabled |
| Time zone | `Europe/Sofia` |
| Keyboard layout | `us` |

### Wireless LAN (for initial setup)

Configure your **home WiFi** here so the Pi can connect during initial setup:

| Setting | Value |
|---------|-------|
| SSID | *(your home WiFi name)* |
| Password | *(your home WiFi password)* |

> **Note:** This is only used for initial setup. After running `setup.sh`, the Pi creates its own hotspot and no longer needs your home WiFi.

### Services

| Setting | Value |
|---------|-------|
| Enable SSH | ✅ Enabled |
| Use password authentication | ❌ Disabled |
| Allow public-key authentication only | ✅ Enabled |
| Set authorized_keys for 'georgi' | *(paste your SSH public key)* |

### SSH Public Key

Paste your public key in the "Set authorized_keys" field. It looks like:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... your-email@example.com
```

or

```
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... your-email@example.com
```

> **Important:** This must match the private key on your laptop/phone. If you lose this key pair, you'll need to generate a new one and update both the Pi and your devices.

## After Flashing

1. Insert the SD card into the Pi and boot
2. Wait 1-2 minutes for first boot to complete
3. Find the Pi on your network:
   ```bash
   ping travel-pi.local
   # or check your router's DHCP leases
   ```
4. SSH in:
   ```bash
   ssh georgi@travel-pi.local
   ```
5. Clone the repo and run setup:
   ```bash
   git clone https://github.com/ivanovg85/pi-travel-router.git
   cd pi-travel-router
   cp config.env.example config.env
   nano config.env  # fill in passwords and token
   chmod +x setup.sh configure-location.sh
   sudo ./setup.sh
   ```

## Backup Your SSH Key

Store your SSH private key securely. Common locations:

| OS | Default location |
|----|------------------|
| macOS/Linux | `~/.ssh/id_ed25519` or `~/.ssh/id_rsa` |
| Windows | `C:\Users\<username>\.ssh\id_ed25519` |

To view your public key (for pasting into Imager):
```bash
cat ~/.ssh/id_ed25519.pub
# or
cat ~/.ssh/id_rsa.pub
```

## Summary Checklist

Before flashing, ensure you have:

- [ ] Raspberry Pi Imager installed
- [ ] MicroSD card (16GB+ recommended)
- [ ] Your SSH public key ready to paste
- [ ] Your home WiFi credentials (for initial setup)
- [ ] Your `config.env` backup (or values to fill in the template)
- [ ] Your NordVPN token
