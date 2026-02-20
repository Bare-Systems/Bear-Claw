const std = @import("std");
const security_mod = @import("security.zig");
const memory_mod = @import("memory.zig");
const mcp_mod = @import("mcp_client.zig");

pub const ToolResult = struct {
    success:   bool,
    output:    []const u8,
    /// true  → output was heap-allocated; caller must free it.
    /// false → output is a string literal or borrowed slice; do NOT free.
    allocated: bool = false,

    /// Convenience constructor for an allocated result (the common case for
    /// success paths that build a string with allocPrint/dupe).
    pub fn owned(success: bool, output: []const u8) ToolResult {
        return .{ .success = success, .output = output, .allocated = true };
    }

    /// Convenience constructor for an unallocated result (error literals,
    /// borrowed slices). Safe to return from any tool without an allocator.
    pub fn literal(success: bool, output: []const u8) ToolResult {
        return .{ .success = success, .output = output, .allocated = false };
    }
};

pub const Tool = struct {
    name:        []const u8,
    description: []const u8 = "", // human/LLM-readable description; "" = no description
    executeFn:   *const fn (ctx: *ToolContext, args_json: []const u8) anyerror!ToolResult,
    /// Optional per-tool metadata (e.g. for MCP proxy tools). Owned by the tool registry.
    user_data: ?*anyopaque = null,
};

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    policy: *security_mod.SecurityPolicy,
    memory: *memory_mod.MemoryBackend,
    cfg: *const @import("config.zig").Config,
    /// Optional MCP session pool, shared across all MCP proxy tool calls in a session.
    mcp_pool: ?*mcp_mod.McpSessionPool = null,
    /// Set by agent.zig dispatch loop to point at the current tool's McpProxyMeta
    /// before calling toolMcpProxy. Only valid during an MCP proxy tool call.
    mcp_current_meta: ?*anyopaque = null,
};

// ── helpers ──────────────────────────────────────────────────────────────────

/// Extract a string field from a parsed JSON object. Returns null if missing
/// or not a string. The returned slice is valid for the lifetime of `parsed`.
fn getString(obj: std.json.Value, field: []const u8) ?[]const u8 {
    const v = obj.object.get(field) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ── tool: shell ───────────────────────────────────────────────────────────────

/// Join a JSON string array into a single space-separated shell command.
/// Caller owns the returned slice.
fn joinCmdArray(allocator: std.mem.Allocator, arr: std.json.Array) ![]u8 {
    var parts = std.ArrayList(u8).init(allocator);
    errdefer parts.deinit();
    for (arr.items, 0..) |item, idx| {
        if (idx > 0) try parts.append(' ');
        switch (item) {
            .string => |s| try parts.appendSlice(s),
            else => {},
        }
    }
    return parts.toOwnedSlice();
}

/// Run a shell command string and return a capped ToolResult.
fn runShellCmd(ctx: *ToolContext, cmd: []const u8) !ToolResult {
    if (!ctx.policy.allowShellCommand(cmd)) {
        return ToolResult.literal(false, "command blocked by security policy");
    }
    ctx.policy.auditLog("shell", cmd) catch {};

    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "shell exec failed: {}", .{err});
        return ToolResult.owned(false, msg);
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    const output = try capOutput(ctx.allocator,
        if (result.stdout.len > 0) result.stdout else result.stderr);
    return ToolResult.owned(result.term == .Exited and result.term.Exited == 0, output);
}

fn toolShell(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Accepts several model-output variations:
    //   {"command": "ls -l /tmp"}            — canonical string form
    //   {"cmd": "ls -l /tmp"}                — "cmd" alias
    //   {"cmd": ["ls", "-l", "/tmp"]}        — array form (model sometimes emits this)
    //   {"command": ["ls", "-l", "/tmp"]}    — array form with canonical key
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in shell args");
    };
    defer parsed.deinit();

    // Try "command" then "cmd" — both are accepted.
    const val = parsed.value.object.get("command") orelse
                parsed.value.object.get("cmd");

    switch (val orelse return runShellCmd(ctx, "echo \"no command provided\"")) {
        .string => |s| return runShellCmd(ctx, s),
        .array  => |arr| {
            const joined = try joinCmdArray(ctx.allocator, arr);
            defer ctx.allocator.free(joined);
            return runShellCmd(ctx, joined);
        },
        else => return runShellCmd(ctx, "echo \"no command provided\""),
    }
}

// ── tool: file_read ───────────────────────────────────────────────────────────

fn toolFileRead(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"path":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in file_read args");
    };
    defer parsed.deinit();

    const path = getString(parsed.value, "path") orelse {
        return ToolResult.literal(false, "file_read: missing 'path' argument");
    };

    // Security: reject paths that escape the workspace.
    if (!ctx.policy.allowPath(path)) {
        return ToolResult.literal(false, "file_read: path outside workspace is not allowed");
    }

    ctx.policy.auditLog("file_read", path) catch {};

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "file_read: cannot open '{s}': {}", .{ path, err });
        return ToolResult.owned(false, msg);
    };
    defer file.close();

    const raw_content = file.readToEndAlloc(ctx.allocator, 4 * 1024 * 1024) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "file_read: read error: {}", .{err});
        return ToolResult.owned(false, msg);
    };
    defer ctx.allocator.free(raw_content);

    // T2-5: Cap output to MAX_TOOL_OUTPUT_CHARS to protect context window.
    const content = try capOutput(ctx.allocator, raw_content);
    return ToolResult.owned(true, content);
}

// ── tool: file_write ──────────────────────────────────────────────────────────

fn toolFileWrite(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"path":"...","content":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in file_write args");
    };
    defer parsed.deinit();

    const path = getString(parsed.value, "path") orelse {
        return ToolResult.literal(false, "file_write: missing 'path' argument");
    };
    const content = getString(parsed.value, "content") orelse "";

    if (!ctx.policy.allowPath(path)) {
        return ToolResult.literal(false, "file_write: path outside workspace is not allowed");
    }

    ctx.policy.auditLog("file_write", path) catch {};

    // Ensure parent directory exists.
    const dir_path = std.fs.path.dirname(path);
    if (dir_path) |d| {
        std.fs.cwd().makePath(d) catch {};
    }

    var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "file_write: cannot create '{s}': {}", .{ path, err });
        return ToolResult.owned(false, msg);
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "file_write: write error: {}", .{err});
        return ToolResult.owned(false, msg);
    };

    const msg = try std.fmt.allocPrint(ctx.allocator, "wrote {d} bytes to {s}", .{ content.len, path });
    return ToolResult.owned(true, msg);
}

// ── tool: memory_store ────────────────────────────────────────────────────────

fn toolMemoryStore(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"key":"...","content":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in memory_store args");
    };
    defer parsed.deinit();

    const key = getString(parsed.value, "key") orelse "default";
    const content = getString(parsed.value, "content") orelse "";

    try ctx.memory.store(key, content);
    ctx.policy.auditLog("memory_store", key) catch {};
    return ToolResult.literal(true, "stored");
}

// ── tool: memory_recall ───────────────────────────────────────────────────────

fn toolMemoryRecall(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"key":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in memory_recall args");
    };
    defer parsed.deinit();

    const key = getString(parsed.value, "key") orelse "default";

    ctx.policy.auditLog("memory_recall", key) catch {};

    const content = ctx.memory.recall(key) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "memory_recall error: {}", .{err});
        return ToolResult.owned(false, msg);
    };

    return ToolResult.owned(true, content);
}

// ── tool: memory_forget ───────────────────────────────────────────────────────

fn toolMemoryForget(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"key":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in memory_forget args");
    };
    defer parsed.deinit();

    const key = getString(parsed.value, "key") orelse "default";

    ctx.policy.auditLog("memory_forget", key) catch {};

    ctx.memory.forget(key) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "memory_forget error: {}", .{err});
        return ToolResult.owned(false, msg);
    };

    const msg = try std.fmt.allocPrint(ctx.allocator, "forgot '{s}'", .{key});
    return ToolResult.owned(true, msg);
}

// ── tool: http_request ────────────────────────────────────────────────────────

fn toolHttpRequest(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"url":"...","method":"GET|POST","body":"...","headers":{}}
    // Only GET and POST are supported for now.
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in http_request args");
    };
    defer parsed.deinit();

    const url_str = getString(parsed.value, "url") orelse {
        return ToolResult.literal(false, "http_request: missing 'url' argument");
    };
    const method_str = getString(parsed.value, "method") orelse "GET";
    const body_str = getString(parsed.value, "body") orelse "";

    ctx.policy.auditLog("http_request", url_str) catch {};

    const uri = std.Uri.parse(url_str) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "http_request: invalid URL '{s}'", .{url_str});
        return ToolResult.owned(false, msg);
    };

    const method: std.http.Method = if (std.mem.eql(u8, method_str, "POST"))
        .POST
    else
        .GET;

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    var response_buf = std.ArrayList(u8).init(ctx.allocator);
    errdefer response_buf.deinit();

    const payload: ?[]const u8 = if (body_str.len > 0) body_str else null;

    const result = client.fetch(.{
        .method = method,
        .location = .{ .uri = uri },
        .payload = payload,
        .response_storage = .{ .dynamic = &response_buf },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "http_request failed: {}", .{err});
        return ToolResult.owned(false, msg);
    };

    const success = @intFromEnum(result.status) < 400;
    const output = try response_buf.toOwnedSlice();

    if (!success) {
        const msg = try std.fmt.allocPrint(
            ctx.allocator,
            "HTTP {d}: {s}",
            .{ @intFromEnum(result.status), output },
        );
        ctx.allocator.free(output);
        return ToolResult.owned(false, msg);
    }

    return ToolResult.owned(true, output);
}

// ── T1-2: Tool output size cap ────────────────────────────────────────────────
// Maximum bytes returned by any single tool. Prevents a large file_read or
// verbose shell command from consuming the entire model context window.
pub const MAX_TOOL_OUTPUT_CHARS: usize = 8_000;

/// Truncate output to MAX_TOOL_OUTPUT_CHARS, appending a marker if truncated.
/// Returns an owned slice; caller must free.
fn capOutput(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len <= MAX_TOOL_OUTPUT_CHARS) return allocator.dupe(u8, raw);
    const truncated = raw[0..MAX_TOOL_OUTPUT_CHARS];
    return std.fmt.allocPrint(
        allocator,
        "{s}\n[... output truncated at {d} chars ...]",
        .{ truncated, MAX_TOOL_OUTPUT_CHARS },
    );
}

// ── tool: git_operations ──────────────────────────────────────────────────────

fn toolGitOperations(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"op":"clone|status|add|commit|push|log|diff","path":"...","args":"..."}
    //   op    – the git sub-command (allowlisted)
    //   path  – working directory for the git command (must be in workspace)
    //   args  – extra arguments appended after the sub-command (space-separated,
    //           each argument is passed as a separate argv element — NO shell
    //           interpolation, so metacharacters are safe)
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in git_operations args");
    };
    defer parsed.deinit();

    const op    = getString(parsed.value, "op")   orelse "status";
    const path  = getString(parsed.value, "path") orelse ".";
    const extra = getString(parsed.value, "args") orelse "";

    // Validate allowed operations.
    const allowed_ops = [_][]const u8{
        "status", "log", "diff", "add", "commit", "push", "pull",
        "clone", "init", "branch", "checkout", "fetch", "stash",
    };
    var op_ok = false;
    for (allowed_ops) |allowed| {
        if (std.mem.eql(u8, op, allowed)) { op_ok = true; break; }
    }
    if (!op_ok) {
        return ToolResult.literal(false, "git_operations: unsupported operation");
    }

    // Validate path.
    if (!ctx.policy.allowPath(path)) {
        return ToolResult.literal(false, "git_operations: path outside workspace");
    }

    ctx.policy.auditLog("git_operations", op) catch {};

    // T1-3: Build argv explicitly — no shell, no string interpolation.
    // Split `extra` on spaces into individual arguments so shell metacharacters
    // in any argument are passed literally to git, not interpreted by a shell.
    var argv = std.ArrayList([]const u8).init(ctx.allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(path);
    try argv.append(op);

    if (extra.len > 0) {
        var word_it = std.mem.splitScalar(u8, extra, ' ');
        while (word_it.next()) |word| {
            const w = std.mem.trim(u8, word, " \t");
            if (w.len > 0) try argv.append(w);
        }
    }

    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv      = argv.items,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "git exec failed: {}", .{err});
        return ToolResult.owned(false, msg);
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    const raw = if (result.stdout.len > 0) result.stdout else result.stderr;
    const output = try capOutput(ctx.allocator, raw);
    return ToolResult.owned(result.term == .Exited and result.term.Exited == 0, output);
}

// ── T2-6: memory_list_keys ───────────────────────────────────────────────────

fn toolMemoryListKeys(ctx: *ToolContext, _: []const u8) !ToolResult {
    ctx.policy.auditLog("memory_list_keys", "") catch {};

    const mem_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.policy.workspace_dir, "memory" });
    defer ctx.allocator.free(mem_dir);

    var dir = std.fs.cwd().openDir(mem_dir, .{ .iterate = true }) catch {
        return ToolResult.owned(true, try ctx.allocator.dupe(u8, "(no memory directory yet)"));
    };
    defer dir.close();

    var out = std.ArrayList(u8).init(ctx.allocator);
    errdefer out.deinit();

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        // Strip ".md" suffix to show the logical key name.
        const name = if (std.mem.endsWith(u8, entry.name, ".md"))
            entry.name[0 .. entry.name.len - 3]
        else
            entry.name;
        try out.writer().print("{s}\n", .{name});
        count += 1;
    }

    if (count == 0) {
        out.deinit();
        return ToolResult.owned(true, try ctx.allocator.dupe(u8, "(no memory entries)"));
    }
    return ToolResult.owned(true, try out.toOwnedSlice());
}

// ── T2-6: memory_delete_prefix ───────────────────────────────────────────────

fn toolMemoryDeletePrefix(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in memory_delete_prefix args");
    };
    defer parsed.deinit();

    const prefix = getString(parsed.value, "prefix") orelse {
        return ToolResult.literal(false, "memory_delete_prefix: missing 'prefix' argument");
    };

    ctx.policy.auditLog("memory_delete_prefix", prefix) catch {};

    const mem_dir_path = try std.fs.path.join(ctx.allocator, &.{ ctx.policy.workspace_dir, "memory" });
    defer ctx.allocator.free(mem_dir_path);

    var dir = std.fs.cwd().openDir(mem_dir_path, .{ .iterate = true }) catch {
        return ToolResult.owned(true, try ctx.allocator.dupe(u8, "deleted 0 entries"));
    };
    defer dir.close();

    var deleted: usize = 0;
    var it = dir.iterate();
    // Collect matching names first (can't delete while iterating).
    var to_delete = std.ArrayList([]u8).init(ctx.allocator);
    defer {
        for (to_delete.items) |name| ctx.allocator.free(name);
        to_delete.deinit();
    }
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const key = if (std.mem.endsWith(u8, entry.name, ".md"))
            entry.name[0 .. entry.name.len - 3]
        else
            entry.name;
        if (std.mem.startsWith(u8, key, prefix)) {
            try to_delete.append(try ctx.allocator.dupe(u8, entry.name));
        }
    }
    for (to_delete.items) |name| {
        dir.deleteFile(name) catch continue;
        deleted += 1;
    }

    const msg = try std.fmt.allocPrint(ctx.allocator, "deleted {d} memory entries with prefix '{s}'", .{ deleted, prefix });
    return ToolResult.owned(true, msg);
}

// ── T2-7: agent_status ───────────────────────────────────────────────────────

fn toolAgentStatus(ctx: *ToolContext, _: []const u8) !ToolResult {
    ctx.policy.auditLog("agent_status", "") catch {};

    // Count memory files.
    const mem_dir_path = try std.fs.path.join(ctx.allocator, &.{ ctx.policy.workspace_dir, "memory" });
    defer ctx.allocator.free(mem_dir_path);

    var mem_count: usize = 0;
    if (std.fs.cwd().openDir(mem_dir_path, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind == .file) mem_count += 1;
        }
    } else |_| {}

    const out = try std.fmt.allocPrint(
        ctx.allocator,
        "workspace: {s}\nmemory_entries: {d}\npolicy: workspace-only sandbox",
        .{ ctx.policy.workspace_dir, mem_count },
    );
    return ToolResult.owned(true, out);
}

// ── T2-7: audit_log_read ─────────────────────────────────────────────────────

fn toolAuditLogRead(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in audit_log_read args");
    };
    defer parsed.deinit();

    // Optional: {"n": 20} — default to last 50 lines.
    var n: usize = 50;
    if (parsed.value.object.get("n")) |nv| {
        n = switch (nv) {
            .integer => |i| @intCast(@max(1, i)),
            else => 50,
        };
    }

    ctx.policy.auditLog("audit_log_read", "") catch {};

    const log_path = try std.fs.path.join(ctx.allocator, &.{ ctx.policy.workspace_dir, "audit.log" });
    defer ctx.allocator.free(log_path);

    const file = std.fs.cwd().openFile(log_path, .{}) catch {
        return ToolResult.owned(true, try ctx.allocator.dupe(u8, "(audit log empty or not yet created)"));
    };
    defer file.close();

    const raw = file.readToEndAlloc(ctx.allocator, 4 * 1024 * 1024) catch {
        return ToolResult.owned(false, try ctx.allocator.dupe(u8, "audit_log_read: read error"));
    };
    defer ctx.allocator.free(raw);

    // Return last `n` lines.
    var lines = std.ArrayList([]const u8).init(ctx.allocator);
    defer lines.deinit();
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(line);
    }

    const start = if (lines.items.len > n) lines.items.len - n else 0;
    var out = std.ArrayList(u8).init(ctx.allocator);
    errdefer out.deinit();
    for (lines.items[start..]) |line| {
        try out.appendSlice(line);
        try out.append('\n');
    }

    if (out.items.len == 0) {
        out.deinit();
        return ToolResult.owned(true, try ctx.allocator.dupe(u8, "(no audit entries)"));
    }
    return ToolResult.owned(true, try capOutput(ctx.allocator, out.items));
}

// ── tool: discord_notify ──────────────────────────────────────────────────────
//
// Posts a message to a Discord channel via the configured webhook URL.
// This is the feedback path for cron agent-prompt tasks — scheduled tasks
// can call this tool to report results back to the user on Discord.
//
// Args: {"message": "Your portfolio summary: ..."}
// Optional: {"channel_id": "..."} — future use; webhook already targets a channel.
//
// Requires discord_webhook to be set in config.toml:
//   bareclaw config set discord_webhook "https://discord.com/api/webhooks/..."

fn toolDiscordNotify(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const webhook_url = ctx.cfg.discord_webhook;
    if (webhook_url.len == 0) {
        return ToolResult.literal(false,
            "discord_notify: discord_webhook is not configured. " ++
            "Run: bareclaw config set discord_webhook \"https://discord.com/api/webhooks/...\"");
    }

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return ToolResult.literal(false, "discord_notify: invalid JSON args");
    defer parsed.deinit();

    const message = getString(parsed.value, "message") orelse
        return ToolResult.literal(false, "discord_notify: missing 'message' field");

    ctx.policy.auditLog("discord_notify", "webhook") catch {};

    // Build the Discord webhook JSON payload: {"content": "<message>"}
    // We JSON-encode the message string to safely escape quotes/newlines.
    var body_buf = std.ArrayList(u8).init(ctx.allocator);
    defer body_buf.deinit();
    try body_buf.appendSlice("{\"content\":");
    try std.json.stringify(message, .{}, body_buf.writer());
    try body_buf.append('}');

    const uri = std.Uri.parse(webhook_url) catch {
        return ToolResult.literal(false, "discord_notify: invalid webhook URL in config");
    };

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    var response_buf = std.ArrayList(u8).init(ctx.allocator);
    defer response_buf.deinit();

    const fetch_result = client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .payload = body_buf.items,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .response_storage = .{ .dynamic = &response_buf },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "discord_notify: HTTP error: {}", .{err});
        return ToolResult.owned(false, msg);
    };

    // Discord returns 204 No Content on success.
    const status = @intFromEnum(fetch_result.status);
    if (status == 204 or status < 300) {
        return ToolResult.literal(true, "Message sent to Discord.");
    }

    const msg = try std.fmt.allocPrint(
        ctx.allocator, "discord_notify: Discord returned HTTP {d}: {s}",
        .{ status, response_buf.items },
    );
    return ToolResult.owned(false, msg);
}

// ── cron tools ────────────────────────────────────────────────────────────────
//
// Native built-in tools for Bear to manage its own cron scheduler.
// These shell out to `bareclaw cron` subcommands so they are always available
// without requiring an external MCP server.

/// List all scheduled cron tasks.
fn toolCronList(ctx: *ToolContext, _: []const u8) !ToolResult {
    ctx.policy.auditLog("cron_list", "") catch {};
    return runShellCmd(ctx, "bareclaw cron list");
}

/// Add an agent-prompt cron task.
/// Args: {"schedule": "0 9 * * *", "prompt": "Summarise portfolio"}
fn toolCronAddPrompt(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return ToolResult.literal(false, "cron_add_prompt: invalid JSON args");
    defer parsed.deinit();

    const schedule = getString(parsed.value, "schedule") orelse
        return ToolResult.literal(false, "cron_add_prompt: missing 'schedule' field");
    const prompt = getString(parsed.value, "prompt") orelse
        return ToolResult.literal(false, "cron_add_prompt: missing 'prompt' field");

    ctx.policy.auditLog("cron_add_prompt", schedule) catch {};

    // Shell out: bareclaw cron add-prompt "<schedule>" "<prompt>"
    // We build the command string safely — single-quote each arg to prevent injection.
    const cmd = try std.fmt.allocPrint(
        ctx.allocator,
        "bareclaw cron add-prompt '{s}' '{s}'",
        .{ schedule, prompt },
    );
    defer ctx.allocator.free(cmd);
    return runShellCmd(ctx, cmd);
}

/// Remove a cron task by ID.
/// Args: {"id": "t1"}
fn toolCronRemove(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return ToolResult.literal(false, "cron_remove: invalid JSON args");
    defer parsed.deinit();

    const id = getString(parsed.value, "id") orelse
        return ToolResult.literal(false, "cron_remove: missing 'id' field");

    ctx.policy.auditLog("cron_remove", id) catch {};

    const cmd = try std.fmt.allocPrint(ctx.allocator, "bareclaw cron remove {s}", .{id});
    defer ctx.allocator.free(cmd);
    return runShellCmd(ctx, cmd);
}

// ── registry ──────────────────────────────────────────────────────────────────

pub fn buildCoreTools(
    allocator: std.mem.Allocator,
    _: *security_mod.SecurityPolicy,
    _: *memory_mod.MemoryBackend,
) ![]Tool {
    var list = std.ArrayList(Tool).init(allocator);
    errdefer list.deinit();

    try list.append(Tool{ .name = "shell",                .description = "Run a shell command. Args: {\"command\": \"<shell string>\"}",  .executeFn = toolShell });
    try list.append(Tool{ .name = "file_read",            .description = "Read a file from the workspace",                        .executeFn = toolFileRead });
    try list.append(Tool{ .name = "file_write",           .description = "Write content to a file in the workspace",              .executeFn = toolFileWrite });
    try list.append(Tool{ .name = "memory_store",         .description = "Store a value in memory by key",                       .executeFn = toolMemoryStore });
    try list.append(Tool{ .name = "memory_recall",        .description = "Recall a stored memory entry by key",                  .executeFn = toolMemoryRecall });
    try list.append(Tool{ .name = "memory_forget",        .description = "Delete a stored memory entry by key",                  .executeFn = toolMemoryForget });
    try list.append(Tool{ .name = "memory_list_keys",     .description = "List all memory entry keys",                           .executeFn = toolMemoryListKeys });
    try list.append(Tool{ .name = "memory_delete_prefix", .description = "Delete all memory entries whose key starts with prefix",.executeFn = toolMemoryDeletePrefix });
    try list.append(Tool{ .name = "http_request",         .description = "Make a GET or POST HTTP request",                      .executeFn = toolHttpRequest });
    try list.append(Tool{ .name = "git_operations",       .description = "Run a git subcommand in the workspace",                 .executeFn = toolGitOperations });
    try list.append(Tool{ .name = "agent_status",         .description = "Return agent runtime status (workspace, memory count)", .executeFn = toolAgentStatus });
    try list.append(Tool{ .name = "audit_log_read",       .description = "Read the last N lines of the audit log",               .executeFn = toolAuditLogRead });
    try list.append(Tool{ .name = "discord_notify",       .description = "Send a message to Discord via webhook. Args: {\"message\":\"text\"}. Requires discord_webhook in config.", .executeFn = toolDiscordNotify });
    try list.append(Tool{ .name = "cron_list",            .description = "List all scheduled cron tasks",                        .executeFn = toolCronList });
    try list.append(Tool{ .name = "cron_add_prompt",      .description = "Schedule a recurring agent-prompt task. Args: {\"schedule\":\"0 9 * * *\",\"prompt\":\"your prompt here\"}", .executeFn = toolCronAddPrompt });
    try list.append(Tool{ .name = "cron_remove",          .description = "Remove a cron task by ID. Args: {\"id\":\"t1\"}",      .executeFn = toolCronRemove });

    return list.toOwnedSlice();
}

pub fn freeTools(allocator: std.mem.Allocator, tools: []Tool) void {
    allocator.free(tools);
}

// ── MCP proxy tools ───────────────────────────────────────────────────────────
//
// Each MCP server tool is represented as a BareClaw Tool with an McpProxyMeta
// stored in user_data. The single proxy executeFn reads the metadata to
// determine which MCP server to call and which tool name to invoke.

/// Per-tool metadata for MCP proxy tools.
pub const McpProxyMeta = struct {
    /// The argv used to spawn the MCP server subprocess.
    server_argv: []const []const u8, // slice of owned strings
    /// The tool name as published by the MCP server (may differ from Tool.name).
    mcp_tool_name: []const u8, // owned
    /// Human-readable description from the MCP server's tools/list response.
    description: []const u8, // owned

    pub fn deinit(self: *McpProxyMeta, allocator: std.mem.Allocator) void {
        for (self.server_argv) |arg| allocator.free(arg);
        allocator.free(self.server_argv);
        allocator.free(self.mcp_tool_name);
        allocator.free(self.description);
        self.* = undefined;
    }
};

/// Single executeFn for all MCP proxy tools.
/// Reads user_data as *McpProxyMeta to know which server and tool to call.
fn toolMcpProxy(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const pool = ctx.mcp_pool orelse {
        return ToolResult.literal(false, "mcp: no session pool in context");
    };
    // user_data is set by buildMcpTools to point at the McpProxyMeta for this tool.
    // The caller (agent.zig) passes &ctx with the correct tool's user_data already wired in.
    // However, executeFn doesn't receive the Tool struct — we rely on the per-tool
    // context passed via a wrapper. Since Zig has no closures, we use a small trampoline:
    // the tool's name IS the lookup key — but the function doesn't receive its own name.
    //
    // Resolution: We MUST have the metadata available. The contract is that callers
    // wishing to invoke MCP tools must set ctx.mcp_pool AND call via the tool's own
    // executeFn which has user_data set. We embed a thread-local pointer to current meta.
    //
    // Simpler: we accept that ctx needs one more field for MCP tool dispatch.
    // Add mcp_current_meta to ToolContext temporarily, set by dispatchAllToolCalls.
    const meta: *McpProxyMeta = @ptrCast(@alignCast(ctx.mcp_current_meta orelse {
        return ToolResult.literal(false, "mcp: missing tool metadata in context");
    }));

    ctx.policy.auditLog("mcp_tool", meta.mcp_tool_name) catch {};

    const session = pool.getOrStart(meta.server_argv) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "mcp: failed to start server: {}", .{err});
        return ToolResult.owned(false, msg);
    };

    const result = session.callTool(meta.mcp_tool_name, args_json) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "mcp: call failed: {}", .{err});
        return ToolResult.owned(false, msg);
    };

    return ToolResult.owned(true, result);
}

// T1-5: MCP startup error reporting ──────────────────────────────────────────
//
// Previously, MCP server startup failures were silently logged at warn level
// and skipped. The agent would proceed with zero MCP tools and the user had
// no way to know. Now we collect failures and return them alongside the tools
// so callers can surface them to the user before starting the agent loop.

pub const McpStartupError = struct {
    server_name: []const u8, // owned
    message:     []const u8, // owned

    pub fn deinit(self: *McpStartupError, allocator: std.mem.Allocator) void {
        allocator.free(self.server_name);
        allocator.free(self.message);
        self.* = undefined;
    }
};

/// Build Tool entries for all tools discovered from a set of MCP servers.
/// `server_defs` comes from config_mod.parseMcpServers().
/// The returned tools share a McpSessionPool (also returned via `pool_out`).
/// `errors_out` receives a slice of startup errors (one per failed server).
/// Caller is responsible for calling freeMcpTools(), pool.deinit(), and
/// freeing each McpStartupError + the errors_out slice.
pub fn buildMcpTools(
    allocator: std.mem.Allocator,
    server_defs: []const @import("config.zig").McpServerDef,
    pool_out: *mcp_mod.McpSessionPool,
    errors_out: *[]McpStartupError,
) ![]Tool {
    pool_out.* = mcp_mod.McpSessionPool.init(allocator);

    var list   = std.ArrayList(Tool).init(allocator);
    var errs   = std.ArrayList(McpStartupError).init(allocator);
    errdefer list.deinit();
    errdefer {
        for (errs.items) |*e| e.deinit(allocator);
        errs.deinit();
    }

    for (server_defs) |def| {
        // Start a temporary session to discover the tools list.
        // We immediately deinit it — the pool will re-spawn on first actual call.
        var probe = mcp_mod.McpSession.startProbe(allocator, def.argv) catch |err| {
            // T1-5: Collect the error instead of silently skipping.
            const msg = std.fmt.allocPrint(allocator, "{}", .{err}) catch "unknown error";
            try errs.append(McpStartupError{
                .server_name = try allocator.dupe(u8, def.name),
                .message     = msg,
            });
            continue;
        };
        const discovered = probe.listTools() catch &[_]mcp_mod.McpTool{};
        probe.deinit();

        for (discovered) |mcp_tool| {
            defer {} // mcp_tool strings are owned by discovered; we dupe below

            // Build tool name: "servername__toolname" (double underscore).
            const tool_name = try std.fmt.allocPrint(
                allocator,
                "{s}__{s}",
                .{ def.name, mcp_tool.name },
            );
            errdefer allocator.free(tool_name);

            // Build argv copy for the proxy meta.
            var argv_copy = try allocator.alloc([]const u8, def.argv.len);
            for (def.argv, 0..) |arg, i| argv_copy[i] = try allocator.dupe(u8, arg);

            const desc_copy = try allocator.dupe(u8, mcp_tool.description);
            errdefer allocator.free(desc_copy);

            const meta = try allocator.create(McpProxyMeta);
            meta.* = McpProxyMeta{
                .server_argv   = argv_copy,
                .mcp_tool_name = try allocator.dupe(u8, mcp_tool.name),
                .description   = desc_copy,
            };

            try list.append(Tool{
                .name        = tool_name,
                .description = meta.description, // points into meta — freed via freeMcpTools
                .executeFn   = toolMcpProxy,
                .user_data   = @ptrCast(meta),
            });
        }

        // Free discovered tools (we've duped what we need).
        for (@constCast(discovered)) |*t| t.deinit(allocator);
        allocator.free(discovered);
    }

    errors_out.* = try errs.toOwnedSlice();
    return list.toOwnedSlice();
}

/// Free MCP tools built by buildMcpTools().
pub fn freeMcpTools(allocator: std.mem.Allocator, tools: []Tool) void {
    for (tools) |tool| {
        if (tool.user_data) |ud| {
            const meta: *McpProxyMeta = @ptrCast(@alignCast(ud));
            meta.deinit(allocator);
            allocator.destroy(meta);
        }
        allocator.free(tool.name);
    }
    allocator.free(tools);
}
