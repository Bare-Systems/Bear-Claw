# Contributing to BearClaw

Thanks for your interest in contributing! BearClaw is optimized for embedded-first deployments. This guide will get you set up.

## Development Setup

**Requirements**: Zig 0.14+

```bash
# Clone
git clone <your-repo-url> bareclaw
cd bareclaw

# Build
zig build

# Run tests (all must pass)
zig build test

# Verify the binary works
./zig-out/bin/bareclaw status
```

### Validation (Required Before Every Commit)

```bash
zig build           # zero errors, zero warnings
zig build test      # all tests pass
```

If both pass, you're clear. There are no external linting or formatting tools required beyond the Zig compiler.

---

## Local Secret Management

BearClaw never commits API keys. Follow these rules:

### Setting Keys for Development

Use environment variables — never put keys in files you might commit:

```bash
export BARECLAW_API_KEY="sk-ant-..."      # preferred
export API_KEY="sk-ant-..."               # generic fallback
```

Channel tokens:

```bash
export DISCORD_BOT_TOKEN="Bot.your-token"
export TELEGRAM_BOT_TOKEN="1234:your-token"
```

### Pre-Commit Secret Hygiene (Mandatory)

Before every commit:

- [ ] No raw API keys in code, tests, fixtures, examples, or commit messages
- [ ] `~/.bareclaw/config.toml` is not staged (it may contain keys)
- [ ] No credentials in error output or log examples in docs
- [ ] `git diff --cached` has no secret-like strings

Quick local audit:

```bash
git diff --cached | grep -iE '(api[_-]?key|secret|token|bearer|sk-ant|sk-or)'
```

### What Must Never Be Committed

- Real API keys or tokens (plain or encoded)
- OAuth tokens or session identifiers
- Webhook signing secrets
- Personal identifiers or real user data in tests or fixtures

### If a Secret Is Committed Accidentally

1. Revoke/rotate the credential immediately
2. Purge history with `git filter-repo` or BFG Repo Cleaner
3. Force-push the cleaned history (coordinate with maintainers)
4. Ensure the value is removed from any PR/issue/comment history

---

## Collaboration Tracks (Risk-Based)

Every contribution maps to one track:

| Track | Typical scope | Required validation |
|---|---|---|
| **Track A (Low risk)** | docs, tests, comments, isolated chore | build + test pass |
| **Track B (Medium risk)** | new tools, providers, channels, memory behavior | build + test pass + manual smoke test |
| **Track C (High risk)** | `security.zig`, `gateway.zig`, path policy, shell blocklist, config schema | build + test pass + boundary test + rollback plan |

When in doubt, choose the higher track.

---

## Architecture: Extension Points

BearClaw's architecture is modular. Adding a new capability means implementing one clean addition and wiring it in — not cross-cutting rewrites.

```
src/
├── provider.zig     # LLM backends      → add chatYourProvider() + ProviderKind variant
├── channels.zig     # Messaging          → add runYourChannel()
├── tools.zig        # Agent tools        → add Tool entry in buildCoreTools()
├── memory.zig       # Persistence        → MemoryBackend interface
└── security.zig     # Policy             → SecurityPolicy
```

### Adding a Provider

Add a `chatYourProvider()` function in `src/provider.zig`, add a `ProviderKind` variant, and wire it into `createProviderByName()`:

```zig
// In provider.zig
fn chatYourProvider(
    self: *Provider,
    system: []const u8,
    user:   []const u8,
    model:  []const u8,
    temperature: f32,
) ![]u8 {
    // Build request, POST to your endpoint, parse response.
    // Return allocated []u8 owned by caller.
}
```

Then register it:

```zig
// In createProviderByName()
} else if (std.mem.eql(u8, name, "yourprovider")) {
    p.kind    = .your_provider;
    p.api_key = try allocator.dupe(u8, api_key);
    p.base_url = try allocator.dupe(u8, "https://api.yourprovider.com");
```

### Adding a Channel

Add `runYourChannel()` in `src/channels.zig`. Reuse `buildStack()` for the agent stack:

```zig
pub fn runYourChannel(cfg: *const config_mod.Config) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = try buildStack(allocator, cfg);
    defer stack.deinit(allocator);

    // Your receive/send loop here.
    // Call stack.any_provider.chatOnce(...) for each message.
}
```

Wire it into `main.zig`'s channel dispatch block.

### Adding a Tool

Add a new `Tool` entry in `buildCoreTools()` in `src/tools.zig`:

```zig
Tool{
    .name        = "your_tool",
    .description = "Does something useful",
    .parameters  = "{ \"type\": \"object\", \"properties\": { \"input\": { \"type\": \"string\" } }, \"required\": [\"input\"] }",
    .executeFn   = executeYourTool,
    .policy      = policy,
    .memory      = memory,
},
```

In `executeYourTool`, always call `ctx.policy.auditLog("your_tool", detail)` before execution and `ctx.policy.allowPath(path)` for any path arguments.

---

## Code Naming Conventions (Required)

- **Zig casing**: files `snake_case`, types/structs `PascalCase`, functions/variables `camelCase` or `snake_case` per context, constants `SCREAMING_SNAKE_CASE`.
- **Domain-first naming**: prefer `SecurityPolicy`, `MemoryBackend`, `AnyProvider` over `Manager`/`Helper`/`Util`.
- **Factory keys**: keep lowercase and stable (`"anthropic"`, `"discord"`, `"shell"`). Don't add aliases without good reason.
- **Tests**: use behavior-oriented names (`path_traversal_blocked`, `provider_echoes_without_key`).

### Naming Examples

| ❌ Bad | ✅ Good |
|---|---|
| `Manager`, `Helper` | `SecurityPolicy`, `MemoryBackend` |
| `doStuff()` | `sendMessage()`, `allowPath()` |
| `test1`, `works` | `shell_blocklist_rejects_rm_rf` |
| `john_user` | `bareclaw_user`, `bareclaw_agent` |

---

## Architecture Boundary Rules (Required)

- Extend via addition + wiring first. Avoid cross-module rewrites for isolated features.
- Dependency direction: concrete backends depend on `config`, `security`, `memory` contracts — not on each other.
- No cross-subsystem coupling. Provider code must not import channel internals. Tool code must not mutate gateway policy directly.
- Config schema keys are user-facing API. Document defaults, compatibility impact, and migration path for any changes.

### Boundary Examples

| ❌ Bad | ✅ Good |
|---|---|
| Channel imports provider internals to call model APIs | Channel calls `stack.any_provider.chatOnce()` via vtable |
| Tool mutates security policy from execution path | Tool calls `ctx.policy.allowPath()` and returns `ToolResult` |
| Adding broad abstraction before any repeated caller | Keep local logic first; extract after rule-of-three evidence |

---

## Commit Convention

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add Anthropic provider
feat(provider): add Ollama backend
fix: path traversal edge case with absolute paths
docs: update contributing guide
test: add shell blocklist tests
refactor: extract common TLS read helpers
chore: update build.zig for Zig 0.14.1
```

Recommended scope keys: `provider`, `channel`, `tool`, `memory`, `security`, `gateway`, `cron`, `docs`, `tests`

---

## Pull Request Checklist

- [ ] `zig build` passes with zero errors
- [ ] `zig build test` passes with zero failures
- [ ] Manual smoke test run for any user-facing behavior change
- [ ] README updated if adding user-visible features
- [ ] CHANGELOG.md updated under `[Unreleased]`
- [ ] No external dependencies added without explicit justification
- [ ] Follows code naming conventions and architecture boundary rules
- [ ] No personal/sensitive data in code, docs, tests, fixtures, or commit messages
- [ ] Test names/fixtures are neutral and project-scoped (`bareclaw_user`, not real names)

---

## Reporting Issues

- **Bugs**: Include OS, Zig version, steps to reproduce, expected vs actual behavior.
- **Features**: Describe the use case and which extension point you'd use.
- **Security**: See [SECURITY.md](SECURITY.md) for responsible disclosure.
- **Privacy**: Redact all personal data and sensitive identifiers before posting logs or payloads.

---

## Code Style

- **Zero external dependencies** — every package adds to binary size and portability risk.
- **Explicit error handling** — use `try`/`catch`/`!` return types. Never `unreachable` in production paths.
- **No silent failures** — raise errors, don't swallow them.
- **Audit everything** — tool execution paths must call `auditLog()` before acting.
- **`const` by default** — only use `var` when mutation is actually required (Zig will catch this).

## License

By contributing, you agree your contributions will be licensed under the same license as this project. See [LICENSE](LICENSE).
