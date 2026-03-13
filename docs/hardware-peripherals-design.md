# Hardware Peripherals Design — BearClaw

BearClaw is built from the ground up with embedded hardware in mind. The goal: a bear-themed AI agent that understands hardware, controls peripherals via natural language, and runs on $10 boards — not just on developer laptops.

---

## 1. Vision

**Goal:** BearClaw acts as a hardware-aware AI agent that:

- Receives natural language commands via channels (Telegram, Discord, CLI)
- Maps them to hardware operations (GPIO, I2C, SPI, serial)
- Synthesizes and executes logic using an LLM
- Persists optimized routines for future reuse
- Runs directly on the edge device with no host required (for Wi-Fi-capable boards)

**Mental model:** BearClaw = brain. Peripherals = claws it controls.

---

## 2. Two Modes of Operation

### Mode 1: Edge-Native (Standalone)

**Target:** Wi-Fi-enabled boards (ESP32, Raspberry Pi).

BearClaw runs **directly on the device**. Channels receive messages from Telegram/Discord, the agent loop calls the LLM, tools execute hardware operations locally.

```
┌──────────────────────────────────────────────────────────────────┐
│  BearClaw on Raspberry Pi / ESP32 (Edge-Native)                  │
│                                                                  │
│  ┌──────────────┐    ┌───────────────┐    ┌────────────────────┐ │
│  │ Channels     │───►│  Agent Loop   │───►│ LLM Provider       │ │
│  │ Telegram     │    │ (tool-calling)│    │ (Anthropic/Ollama) │ │
│  │ Discord      │    └──────┬────────┘    └────────────────────┘ │
│  │ CLI          │           │                                    │
│  └──────────────┘           ▼                                    │
│                   ┌─────────────────────────────────────────┐    │
│                   │ Tools: shell, file I/O, memory, GPIO    │    │
│                   └─────────────────────────────────────────┘    │
│                                                                  │
│  Peripherals: GPIO, I2C, SPI, UART, sensors, actuators          │
└──────────────────────────────────────────────────────────────────┘
```

**Workflow example:**
1. User sends Telegram: *"Turn on the LED on pin 17"*
2. BearClaw fetches board-specific config (pin map, GPIO tool)
3. Agent calls `shell` tool: `raspi-gpio set 17 op dh`
4. GPIO is toggled; result returned to Telegram
5. Tool call is logged to `audit.log`

**Entirely on-device. No host required.**

### Mode 2: Host-Mediated (Development / Debugging)

**Target:** Microcontrollers connected via USB or serial to a developer machine.

BearClaw runs on the **host** and communicates with the target device over serial/USB. Useful for development, debugging, and flashing.

```
┌─────────────────────┐   USB / Serial   ┌──────────────────────┐
│  BearClaw on Mac    │ ◄──────────────► │  Arduino / Nucleo    │
│                     │                  │  (or other MCU)      │
│  - Channels         │   JSON-over-     │  - GPIO pins         │
│  - LLM calls        │   serial         │  - Sensors           │
│  - shell tool       │   protocol       │  - Actuators         │
└─────────────────────┘                  └──────────────────────┘
```

**Workflow example:**
1. User (via CLI): *"Blink the LED on pin 13 three times"*
2. Agent calls `shell`: `echo '{"op":"blink","pin":13,"times":3}' > /dev/ttyACM0`
3. Firmware on the Arduino receives the JSON command and executes
4. Confirmation echoed back over serial

---

## 3. Communication Protocols

### Serial / USB (Host-Mediated Mode)

BearClaw uses a simple JSON-over-serial protocol to communicate with microcontrollers:

**Host → MCU:**
```json
{"op": "gpio_set", "pin": 13, "value": 1}
{"op": "gpio_get", "pin": 5}
{"op": "i2c_read", "addr": "0x48", "reg": "0x00", "len": 2}
```

**MCU → Host:**
```json
{"status": "ok", "result": null}
{"status": "ok", "result": 1}
{"status": "ok", "result": [0x01, 0x23]}
{"status": "error", "message": "pin not configured as input"}
```

### GPIO (Edge-Native on Raspberry Pi)

For Raspberry Pi native GPIO, BearClaw currently uses the `shell` tool with `raspi-gpio` or `pinctrl`:

```bash
# Set GPIO 17 high
raspi-gpio set 17 op dh

# Read GPIO 27
raspi-gpio get 27
```

Future: native `/sys/class/gpio` interface or `libgpiod` bindings via Zig FFI for zero-shell-overhead control.

---

## 4. Supported Hardware (Current + Planned)

### Currently Working

| Board | Transport | Method | Notes |
|---|---|---|---|
| Raspberry Pi 3/4/5 | Native | `shell` → `raspi-gpio` / `pinctrl` | BearClaw runs on-device |
| Any Arduino | USB Serial | `shell` → serial write | Requires JSON firmware on MCU |
| Any MCU with serial | USB Serial | `shell` → serial write | Requires JSON firmware on MCU |

### Planned

| Board | Transport | Notes |
|---|---|---|
| ESP32 | Wi-Fi / Serial | Edge-native mode; Zig native TLS already works |
| STM32 Nucleo-F401RE | USB Serial / J-Link | Host-mediated debug/flash |
| Arduino Uno | USB Serial | Improved firmware with `bareclaw flash` command |
| Raspberry Pi GPIO | libgpiod | Zero-overhead native GPIO without shell fork |

---

## 5. Datasheet / Pin Reference

Pin references live in `docs/datasheets/` (to be added). These documents map board-specific pin names, GPIO numbers, and peripheral functions so the agent can resolve natural language ("pin 13", "the blue LED", "SDA") to hardware addresses without hallucinating.

---

## 6. Peripheral Config

Supported `~/.bareclaw/config.toml` schema for peripheral listing:

```toml
[peripherals]
enabled = true

[[peripherals.boards]]
board     = "rpi-gpio"
transport = "native"

[[peripherals.boards]]
board     = "arduino-uno"
transport = "serial"
path      = "/dev/ttyACM0"
baud      = 115200

[[peripherals.boards]]
board     = "esp32"
transport = "serial"
path      = "/dev/ttyUSB0"
baud      = 115200
```

---

## 7. Implementation Phases

| Phase | Feature | Status |
|-------|---------|--------|
| **P0** | `peripheral list` command | ✅ Done |
| **P1** | Serial read/write via `shell` tool | ✅ Works today |
| **P2** | Raspberry Pi GPIO via `shell` + `raspi-gpio` | ✅ Works today |
| **P3** | `[peripherals]` config schema | ✅ Minimal listing support |
| **P4** | Dedicated `gpio_read`/`gpio_write` tools (no shell fork) | 🔜 Roadmap |
| **P5** | Native I2C/SPI via Zig FFI (`libgpiod`) | 🔜 Roadmap |
| **P6** | ESP32 edge-native mode (BearClaw running on ESP32) | 🔜 Roadmap |
| **P7** | Firmware flash command (`bareclaw flash`) | 🔜 Roadmap |

---

## 8. Security Considerations for Hardware Tools

All hardware tool calls go through the same security stack as other tools:

1. **Audit logging** — every tool call (including `shell` calls that hit hardware) is logged to `audit.log`.
2. **Path policy** — serial device paths (e.g. `/dev/ttyACM0`) are in the system-forbidden list by default. Future dedicated GPIO tools will expose hardware access without needing to open `/dev` directly.
3. **Shell blocklist** — even with hardware targets, the shell blocklist applies. Commands that look like filesystem destruction are blocked regardless of intent.
4. **Allowlist** — future hardware tools will use an explicit device allowlist, similar to channel sender allowlists.

---

## 9. References

- `src/peripherals.zig` — peripheral config parsing and listing
- `src/tools.zig` — `shell` tool (primary hardware interface today)
- `src/security.zig` — path policy (`/dev/` is in the forbidden path list)
- [docs/network-deployment.md](./network-deployment.md) — running BearClaw on Raspberry Pi
