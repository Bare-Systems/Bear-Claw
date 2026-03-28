# CLAUDE.md — BearClaw Agent Engineering Protocol

This file defines the working protocol for Claude Code in this repository.
Scope: entire repository.

---

## Agent Driven Hyper Development

The MCP server (`mcp/server.py`) is the primary development interface. All features of of BearClaw, and actions taken to develop it, shuold be wrapped in mcp tools. This is the primary entrance point for you test perform building, testing, or validation of the running system. 

### Keep MCP updated

Whenever you build a new feature leverage the MCP server to test it. If you need to added tooling to the MCP server to do this then update the `mcp/server.py` as needed.

### The Agent Development Loop

When building a new feature in BearClaw, the canonical loop is:

1. Understand the current code — `read_source_file()`, `repo_structure()`
2. Edit the source code
3. `build()` — compile and catch errors immediately
4. `run_tests()` — Zig unit tests, must be zero failures
5. `run_smoke_tests()` — binary + status + Ollama + agent round-trip (~15s)
6. `status()` — confirm runtime config looks right
7. `run_agent("test prompt")` — quick interactive smoke test
8. If touching Discord/channels: `run_integration_test_discord()` — full end-to-end (~30s)
9. Repeat from step 1

**Rule: never finish a session without all applicable test tools passing.**

## 1) Project Snapshot (Read First)

BearClaw is a **Zig 0.14** autonomous AI agent runtime ptimized for:

- zero external dependencies (Zig stdlib only)
- minimal binary size and fast startup
- embedded-first portability (Raspberry Pi, ESP32, microcontrollers)
- security by default
- extensibility without overhead

**Key extension points:**

| File | What it controls |
|---|---|
| `src/provider.zig` | LLM backends — `Provider`, `Router`, `AnyProvider` vtable |
| `src/channels.zig` | Messaging channels — `AgentStack`, channel run functions |
| `src/tools.zig` | Agent tools — `Tool` struct, `buildCoreTools()`, `buildMcpTools()` |
| `src/memory.zig` | Memory persistence — `MemoryBackend` |
| `src/security.zig` | Policy enforcement — `SecurityPolicy`, `allowPath()`, `auditLog()` |
| `src/config.zig` | Config loading — `Config`, `loadOrInit()`, `parseMcpServers()` |
| `src/mcp_client.zig` | Generic MCP client — `McpSession`, `McpSessionPool`, JSON-RPC stdio |
| `src/cron.zig` | Task scheduler — TSV persistence, subcommand dispatch |
| `src/gateway.zig` | HTTP server — `GET /health`, `POST /webhook` |
| `src/peripherals.zig` | Hardware peripheral listing (stub, expanding) |

**Current providers:** anthropic, openai, openai-compatible, ollama, openrouter, echo
**Current tools:** shell, file_read, file_write, memory_store, memory_recall, memory_forget, http_request, git_operations + any tools from configured MCP servers
**Current channels:** CLI (single-turn + loop), Discord (WebSocket Gateway), Telegram (long-polling)
**MCP servers:** zero-coupling generic client — any server wired via config at runtime

---

## 2) Critical Zig 0.14 Facts

These are not suggestions — they are compiler-enforced realities that will cause build failures if ignored.

1. **`var` vs `const` strictness** — Zig 0.14 errors on unused mutability. Declare `const` unless the binding is actually reassigned. This applies to local variables, slices, and struct fields.

2. **TLS stream API** — `std.crypto.tls.Client` does **not** own the underlying stream. Every read/write must pass the TCP stream explicitly:
   ```zig
   // Correct
   try tls.writeAll(tcp, data);
   _ = try tls.readAtLeast(tcp, buf, min_len);

   // Wrong — .stream() does not exist in Zig 0.14
   const stream = tls.stream();
   ```

3. **Integer casts** — Use `@intCast` for narrowing conversions. `buf.resize()` takes `usize`; WebSocket `payload_len` is `u64`. Always cast explicitly.

4. **Allocator discipline** — Every function that allocates takes an explicit `std.mem.Allocator`. Return values that are allocated are owned by the caller. Use `defer allocator.free(...)` consistently.

5. **Error handling** — Use `try`/`catch`/error return types everywhere in production paths. Never use `unreachable` for runtime error conditions.

---

## 3) Architecture Observations

1. **`AnyProvider` vtable is the stability backbone** — `agent.zig` never imports concrete provider backends. It calls `any_provider.chatOnce(...)` through the vtable. Adding a new provider means adding a `chatFn` and wiring it in `createProviderByName()` — `agent.zig` does not change.

2. **`buildStack()` is the canonical agent setup** — all channels use `buildStack(allocator, cfg)` to get a consistent `AgentStack` (provider + memory + policy + tools). Don't bypass it.

3. **Security surfaces have real blast radius** — `security.zig`, `tools.zig` (shell execution), and `gateway.zig` are internet-adjacent. Path policy and the shell blocklist are not optional; they are default behavior that must not be silently weakened.

4. **Config keys are user-facing API** — changes to `config.zig` fields affect `config.toml` on disk. Document defaults, compatibility, and migration path for any schema changes.

5. **Zero dependencies is a hard constraint** — do not add Zig packages or C library dependencies. Everything uses `std`. This is what keeps the binary portable to $10 hardware.

6. **MCP client is zero-coupling by design** — `mcp_client.zig` has no knowledge of any specific MCP server. Servers are wired at runtime via `mcp_servers` in config. The `McpProxyMeta` struct in `tools.zig` carries per-tool state (server argv + remote tool name). The `McpSessionPool` in `main.zig` keeps sessions alive across tool calls within one agent run. Channels that don't need MCP pass `null` for `mcp_pool`.

7. **MCP tool naming convention** — discovered MCP tools are named `servername__toolname` (double underscore). This makes them unambiguous to the LLM and parseable at dispatch time. The `tool.user_data` field carries the `*McpProxyMeta` that the proxy executeFn needs.

---

## 4) Engineering Principles

### 4.1 KISS — Keep It Simple

- Prefer straightforward control flow. Match on named error values, not opaque conditions.
- Prefer explicit struct fields over hidden dynamic behavior.
- Keep error paths obvious and localized.

### 4.2 YAGNI — You Aren't Gonna Need It

- Do not add config keys, struct fields, or functions without a concrete current caller.
- Do not add speculative abstractions. Unsupported paths must error explicitly, not silently degrade.

### 4.3 Fail Fast + Explicit Errors

- Use named errors (`error.PathTraversalBlocked`, `error.WebSocketUpgradeFailed`).
- Never silently broaden permissions or swallow errors.
- Echo mode (no API key) is the only intentional graceful fallback — document it explicitly.

### 4.4 Secure by Default

- Deny-by-default for file access, shell execution, and network exposure.
- Never log secrets, tokens, or sensitive payloads.
- All tool calls must invoke `ctx.policy.auditLog()` before execution.
- All path arguments must pass through `ctx.policy.allowPath()`.

### 4.5 Determinism

- `zig build` with no flags must produce a working binary on every commit.
- `zig build test` must pass with zero failures.
- `run_smoke_tests()` must pass before any session ends.
- `run_integration_test_discord()` must pass after any change to `channels.zig`.

---

## 5) Repository Map

```
src/
├── main.zig          # CLI entrypoint and command routing
├── agent.zig         # Multi-round tool-calling agent loop (MAX_TOOL_ROUNDS = 8)
├── provider.zig      # All LLM backends + Router + AnyProvider vtable
├── channels.zig      # CLI, Discord (WebSocket), Telegram (long-poll)
├── tools.zig         # 8 built-in tools
├── memory.zig        # Markdown file-per-key memory backend + forget()
├── security.zig      # allowPath(), auditLog(), shell blocklist
├── config.zig        # TOML config, loadOrInit(), quickOnboard()
├── cron.zig          # TSV task scheduler, subcommand dispatch
├── gateway.zig       # Minimal TCP HTTP server
├── daemon.zig        # Gateway + cron combined runner
├── mcp_client.zig    # Generic MCP client — McpSession, McpSessionPool, JSON-RPC stdio
├── peripherals.zig   # Hardware peripheral listing stub
└── migration.zig     # OpenClaw workspace importer
```

---

## 6) Risk Tiers

| Tier | Paths | Required validation |
|------|-------|---------------------|
| **Low** | root documentation files, `*.md`, comment-only | None |
| **Medium** | New tools, providers, config fields | `build()` + `run_tests()` + `run_smoke_tests()` |
| **High** | `channels.zig`, `security.zig`, `gateway.zig`, `tools.zig` (shell), `config.zig` schema | `build()` + `run_tests()` + `run_smoke_tests()` + `run_integration_test_discord()` |

When uncertain, classify higher.

---

## 7) Agent Workflow (Required)

1. **Read before write** — inspect the existing module and adjacent code before editing.
2. **Define scope** — one concern per session. Avoid mixing feature + refactor + docs in one go.
3. **Implement minimal patch** — apply KISS/YAGNI explicitly. No speculative additions.
4. **Validate** — run `zig build` and `zig build test`. Both must pass before finishing.
5. **Document** — update `CHANGELOG.md` under `[Unreleased]` for any user-visible change. Update relevant docs for config/interface changes.

### Validation (Required)

All validation is done through MCP tools — do not run raw shell commands for testing.

| Change scope | Required tools |
|---|---|
| Any code change | `build()` → `run_tests()` |
| Behavior/feature change | + `run_smoke_tests()` |
| `channels.zig` / Discord | + `run_integration_test_discord()` |
| Config schema change | + `config_get()` to verify round-trip |
| New MCP tool added | call the new tool to verify it works |

**MCP test tools reference:**
- `build()` — compile the binary, surface errors immediately
- `run_tests()` — Zig unit tests (`zig build test`)
- `run_smoke_tests()` — binary + status + Ollama + agent round-trip (~15s, no Discord)
- `run_integration_test_discord()` — full Discord bot round-trip via webhook (~30s)
- `status()` — runtime config sanity check
- `run_agent("prompt")` — single-turn agent call for interactive verification

---

## 8) Change Playbooks

### Adding a Provider

1. Add a `chatYourProvider()` function in `src/provider.zig`
2. Add a variant to `ProviderKind` enum
3. Wire into `createProviderByName()` match block
4. Test with `bareclaw agent` pointing at the new provider

Anthropic format note: Anthropic uses `POST /v1/messages`, `x-api-key` header (not Bearer), `content` as an array of blocks, and `max_tokens` is required. `extractAnthropicContent()` translates `tool_use` blocks to the internal OpenAI format — follow this pattern for any provider with a non-standard tool format.

### Adding a Channel

1. Add `runYourChannel()` in `src/channels.zig`
2. Call `buildStack(allocator, cfg)` for the agent stack
3. Read tokens from env var first, config fallback second (match existing pattern)
4. Wire into `main.zig` channel dispatch

### Adding a Tool

1. Add a `Tool` entry in `buildCoreTools()` in `src/tools.zig`
2. Implement `executeYourTool()` with a `ToolContext` parameter
3. Call `ctx.policy.auditLog("your_tool", detail)` before any action
4. Call `ctx.policy.allowPath(path)` for any path argument
5. Define a JSON parameters schema string matching what the LLM will send

### Connecting an MCP Server

BearClaw can use any MCP server as a tool source — no code changes required.

**At the command line:**
```bash
bareclaw config set mcp_servers "autotrader=trader mcp serve"
# Multiple servers: pipe-separated
bareclaw config set mcp_servers "autotrader=trader mcp serve|mybot=python /path/to/bot.py"
```

**Via MCP server tools (for agent-driven setup):**
```
mcp_add_server(name="autotrader", command="trader mcp serve")
mcp_list_servers()
mcp_list_tools(server="autotrader")
mcp_call_tool(server="autotrader", tool="get_status")
```

**Format:** `mcp_servers = "name=command arg1 arg2|name2=cmd2 ..."` in `config.toml`

**What happens at agent startup:**
1. `parseMcpServers()` splits the config string into `McpServerDef` entries
2. `buildMcpTools()` spawns each server, completes the MCP handshake, calls `tools/list`
3. Each discovered tool becomes a BearClaw `Tool` named `servername__toolname`
4. `McpSessionPool` keeps sessions alive across tool calls in one agent run

**Validation:** After adding a server, run:
```
mcp_list_tools()      → confirms server connects and exposes tools
mcp_call_tool(...)    → confirms a round-trip tool call works
run_smoke_tests()     → full binary health check
```

### Security / Gateway Changes

- Include threat/risk notes in your commit message
- Add or update tests for failure modes and policy edge cases
- Never log secrets or sensitive argument values in the audit log
- Gateway currently binds to `127.0.0.1` only — do not change this default

---

## 9) Naming Conventions

| Category | Convention | Example |
|---|---|---|
| Files | `snake_case` | `security.zig`, `provider.zig` |
| Types / structs | `PascalCase` | `SecurityPolicy`, `AnyProvider` |
| Functions | `camelCase` | `chatOnce`, `buildStack`, `allowPath` |
| Constants | `SCREAMING_SNAKE_CASE` | `MAX_TOOL_ROUNDS`, `DISCORD_API` |
| Factory keys (config) | lowercase stable strings | `"anthropic"`, `"shell"`, `"discord"` |

Name by domain role, not implementation detail:
- ✅ `SecurityPolicy`, `MemoryBackend`, `AnyProvider`
- ❌ `Manager`, `Helper`, `Wrapper`

Identity-safe naming for tests/fixtures: use `bareclaw_user`, `bareclaw_agent`, `bareclaw_bot` — not real names or personas.

---

## 10) Anti-Patterns (Do Not)

- Do not add external Zig packages or C library dependencies.
- Do not silently weaken path policy, the shell blocklist, or audit logging.
- Do not add speculative config fields or struct members.
- Do not mix large formatting or comment changes with functional changes.
- Do not modify unrelated modules while implementing a feature.
- Do not bypass `zig build` failures without an explicit explanation.
- Do not hide behavior-changing side effects in refactor commits.
- Do not include personal data, real API keys, or real tokens in any file.

---

## 11) Handoff Template (Claude → Claude / Maintainer)

When ending a session or handing off work, include:

1. **What changed** — files modified, features added, bugs fixed
2. **What did not change** — scope boundary, intentional non-goals
3. **Validation results** — `zig build` output, `zig build test` output
4. **Remaining risks / unknowns** — what wasn't tested, what might break
5. **Next recommended action** — concrete next step for whoever picks this up

---

## 12) Vibe Coding Guardrails

When working in fast iterative mode:

- Keep each iteration reversible — focused changes with clear rollback.
- Search existing code before implementing — pattern may already exist.
- Prefer deterministic behavior over clever shortcuts.
- Do not "ship and hope" on security-sensitive paths (`security.zig`, shell tool, gateway).
- If uncertain about a Zig API, check what the compiler says — it is always right.
- Leave a concrete `// TODO(bareclaw): ...` with context when deferring something, not a silent assumption.
