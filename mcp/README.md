# BearClaw MCP Server 🐻

The agent-driven development harness for BearClaw. This is the **primary development interface** — not a convenience wrapper. It exists so AI agents can close the full build-test-run-inspect loop without a terminal, without context switching, and without friction.

---

## The Philosophy: MCP-First, ADHD

**ADHD = Agent Driven Hyper Development.**

BearClaw is built by agents, for agents, using agents.

Most dev tools assume a human is at the keyboard. BearClaw assumes an agent is in the loop. The MCP server is the mechanism that makes agent-driven development **fast and tight**:

```
Agent reads source → edits code → build() → run_tests() → run_agent() → reads output → iterates
      ↑                                                                                    ↓
      └────────────────────────── tight feedback loop ◄──────────────────────────────────┘
```

### Why This Matters

Traditional development has friction: open terminal, run command, read output, switch back to editor, repeat. For an AI agent — or a human with ADHD — that friction compounds into lost flow, lost context, and slower iteration.

The MCP server eliminates that friction. Every part of the BearClaw development cycle is a **tool call**:

- Understand the codebase → `read_source_file()`, `repo_structure()`
- Write code → Claude Code's file tools (Edit, Write)
- Compile → `build()`
- Verify → `run_tests()`
- Inspect → `status()`, `read_config()`, `workspace_contents()`
- End-to-end test → `run_agent("your prompt here")`

The agent stays in one conversation. One context. No terminal tabs. No copy-pasting output. No "now run this command." Just a tight loop that produces working Zig.

### Self-Bootstrapping: BearClaw Builds BearClaw

The deeper principle is that BearClaw agents — running via Telegram, Discord, or CLI — can be used to iterate on the BearClaw runtime itself. The MCP server makes the boundary between "using BearClaw" and "building BearClaw" intentionally thin. This is the embedded-AI equivalent of a self-hosting compiler.

---

## Prerequisites

- Python 3.10+
- [uv](https://github.com/astral-sh/uv) (`brew install uv` or `pip install uv`)
- Zig 0.14+
- The BearClaw binary built at `zig-out/bin/bareclaw` (for runtime tools)

---

## Setup

```bash
cd mcp/
uv sync
```

---

## Register with Claude 

The MCP server for BearClaw can be configured for Claude and other tools with a config like so:

```json
{
  "mcpServers": {
    "BearClaw": {
        "command": "/path/to/bareclaw/mcp/.venv/bin/python3",
        "args": ["/path/to/bareclaw/mcp/server.py"]
    }
  }
}
```

Restart Claude Desktop after saving. The `BearClaw` tools will appear in Claude's tool palette.

---

## Test Locally

```bash
# Run the server directly (stdio mode)
uv run server.py

# Inspect available tools with MCP Inspector
uv run --with mcp-inspector mcp inspect server.py
```

---

## Available Tools

### Build & Verify

| Tool | What it does |
|---|---|
| `build()` | `zig build` — debug mode by default, `release=True` for ReleaseSafe |
| `run_tests()` | `zig build test` — all unit tests must pass |
| `binary_exists()` | Check if `zig-out/bin/bareclaw` exists and show its size |

### Runtime Inspection

| Tool | What it does |
|---|---|
| `status()` | `bareclaw status` — provider, model, memory backend, API key state, cron count |
| `run_agent(prompt)` | `bareclaw agent "<prompt>"` — single-turn agent call with tool-calling |
| `run_cron()` | `bareclaw cron` — run all enabled cron tasks once |
| `list_peripherals()` | `bareclaw peripheral` — list configured hardware peripherals |
| `help()` | `bareclaw` (no args) — show CLI usage |

### Source Inspection

| Tool | What it does |
|---|---|
| `list_source_files()` | List all `.zig` files in `src/` with sizes |
| `read_source_file(filename)` | Read a specific file from `src/` (e.g. `"provider.zig"`) |
| `repo_structure()` | Top-level directory layout |

### Config & Workspace

| Tool | What it does |
|---|---|
| `read_config()` | Read `~/.bareclaw/config.toml` |
| `workspace_contents()` | List all files in `~/.bareclaw/workspace/` |

---

## The Canonical Agent Development Loop

When building or debugging a BearClaw feature, use this loop:

```
1. read_source_file("provider.zig")   → understand current code
2. [edit source via Claude Code]       → make the change
3. build()                             → catch compile errors immediately
4. run_tests()                         → verify nothing broke
5. status()                            → confirm runtime config
6. run_agent("test prompt")            → end-to-end smoke test
7. workspace_contents()                → inspect side effects (memory, audit log)
8. → iterate
```

**Keep iterations small.** One concept per loop. The goal is fast feedback — catch the error in step 3, not after 10 more steps of work.

### Example: Adding a New Tool

```
read_source_file("tools.zig")          → understand Tool struct and buildCoreTools()
read_source_file("security.zig")       → understand allowPath() and auditLog()
[edit tools.zig to add new tool]
build()                                → does it compile?
run_tests()                            → do existing tests still pass?
run_agent("use my_new_tool on X")      → does the agent call it correctly?
workspace_contents()                   → did the audit log capture the call?
```

### Example: Debugging a Provider

```
status()                               → what provider/model is active?
read_config()                          → what's in config.toml?
read_source_file("provider.zig")       → inspect the provider implementation
run_agent("hello")                     → does it respond?
[edit provider.zig]
build()
run_agent("hello")                     → fixed?
```

---

## Architecture

The MCP server is intentionally thin:

```
mcp/server.py
    ↓ shells out to
zig-out/bin/bareclaw    (runtime tools: status, agent, cron, etc.)
zig build               (build tools: build, test)
src/*.zig               (source tools: read_source_file, list_source_files)
~/.bareclaw/            (config tools: read_config, workspace_contents)
```

No Zig code lives in the MCP server. No business logic. The server is a thin translation layer between MCP tool calls and the BearClaw CLI + build system. All intelligence is in the Zig binary and the agent using these tools.

---

## Design Principles

1. **Every tool call closes a loop** — no tool should require follow-up "now go do X manually"
2. **Immediate feedback** — `build()` returns the full compiler error, `run_tests()` returns the full test output. No filtering, no summaries that hide the error.
3. **Transparent state** — the agent can always know the full state of the system via `status()`, `read_config()`, `workspace_contents()`
4. **No side effects without intent** — source inspection tools are read-only. The agent explicitly builds and runs; inspection never modifies anything.
5. **Stay in the loop** — every tool is designed to keep the agent in context, not bounce it to a terminal or another interface

---

## Adding New MCP Tools

When a new BearClaw CLI command is added, add a corresponding MCP tool in `server.py`:

```python
@mcp.tool()
def your_new_command(arg: str) -> str:
    """One-line description of what this does.

    Args:
        arg: Description of the argument.
    """
    result = _run([str(BINARY), "your-command", arg])
    return _format(result)
```

Keep tools thin. Shell out to the binary. Return the full output. Let the agent interpret it.
