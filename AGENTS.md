# AGENTS.md — BearClaw Agent Engineering Protocol

This file defines the working protocol for coding agents in this repository.
Scope: entire repository.

## 1) Project Snapshot (Read First)

BearClaw is a Zig-first autonomous agent runtime optimized for:

- high performance
- high efficiency
- minimal binary size
- embedded-first portability
- security by default
- extensibility without overhead

Core architecture is function-pointer-driven and modular. The primary extension pattern is implementing the `AnyProvider` vtable interface and registering new backends in `provider.zig`. Tool additions go in `tools.zig`, channels in `channels.zig`.

Key extension points:

- `src/provider.zig` — `Provider`, `Router`, `AnyProvider` vtable
- `src/channels.zig` — `AgentStack`, channel run functions
- `src/tools.zig` — `Tool` struct, `buildCoreTools()`
- `src/memory.zig` — `MemoryBackend`
- `src/security.zig` — `SecurityPolicy`
- `src/peripherals.zig` — hardware peripheral listing (stub, expanding)

## 2) Deep Architecture Observations

These realities should drive every design decision:

1. **No allocator-hiding** — every function that allocates takes an explicit `std.mem.Allocator`. Callers own their memory. Never stash allocators inside opaque state.
2. **Zero external dependencies** — BearClaw uses only the Zig standard library. TLS, HTTP, JSON, and crypto are all stdlib. Resist adding dependencies; they regress binary size and portability.
3. **Zig 0.14 idioms are the law** — `var` vs `const` strictness, the `tls.readAtLeast(tcp, ...)` API pattern (TLS does not own the stream), `@intCast` for type narrowing. When in doubt, check what `zig build` says.
4. **AnyProvider vtable is the stability backbone** — `agent.zig` is decoupled from concrete backends via `AnyProvider`. Adding a provider means adding a `chatFn` implementation and wiring it in `createProviderByName()`. Agent code never changes.
5. **Security surfaces are first-class** — `security.zig`, `tools.zig`, and `gateway.zig` carry real blast radius. Path policy, shell blocklist, and audit logging are not optional features; they are default behavior.
6. **Binary size and startup time are product goals** — not nice-to-have. Keep allocations tight, avoid deep indirection, and prefer stack-allocated buffers where safe.

## 3) Engineering Principles

These principles are mandatory. They are implementation constraints, not suggestions.

### 3.1 KISS (Keep It Simple)

Required:
- Prefer straightforward control flow over clever meta-programming.
- Prefer explicit match branches and typed structs over hidden dynamic behavior.
- Keep error paths obvious. Use named errors (`error.PathTraversalBlocked`) not silent fallback.

### 3.2 YAGNI (You Aren't Gonna Need It)

Required:
- Do not add config keys, struct fields, or functions without a concrete current caller.
- Do not introduce speculative "future-proof" abstractions prematurely.
- Unsupported paths must error explicitly, not silently fall back.

### 3.3 DRY + Rule of Three

Required:
- Duplicate small local logic when it preserves clarity.
- Extract shared helpers only after the same pattern appears three times and is stable.
- When extracting, keep module boundaries clean.

### 3.4 Fail Fast + Explicit Errors

Required:
- Prefer explicit errors for unsupported or unsafe states.
- Never silently broaden permissions or capabilities.
- Document intentional fallback behavior (e.g., echo mode when no API key is set).

### 3.5 Secure by Default + Least Privilege

Required:
- Deny-by-default for access and exposure.
- Never log secrets, raw tokens, or sensitive payloads.
- Keep network/filesystem/shell scope as narrow as possible.

### 3.6 Determinism + Reproducibility

Required:
- Keep builds deterministic. `zig build` with no flags must produce a working binary.
- Tests must be deterministic — no flaky timing or network dependence without explicit guards.

### 3.7 Reversibility

Required:
- Keep changes easy to revert (small scope, clear blast radius).
- For risky changes, define rollback path before implementing.

## 4) Repository Map

```
src/
├── main.zig          # CLI entrypoint and command routing
├── agent.zig         # Tool-calling agent loop
├── provider.zig      # Provider backends, Router, AnyProvider vtable
├── channels.zig      # CLI, Discord, Telegram channel implementations
├── tools.zig         # 8 built-in tools
├── memory.zig        # Markdown file-per-key memory backend
├── security.zig      # Path policy, shell blocklist, audit logging
├── config.zig        # TOML config loader, defaults, onboard wizard
├── cron.zig          # Task scheduler with TSV persistence
├── gateway.zig       # Minimal TCP/HTTP server
├── daemon.zig        # Gateway + cron combined runner
├── peripherals.zig   # Hardware peripheral listing (stub, expanding)
└── migration.zig     # OpenClaw workspace importer
```

## 5) Risk Tiers by Path

Use these when deciding validation depth.

- **Low risk**: root documentation files, `README.md`, `CHANGELOG.md`, comment-only changes
- **Medium risk**: new tools, new providers, channel behavior changes
- **High risk**: `src/security.zig`, `src/gateway.zig`, `src/tools.zig` (shell execution), path policy changes, config schema changes

When uncertain, classify higher.

## 6) Agent Workflow (Required)

1. **Read before write** — inspect the existing module, factory wiring, and adjacent code before editing.
2. **Define scope boundary** — one concern per session; avoid mixed feature + refactor patches.
3. **Implement minimal patch** — apply KISS/YAGNI/DRY rule-of-three explicitly.
4. **Validate** — always run `zig build` and `zig build test` before finishing. Both must pass with zero errors and zero warnings.
5. **Document impact** — update docs for any behavior, config schema, or interface change.

### 6.1 Code Naming Contract (Required)

- Zig casing: files `snake_case`, types/structs `PascalCase`, functions/variables `camelCase` or `snake_case` per stdlib convention, constants `SCREAMING_SNAKE_CASE`.
- Name types and modules by domain role, not implementation detail (`SecurityPolicy`, `MemoryBackend`, not `Manager`/`Helper`).
- Keep factory keys stable, lowercase, and user-facing (`"anthropic"`, `"shell"`, `"discord"`).
- Name tests by behavior/outcome: `path_traversal_blocked`, `provider_returns_error_on_missing_key`.

### 6.2 Architecture Boundary Contract (Required)

- Extend capabilities by adding implementations + wiring first; avoid cross-module rewrites.
- Dependency direction goes inward to contracts: concrete backends depend on config/policy, not on other concrete backends.
- Avoid cross-subsystem coupling (provider code must not import channel internals; tool code must not mutate gateway policy directly).
- Config schema changes are user-facing API — document defaults, compatibility impact, and migration path.

## 7) Change Playbooks

### 7.1 Adding a Provider

- Add `chatYourProvider()` function in `src/provider.zig`.
- Add variant to `ProviderKind` enum.
- Wire in `createProviderByName()`.
- Add focused tests.
- Avoid provider-specific behavior leaks into `agent.zig`.

### 7.2 Adding a Channel

- Add `runYourChannel()` in `src/channels.zig`.
- Reuse `buildStack()` for the agent stack.
- Handle token/config loading consistently with existing channels.
- Wire into `main.zig` channel dispatch.

### 7.3 Adding a Tool

- Add a new `Tool` entry in `buildCoreTools()` in `src/tools.zig`.
- Define name, description, and JSON parameters schema.
- Validate and sanitize all inputs with `ctx.policy.allowPath()` where applicable.
- Always call `ctx.policy.auditLog()` before execution.
- Handle all errors explicitly — no panics in the runtime path.

### 7.4 Security / Gateway Changes

- Include threat/risk notes and rollback strategy.
- Add or update tests for failure modes and policy boundaries.
- Keep observability useful but non-sensitive (never log secrets).

## 8) Validation Matrix

Required before finishing any code change:

```bash
zig build          # must succeed with zero errors
zig build test     # all tests must pass
```

Additional by change type:

- **Docs-only**: no build required; check markdown formatting.
- **New tool**: manually run `bareclaw agent` with a prompt that triggers the tool.
- **Security/gateway/tools**: include at least one boundary/failure-mode validation.
- **Provider**: verify with `bareclaw status` and a real or echo-mode `bareclaw agent` call.

If full checks are impractical, run the most relevant subset and document what was skipped.

## 9) Anti-Patterns (Do Not)

- Do not add external Zig packages for minor convenience.
- Do not silently weaken security policy or access constraints.
- Do not add speculative config fields "just in case".
- Do not mix large formatting-only changes with functional changes.
- Do not modify unrelated modules while implementing a feature.
- Do not bypass failing builds without explicit explanation.
- Do not hide behavior-changing side effects in refactor commits.
- Do not include personal identity or sensitive information in test data, examples, docs, or commits.

## 10) Handoff Template (Agent → Agent / Maintainer)

When handing off work, include:

1. What changed
2. What did not change
3. Validation run and results (`zig build` output, `zig build test` output)
4. Remaining risks / unknowns
5. Next recommended action

## 11) Vibe Coding Guardrails

When working in fast iterative mode:

- Keep each iteration reversible (focused changes, clear rollback).
- Validate assumptions with code search before implementing.
- Prefer deterministic behavior over clever shortcuts.
- Do not "ship and hope" on security-sensitive paths.
- If uncertain, leave a concrete `// TODO:` with verification context, not a hidden guess.
