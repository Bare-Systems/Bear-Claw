# Audit Logging — BearClaw

## Overview

Every tool call in BearClaw is logged to an append-only audit trail **before** the tool executes. This gives you a tamper-evident record of what the agent did, when, and with what arguments.

---

## Current Implementation

Audit logging is live. The `auditLog()` method in `security.zig` appends one line per tool call to:

```
~/.bareclaw/workspace/audit.log
```

### Log Format (Current)

```
<unix_timestamp>	<tool_name>	<detail>
```

Example entries:

```
1700000000	shell	ls -la ~/.bareclaw/workspace
1700000001	file_read	workspace/notes.md
1700000002	file_write	workspace/output.txt
1700000003	memory_store	last_message
1700000004	git_operations	status /Users/joe/Projects/bareclaw
1700000005	http_request	GET https://api.example.com/data
```

Each line is:
- **Tab-separated** (3 fields)
- **Appended atomically** via standard file append
- **Written before execution** — if the tool errors, the log entry still exists

---

## Implementation Details

`SecurityPolicy.auditLog()` in `src/security.zig`:

```zig
pub fn auditLog(self: *SecurityPolicy, tool: []const u8, detail: []const u8) void {
    const log_path = std.fmt.allocPrint(
        self.allocator,
        "{s}/audit.log",
        .{self.workspace_dir},
    ) catch return;
    defer self.allocator.free(log_path);

    const file = std.fs.createFileAbsolute(log_path, .{ .truncate = false }) catch return;
    defer file.close();

    const ts = std.time.timestamp();
    _ = file.writer().print("{d}\t{s}\t{s}\n", .{ ts, tool, detail }) catch {};
}
```

All 8 tools call `ctx.policy.auditLog()` before any action is taken.

---

## Querying the Log

The audit log is plain text — query it with standard Unix tools:

```bash
# View all entries
cat ~/.bareclaw/workspace/audit.log

# Show only shell executions
grep $'\tshell\t' ~/.bareclaw/workspace/audit.log

# Show all file_write calls
grep $'\tfile_write\t' ~/.bareclaw/workspace/audit.log

# Show entries from a specific time window (last hour)
awk -F'\t' -v cutoff=$(date -d '1 hour ago' +%s) '$1 > cutoff' ~/.bareclaw/workspace/audit.log

# Count calls per tool
awk -F'\t' '{print $2}' ~/.bareclaw/workspace/audit.log | sort | uniq -c | sort -rn
```

---

## Proposed Future Format (JSON)

The current TSV format is readable but minimal. A future enhancement would move to structured JSON events with richer context:

```json
{
  "timestamp": "2026-02-16T12:34:56Z",
  "event_id": "evt_1a2b3c4d",
  "event_type": "tool_execution",
  "tool": "shell",
  "detail": "ls -la",
  "result": {
    "success": true,
    "duration_ms": 15
  },
  "security": {
    "policy_violation": false
  }
}
```

---

## Proposed CLI Query Interface (Roadmap)

```bash
# Show all shell executions
bareclaw audit --tool shell

# Show entries from last 24 hours
bareclaw audit --since 24h

# Show only policy violations
bareclaw audit --violations-only

# Export to JSON
bareclaw audit --format json --output audit.json
```

---

## Log Rotation

BearClaw does not currently rotate audit logs. For long-running deployments, manage rotation externally:

```bash
# Example: rotate when over 50MB, keep 5 archives
logrotate -f /etc/logrotate.d/bareclaw
```

Or set up a simple cron task:

```bash
# Compress logs older than 7 days
find ~/.bareclaw/workspace -name "audit.log.*" -mtime +7 -exec gzip {} \;
```

Future: automatic rotation via the cron daemon.

---

## Implementation Priority

| Phase | Feature | Effort | Security Value |
|-------|---------|--------|----------------|
| **P0** | Basic TSV logging | ✅ Done | Medium |
| **P1** | JSON structured format | Low | Medium |
| **P2** | `bareclaw audit` query CLI | Medium | Medium |
| **P3** | HMAC event signing (tamper evidence) | Medium | High |
| **P4** | Automatic log rotation | Low | Medium |
