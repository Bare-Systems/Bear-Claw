# MCP-First Development — Agent Driven Hyper Development (ADHD)

BearClaw is designed around a core principle we call **ADHD: Agent Driven Hyper Development**.

The idea is simple: AI agents should be able to build, test, run, and iterate on BearClaw itself — as fast as possible, with as little friction as possible — using BearClaw's own MCP server as the development harness.

---

## What Is ADHD?

**Agent Driven Hyper Development** is a development philosophy where:

1. **Agents are first-class developers** — not just users of the tool, but active contributors to it
2. **The feedback loop is as tight as possible** — build → test → run → inspect in seconds, not minutes
3. **Context never leaves the conversation** — the agent reads code, writes code, compiles, tests, and runs all within a single coherent session
4. **The tool builds itself** — BearClaw agents running via Telegram, Discord, or CLI can iterate on the BearClaw Zig source using the same MCP tools

This is why the MCP server exists. It is not a convenience wrapper — it is the **primary development interface** for anyone (human or agent) building BearClaw.

---

## The Development Loop

```
┌─────────────────────────────────────────────────────────────────────┐
│                    ADHD Development Loop                            │
│                                                                     │
│   read_source_file()  ──►  [edit Zig source]  ──►  build()         │
│          ▲                                              │           │
│          │                                              ▼           │
│   workspace_contents()                          run_tests()         │
│          ▲                                              │           │
│          │                                              ▼           │
│   run_agent("prompt")  ◄──  status()  ◄────────  [tests pass?]     │
│          │                                                          │
│          └──────────────────── iterate ◄────────────────────────── │
└─────────────────────────────────────────────────────────────────────┘
```

Every step is a **tool call**. No terminal. No context switching. No "open a new tab and run this." The agent stays in one conversation and closes the loop entirely through the MCP server.

---

## Why This Design?

### Traditional Development Has Friction

A human developer workflow looks like:
- Read code in editor
- Switch to terminal
- Run `zig build`, read errors
- Switch back to editor
- Fix code
- Switch back to terminal
- Repeat

For an agent, this friction is fatal — every "switch context" moment is a potential point of confusion, lost state, or compounding error. For humans who work best in flow states, it's equally costly.

### ADHD Eliminates the Context Switch

With the MCP server, the entire loop happens in one place:

```
Agent: "Let me read provider.zig first."
→ read_source_file("provider.zig")

Agent: "I see the issue. Let me fix the Anthropic tool_use translation."
→ [edits provider.zig via Claude Code file tools]

Agent: "Building now."
→ build()   # returns compiler output immediately

Agent: "Build passed. Running tests."
→ run_tests()   # returns test output immediately

Agent: "All good. Let me verify end-to-end."
→ run_agent("summarize my workspace")   # smoke test

Agent: "Working. Let me check the audit log."
→ workspace_contents()   # inspect side effects
```

The agent never leaves the conversation. The human never leaves the conversation. The loop is tight, fast, and ADHD-compatible.

---

## MCP Server Architecture

```
Claude Desktop / Claude Code
         │
         │  MCP protocol (stdio)
         ▼
   mcp/server.py  (thin Python wrapper)
         │
    ┌────┴────────────────────────────────┐
    │                                     │
    ▼                                     ▼
zig build / zig build test        zig-out/bin/bareclaw
  (build tools)                     (runtime tools)
                                         │
                               ┌─────────┴──────────┐
                               ▼                    ▼
                        src/*.zig           ~/.bareclaw/
                    (source inspection)   (config + workspace)
```

The MCP server is intentionally thin. It shells out to the Zig build system and the BearClaw binary. All intelligence lives in the Zig runtime and in the agent using the MCP tools.

---

## Tool Categories and When to Use Them

### Build Tools — Use After Every Edit

| Tool | When |
|---|---|
| `build()` | After any Zig source change |
| `run_tests()` | After build passes |
| `binary_exists()` | When unsure if build output is stale |

Always run `build()` before `run_tests()`. Always run both before `run_agent()`.

### Runtime Tools — Use to Verify Behavior

| Tool | When |
|---|---|
| `status()` | Start of every session; after config changes |
| `run_agent(prompt)` | End-to-end smoke test after build + tests pass |
| `run_cron()` | After adding or modifying cron tasks |
| `list_peripherals()` | When working on hardware integration |
| `help()` | When unsure what CLI commands exist |

### Source Tools — Use to Orient Before Editing

| Tool | When |
|---|---|
| `read_source_file(filename)` | Before editing any module |
| `list_source_files()` | When unsure which file to look at |
| `repo_structure()` | At the start of a new session |

### Config & Workspace Tools — Use to Inspect State

| Tool | When |
|---|---|
| `read_config()` | When debugging provider or channel issues |
| `workspace_contents()` | After `run_agent()` to verify memory/audit side effects |

---

## Canonical Playbooks

### Starting a New Session

```
repo_structure()             → orient: what files exist?
status()                     → orient: what's the current runtime state?
read_config()                → orient: what provider/model is active?
```

### Adding a New Provider

```
read_source_file("provider.zig")    → understand ProviderKind, AnyProvider, createProviderByName()
[edit provider.zig]
build()                              → catch compile errors
run_tests()                          → verify no regressions
status()                             → confirm provider shows up
run_agent("hello from new provider") → end-to-end test
```

### Adding a New Tool

```
read_source_file("tools.zig")        → understand Tool struct and buildCoreTools()
read_source_file("security.zig")     → understand allowPath() and auditLog() contracts
[edit tools.zig]
build()
run_tests()
run_agent("use the new tool to X")   → does the agent call it?
workspace_contents()                 → did audit.log record the call?
```

### Debugging a Channel

```
read_source_file("channels.zig")     → find the relevant channel function
status()                             → is the token configured?
read_config()                        → is the token in config.toml?
[edit channels.zig]
build()
run_tests()
[run the channel manually to test]
```

### Debugging Agent Behavior

```
run_agent("simple test prompt")      → does it respond at all?
read_source_file("agent.zig")        → inspect the tool-calling loop
read_source_file("provider.zig")     → inspect the provider implementation
status()                             → is the API key set?
read_config()                        → is the right provider/model configured?
```

---

## The Self-Improvement Loop

The deepest expression of ADHD is using BearClaw agents to improve BearClaw itself:

```
1. Start a Telegram or Discord channel session with BearClaw
2. Ask the BearClaw agent: "Read tools.zig and suggest what tool is missing"
3. Agent reads source, identifies gap, suggests implementation
4. Developer (or another agent in Claude Code) implements the suggestion
5. build() → run_tests() → run_agent() to verify
6. The improved BearClaw is now available to the same Telegram/Discord session
```

This is intentional. The runtime that processes natural language commands is also the runtime that can reason about and propose improvements to itself.

---

## Design Rules for MCP Tools

When adding new MCP tools to `mcp/server.py`:

1. **Thin wrappers only** — shell out to the binary or build system. No business logic in Python.
2. **Return full output** — never filter, summarize, or truncate compiler/test output. The agent needs to see errors verbatim.
3. **Every tool closes a loop** — a tool that requires manual follow-up ("now go run this in a terminal") defeats the purpose.
4. **Read-only inspection is free** — `read_source_file`, `workspace_contents`, `read_config` have no side effects and can be called anytime.
5. **Match the CLI** — when a new `bareclaw <command>` is added in Zig, add a corresponding MCP tool immediately. The MCP surface should mirror the CLI surface.

---

## References

- `mcp/server.py` — the MCP server implementation
- `mcp/README.md` — setup, registration, and tool reference
- `CLAUDE.md` — full agent engineering protocol (includes ADHD principle in section 0)
- `src/agent.zig` — the BearClaw agent loop that MCP `run_agent()` invokes
- `src/channels.zig` — channel implementations (Telegram, Discord) that can be used in the self-improvement loop
