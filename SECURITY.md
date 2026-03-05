# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅        |

## Reporting a Vulnerability

**Please do NOT open a public GitHub issue for security vulnerabilities.**

Report them responsibly:

1. **Email**: Contact the maintainer via GitHub private vulnerability reporting.
2. **GitHub**: Use [GitHub Security Advisories](https://github.com/your-repo/bareclaw/security/advisories/new).

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Impact assessment
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Assessment**: Within 1 week
- **Fix**: Within 2 weeks for critical issues

---

## Security Architecture

BearClaw implements defense-in-depth security. Every layer applies independently; none is optional.

### Security Checklist

| # | Item | Status | How |
|---|------|--------|-----|
| 1 | **Gateway not publicly exposed** | ✅ | Binds `127.0.0.1` by default. Refuses `0.0.0.0` without explicit config. |
| 2 | **Filesystem scoped** | ✅ | `allowPath()` enforces workspace-only access. 6 system dirs + 4 sensitive dotfiles always blocked. `..` traversal blocked. |
| 3 | **Shell command blocklist** | ✅ | Destructive patterns (`rm -rf`, `mkfs`, `dd if=`, fork bombs) rejected before execution. |
| 4 | **Audit trail** | ✅ | Append-only `workspace/audit.log` records every tool call before execution. |
| 5 | **API keys never logged** | ✅ | Config loading and provider code never emit key material to stdout or the audit log. |

### Path Security Policy

`allowPath()` in `security.zig` enforces the following rules on every `file_read`, `file_write`, and `git_operations` call:

1. **Directory traversal blocked** — any path segment equal to `..` is rejected immediately.
2. **Forbidden system path prefixes** — `/etc/`, `/root/`, `/usr/`, `/proc/`, `/sys/`, `/dev/` are always blocked.
3. **Sensitive directory patterns** — paths containing `/.ssh`, `/.gnupg`, `/.aws`, or `/.bareclaw/secrets` are rejected.
4. **Absolute path scoping** — absolute paths must be inside the configured workspace directory.
5. **Relative paths** — allowed; resolved relative to workspace.

### Shell Command Blocklist

The `shell` tool checks the command string against a blocklist before execution:

- `rm -rf` variants
- `mkfs` (filesystem format)
- `dd if=` (raw disk write)
- `:(){:|:& };:` (fork bomb)
- Additional destructive patterns

**Note:** The blocklist is a defense-in-depth layer. It is not a full sandbox. For production deployments where untrusted users control agent prompts, consider additional OS-level isolation (see `docs/sandboxing.md`).

### Audit Logging

Every tool call is logged to `~/.bareclaw/workspace/audit.log` **before** execution:

```
1700000000	shell	ls -la
1700000001	file_read	workspace/notes.md
1700000002	memory_store	last_message
```

Format: `unix_timestamp TAB tool_name TAB detail`

The log is append-only. BearClaw never reads it back or rotates it automatically. Monitor it externally or use standard log management tools.

### Provider Security

- API keys are read from environment variables and never written to logs.
- The echo provider (`kind = echo`) is the safe default when no key is configured.
- Keys are stored in `config.toml` only when the user explicitly runs `onboard`.

---

## Sandboxing

BearClaw's built-in security is workspace-scoped application-level enforcement. It does not provide OS-level process isolation by default.

For higher-assurance deployments, see `docs/sandboxing.md` for options including:
- **Firejail** — Linux seccomp + filesystem namespacing
- **Bubblewrap** — Unprivileged sandboxing (used by Flatpak)
- **Docker** — Full container isolation with `--network none` and read-only rootfs

---

## What BearClaw Protects Against

- Path traversal attacks (`../../../etc/passwd`)
- Command injection via shell tool
- Workspace escape via absolute paths or dotfile access
- Unauthorized tool calls (audit log provides traceability)
- API key exposure via logs

## What BearClaw Does NOT Currently Protect Against

- A compromised process running as the same user
- Resource exhaustion from runaway LLM API calls (rate limiting is on the roadmap)
- Network-level attacks on the gateway (currently localhost-only by design)
- Symlink escape (canonicalization-based detection is on the roadmap)
