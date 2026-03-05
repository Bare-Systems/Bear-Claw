# Changelog

All notable changes to BearClaw will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **OpenClaw migration** — `bareclaw migrate` imports memory from `~/.openclaw/workspace`.
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
