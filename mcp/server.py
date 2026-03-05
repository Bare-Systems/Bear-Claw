"""
BearClaw MCP Server – agent-driven development harness.

Wraps the bareclaw CLI so AI agents can build, test, and inspect
the runtime as they develop it. All tools shell out to the binary
or zig build system; no Zig code lives here.

Usage:
    uv run server.py

Register in Claude Desktop (~/Library/Application Support/Claude/claude_desktop_config.json):
    {
      "mcpServers": {
        "bareclaw": {
          "command": "uv",
          "args": ["--directory", "/path/to/bareclaw/mcp", "run", "server.py"]
        }
      }
    }
"""

import json
import subprocess
import sys
import os
import time
import urllib.request
import urllib.error
from pathlib import Path
from mcp.server.fastmcp import FastMCP

# Resolve the repo root relative to this file (mcp/ is one level below root)
REPO_ROOT = Path(__file__).parent.parent.resolve()
MCP_DIR = Path(__file__).parent.resolve()
BINARY = REPO_ROOT / "zig-out" / "bin" / "bareclaw"

# ---------------------------------------------------------------------------
# Load .env files at startup (mcp/.venv/.env, mcp/.env, repo root .env)
# Environment variables already set take precedence — we never overwrite them.
# ---------------------------------------------------------------------------

def _load_env_files() -> None:
    env_locations = [
        MCP_DIR / ".venv" / ".env",
        MCP_DIR / ".env",
        REPO_ROOT / ".env",
    ]
    for env_path in env_locations:
        if not env_path.exists():
            continue
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = val

_load_env_files()

# ---------------------------------------------------------------------------
# Discord helpers (used by tester tools below)
# ---------------------------------------------------------------------------

# Background bot subprocess — tracked across tool calls within one server session
_discord_bot_proc: "subprocess.Popen | None" = None


def _discord_test_channel_id() -> str:
    """Return the test channel ID: env var first, then bareclaw config fallback."""
    ch = os.environ.get("DISCORD_TEST_CHANNEL_ID", "")
    if ch:
        return ch
    config_path = Path.home() / ".bareclaw" / "config.toml"
    if config_path.exists():
        for line in config_path.read_text().splitlines():
            line = line.strip()
            if line.startswith("discord_notify_channel"):
                eq = line.find("=")
                if eq != -1:
                    val = line[eq + 1:].strip().strip('"').strip("'")
                    if val:
                        return val
    return ""


def _discord_api(method: str, path: str, body: dict | None = None, token: str | None = None) -> dict | list:
    """Make a Discord REST API call. Returns parsed JSON or an error dict."""
    api_token = token or os.environ.get("DISCORD_CLAUDE_TOKEN", "")
    if not api_token:
        return {"error": "DISCORD_CLAUDE_TOKEN not set. Add it to mcp/.venv/.env"}
    url = f"https://discord.com/api/v10{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bot {api_token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "BearClaw-MCP/1.0")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()}"}
    except Exception as e:
        return {"error": str(e)}


def _run(cmd: list[str], cwd: Path | None = None, timeout: int = 60, env: dict | None = None) -> dict:
    """Run a subprocess and return stdout, stderr, and return code."""
    try:
        result = subprocess.run(
            cmd,
            cwd=str(cwd or REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
        return {
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
            "returncode": result.returncode,
            "ok": result.returncode == 0,
        }
    except subprocess.TimeoutExpired:
        return {
            "stdout": "",
            "stderr": f"Command timed out after {timeout}s",
            "returncode": -1,
            "ok": False,
        }
    except FileNotFoundError as e:
        return {
            "stdout": "",
            "stderr": str(e),
            "returncode": -1,
            "ok": False,
        }


def _format(result: dict) -> str:
    """Format a subprocess result into a readable string."""
    parts = []
    if result["stdout"]:
        parts.append(result["stdout"])
    if result["stderr"]:
        parts.append(f"[stderr]\n{result['stderr']}")
    if not result["ok"]:
        parts.append(f"[exit code: {result['returncode']}]")
    return "\n".join(parts) if parts else "(no output)"


mcp = FastMCP("bareclaw")


# ---------------------------------------------------------------------------
# Build tools
# ---------------------------------------------------------------------------


@mcp.tool()
def build(release: bool = False) -> str:
    """Build the BearClaw Zig binary.

    Args:
        release: If true, build with ReleaseSafe optimization. Defaults to debug.
    """
    cmd = ["zig", "build"]
    if release:
        cmd += ["-Doptimize=ReleaseSafe"]
    result = _run(cmd)
    if result["ok"]:
        return f"Build succeeded. Binary at: {BINARY}\n{_format(result)}"
    return f"Build FAILED.\n{_format(result)}"


@mcp.tool()
def run_tests() -> str:
    """Run all BearClaw Zig unit tests via `zig build test`."""
    result = _run(["zig", "build", "test"])
    if result["ok"]:
        return f"All tests passed.\n{_format(result)}"
    return f"Tests FAILED.\n{_format(result)}"


@mcp.tool()
def binary_exists() -> str:
    """Check whether the bareclaw binary has been built and exists on disk."""
    if BINARY.exists():
        size = BINARY.stat().st_size
        return f"Binary exists: {BINARY} ({size:,} bytes)"
    return f"Binary NOT found at: {BINARY}\nRun build() first."


# ---------------------------------------------------------------------------
# Runtime inspection tools
# ---------------------------------------------------------------------------


@mcp.tool()
def status() -> str:
    """Run `bareclaw status` to inspect the current runtime configuration.

    Shows workspace path, config path, provider, model, and memory backend.
    """
    result = _run([str(BINARY), "status"])
    return _format(result)


@mcp.tool()
def run_agent(prompt: str) -> str:
    """Send a prompt to the BearClaw agent and return its response.

    Runs `bareclaw agent "<prompt>"` as a single-turn interaction.

    Args:
        prompt: The input to send to the agent.
    """
    result = _run([str(BINARY), "agent", prompt], timeout=30)
    return _format(result)


@mcp.tool()
def run_cron() -> str:
    """Run `bareclaw cron` to execute any scheduled tasks once."""
    result = _run([str(BINARY), "cron"])
    return _format(result)


@mcp.tool()
def list_peripherals() -> str:
    """Run `bareclaw peripheral` to list configured hardware peripherals."""
    result = _run([str(BINARY), "peripheral"])
    return _format(result)


@mcp.tool()
def help() -> str:
    """Run `bareclaw` with no arguments to show the CLI usage/help text."""
    result = _run([str(BINARY)])
    return _format(result)


# ---------------------------------------------------------------------------
# Source inspection tools
# ---------------------------------------------------------------------------


@mcp.tool()
def list_source_files() -> str:
    """List all Zig source files in the src/ directory with their sizes."""
    src_dir = REPO_ROOT / "src"
    if not src_dir.exists():
        return "src/ directory not found."
    lines = []
    for f in sorted(src_dir.glob("*.zig")):
        size = f.stat().st_size
        lines.append(f"{f.name:30s} {size:>6,} bytes")
    return "\n".join(lines) if lines else "No .zig files found in src/"


@mcp.tool()
def read_source_file(filename: str) -> str:
    """Read the contents of a Zig source file from src/.

    Args:
        filename: The filename within src/ (e.g. "agent.zig", "main.zig").
    """
    path = REPO_ROOT / "src" / filename
    if not path.exists():
        return f"File not found: src/{filename}"
    if not path.suffix == ".zig":
        return "Only .zig files are supported."
    return path.read_text()


@mcp.tool()
def repo_structure() -> str:
    """Show the top-level directory structure of the BearClaw repository."""
    lines = []
    for item in sorted(REPO_ROOT.iterdir()):
        if item.name.startswith(".") or item.name in ("zig-out", ".zig-cache"):
            continue
        if item.is_dir():
            lines.append(f"{item.name}/")
            for child in sorted(item.iterdir()):
                if not child.name.startswith("."):
                    lines.append(f"  {child.name}")
        else:
            lines.append(item.name)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Config inspection
# ---------------------------------------------------------------------------


@mcp.tool()
def read_config() -> str:
    """Read the current BearClaw config file (~/.bareclaw/config.toml)."""
    config_path = Path.home() / ".bareclaw" / "config.toml"
    if not config_path.exists():
        return "Config file not found. Run `bareclaw onboard` or `bareclaw status` to initialize."
    return config_path.read_text()


@mcp.tool()
def run_smoke_tests() -> str:
    """Run the BearClaw smoke test suite. No Discord required.

    USE THIS after every non-trivial code change to verify nothing broke.
    Checks: binary exists, status works, zig unit tests pass,
    Ollama is reachable, agent round-trip responds.
    Fast (~15s). Always run before run_integration_test_discord.
    """
    script = REPO_ROOT / "tests" / "smoke.sh"
    result = _run(["bash", str(script)], timeout=90)
    return _format(result)


@mcp.tool()
def run_integration_test_discord() -> str:
    """Run the full Discord end-to-end integration test.

    USE THIS to validate the Discord channel feature end-to-end.
    Starts the bot, sends a real @mention via webhook to #testing,
    waits for the bot to reply via Ollama, verifies the reply arrived.
    Requires: Ollama running, discord_token + discord_webhook in config.
    Slower (~30s). Run after smoke tests pass.

    Bot token resolution order:
      1. DISCORD_TEST_TOKEN in .env (integration test token, preferred)
      2. DISCORD_BOT_TOKEN in environment
      3. discord_token in ~/.bareclaw/config.toml
    """
    script = REPO_ROOT / "tests" / "integration_discord.sh"
    env = os.environ.copy()
    env["BINARY"] = str(BINARY)

    # Load .env from the repo root and inject DISCORD_TEST_TOKEN so the
    # integration test uses the dev bot token regardless of what personal
    # token is set in config.toml.
    dot_env = REPO_ROOT / ".env"
    if dot_env.exists():
        for line in dot_env.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            env.setdefault(key, val)  # don't override vars already in env

    result = _run(["bash", str(script)], timeout=120, env=env)
    return _format(result)


@mcp.tool()
def config_set(key: str, value: str) -> str:
    """Set a config value and persist it to ~/.bareclaw/config.toml.

    Args:
        key: Config key to set. One of: default_provider, default_model,
             memory_backend, fallback_providers, api_key,
             discord_token, telegram_token.
        value: The value to set.
    """
    result = _run([str(BINARY), "config", "set", key, value])
    return _format(result)


@mcp.tool()
def config_get() -> str:
    """Show all current config values (secrets are masked)."""
    result = _run([str(BINARY), "config", "get"])
    return _format(result)


@mcp.tool()
def workspace_contents() -> str:
    """List files in the BearClaw workspace directory (~/.bareclaw/workspace/)."""
    workspace = Path.home() / ".bareclaw" / "workspace"
    if not workspace.exists():
        return "Workspace directory does not exist yet."
    lines = []
    for item in sorted(workspace.rglob("*")):
        rel = item.relative_to(workspace)
        if item.is_file():
            lines.append(str(rel))
    return "\n".join(lines) if lines else "Workspace exists but is empty."


# ---------------------------------------------------------------------------
# T2-6/T2-7: Agent introspection and memory management tools
# ---------------------------------------------------------------------------


@mcp.tool()
def agent_status() -> str:
    """Return agent runtime status: workspace path, memory entry count, policy.

    Calls the built-in agent_status tool via a single-turn agent run.
    Useful for checking the health of the agent's working state.
    """
    result = _run([str(BINARY), "mcp", "call", "bareclaw", "agent_status"], timeout=15)
    # Fallback: call via bareclaw agent (single-turn) if mcp call not available
    if not result["ok"]:
        result = _run([str(BINARY), "agent", "call agent_status tool and show the result"], timeout=30)
    return _format(result)


@mcp.tool()
def audit_log_read(n: int = 50) -> str:
    """Read the last N lines of the BearClaw audit log.

    The audit log records every tool call with a unix timestamp, tool name,
    and detail string. Useful for debugging what the agent did.

    Args:
        n: Number of lines to return (default: 50).
    """
    audit_path = Path.home() / ".bareclaw" / "workspace" / "audit.log"
    if not audit_path.exists():
        return "(audit log not yet created)"
    lines = audit_path.read_text().splitlines()
    tail = lines[-n:] if len(lines) > n else lines
    return "\n".join(tail) if tail else "(audit log is empty)"


@mcp.tool()
def memory_list_keys() -> str:
    """List all keys stored in BearClaw's memory backend.

    Returns the logical key name (filename without .md extension) for each
    memory entry stored in ~/.bareclaw/workspace/memory/.
    """
    memory_dir = Path.home() / ".bareclaw" / "workspace" / "memory"
    if not memory_dir.exists():
        return "(no memory directory yet)"
    keys = sorted(
        f.stem for f in memory_dir.glob("*.md") if f.is_file()
    )
    if not keys:
        return "(no memory entries)"
    return "\n".join(keys)


@mcp.tool()
def memory_delete_prefix(prefix: str) -> str:
    """Delete all memory entries whose key starts with the given prefix.

    Useful for cleaning up session transcripts or bulk-removing related entries.

    Args:
        prefix: Key prefix to match (e.g. "session/" deletes all session entries).
    """
    memory_dir = Path.home() / ".bareclaw" / "workspace" / "memory"
    if not memory_dir.exists():
        return f"deleted 0 entries (no memory directory)"
    deleted = 0
    for f in list(memory_dir.glob("*.md")):
        if f.stem.startswith(prefix):
            f.unlink()
            deleted += 1
    return f"deleted {deleted} memory entries with prefix '{prefix}'"


@mcp.tool()
def doctor() -> str:
    """Run `bareclaw doctor` to check health of all subsystems.

    Checks workspace writability, config file, API key, audit log, and cron tasks.
    """
    result = _run([str(BINARY), "doctor"])
    return _format(result)


# ---------------------------------------------------------------------------
# Cron management tools (T2-3)
# ---------------------------------------------------------------------------


@mcp.tool()
def cron_list() -> str:
    """List all configured cron tasks with schedule, status, and time until next run."""
    result = _run([str(BINARY), "cron", "list"])
    return _format(result)


@mcp.tool()
def cron_add(schedule: str, command: str) -> str:
    """Add a new cron task.

    Args:
        schedule: Cron expression. Supports @hourly @daily @weekly @monthly,
                  or standard 5-field format (e.g. "0 * * * *" for hourly,
                  "*/15 * * * *" for every 15 minutes).
        command:  Shell command to run when the task fires.
    """
    result = _run([str(BINARY), "cron", "add", schedule, command])
    return _format(result)


@mcp.tool()
def cron_remove(task_id: str) -> str:
    """Remove a cron task by ID (e.g. "t1").

    Args:
        task_id: The task ID shown in cron_list().
    """
    result = _run([str(BINARY), "cron", "remove", task_id])
    return _format(result)


@mcp.tool()
def cron_pause(task_id: str) -> str:
    """Pause a cron task (keep it but stop it from firing).

    Args:
        task_id: The task ID shown in cron_list().
    """
    result = _run([str(BINARY), "cron", "pause", task_id])
    return _format(result)


@mcp.tool()
def cron_resume(task_id: str) -> str:
    """Resume a paused cron task.

    Args:
        task_id: The task ID shown in cron_list().
    """
    result = _run([str(BINARY), "cron", "resume", task_id])
    return _format(result)


@mcp.tool()
def cron_add_prompt(schedule: str, prompt: str) -> str:
    """Add a new agent-prompt cron task.

    When the task fires, BearClaw runs the agent with the given prompt instead
    of a shell command. The agent response is stored in memory under
    "cron/<task_id>/<timestamp>" for later recall.

    Args:
        schedule: Cron expression. Supports @hourly @daily @weekly @monthly,
                  or standard 5-field format (e.g. "0 9 * * *" for 9am daily).
        prompt:   The agent prompt to send when the task fires.
    """
    result = _run([str(BINARY), "cron", "add-prompt", schedule, prompt])
    return _format(result)


@mcp.tool()
def cron_run() -> str:
    """Execute all cron tasks that are currently due.

    Tasks whose next_run timestamp has passed are executed and their next_run
    is advanced to the following scheduled time. Tasks not yet due are skipped.
    Prompt tasks call the agent; shell tasks exec the command.
    """
    result = _run([str(BINARY), "cron", "run"], timeout=60)
    return _format(result)


# ---------------------------------------------------------------------------
# MCP server management tools
# ---------------------------------------------------------------------------


@mcp.tool()
def mcp_list_servers() -> str:
    """List all configured MCP servers that BearClaw knows about.

    MCP servers extend BearClaw with external tools (e.g. AutoTrader, custom bots).
    """
    result = _run([str(BINARY), "mcp", "list-servers"])
    return _format(result)


@mcp.tool()
def mcp_list_tools(server: str = "") -> str:
    """List all tools available from configured MCP servers.

    Connects to each server, runs tools/list, and displays the results.

    Args:
        server: Filter to a specific server by name. If empty, lists all servers.
    """
    cmd = [str(BINARY), "mcp", "list-tools"]
    if server:
        cmd.append(server)
    result = _run(cmd, timeout=30)
    return _format(result)


@mcp.tool()
def mcp_call_tool(server: str, tool: str, args_json: str = "{}") -> str:
    """Call a specific tool on a configured MCP server.

    Useful for testing MCP server connectivity and tool responses.

    Args:
        server: The server name as configured (e.g. "autotrader").
        tool: The tool name to call (e.g. "get_balance").
        args_json: JSON object of arguments, e.g. '{"symbol": "AAPL"}'.
    """
    result = _run([str(BINARY), "mcp", "call", server, tool, args_json], timeout=30)
    return _format(result)


@mcp.tool()
def mcp_add_server(name: str, command: str) -> str:
    """Add or update an MCP server in BearClaw's config.

    Appends the server to the mcp_servers config key. If a server with the
    same name exists, it is replaced.

    Args:
        name: Short identifier for this server (e.g. "autotrader").
        command: Full command to launch the server (e.g. "trader mcp serve").
    """
    config_path = Path.home() / ".bareclaw" / "config.toml"
    if not config_path.exists():
        return "Config file not found. Run bareclaw status first."

    content = config_path.read_text()

    # Parse existing mcp_servers value.
    import re
    match = re.search(r'^mcp_servers\s*=\s*"(.*?)"', content, re.MULTILINE)
    if match:
        existing = match.group(1)
        # Remove any existing entry with the same name.
        entries = [e for e in existing.split("|") if e and not e.startswith(f"{name}=")]
        entries.append(f"{name}={command}")
        new_val = "|".join(entries)
        new_content = content[:match.start()] + f'mcp_servers = "{new_val}"' + content[match.end():]
    else:
        # No mcp_servers line yet — append it.
        new_content = content.rstrip() + f'\nmcp_servers = "{name}={command}"\n'

    config_path.write_text(new_content)
    return f"✓ Added MCP server '{name}' → {command}\n  Saved to {config_path}"


@mcp.tool()
def mcp_remove_server(name: str) -> str:
    """Remove an MCP server from BearClaw's config by name.

    Args:
        name: The server name to remove (e.g. "autotrader").
    """
    config_path = Path.home() / ".bareclaw" / "config.toml"
    if not config_path.exists():
        return "Config file not found."

    content = config_path.read_text()

    import re
    match = re.search(r'^mcp_servers\s*=\s*"(.*?)"', content, re.MULTILINE)
    if not match:
        return f"No mcp_servers configured. Nothing to remove."

    existing = match.group(1)
    entries = [e for e in existing.split("|") if e and not e.startswith(f"{name}=")]
    removed = len(existing.split("|")) - len(entries)
    if removed == 0:
        return f"Server '{name}' not found in mcp_servers."

    new_val = "|".join(entries)
    new_content = content[:match.start()] + f'mcp_servers = "{new_val}"' + content[match.end():]
    config_path.write_text(new_content)
    return f"✓ Removed MCP server '{name}'. Remaining: {new_val or '(none)'}"


# ---------------------------------------------------------------------------
# Discord ↔ Claude testing loop
# Five tools that let Claude talk directly to the running BearClaw Discord bot.
# Requires DISCORD_CLAUDE_TOKEN in mcp/.venv/.env (Claude's tester bot token).
# Optionally set DISCORD_TEST_CHANNEL_ID (falls back to discord_notify_channel).
# ---------------------------------------------------------------------------


@mcp.tool()
def discord_tester_send(message: str, channel_id: str = "") -> str:
    """Send a message to the Discord test channel as Claude's tester bot.

    Uses DISCORD_CLAUDE_TOKEN (loaded from mcp/.venv/.env) to post as the
    Claude tester identity. The channel defaults to DISCORD_TEST_CHANNEL_ID
    env var, or discord_notify_channel from BearClaw's config.

    Args:
        message: The message text to send.
        channel_id: Optional channel ID override.

    Returns:
        The sent message ID (snowflake) — pass this to discord_fetch_messages
        as after_snowflake to poll for BearClaw's reply.
    """
    ch = channel_id or _discord_test_channel_id()
    if not ch:
        return (
            "Error: no channel ID configured.\n"
            "Set DISCORD_TEST_CHANNEL_ID in mcp/.venv/.env, or:\n"
            "  bareclaw config set discord_notify_channel <channel_id>"
        )
    result = _discord_api("POST", f"/channels/{ch}/messages", {"content": message})
    if isinstance(result, dict) and "error" in result:
        return f"Failed to send: {result['error']}"
    msg_id = result.get("id", "unknown") if isinstance(result, dict) else "unknown"
    return f"Sent (id={msg_id}): {message}"


@mcp.tool()
def discord_fetch_messages(limit: int = 20, after_snowflake: str = "", channel_id: str = "") -> str:
    """Fetch recent messages from the Discord test channel.

    Uses DISCORD_CLAUDE_TOKEN to read message history. Messages are returned
    oldest-first so the conversation reads naturally.

    Args:
        limit: Number of messages to fetch (1–100). Default: 20.
        after_snowflake: Only fetch messages after this ID (use the ID returned
                         by discord_tester_send to poll for new replies).
        channel_id: Optional channel ID override.

    Returns:
        Formatted list of messages: [timestamp] author (id=<snowflake>): content
    """
    ch = channel_id or _discord_test_channel_id()
    if not ch:
        return "Error: no channel ID. Set DISCORD_TEST_CHANNEL_ID in mcp/.venv/.env"
    params = f"?limit={min(max(limit, 1), 100)}"
    if after_snowflake:
        params += f"&after={after_snowflake}"
    result = _discord_api("GET", f"/channels/{ch}/messages{params}")
    if isinstance(result, dict) and "error" in result:
        return f"Failed to fetch: {result['error']}"
    if not isinstance(result, list):
        return f"Unexpected response: {result}"
    if not result:
        return "(no messages)"
    lines = []
    for msg in reversed(result):  # oldest first
        author = msg.get("author", {}).get("username", "?")
        content = msg.get("content", "")
        msg_id = msg.get("id", "")
        ts = msg.get("timestamp", "")[:19].replace("T", " ")
        lines.append(f"[{ts}] {author} (id={msg_id}): {content}")
    return "\n".join(lines)


@mcp.tool()
def discord_start_bot() -> str:
    """Start the BearClaw Discord bot in the background.

    Spawns `bareclaw channel discord` using DISCORD_BOT_TOKEN from the
    environment or discord_token from BearClaw's config. If the bot is
    already running, returns its PID without starting a new process.

    Returns:
        PID of the running bot process on success, or an error string.
    """
    global _discord_bot_proc
    if _discord_bot_proc is not None and _discord_bot_proc.poll() is None:
        return f"Bot already running (PID {_discord_bot_proc.pid})"

    # Resolve bot token: env var first, then config file
    bot_token = os.environ.get("DISCORD_BOT_TOKEN", "")
    if not bot_token:
        config_path = Path.home() / ".bareclaw" / "config.toml"
        if config_path.exists():
            for line in config_path.read_text().splitlines():
                line = line.strip()
                if line.startswith("discord_token"):
                    eq = line.find("=")
                    if eq != -1:
                        bot_token = line[eq + 1:].strip().strip('"').strip("'")
                        break
    if not bot_token:
        return (
            "Error: no bot token found.\n"
            "Set DISCORD_BOT_TOKEN env var or: bareclaw config set discord_token <token>"
        )

    env = os.environ.copy()
    env["DISCORD_BOT_TOKEN"] = bot_token
    try:
        _discord_bot_proc = subprocess.Popen(
            [str(BINARY), "channel", "discord"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        time.sleep(2)  # let it attempt to connect
        if _discord_bot_proc.poll() is not None:
            stdout = (_discord_bot_proc.stdout.read() or b"").decode()
            stderr = (_discord_bot_proc.stderr.read() or b"").decode()
            _discord_bot_proc = None
            return f"Bot exited immediately.\nstdout: {stdout}\nstderr: {stderr}"
        return f"Bot started (PID {_discord_bot_proc.pid})"
    except Exception as e:
        return f"Failed to start bot: {e}"


@mcp.tool()
def discord_stop_bot() -> str:
    """Stop the BearClaw Discord bot that was started via discord_start_bot().

    Sends SIGTERM to the subprocess and waits up to 5 seconds. Force-kills
    if it does not exit in time.
    """
    global _discord_bot_proc
    if _discord_bot_proc is None:
        return "No bot is running (not started via discord_start_bot)."
    if _discord_bot_proc.poll() is not None:
        _discord_bot_proc = None
        return "Bot had already exited."
    pid = _discord_bot_proc.pid
    _discord_bot_proc.terminate()
    try:
        _discord_bot_proc.wait(timeout=5)
        _discord_bot_proc = None
        return f"Bot (PID {pid}) stopped cleanly."
    except subprocess.TimeoutExpired:
        _discord_bot_proc.kill()
        _discord_bot_proc = None
        return f"Bot (PID {pid}) force-killed after timeout."


@mcp.tool()
def discord_conversation(prompt: str, timeout_seconds: int = 30, channel_id: str = "") -> str:
    """Send a message to BearClaw via Discord and wait for its reply.

    Full end-to-end conversation loop:
      1. Starts the BearClaw bot if not already running.
      2. Records the latest message snowflake as a baseline.
      3. Posts `prompt` as the Claude tester bot.
      4. Polls every 2s for a reply from the BearClaw bot (any bot that is
         not the tester identity).
      5. Returns the first BearClaw reply found, or a timeout error.

    Args:
        prompt: The message text to send to BearClaw.
        timeout_seconds: Max wait for a reply (5–120s, default 30s).
        channel_id: Optional channel ID override.

    Returns:
        BearClaw's reply text, or a descriptive timeout/error message.
    """
    global _discord_bot_proc
    ch = channel_id or _discord_test_channel_id()
    if not ch:
        return "Error: no channel ID. Set DISCORD_TEST_CHANNEL_ID in mcp/.venv/.env"

    timeout_seconds = min(max(timeout_seconds, 5), 120)

    # 1. Start bot if needed
    bot_was_running = _discord_bot_proc is not None and _discord_bot_proc.poll() is None
    if not bot_was_running:
        start_result = discord_start_bot()
        if any(w in start_result for w in ("Error", "Failed", "exited")):
            return f"Could not start BearClaw bot: {start_result}"

    # 2. Identify tester bot user ID so we can exclude its own messages
    tester_me = _discord_api("GET", "/users/@me")
    tester_user_id = tester_me.get("id", "") if isinstance(tester_me, dict) else ""

    # 3. Baseline: latest message ID before we send
    baseline = _discord_api("GET", f"/channels/{ch}/messages?limit=1")
    baseline_id = ""
    if isinstance(baseline, list) and baseline:
        baseline_id = baseline[0].get("id", "")

    # 4. Send prompt
    send_result = _discord_api("POST", f"/channels/{ch}/messages", {"content": prompt})
    if isinstance(send_result, dict) and "error" in send_result:
        return f"Failed to send message: {send_result['error']}"
    sent_id = send_result.get("id", "") if isinstance(send_result, dict) else ""

    # 5. Poll for BearClaw's reply
    poll_after = sent_id or baseline_id
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        time.sleep(2)
        params = "?limit=10"
        if poll_after:
            params += f"&after={poll_after}"
        msgs = _discord_api("GET", f"/channels/{ch}/messages{params}")
        if not isinstance(msgs, list):
            continue
        for msg in msgs:
            author = msg.get("author", {})
            # Accept any bot reply that is NOT the tester
            if author.get("bot") and author.get("id") != tester_user_id:
                username = author.get("username", "bareclaw")
                content = msg.get("content", "")
                return f"{username}: {content}"
        # Advance poll cursor to avoid re-reading the same messages
        if msgs:
            latest = max((m.get("id", "0") for m in msgs), default=poll_after)
            if latest > poll_after:
                poll_after = latest

    return (
        f"Timeout: no reply from BearClaw after {timeout_seconds}s.\n"
        "Make sure the bot is running and has a valid API key / provider configured."
    )


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
