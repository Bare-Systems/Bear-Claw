# BearClaw 🐻

A fast, self-hostable AI agent runtime written in Zig. BearClaw has zero dependencies beyond the Zig standard library, small binary, runs anywhere from your dev machine to a Raspberry Pi.

> **Theme**: a pragmatic, hardware-savvy bear who guards your workspace — claws out, no compromises.

---

## Table of Contents

- [MCP](#mcp)
- [Features](#features)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Commands](#commands)
- [Providers](#providers)
- [Tools](#tools)
- [Channels](#channels)
- [Memory](#memory)
- [Security](#security)
- [Cron](#cron)
- [Gateway & Daemon](#gateway--daemon)
- [Architecture](#architecture)

---

## MCP

The Bare Claw repository comes equiped with an MCP server (`mcp/`) which wraps the entire BearClaw CLI and build system as MCP tools so any agent (Claude Desktop, Claude Code, or a BearClaw agent itself) can:

- Read and understand the Zig source
- Edit code and compile immediately
- Run the full test suite
- Send prompts to the live agent and inspect side effects
- Close the loop — all without leaving the conversation

**BearClaw agents can improve BearClaw.** A session running via Telegram or Discord can reason about and propose changes to its own Zig source — the same MCP tools the developer uses are available to any sufficiently capable agent.

Claude can be configured in CLI to user bareclaw like so:
```sh
cd mcp && uv sync
cd ..
claude mcp add bareclaw mcp/.venv/bin/python3 mcp/server.py
```

See [`docs/mcp-development.md`](docs/mcp-development.md) for the full ADHD playbook and [`mcp/README.md`](mcp/README.md) for setup.

---

## Features

| Area | What's implemented |
|---|---|
| **Providers** | Anthropic (Claude), OpenAI, OpenAI-compatible, Ollama, OpenRouter, Echo (offline) |
| **Routing** | Fallback chain — tries providers in order, returns first success |
| **Tools** | shell, file_read, file_write, memory_store, memory_recall, memory_forget, memory_search, planner_execute, http_request, git_operations |
| **Agent loop** | Multi-round tool-calling with configurable max rounds (default 8) |
| **Channels** | CLI (single-turn & interactive loop), Discord (WebSocket Gateway), Telegram (long-polling) |
| **Memory** | Markdown file-per-key store under `~/.bareclaw/workspace/memory/` |
| **Security** | Path allowlisting, shell command blocklist, append-only audit log |
| **Cron** | Persistent task scheduler with TSV storage, pause/resume, manual run |
| **Gateway** | Minimal internal HTTP server (`/health`, `/webhook`, `/v1/chat`) |
| **Daemon** | Gateway + cron runner combined |
| **Migration** | Import from OpenClaw workspace |

---

## Quick Start

**Requirements**: Zig 0.14+

```bash
# Clone and build
git clone <your-repo-url> bareclaw
cd bareclaw
zig build

# First-run setup
./zig-out/bin/bareclaw onboard

# Check status
./zig-out/bin/bareclaw status

# Run health diagnostics
./zig-out/bin/bareclaw doctor

# Chat with the agent
./zig-out/bin/bareclaw agent "What files are in my workspace?"

# Run tests
zig build test
```

### Install latest Linux binary

```bash
curl -fsSL -o bareclaw-linux-x86_64.tar.gz \
  https://github.com/Bare-Labs/BearClaw/releases/latest/download/bareclaw-linux-x86_64.tar.gz
tar -xzf bareclaw-linux-x86_64.tar.gz
chmod +x bareclaw
./bareclaw --help
```

### Setting your API key

BearClaw checks these environment variables in order:

```bash
export BARECLAW_API_KEY="your-key-here"   # preferred
export API_KEY="your-key-here"            # generic fallback
```

Without a key, BearClaw runs in **echo mode** — it reflects your input back as the reply, which is useful for testing tools and channels without an API.

---

## Configuration

Config lives at `~/.bareclaw/config.toml`. Run `bareclaw onboard` to create it, or edit it directly:

```toml
default_provider   = "anthropic"
default_model      = "claude-opus-4-5"
memory_backend     = "markdown"
fallback_providers = "openai,ollama"

# Optional channel tokens
discord_token  = "Bot.token.here"
telegram_token = "1234567890:your-telegram-token"
```

Tokens for Discord and Telegram can also be set via environment variables — those take precedence over the config file:

```bash
export DISCORD_BOT_TOKEN="Bot.token.here"
export TELEGRAM_BOT_TOKEN="1234567890:your-telegram-token"
```

---

## Commands

```
bareclaw <command> [options]
```

| Command | Description |
|---|---|
| `onboard` | Interactive first-run setup, writes config.toml |
| `status` | Print workspace, provider, model, memory count, cron count |
| `doctor` | Health-check all subsystems and report issues |
| `agent "<prompt>"` | Run a single agent turn with tool-calling support |
| `channel` | Start CLI channel (single turn) |
| `channel loop` | Start interactive CLI REPL |
| `channel discord` | Connect to Discord via Gateway WebSocket |
| `channel telegram` | Start Telegram long-poll loop |
| `cron list` | List all scheduled tasks |
| `cron add "<schedule>" "<command>"` | Add a new cron task |
| `cron remove <id>` | Delete a task |
| `cron pause <id>` | Disable a task without deleting it |
| `cron resume <id>` | Re-enable a paused task |
| `cron run` | Execute all enabled tasks immediately |
| `gateway` | Start HTTP gateway on port 8080 |
| `daemon` | Start gateway + cron runner together |
| `tardigrade` | Start BearClaw gateway + Tardigrade edge together |
| `peripheral` | List configured hardware peripherals from `[peripherals]` config |
| `migrate [source_path]` | Import markdown memory entries from OpenClaw (default: `~/.openclaw/workspace`) |

---

## Providers

BearClaw supports multiple AI backends. Set `default_provider` in config or use the fallback chain.

### Anthropic (Claude)

```toml
default_provider = "anthropic"
default_model    = "claude-opus-4-5"
```

```bash
export BARECLAW_API_KEY="sk-ant-..."
```

Uses the native Anthropic Messages API (`POST /v1/messages`). Tool-use blocks (`tool_use`) are automatically translated to the internal OpenAI-compatible format so the agent loop works identically regardless of backend.

### OpenAI

```toml
default_provider = "openai"
default_model    = "gpt-4o"
```

```bash
export BARECLAW_API_KEY="sk-..."
```

### OpenAI-Compatible (any clone)

```toml
default_provider = "openai-compatible"
default_model    = "your-model-name"
```

```bash
export BARECLAW_API_KEY="your-key"
export BARECLAW_API_URL="https://your-openai-clone.example.com"
```

### Ollama (local, no key required)

```toml
default_provider = "ollama"
default_model    = "llama3"
```

Connects to `http://localhost:11434` by default. No API key needed.

### OpenRouter

```toml
default_provider = "openrouter"
default_model    = "anthropic/claude-opus-4-5"
```

```bash
export BARECLAW_API_KEY="sk-or-..."
```

### Echo (offline / testing)

```toml
default_provider = "echo"
```

Reflects the user message back as the reply. No network calls. Useful for testing tools, channels, and cron without an API key.

### Fallback / Router

Configure a comma-separated fallback chain. BearClaw tries each provider in order and returns the first successful response:

```toml
default_provider   = "anthropic"
fallback_providers = "openai,ollama,echo"
```

---

## Tools

The agent can call any of these tools during a conversation. Tools are executed with the real security policy and memory context.

| Tool | Description | Key Arguments |
|---|---|---|
| `shell` | Run a shell command via `/bin/sh -c` | `command` |
| `file_read` | Read a file from the workspace | `path` |
| `file_write` | Write content to a file in the workspace | `path`, `content` |
| `memory_store` | Persist a value to the memory backend | `key`, `content` |
| `memory_recall` | Retrieve a stored value | `key` |
| `memory_forget` | Delete a stored memory entry | `key` |
| `memory_search` | Rank memory entries by relevance | `query`, `limit` |
| `http_request` | Make a GET or POST HTTP request | `url`, `method`, `body` |
| `git_operations` | Run git subcommands in a workspace path | `op`, `path`, `args` |

**Allowed git operations**: `status`, `log`, `diff`, `add`, `commit`, `push`, `pull`, `clone`, `init`, `branch`, `checkout`, `fetch`, `stash`

All tool calls are logged to the audit log before execution.

---

## Channels

Channels are the interfaces through which users (or bots) interact with BearClaw.

### CLI — Single Turn

```bash
bareclaw channel
```

Prompts for one line of input, runs the agent, prints the reply, exits.

### CLI — Interactive Loop

```bash
bareclaw channel loop
```

A full REPL. Type messages, get replies. Type `exit` or `quit` to stop.

### Discord

```bash
export DISCORD_BOT_TOKEN="Bot.your.token"
bareclaw channel discord
```

Connects to the Discord Gateway via WebSocket (TLS). Listens for `MESSAGE_CREATE` events and replies to every non-bot message in-channel. Handles heartbeats, reconnection, and pong frames automatically.

**Setup**:
1. Create a bot at [discord.com/developers](https://discord.com/developers)
2. Enable the **Message Content Intent** under Privileged Gateway Intents
3. Invite the bot to your server with `Send Messages` permission
4. Set `DISCORD_BOT_TOKEN` and run

### Telegram

```bash
export TELEGRAM_BOT_TOKEN="1234567890:your-token"
bareclaw channel telegram
```

Long-polls `getUpdates` (30-second timeout). Processes each text message through the agent and replies via `sendMessage`. Automatically advances the update offset to avoid duplicates.

**Setup**:
1. Message [@BotFather](https://t.me/BotFather) on Telegram to create a bot
2. Copy the token and set `TELEGRAM_BOT_TOKEN`
3. Run `bareclaw channel telegram`

---

## Memory

BearClaw stores persistent memory as Markdown files under `~/.bareclaw/workspace/memory/`.

Each `memory_store` call writes `<key>.md`. `memory_recall` reads it back. `memory_forget` deletes it.

The agent automatically stores the last user message as `last_message` after each successful turn.
Interactive sessions and single-turn agent runs also store a transcript under
`session/YYYY-MM-DDTHH:MM`, and cron agent-prompt runs store results under
`cron/<task_id>/<timestamp>`.
User preferences can be stored separately in `profile.md` via the `profile_get`
and `profile_set` tools, and the agent now incorporates that profile into the
system prompt when present. Planner runs also store reflective summaries under
`reflection/<timestamp>` and refresh `reflection/latest`, which is loaded back
into future prompts as lightweight guidance.
`memory_search` ranks stored entries by relevance so transcripts, reflections,
and notes remain usable as the workspace grows.

```bash
# View your memory files directly
ls ~/.bareclaw/workspace/memory/
```

The `status` command shows a count of stored memory files.

## Planner

BearClaw now includes a planner/reflector path via the `planner_execute` tool.
When the agent chooses that tool, it:
- asks the model for a structured tool plan
- executes the planned steps one by one
- reflects after each step to decide whether to continue, stop, or append work
- stores a final reflective summary in memory for future sessions

This is primarily meant for higher-level goals that benefit from explicit
multi-step execution instead of a single tool-calling turn.

## Migration

`bareclaw migrate` imports Markdown memory entries from an OpenClaw workspace
into BearClaw's `memory/` directory. By default it reads
`~/.openclaw/workspace/memory/**/*.md` and preserves nested key paths.

```bash
# Import from the default OpenClaw workspace
bareclaw migrate

# Import from a different exported workspace path
bareclaw migrate /tmp/openclaw-workspace
```

`bareclaw doctor` now also checks whether configured peripherals are structurally
valid and whether the default OpenClaw migration source exists.

---

## Security

BearClaw enforces a layered security model:

### Path Policy

`file_read`, `file_write`, and `git_operations` all validate paths before execution:

- **Directory traversal blocked**: any path containing `..` is rejected
- **Forbidden system paths**: `/etc/`, `/root/`, `/usr/`, `/proc/`, `/sys/`, `/dev/` are always blocked
- **Sensitive directories blocked**: paths containing `/.ssh`, `/.gnupg`, `/.aws`, or `/.bareclaw/secrets` are rejected
- **Absolute paths**: must be inside `workspace_dir`
- **Relative paths**: allowed (resolved relative to workspace)

### Shell Command Blocklist

The `shell` tool blocks a set of destructive command patterns before execution (e.g. `rm -rf`, `mkfs`, `dd if=`, `:(){ :|:& };:`). This is a defense-in-depth layer — it is not a sandbox. Full sandboxing requires OS-level isolation.

Time-bounded tool execution is enforced by default. `shell`,
`git_operations`, cron shell wrappers, and `http_request` all return an
explicit timeout error after 30 seconds instead of hanging the agent
indefinitely.

### Audit Log

Every tool call is appended to `~/.bareclaw/workspace/audit.log` before execution:

```
1700000000	shell	ls -la
1700000001	file_read	notes.md
1700000002	memory_store	last_message
```

Format: `unix_timestamp TAB tool_name TAB detail`

---

## Cron

BearClaw includes a lightweight task scheduler. Tasks are persisted as a TSV file at `~/.bareclaw/cron.tsv`.

```bash
# Add a task (schedule field is stored but not yet parsed for time-based firing)
bareclaw cron add "0 9 * * *" "echo good morning"

# List all tasks
bareclaw cron list

# Pause / resume
bareclaw cron pause <id>
bareclaw cron resume <id>

# Run all enabled tasks right now
bareclaw cron run

# Remove a task
bareclaw cron remove <id>
```

The `daemon` command runs `cron run` alongside the HTTP gateway so tasks execute on daemon startup. Time-based scheduling (cron expression parsing) is on the roadmap.

---

## Gateway & Daemon

### Gateway

```bash
bareclaw gateway
```

Starts an internal HTTP server on `127.0.0.1:8080`:

| Endpoint | Method | Response |
|---|---|---|
| `/health` | GET | `{"status":"ok","service":"bareclaw"}` |
| `/webhook` | POST | `{"received":true}` |
| `/v1/chat` | POST | `{"message":{...},"requires_confirmation":false,"confirmation_reason":null}` |

`/v1/chat` is designed for trusted local callers (for example, Tardigrade edge
running on the same host). It does not enforce bearer auth directly in this
MVP. Each connection is handled on its own thread, and agent execution is cut
off after 30 seconds with `504 Gateway Timeout` instead of blocking the gateway
indefinitely.

### Daemon

```bash
bareclaw daemon
```

Runs the gateway and cron runner together. Intended as a long-running background process for server deployments.

### Tardigrade Orchestration

```bash
bareclaw tardigrade --tardigrade-bin /path/to/tardigrade
```

Optional flags:
- `--host <host>` (default `0.0.0.0`)
- `--port <port>` (default `8069`)
- `--endpoint-host <host>` (override the host embedded in pairing/smoke output)
- `--tls-cert <path>`
- `--tls-key <path>`
- `--print-deploy-json`
- `--print-deploy-env`
- `--write-deploy-env <path>`

This command:
- starts local BearClaw gateway automatically
- starts Tardigrade as the direct HTTPS edge in front of BearClaw
- generates a bearer token and prints:
  - public endpoint (`http[s]://<public-ip>:<port>`)
  - bearer token for iPhone settings
  - cert SHA-256 fingerprint
  - pairing payload JSON and compact `tardi1:` pairing code

If `--tls-cert`/`--tls-key` are not provided, BearClaw generates a self-signed certificate under `~/.bareclaw/tls/` using `openssl`.

For manual or service-managed installs, use deployment mode instead of spawning
the processes directly:

```bash
bareclaw tardigrade --print-deploy-json --endpoint-host 127.0.0.1
bareclaw tardigrade --print-deploy-env
bareclaw tardigrade --write-deploy-env /etc/bareclaw/tardigrade.env
```

Those modes print or write the direct Tardigrade env block BearClaw expects,
along with:
- pairing payload JSON and `tardi1:` code for the iOS app
- the bearer token and cert fingerprint
- a smoke-test `curl` command that uses `Authorization: Bearer ...` and `--cacert`

`--print-deploy-json` emits one machine-readable JSON object containing:
- `endpoint`
- `bearer_token`
- `cert_sha256`
- `tls_cert_path`
- `tls_key_path`
- `deploy_env`
- `deploy_env_path` (or `null` when not writing a file)

Pairing payload format:

```json
{
  "endpoint": "https://<public-ip>:<port>",
  "bearer_token": "<secret>",
  "cert_sha256": "<64-char-lowercase-sha256>"
}
```

### Linux `systemd --user` service

For a manual host-native install on Linux, the simplest durable path is a
user-scoped `systemd` unit plus lingering:

```bash
sudo loginctl enable-linger "$USER"
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
cp ./zig-out/bin/bareclaw "$HOME/.local/bin/bareclaw"

cat > "$HOME/.config/systemd/user/bearclaw.service" <<'EOF'
[Unit]
Description=BearClaw daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=%h
ExecStart=%h/.local/bin/bareclaw daemon
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now bearclaw.service
systemctl --user status bearclaw.service
journalctl --user -u bearclaw.service -f
```

On the `blink` homelab deployment, the staged unit file and installer live at:

- `/home/admin/baresystems/runtime/blink-homelab/systemd-user/bearclaw.service`
- `/home/admin/baresystems/runtime/blink-homelab/install_user_systemd_units.sh`

After enabling lingering for `admin`, install the staged units with:

```bash
/home/admin/baresystems/runtime/blink-homelab/install_user_systemd_units.sh enable
```

Paste this payload (or the `tardi1:` code) into the iOS app Pairing section. The app pins `cert_sha256` and uses it for TLS trust.

---

## Architecture

```
bareclaw/
├── src/
│   ├── main.zig          # CLI entry point, command dispatch
│   ├── agent.zig         # Tool-calling agent loop (up to 8 rounds)
│   ├── provider.zig      # Provider backends + Router + AnyProvider vtable
│   ├── tools.zig         # 8 built-in tools (shell, file I/O, memory, HTTP, git)
│   ├── channels.zig      # CLI, Discord, Telegram channel implementations
│   ├── memory.zig        # Markdown file-per-key memory backend
│   ├── security.zig      # Path policy, shell blocklist, audit logging
│   ├── config.zig        # TOML config loader, defaults, onboard
│   ├── cron.zig          # Task scheduler with TSV persistence
│   ├── gateway.zig       # Minimal TCP/HTTP server
│   ├── daemon.zig        # Gateway + cron combined runner
│   ├── peripherals.zig   # Hardware peripheral config parsing and listing
│   └── migration.zig     # OpenClaw workspace importer
└── build.zig             # Zig build system
```

**No external dependencies** — BearClaw uses only the Zig standard library. TLS (for Discord WebSocket and HTTPS), HTTP, JSON parsing, and crypto are all stdlib.

### How the Agent Loop Works

1. User message is sent to the configured provider
2. If the response contains `tool_calls`, each tool is dispatched with a real `ToolContext` (policy + memory)
3. Tool results are appended to a context buffer and fed back to the model as a follow-up turn
4. This repeats up to 8 rounds (`MAX_TOOL_ROUNDS`)
5. When the model produces a plain text response (no tool calls), it is printed and the turn ends

The Anthropic `tool_use` block format is translated to the internal OpenAI `tool_calls` format transparently, so the agent loop is provider-agnostic.

---

## Roadmap

- [ ] Cron expression parsing (time-based firing)
- [ ] Structured JSON logging / observability
- [ ] Per-provider cost tracking
- [ ] Hardware peripheral I/O (GPIO, serial bridge for microcontrollers)
- [x] systemd user service units for daemon mode
- [ ] launchd service files for daemon mode
- [ ] Multi-turn conversation history (beyond single-turn tool context)
- [ ] Vector memory backend

---
