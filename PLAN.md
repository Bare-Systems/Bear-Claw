# BearClaw — Review & Feature Plan
---

## How to Read This Document

This document is grouped into three tiers:

- **Tier 1 — Fix Now:** bugs, security issues, and reliability problems. These block everything else.
- **Tier 2 — Build Next:** features both reviews identify as foundational to any real agent capability.
- **Tier 3 — Build Later:** higher-order capabilities that depend on Tier 2 being solid first.

---

## Portfolio Alignment (Iterations 1-2)

This section tracks only the BearClaw-owned items assigned in `PORTFOLIO-PRIORITY.md`.

### Iteration 1 (Weeks 1-2): Tier-1 reliability/security fixes

- [ ] Tool-call parsing robustness
- [ ] Context budget limits
- [ ] Shell injection hardening for git tool
- [ ] MCP startup error surfacing
- [ ] Agent-loop test coverage

### Iteration 2 (Weeks 3-4): Gateway + automation wiring

- [x] Production-grade gateway middleware baseline (auth/validation/audit)
- [ ] Cron-to-agent prompt execution path
- [ ] Transcript/session persistence in BearClaw runtime

---

## Remote Secure Access MVP Track (Tardigrade -> BearClaw)

Status: in progress

- [x] add `bareclaw tardigrade` orchestration command as product entrypoint
- [x] auto-launch local `bareclaw gateway` + external `tardigrade` process
- [ ] make Tardigrade itself the HTTPS edge and remove the current Caddy sidecar dependency
- [x] auto-generate self-signed TLS cert/key when none provided
- [x] generate bearer key, inject SHA-256 hash into Tardigrade env config
- [x] print public endpoint + bearer key at startup for iPhone pairing
- [x] emit copy/paste pairing payload protocol (`endpoint`, `bearer_token`, `cert_sha256`)
- [x] keep gateway bound to `127.0.0.1` (internal trust boundary)
- [x] publish Linux binary artifact to GitHub Releases (`bareclaw-linux-x86_64.tar.gz`)
- [x] document release download/install path in README (`releases/latest/download`)
- [x] add `POST /v1/chat` internal endpoint
- [x] parse `ChatRequest.message` and run single-turn agent execution
- [x] return iOS-compatible `ChatResponse` envelope:
  - `message` object with `id`, `role`, `content`, `timestamp`
  - `requires_confirmation` (default `false`)
  - `confirmation_reason` (default `null`)
- [x] return structured error envelopes with `request_id`
- [ ] add a deployment-oriented mode that writes or prints the direct Tardigrade env/config needed for manual or service-managed installs
- [ ] verify the auth contract end-to-end against Tardigrade using `Authorization: Bearer`, matching the pairing payload and iOS client behavior
- [ ] add a smoke/integration path that proves `BearClawiOS -> Tardigrade HTTPS -> BearClaw localhost gateway` without Caddy in the request path
- [ ] enforce hard agent execution timeout with cancellation

---

## Where the Reviews Agree

Both reviews independently identified the same core gaps. These are high-confidence findings:

| Finding | Review A | Review B |
|---|---|---|
| Cron scheduler doesn't actually run on a schedule | ✓ (Feature Gap) | ✓ (Limitation #4) |
| Memory is shallow — no history, no semantic search | ✓ (Feature Gap) | ✓ (Limitation #2) |
| No conversation history across turns | ✓ (Feature Gap) | ✓ (Limitation #2) |
| Cron tasks not wired to agent prompts | ✓ (Feature Gap) | ✓ (Enhancement #3) |
| Stubs (migrate, peripherals) need to be resolved | ✓ (Weakness #5) | ✓ (implied by architecture section) |
| Security policy needs attention as new tools are added | ✓ (git injection) | ✓ (Enhancement #7) |
| Tool introspection tooling is insufficient | ✓ (Feature Gap) | ✓ (Limitation #5) |

---

## Where the Reviews Diverge

These findings were raised by only one review and should be taken seriously precisely because the other review missed them:

### Only in Review A (code-level, actionable immediately)
- **Tool-calling loop is structurally fragile** — silent failure when models produce prose-wrapped JSON. This is the highest-risk finding in the entire codebase.
- **Context window accumulation is unbounded** — tool results grow without limit, silently blowing past model context windows.
- **`SecretStore` writes plaintext credentials** — inert today, dangerous if wired up.
- **Shell injection in `git_operations` `extra` field** — `path` is validated but `extra` is not.
- **MCP server startup failures are silent** — the agent proceeds with no tools and the user doesn't know.
- **`mcp_servers` missing from `config set`** — the config key can't be set via CLI.
- **No agent loop test coverage** — smoke tests pass while tool-calling is broken.

### Only in Review B (capability-level, longer horizon)
- **No planner/reflector module** — the agent dispatches tools but can't decompose a high-level goal into a multi-step plan.
- **No user profile / preferences** — every session starts from zero, no persistent model of the user.
- **No personality / system prompt customization** — tone and character are hardcoded in `agent.zig`.
- **No reflective summaries** — no mechanism for the agent to learn from past task outcomes.
- **AutoTrader-specific planning templates** — trading-domain workflows could be first-class, not improvised.
- **Timeout enforcement in long-running tool calls** — a hanging tool blocks the entire agent indefinitely.

---

## Tier 1 — Fix Now (Bugs, Security, Reliability)

These are blockers. Nothing in Tier 2 or Tier 3 is reliable until these are addressed.

### T1-1: Tool-Calling Loop Reliability
**Source:** Review A (Weakness #1)
**Risk:** High — tool calls silently fail with no user feedback

The agent parses model output as strict JSON. Any prose wrapping causes silent failure. Fix approach:
- Strip markdown code fences and leading/trailing whitespace before JSON parse
- Try to extract a JSON object from within a prose response (scan for `{` ... `}`)
- If parsing still fails, log a warning and surface it to the user rather than treating it as a final reply
- Add a mock-provider unit test that returns prose-wrapped JSON and verifies dispatch still succeeds

### T1-2: Context Window Budget Management
**Source:** Review A (Weakness #2), Review B (implied by memory enhancement)
**Risk:** High — silent context overflow degrades model responses unpredictably

Tool result context grows unbounded. Fix approach:
- Add a `MAX_CONTEXT_CHARS` constant (configurable, default ~12,000 chars — safe for most models)
- Before appending a new tool result to context, check accumulated length
- If over budget: truncate the oldest results first, append a `[truncated]` marker
- Emit a visible warning to the user when truncation occurs

### T1-3: Shell Injection in `git_operations`
**Source:** Review A (Weakness #4)
**Risk:** Medium — crafted `extra` argument could inject shell metacharacters

Fix approach:
- Strip or reject `extra` values containing shell metacharacters: `;`, `&&`, `||`, `|`, `` ` ``, `$`, `>`, `<`, `\n`
- Or better: refactor `git_operations` to use `std.process.Child` with explicit argv (no shell interpolation) instead of building a shell command string

### T1-4: `SecretStore` Plaintext Credentials
**Source:** Review A (Weakness #3)
**Risk:** Medium (currently inert, dangerous if activated)

Fix approach:
- Either: enforce `chmod 600` on the secrets file after writing and add a warning in the output
- Or: remove `SecretStore` entirely until a proper secrets backend is designed
- Do not wire `SecretStore` into any command path until this is resolved

### T1-5: MCP Server Startup Failures Must Surface
**Source:** Review A (Weakness #7)
**Risk:** Medium — agent silently loses all MCP tools with no user feedback

Fix approach:
- Collect startup errors from `buildMcpTools()` and return them alongside the tool list
- In the `agent` command handler, print a warning for each failed server before starting the agent loop
- In `bareclaw doctor`, add a check that probes each configured MCP server and reports pass/fail

### T1-6: Add `mcp_servers` to `config set`
**Source:** Review A (Feature Gap)
**Risk:** Low but high friction — users can't configure MCP servers via CLI

Fix approach:
- Add `mcp_servers` to the `setKey()` match block in `config.zig`
- Add it to the `config set` help output in `main.zig`
- Validate the format (`name=command|name2=command2`) and return a clear error on invalid input

### T1-7: Agent Loop Test Coverage
**Source:** Review A (Weakness #8)
**Risk:** Medium — correctness of the core agent path is unverified

Fix approach:
- Add a mock provider (echo variant) that returns a known `tool_calls` JSON payload
- Write unit tests in `agent.zig` (or a test file) that verify:
  - A valid tool call JSON is dispatched correctly
  - Prose-wrapped JSON is handled after T1-1 fix
  - Tool results are injected into the next round correctly
  - The round limit terminates cleanly

---

## Tier 2 — Build Next (Foundational Agent Capabilities)

Both reviews agree these are needed. They are sequenced — each one enables the next.

### T2-1: Conversation History
**Source:** Both reviews
**Priority:** First in Tier 2 — everything else depends on state persistence

The agent is currently fully stateless across turns in channel loop mode. Fix approach:
- Add a `messages: []Message` field to the agent run context (where `Message` is `{role, content}`)
- Accumulate user and assistant turns across rounds in channel loop mode
- Pass the full message history to `chatOnce()` instead of just the current user turn
- Apply context budget (T1-2) to the history buffer

### T2-2: Session Transcript Storage
**Source:** Review B (Enhancement #2)
**Depends on:** T2-1

After each agent session, automatically store the transcript under a timestamped memory key (`session/YYYY-MM-DDTHH:MM`). This makes history persistent across restarts and available for recall.

### T2-3: Real Cron Scheduling
**Source:** Both reviews
**Priority:** High — the daemon is currently non-functional for automation

Implement a minimal cron expression parser in `cron.zig` supporting:
- `*` (every interval)
- `*/n` (every N units)
- Specific values (`5`, `30`, etc.)
- Standard five-field format: `min hour dom mon dow`

Add `next_run` and `last_result` fields to the TSV. The daemon loop should check `next_run` on each tick and fire tasks whose time has arrived.

### T2-4: Cron Tasks Wired to Agent Prompts
**Source:** Both reviews
**Depends on:** T2-3

Extend the cron task format so a task can store a **prompt string** rather than (or in addition to) a shell command. When the daemon fires a prompt task, it calls `runAgentOnce()` and stores the result in memory under `cron/{task_id}/{timestamp}`. This is what makes BearClaw genuinely autonomous — recurring agent-driven work without user intervention.

### T2-5: Tool Output Size Limits
**Source:** Review A (Feature Gap)

`file_read` returns up to 4MB with no truncation. Cap tool output at a configurable `MAX_TOOL_OUTPUT_CHARS` (default ~8,000 chars). For `file_read`, add a `lines` or `offset` argument to support paging. Append a `[output truncated at N chars]` marker when truncation occurs.

### T2-6: Memory — `memory_list_keys()` and `memory_delete_prefix()`
**Source:** Review B (Enhancement #5)

Add two tools:
- `memory_list_keys()` — returns all stored memory keys (lists files in the memory directory)
- `memory_delete_prefix(prefix)` — deletes all memory entries whose key starts with a given prefix (useful for cleaning up session transcripts)

Both must go through `allowPath()` and `auditLog()`.

### T2-7: `agent_status()` and `audit_log_read()` Tools
**Source:** Review B (Enhancement #5)

Add two introspection tools:
- `agent_status()` — returns current provider, model, memory file count, loaded tool names, cron task count
- `audit_log_read(n)` — reads the last N lines from `audit.log` and returns them as a string

These are directly useful for the AutoTrader use case where an operator wants to know what the agent did and why.

---

## Tier 3 — Build Later (Higher-Order Capabilities)

These depend on Tier 1 being stable and Tier 2 being functional. Do not start these until T2-1 through T2-4 are complete.

### T3-1: Planner/Reflector Module (`planner.zig`)
**Source:** Review B (Enhancement #1)

Add a `planner.zig` module with a `planAndExecute()` function:
1. Send the user's goal to the provider with a structured planning prompt
2. Parse the response as a JSON step list `[{tool, args, rationale}]`
3. Execute each step via the existing tool dispatch
4. After each step, feed results back with a reflection prompt ("Continue or adjust?")
5. Expose as a `planner_execute` tool so external agents or cron tasks can invoke it

This is the single highest-leverage capability enhancement but requires T1-1 (tool-call reliability) and T2-1 (conversation history) to be solid first.

### T3-2: Timeout Enforcement for Tool Calls
**Source:** Review B (Enhancement #7)

Long-running shell commands or hung HTTP requests block the entire agent indefinitely. Add a configurable `TOOL_TIMEOUT_SECONDS` (default: 30s). For shell/HTTP tools, use `std.posix.poll` or a watchdog thread to enforce the timeout and return a `ToolResult{ .success = false, .output = "tool timed out" }`.

### T3-3: User Profile System
**Source:** Review B (Enhancement #2, #4)

Create a `profile.md` file in the workspace storing user preferences as key-value pairs (communication style, domain preferences, risk tolerance, etc.). Provide `profile_get(key)` and `profile_set(key, value)` tools. When building the system prompt in `agent.zig`, load the profile and append relevant preferences. This makes the agent feel personalized across sessions.

### T3-4: Configurable System Prompt
**Source:** Review B (Enhancement #4)

Move the hardcoded system prompt out of `agent.zig` and into config:
- Add a `system_prompt` field to `config.toml` with a sensible default
- Add `system_prompt` to `setKey()` and `config set` help
- When the system prompt is empty, fall back to the current hardcoded string

This enables persona customization without code changes.

### T3-5: Reflective Summaries
**Source:** Review B (Enhancement #4)
**Depends on:** T3-1 (planner)

After a planner session completes, send a reflection prompt: *"What went well, what could be improved, what should be remembered for next time?"* Store the reflection under `reflection/{timestamp}`. Load recent reflections into the system prompt for future sessions. This gives the agent a form of experiential memory.

### T3-6: Memory Semantic Search (TF-IDF)
**Source:** Review B (Enhancement #2)

Implement a basic TF-IDF ranking over memory entries using only Zig stdlib math. Provide a `memory_search(query)` tool that scores all memory files and returns the top N keys by relevance. This is significantly more useful than the current prefix-match recall, especially as session transcripts accumulate.

Keep this in Tier 3 because it requires T2-2 (session storage) to have meaningful data to search.

### T3-7: Implement or Remove Stubs
**Source:** Review A (Weakness #5)

`migration.zig` and `peripherals.zig` must be resolved:
- **`migration.zig`**: implement OpenClaw workspace import (copy memory files, remap keys) or remove the `migrate` command from the CLI and CHANGELOG
- **`peripherals.zig`**: either implement the peripheral listing per `docs/hardware-peripherals-design.md` or mark it as `[planned]` in the CLI help rather than listing it as a delivered feature

---

## Complete Priority Order

| # | Item | Tier | Source | Est. Complexity |
|---|---|---|---|---|
| 1 | Tool-calling loop reliability (prose JSON handling) | Fix | A | Medium |
| 2 | Context window budget management | Fix | A | Small |
| 3 | Shell injection fix in `git_operations` | Fix | A | Small |
| 4 | `SecretStore` harden or remove | Fix | A | Small |
| 5 | MCP server startup failures surface to user | Fix | A | Small |
| 6 | Add `mcp_servers` to `config set` | Fix | A | Small |
| 7 | Agent loop unit tests | Fix | A | Medium |
| 8 | Conversation history across turns | Build Next | Both | Medium |
| 9 | Session transcript storage to memory | Build Next | B | Small |
| 10 | Real cron expression parsing | Build Next | Both | Medium |
| 11 | Cron tasks wired to agent prompts | Build Next | Both | Medium |
| 12 | Tool output size limits + paging | Build Next | A | Small |
| 13 | `memory_list_keys()` + `memory_delete_prefix()` | Build Next | B | Small |
| 14 | `agent_status()` + `audit_log_read()` tools | Build Next | B | Small |
| 15 | Planner/reflector module (`planner.zig`) | Build Later | B | Large |
| 16 | Tool call timeout enforcement | Build Later | B | Medium |
| 17 | User profile system | Build Later | B | Medium |
| 18 | Configurable system prompt | Build Later | B | Small |
| 19 | Reflective summaries | Build Later | B | Medium |
| 20 | Memory semantic search (TF-IDF) | Build Later | B | Large |
| 21 | Implement or remove stubs (migrate, peripheral) | Build Later | A | Medium |

---

## Notes on AutoTrader Integration

Both reviews reference AutoTrader. The MCP naming convention (`autotrader__toolname`) is already correct. The enhancements that most directly benefit the AutoTrader use case are:

- **T1-5** (surface MCP failures) — you need to know if `trader mcp serve` fails to start
- **T2-4** (cron → agent prompts) — enables scheduled trading analysis without user intervention
- **T2-7** (`audit_log_read`) — surfaces what the agent did during an automated trading session
- **T3-1** (planner) — enables multi-step workflows like "analyse market → decide → execute → report"
- **T3-3** (user profile) — stores trading preferences (risk tolerance, strategy preference, position sizing)

---

## What Not to Build

Both reviews implicitly agree on what to leave out:

- **External dependencies** — no Zig packages, no C libraries. TF-IDF is acceptable; importing a vector DB is not.
- **Streaming** — both reviews mentioned it, but it's a UX polish item that doesn't unblock any of the above. Not in the plan.
- **Encryption for secrets** — doing this properly (key management, OS keychain integration) is complex and out of scope for the current phase. Remove `SecretStore` instead.
- **Full cron expression syntax** — support `*/n`, `*`, and specific values. POSIX-full cron syntax (ranges, lists, named days) is unnecessary for this use case.
