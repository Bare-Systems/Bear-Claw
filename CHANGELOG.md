# Changelog

All notable changes to BearClaw will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - unreleased

### Added

- `tardigrade` command to orchestrate a public edge deployment from BearClaw:
  - launches local BearClaw gateway process
  - launches Tardigrade process with edge env configuration on internal HTTP port
  - launches Caddy TLS reverse-proxy so public endpoint is HTTPS by default
  - generates bearer token and passes token hash to Tardigrade auth allowlist
  - prints public endpoint + bearer token for mobile pairing
  - prints cert SHA-256 fingerprint and copy/paste pairing payload (`JSON` + `tardi1:` compact code)
- Internal localhost chat gateway endpoint `POST /v1/chat` in `src/gateway.zig`.
- Gateway request parsing and JSON validation for `{ "message": "..." }`.
- Single-turn agent execution path for gateway requests using existing provider/tools stack.
- iOS-compatible chat response envelope with:
  - `message` payload (`id`, `role`, `content`, `timestamp`)
  - `requires_confirmation: false`
  - `confirmation_reason: null`
- Structured JSON error envelopes containing `request_id`.
- `X-Correlation-ID` echo support on gateway responses when provided by caller.
- Audited `file_patch` editing support across BearClaw and the development MCP server:
  - Added `file_patch` to the core Zig tool registry with strict `add`, `update`, and `delete` operations.
  - `update` now rejects stale or ambiguous context, `delete` requires exact file-content match, and every successful mutation is path-validated and logged to `audit.log` before it executes.
  - Added unit coverage for stale context rejection, path traversal blocking, multi-file patching, and delete-then-create on the same path.
  - Added matching `file_patch(patch_json)` support to `mcp/server.py` so external MCP clients can apply the same patch shape against the BearClaw repo.

### Fixed

- Provider upstream failures (OOM, 5xx, connection refused) no longer return HTTP 200 with raw error text embedded in the response body. They now return the correct HTTP status code and a structured JSON error envelope with a `retryable` field:
  - `429` from upstream → `429 Too Many Requests` + `{ "code": "provider_rate_limited", "retryable": true }`
  - `4xx` from upstream → `502 Bad Gateway` + `{ "code": "provider_error", "retryable": false }`
  - `5xx` from upstream → `502 Bad Gateway` + `{ "code": "provider_error", "retryable": false }`
  - Connection refused / network unreachable → `503 Service Unavailable` + `{ "code": "provider_unavailable", "retryable": true }`
- `agent_timeout` error response now also includes `"retryable": false` for envelope consistency.

### Changed

- Ignored the repository-root `blink.toml` and `BLINK.md` and stopped tracking them so homelab-specific Blink targets and operator notes stay local-only.

## [0.2.0] - 2026-02-13

### Added

- **Anthropic (Claude) provider** — Native Messages API (`POST /v1/messages`) with `x-api-key` auth.
  `tool_use` blocks are automatically translated to the internal OpenAI-compatible format so the agent loop is provider-agnostic.
- **Multi-provider routing (fallback chain)** — `Router` struct tries providers in priority order and returns the first successful response. Configure via `fallback_providers` in config.
- **`AnyProvider` vtable** — Type-erased wrapper using function pointers so `agent.zig` works identically with a single `Provider` or a multi-provider `Router`.
- **Discord channel** — TLS WebSocket connection to Discord Gateway (`gateway.discord.gg:443`). Handles WebSocket upgrade, `Identify` payload, heartbeats, ping/pong frames, and `MESSAGE_CREATE` dispatch events. Sends replies via Discord REST API.
- **Telegram channel** — Long-polling via `getUpdates` (30-second timeout) with automatic offset advancement. Sends replies via `sendMessage`.
- **`git_operations` tool** — Runs git subcommands (`status`, `log`, `diff`, `add`, `commit`, `push`, `pull`, `clone`, `init`, `branch`, `checkout`, `fetch`, `stash`) in a workspace path via `/bin/sh -c`.
- **`file_read` tool** — Read a file from workspace; path-checked via security policy.
- **`file_write` tool** — Write content to a file in workspace; path-checked.
- **`memory_recall` tool** — Retrieve a stored markdown memory entry by key.
- **`memory_forget` tool** — Delete a stored memory entry by key.
- **`http_request` tool** — Make GET or POST HTTP requests from the agent.
- **Audit logging** — Every tool call is appended to `workspace/audit.log` before execution (`unix_ts TAB tool TAB detail`).
- **Path security** — `allowPath()` rejects `..` traversal, forbidden system paths, and sensitive directories.
- **Cron scheduler** — TSV-persisted task list at `~/.bareclaw/cron.tsv`. Subcommands: `list`, `add`, `remove`, `pause`, `resume`, `run`.
- **HTTP gateway** — Minimal TCP server on `127.0.0.1:8080`. Endpoints: `GET /health`, `POST /webhook`.
- **Doctor command** — Health diagnostics: workspace write test, config check, API key check, audit log check, cron count.
- **Enriched status** — `bareclaw status` shows API key status, memory file count, and cron task count.
- **Interactive CLI channel** — `bareclaw channel loop` starts a full REPL (type `exit` to quit).
- **OpenClaw migration** — `bareclaw migrate [source_path]` imports markdown memory entries from `~/.openclaw/workspace/memory/` into BearClaw memory.
- **Multi-round tool-calling agent loop** — Up to 8 rounds (`MAX_TOOL_ROUNDS`) of tool dispatch per agent turn.
- **Ollama provider** — Local inference at `http://localhost:11434`, no API key required.
- **OpenRouter provider** — Meta-router with OpenRouter-specific headers and Bearer auth.
- **Echo provider** — Offline no-op backend for testing without an API key.

## [0.1.0] - 2026-02-13

### Added

- **Core CLI** — `onboard`, `agent`, `status`, `gateway`, `daemon`, `cron`, `channel`, `peripheral`, `migrate` commands.
- **Config system** — TOML config at `~/.bareclaw/config.toml` with sensible defaults. Created on first run.
- **Agent loop** — Single-turn agent with OpenAI-compatible tool-calling.
- **Provider** — Generic OpenAI-compatible backend, echo fallback.
- **Tools** — `shell` (sandboxed) and `memory_store`.
- **Memory** — Markdown file-per-key backend at `~/.bareclaw/workspace/memory/`.
- **Security** — Workspace sandboxing, shell command blocklist.
- **CLI channel** — Single-turn stdin/stdout.
- **Gateway stub** — HTTP server skeleton.
- **Cron stub** — Command routing scaffold.
- **Peripheral stub** — Listing scaffold.
- **Build** — `zig build` and `zig build test` wired up.
