# Network Deployment — BearClaw on Raspberry Pi and Local Networks

This document covers deploying BearClaw on a Raspberry Pi or any remote host, with Telegram, Discord, and optional gateway webhook channels.

---

## 1. Overview

| Mode | Inbound port needed? | Use case |
|------|----------------------|----------|
| **Telegram polling** | No | BearClaw polls Telegram API (outbound only) |
| **Discord Gateway** | No | BearClaw connects to Discord Gateway WebSocket (outbound only) |
| **Gateway webhook** | Yes | External services need to POST to your gateway |

**Key:** Telegram and Discord use outbound connections — BearClaw makes requests to their APIs. No port forwarding or public IP is required for these channels.

---

## 2. BearClaw on Raspberry Pi

### 2.1 Prerequisites

- Raspberry Pi (3/4/5) running Raspberry Pi OS or any Linux distro
- Zig 0.14 installed on the Pi, or a cross-compiled binary from your host
- Optional: USB peripherals (Arduino, Nucleo) for hardware tool integration

### 2.2 Build and Install

**Option A — Build directly on the Pi:**

```bash
# Install Zig 0.14 on the Pi
wget https://ziglang.org/download/0.14.0/zig-linux-aarch64-0.14.0.tar.xz
tar xf zig-linux-aarch64-0.14.0.tar.xz
export PATH="$PWD/zig-linux-aarch64-0.14.0:$PATH"

# Clone and build
git clone <your-repo> bareclaw
cd bareclaw
zig build -Doptimize=ReleaseSafe
```

**Option B — Cross-compile from macOS/Linux host:**

```bash
# Target ARM64 Linux (Raspberry Pi 3/4/5)
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe

# Copy binary to Pi
scp zig-out/bin/bareclaw pi@raspberrypi.local:~/bin/
```

### 2.3 Config

Run first-time setup on the Pi:

```bash
bareclaw onboard
```

Or edit `~/.bareclaw/config.toml` directly:

```toml
default_provider   = "anthropic"
default_model      = "claude-opus-4-5"
fallback_providers = "echo"

discord_token  = "Bot.your-token-here"
telegram_token = "1234567890:your-telegram-token"
```

Set your API key via environment:

```bash
export BARECLAW_API_KEY="sk-ant-..."
```

For a permanent setup, add it to `~/.bashrc` or `~/.zshrc`.

### 2.4 Run Telegram Channel (No Port Forwarding Needed)

```bash
bareclaw channel telegram
```

BearClaw polls `https://api.telegram.org` outbound. No firewall changes or public IP required. Works behind NAT on a home network.

### 2.5 Run Discord Channel (No Port Forwarding Needed)

```bash
bareclaw channel discord
```

BearClaw opens a TLS WebSocket to `gateway.discord.gg:443` outbound. Same story — no inbound ports required.

### 2.6 Run Daemon (Gateway + Cron)

```bash
bareclaw daemon
```

Starts the HTTP gateway on `127.0.0.1:8080` and runs any enabled cron tasks. The gateway is localhost-only by default.

---

## 3. Exposing the Gateway

### 3.1 Local Network Only (LAN Access)

If you want other devices on your LAN to reach the gateway (e.g. for pairing or custom webhooks), bind to `0.0.0.0`:

> **Note:** This is not yet a config option in BearClaw — the gateway currently always binds to `127.0.0.1`. LAN binding and `allow_public_bind` config support is on the roadmap.

As a workaround, use a tunnel (see below) or a reverse proxy like nginx listening on `0.0.0.0:8080` forwarding to `127.0.0.1:8080`.

### 3.2 Public URL (Webhooks)

If you need a public HTTPS URL (for custom webhook integrations, third-party services, etc.), use a tunnel:

**Tailscale Funnel** (easiest, no account needed for basic use):
```bash
tailscale funnel 8080
# Your gateway is now reachable at https://your-hostname.ts.net
```

**ngrok:**
```bash
ngrok http 8080
# Copy the HTTPS URL for your webhook configuration
```

**Cloudflare Tunnel:**
Configure your tunnel to forward to `http://localhost:8080` and point your DNS to the tunnel's public hostname.

---

## 4. Running as a Background Service

### macOS (launchd)

Create `~/Library/LaunchAgents/com.bareclaw.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.bareclaw.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/bareclaw</string>
    <string>channel</string>
    <string>telegram</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BARECLAW_API_KEY</key>
    <string>sk-ant-...</string>
    <key>TELEGRAM_BOT_TOKEN</key>
    <string>1234:your-token</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/bareclaw.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/bareclaw.err</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.bareclaw.daemon.plist
launchctl start com.bareclaw.daemon
```

### Linux (systemd)

Create `/etc/systemd/user/bareclaw.service`:

```ini
[Unit]
Description=BearClaw AI Agent
After=network.target

[Service]
ExecStart=/usr/local/bin/bareclaw channel telegram
Environment=BARECLAW_API_KEY=sk-ant-...
Environment=TELEGRAM_BOT_TOKEN=1234:your-token
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable bareclaw
systemctl --user start bareclaw
systemctl --user status bareclaw
```

### Raspberry Pi Simple Autostart

For a simple setup without systemd user services:

```bash
# Add to /etc/rc.local before exit 0
/home/pi/bin/bareclaw channel telegram >> /home/pi/bareclaw.log 2>&1 &
```

---

## 5. Deployment Checklist

- [ ] Zig 0.14 installed or cross-compiled binary copied to device
- [ ] `bareclaw onboard` run to create config
- [ ] `BARECLAW_API_KEY` set in environment (or exported in shell profile)
- [ ] Channel tokens set (`TELEGRAM_BOT_TOKEN` and/or `DISCORD_BOT_TOKEN`)
- [ ] `bareclaw status` shows expected provider, model, and memory count
- [ ] `bareclaw doctor` passes all checks
- [ ] For Telegram: `bareclaw channel telegram` receives test message
- [ ] For Discord: `bareclaw channel discord` shows "WebSocket connected"
- [ ] For gateway: `curl http://127.0.0.1:8080/health` returns `{"status":"ok","service":"bareclaw"}`
- [ ] Background service installed and set to restart on failure

---

## 6. References

- [docs/hardware-peripherals-design.md](./hardware-peripherals-design.md) — Peripherals design and hardware integration
- [SECURITY.md](../SECURITY.md) — Security policy and sandboxing
- [README.md](../README.md) — Full feature reference
