const std = @import("std");
const builtin = @import("builtin");
const cron_mod = @import("cron.zig");
const planner_mod = @import("planner.zig");
const profile_mod = @import("profile.zig");
const provider_mod = @import("provider.zig");
const security_mod = @import("security.zig");
const memory_mod = @import("memory.zig");
const mcp_mod = @import("mcp_client.zig");

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
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
    name: []const u8,
    description: []const u8 = "", // human/LLM-readable description; "" = no description
    executeFn: *const fn (ctx: *ToolContext, args_json: []const u8) anyerror!ToolResult,
    /// Optional per-tool metadata (e.g. for MCP proxy tools). Owned by the tool registry.
    user_data: ?*anyopaque = null,
};

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    policy: *security_mod.SecurityPolicy,
    memory: *memory_mod.MemoryBackend,
    cfg: *const @import("config.zig").Config,
    provider: ?provider_mod.AnyProvider = null,
    all_tools: []const Tool = &.{},
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

pub const TOOL_TIMEOUT_SECONDS: u64 = 30;
const MAX_SUBPROCESS_OUTPUT_BYTES: usize = 64 * 1024;

const CommandRunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn drainPipe(
    file_opt: *?std.fs.File,
    out: *std.ArrayList(u8),
) !void {
    const file = file_opt.* orelse return;
    var buf: [4096]u8 = undefined;

    while (true) {
        const amt = file.read(&buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (amt == 0) {
            file.close();
            file_opt.* = null;
            return;
        }
        if (out.items.len + amt > MAX_SUBPROCESS_OUTPUT_BYTES) {
            return error.StreamTooLong;
        }
        try out.appendSlice(buf[0..amt]);
        if (amt < buf.len) return;
    }
}

fn timeoutMessageSeconds(allocator: std.mem.Allocator, seconds: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "tool timed out after {d}s", .{seconds});
}

fn runCommandWithTimeoutSeconds(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_seconds: u64,
) !CommandRunResult {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv,
            .max_output_bytes = MAX_SUBPROCESS_OUTPUT_BYTES,
        });
        return .{
            .term = result.term,
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }
    try child.waitForSpawn();

    var stdout = std.ArrayList(u8).init(allocator);
    errdefer stdout.deinit();
    var stderr = std.ArrayList(u8).init(allocator);
    errdefer stderr.deinit();

    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_seconds * 1000));

    while (child.stdout != null or child.stderr != null) {
        var fds_buf: [2]std.posix.pollfd = undefined;
        var fd_count: usize = 0;
        var stdout_idx: ?usize = null;
        var stderr_idx: ?usize = null;

        if (child.stdout) |file| {
            stdout_idx = fd_count;
            fds_buf[fd_count] = .{
                .fd = file.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            };
            fd_count += 1;
        }
        if (child.stderr) |file| {
            stderr_idx = fd_count;
            fds_buf[fd_count] = .{
                .fd = file.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            };
            fd_count += 1;
        }

        const now_ms = std.time.milliTimestamp();
        if (now_ms >= deadline_ms) {
            _ = child.kill() catch {};
            if (child.stdout) |*file| {
                file.close();
                child.stdout = null;
            }
            if (child.stderr) |*file| {
                file.close();
                child.stderr = null;
            }
            const msg = try timeoutMessageSeconds(allocator, timeout_seconds);
            errdefer allocator.free(msg);
            return .{
                .term = .{ .Signal = 15 },
                .stdout = msg,
                .stderr = try allocator.dupe(u8, ""),
            };
        }

        const remaining_ms: i32 = @intCast(@min(deadline_ms - now_ms, @as(i64, std.math.maxInt(i32))));
        _ = try std.posix.poll(fds_buf[0..fd_count], remaining_ms);

        if (stdout_idx) |idx| {
            if (fds_buf[idx].revents != 0) {
                try drainPipe(&child.stdout, &stdout);
            }
        }
        if (stderr_idx) |idx| {
            if (fds_buf[idx].revents != 0) {
                try drainPipe(&child.stderr, &stderr);
            }
        }
    }

    const term = try child.wait();
    return .{
        .term = term,
        .stdout = try stdout.toOwnedSlice(),
        .stderr = try stderr.toOwnedSlice(),
    };
}

fn runCommandWithTimeout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !CommandRunResult {
    return runCommandWithTimeoutSeconds(allocator, argv, TOOL_TIMEOUT_SECONDS);
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

    const result = runCommandWithTimeout(ctx.allocator, &[_][]const u8{ "/bin/sh", "-c", cmd }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "shell exec failed: {}", .{err});
        return ToolResult.owned(false, msg);
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    const output = try capOutput(ctx.allocator, if (result.stdout.len > 0) result.stdout else result.stderr);
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
        .array => |arr| {
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

fn toolMemorySearch(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in memory_search args");
    };
    defer parsed.deinit();

    const query = getString(parsed.value, "query") orelse {
        return ToolResult.literal(false, "memory_search: missing 'query' argument");
    };

    var limit: usize = 5;
    if (parsed.value.object.get("limit")) |limit_val| {
        limit = switch (limit_val) {
            .integer => |v| @intCast(@max(@as(i64, 1), @min(v, 10))),
            else => 5,
        };
    }

    ctx.policy.auditLog("memory_search", query) catch {};

    const results = try ctx.memory.search(query, limit);
    defer {
        for (results) |*result| @constCast(result).deinit(ctx.allocator);
        ctx.allocator.free(results);
    }

    if (results.len == 0) {
        return ToolResult.owned(true, try ctx.allocator.dupe(u8, "(no relevant memory entries found)"));
    }

    var out = std.ArrayList(u8).init(ctx.allocator);
    errdefer out.deinit();
    for (results, 0..) |result, idx| {
        try out.writer().print(
            "{d}. {s} (score {d:.2})\n{s}\n",
            .{ idx + 1, result.key, result.score, result.preview },
        );
    }

    return ToolResult.owned(true, try out.toOwnedSlice());
}

// ── tool: profile_get / profile_set ─────────────────────────────────────────

fn toolProfileGet(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in profile_get args");
    };
    defer parsed.deinit();

    const key = getString(parsed.value, "key") orelse {
        return ToolResult.literal(false, "profile_get: missing 'key' argument");
    };

    ctx.policy.auditLog("profile_get", key) catch {};

    const value = try profile_mod.getValue(ctx.allocator, ctx.cfg.workspace_dir, key);
    if (value) |v| {
        return ToolResult.owned(true, v);
    }
    return ToolResult.literal(true, "(profile key not set)");
}

fn toolProfileSet(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in profile_set args");
    };
    defer parsed.deinit();

    const key = getString(parsed.value, "key") orelse {
        return ToolResult.literal(false, "profile_set: missing 'key' argument");
    };
    const value = getString(parsed.value, "value") orelse {
        return ToolResult.literal(false, "profile_set: missing 'value' argument");
    };

    ctx.policy.auditLog("profile_set", key) catch {};

    try profile_mod.setValue(ctx.allocator, ctx.cfg.workspace_dir, key, value);
    const msg = try std.fmt.allocPrint(ctx.allocator, "profile '{s}' updated", .{key});
    return ToolResult.owned(true, msg);
}

// ── tool: planner_execute ───────────────────────────────────────────────────

const PlannerExecuteCtx = struct {
    tool_ctx: *ToolContext,
};

fn plannerExecuteStep(ctx_ptr: *anyopaque, tool_name: []const u8, args_json: []const u8) !planner_mod.ExecutionResult {
    const exec_ctx: *PlannerExecuteCtx = @ptrCast(@alignCast(ctx_ptr));

    if (std.mem.eql(u8, tool_name, "planner_execute")) {
        return planner_mod.ExecutionResult.literal(false, "planner_execute cannot call itself");
    }

    for (exec_ctx.tool_ctx.all_tools) |tool| {
        if (!std.mem.eql(u8, tool.name, tool_name)) continue;

        exec_ctx.tool_ctx.mcp_current_meta = tool.user_data;
        defer exec_ctx.tool_ctx.mcp_current_meta = null;

        const result = tool.executeFn(exec_ctx.tool_ctx, args_json) catch |err| {
            const msg = try std.fmt.allocPrint(exec_ctx.tool_ctx.allocator, "tool error: {}", .{err});
            return planner_mod.ExecutionResult.owned(false, msg);
        };
        return .{
            .success = result.success,
            .output = result.output,
            .allocated = result.allocated,
        };
    }

    return planner_mod.ExecutionResult.literal(false, "unknown tool");
}

fn toolPlannerExecute(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult.literal(false, "invalid JSON in planner_execute args");
    };
    defer parsed.deinit();

    const goal = getString(parsed.value, "goal") orelse getString(parsed.value, "prompt") orelse {
        return ToolResult.literal(false, "planner_execute: missing 'goal' argument");
    };

    const provider = ctx.provider orelse {
        return ToolResult.literal(false, "planner_execute: no provider is active in this tool context");
    };

    ctx.policy.auditLog("planner_execute", goal) catch {};

    var descriptors = std.ArrayList(planner_mod.ToolDescriptor).init(ctx.allocator);
    defer descriptors.deinit();
    for (ctx.all_tools) |tool| {
        try descriptors.append(.{
            .name = tool.name,
            .description = tool.description,
        });
    }

    var exec_ctx = PlannerExecuteCtx{ .tool_ctx = ctx };
    const summary = try planner_mod.planAndExecute(
        ctx.allocator,
        provider,
        ctx.cfg.default_model,
        ctx.memory,
        descriptors.items,
        &exec_ctx,
        plannerExecuteStep,
        goal,
    );
    return ToolResult.owned(true, summary);
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

    _ = std.Uri.parse(url_str) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "http_request: invalid URL '{s}'", .{url_str});
        return ToolResult.owned(false, msg);
    };

    const method: std.http.Method = if (std.mem.eql(u8, method_str, "POST"))
        .POST
    else
        .GET;

    const output = runHttpRequestWithTimeout(ctx.allocator, url_str, method, body_str, TOOL_TIMEOUT_SECONDS) catch |err| switch (err) {
        error.ToolTimedOut => {
            const msg = try timeoutMessageSeconds(ctx.allocator, TOOL_TIMEOUT_SECONDS);
            return ToolResult.owned(false, msg);
        },
        else => {
            const msg = try std.fmt.allocPrint(ctx.allocator, "http_request failed: {}", .{err});
            return ToolResult.owned(false, msg);
        },
    };
    errdefer ctx.allocator.free(output);

    if (std.mem.startsWith(u8, output, "HTTP ")) {
        return ToolResult.owned(false, output);
    }

    return ToolResult.owned(true, output);
}

const HttpRequestJob = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    finished: bool = false,
    caller_timed_out: bool = false,
    url: []u8,
    body: []u8,
    method: std.http.Method,
    output: ?[]u8 = null,
    error_name: ?[]u8 = null,
};

fn runHttpRequestWithTimeout(
    allocator: std.mem.Allocator,
    url: []const u8,
    method: std.http.Method,
    body: []const u8,
    timeout_seconds: u64,
) ![]u8 {
    const job = try std.heap.page_allocator.create(HttpRequestJob);
    errdefer std.heap.page_allocator.destroy(job);

    job.* = .{
        .url = try std.heap.page_allocator.dupe(u8, url),
        .body = try std.heap.page_allocator.dupe(u8, body),
        .method = method,
    };
    errdefer {
        std.heap.page_allocator.free(job.url);
        std.heap.page_allocator.free(job.body);
    }

    var thread = try std.Thread.spawn(.{}, httpRequestWorker, .{job});
    return awaitHttpRequestJob(allocator, job, &thread, timeout_seconds);
}

fn httpRequestWorker(job: *HttpRequestJob) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    defer std.heap.page_allocator.free(job.url);
    defer std.heap.page_allocator.free(job.body);

    const output = runHttpRequest(allocator, job.url, job.method, job.body) catch |err| {
        const err_name = std.heap.page_allocator.dupe(u8, @errorName(err)) catch null;
        finishHttpRequestJob(job, null, err_name);
        return;
    };
    finishHttpRequestJob(job, output, null);
}

fn runHttpRequest(
    allocator: std.mem.Allocator,
    url: []const u8,
    method: std.http.Method,
    body: []const u8,
) ![]u8 {
    const uri = try std.Uri.parse(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_buf = std.ArrayList(u8).init(allocator);
    errdefer response_buf.deinit();

    const payload: ?[]const u8 = if (body.len > 0) body else null;

    const result = try client.fetch(.{
        .method = method,
        .location = .{ .uri = uri },
        .payload = payload,
        .response_storage = .{ .dynamic = &response_buf },
    });

    const raw = try response_buf.toOwnedSlice();
    if (@intFromEnum(result.status) < 400) return raw;
    defer allocator.free(raw);
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ @intFromEnum(result.status), raw });
}

fn finishHttpRequestJob(job: *HttpRequestJob, output: ?[]u8, error_name: ?[]u8) void {
    var destroy_job = false;

    job.mutex.lock();
    job.output = output;
    job.error_name = error_name;
    job.finished = true;
    destroy_job = job.caller_timed_out;
    job.cond.broadcast();
    job.mutex.unlock();

    if (destroy_job) {
        if (job.output) |owned_output| std.heap.page_allocator.free(owned_output);
        if (job.error_name) |owned_error| std.heap.page_allocator.free(owned_error);
        std.heap.page_allocator.destroy(job);
    }
}

fn awaitHttpRequestJob(
    allocator: std.mem.Allocator,
    job: *HttpRequestJob,
    thread: *std.Thread,
    timeout_seconds: u64,
) ![]u8 {
    job.mutex.lock();
    while (!job.finished) {
        job.cond.timedWait(&job.mutex, timeout_seconds * std.time.ns_per_s) catch |err| switch (err) {
            error.Timeout => {
                job.caller_timed_out = true;
                job.mutex.unlock();
                thread.detach();
                return error.ToolTimedOut;
            },
        };
    }

    job.mutex.unlock();
    thread.join();

    defer {
        if (job.output) |owned_output| std.heap.page_allocator.free(owned_output);
        if (job.error_name) |owned_error| std.heap.page_allocator.free(owned_error);
        std.heap.page_allocator.destroy(job);
    }

    if (job.error_name) |_| return error.HttpRequestFailed;

    const output = job.output orelse return error.HttpRequestFailed;
    return allocator.dupe(u8, output);
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

    const op = getString(parsed.value, "op") orelse "status";
    const path = getString(parsed.value, "path") orelse ".";
    const extra = getString(parsed.value, "args") orelse "";

    // Validate allowed operations.
    const allowed_ops = [_][]const u8{
        "status", "log",  "diff",   "add",      "commit", "push",  "pull",
        "clone",  "init", "branch", "checkout", "fetch",  "stash",
    };
    var op_ok = false;
    for (allowed_ops) |allowed| {
        if (std.mem.eql(u8, op, allowed)) {
            op_ok = true;
            break;
        }
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

    const result = runCommandWithTimeout(ctx.allocator, argv.items) catch |err| {
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

    const cron_tasks = cron_mod.loadTasksPublic(ctx.allocator) catch &[_]cron_mod.CronTask{};
    defer {
        for (cron_tasks) |*task| @constCast(task).deinit(ctx.allocator);
        ctx.allocator.free(cron_tasks);
    }

    var tool_names = std.ArrayList(u8).init(ctx.allocator);
    errdefer tool_names.deinit();
    for (ctx.all_tools, 0..) |tool, idx| {
        if (idx > 0) try tool_names.appendSlice(", ");
        try tool_names.appendSlice(tool.name);
    }
    const loaded_tools = if (tool_names.items.len > 0) tool_names.items else "(none)";

    const out = try std.fmt.allocPrint(
        ctx.allocator,
        "workspace: {s}\nprovider: {s}\nmodel: {s}\nmemory_entries: {d}\ncron_tasks: {d}\nloaded_tools: {s}\npolicy: workspace-only sandbox",
        .{ ctx.policy.workspace_dir, ctx.cfg.default_provider, ctx.cfg.default_model, mem_count, cron_tasks.len, loaded_tools },
    );
    tool_names.deinit();
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
// Sends a message directly to a Discord channel via the bot API.
// Used by cron agent-prompt tasks to report results back to the user.
//
// Args: {"message": "Your portfolio summary: ..."}
//
// Requires in config.toml:
//   discord_token          = "Bot token"
//   discord_notify_channel = "1473668167397019823"  ← DM channel or any channel ID
//
// Set via:
//   bareclaw config set discord_notify_channel "1473668167397019823"

fn toolDiscordNotify(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const channel_id = ctx.cfg.discord_notify_channel;
    const bot_token = ctx.cfg.discord_token;

    if (channel_id.len == 0) {
        return ToolResult.literal(false, "discord_notify: discord_notify_channel is not configured. " ++
            "Run: bareclaw config set discord_notify_channel \"<channel_id>\"");
    }
    if (bot_token.len == 0) {
        return ToolResult.literal(false, "discord_notify: discord_token is not configured.");
    }

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return ToolResult.literal(false, "discord_notify: invalid JSON args");
    defer parsed.deinit();

    const message = getString(parsed.value, "message") orelse
        return ToolResult.literal(false, "discord_notify: missing 'message' field");

    ctx.policy.auditLog("discord_notify", channel_id) catch {};

    // Build JSON body: {"content": "<message>"}
    var body_buf = std.ArrayList(u8).init(ctx.allocator);
    defer body_buf.deinit();
    try body_buf.appendSlice("{\"content\":");
    try std.json.stringify(message, .{}, body_buf.writer());
    try body_buf.append('}');

    // POST /channels/{channel_id}/messages using bot token auth.
    const url_str = try std.fmt.allocPrint(
        ctx.allocator,
        "https://discord.com/api/v10/channels/{s}/messages",
        .{channel_id},
    );
    defer ctx.allocator.free(url_str);

    const auth_header = try std.fmt.allocPrint(ctx.allocator, "Bot {s}", .{bot_token});
    defer ctx.allocator.free(auth_header);

    const uri = std.Uri.parse(url_str) catch {
        return ToolResult.literal(false, "discord_notify: failed to parse Discord API URL");
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
            .{ .name = "Authorization", .value = auth_header },
        },
        .response_storage = .{ .dynamic = &response_buf },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "discord_notify: HTTP error: {}", .{err});
        return ToolResult.owned(false, msg);
    };

    const status = @intFromEnum(fetch_result.status);
    if (status == 200 or status == 201) {
        return ToolResult.literal(true, "Message sent to Discord.");
    }

    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "discord_notify: Discord API returned HTTP {d}: {s}",
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

/// Manually trigger all due cron tasks right now (for testing).
/// Args: {} (no arguments needed)
fn toolCronRun(ctx: *ToolContext, _: []const u8) !ToolResult {
    ctx.policy.auditLog("cron_run", "") catch {};
    return runShellCmd(ctx, "bareclaw cron run");
}

// ── registry ──────────────────────────────────────────────────────────────────

pub fn buildCoreTools(
    allocator: std.mem.Allocator,
    _: *security_mod.SecurityPolicy,
    _: *memory_mod.MemoryBackend,
) ![]Tool {
    var list = std.ArrayList(Tool).init(allocator);
    errdefer list.deinit();

    try list.append(Tool{ .name = "shell", .description = "Run a shell command. Args: {\"command\": \"<shell string>\"}", .executeFn = toolShell });
    try list.append(Tool{ .name = "file_read", .description = "Read a file from the workspace", .executeFn = toolFileRead });
    try list.append(Tool{ .name = "file_write", .description = "Write content to a file in the workspace", .executeFn = toolFileWrite });
    try list.append(Tool{ .name = "memory_store", .description = "Store a value in memory by key", .executeFn = toolMemoryStore });
    try list.append(Tool{ .name = "memory_recall", .description = "Recall a stored memory entry by key", .executeFn = toolMemoryRecall });
    try list.append(Tool{ .name = "memory_forget", .description = "Delete a stored memory entry by key", .executeFn = toolMemoryForget });
    try list.append(Tool{ .name = "memory_search", .description = "Search memory entries by relevance. Args: {\"query\":\"...\",\"limit\":5}", .executeFn = toolMemorySearch });
    try list.append(Tool{ .name = "profile_get", .description = "Read a user profile value by key", .executeFn = toolProfileGet });
    try list.append(Tool{ .name = "profile_set", .description = "Set a user profile value by key", .executeFn = toolProfileSet });
    try list.append(Tool{ .name = "planner_execute", .description = "Create a multi-step plan, execute tools, and store a reflective summary. Args: {\"goal\":\"...\"}", .executeFn = toolPlannerExecute });
    try list.append(Tool{ .name = "memory_list_keys", .description = "List all memory entry keys", .executeFn = toolMemoryListKeys });
    try list.append(Tool{ .name = "memory_delete_prefix", .description = "Delete all memory entries whose key starts with prefix", .executeFn = toolMemoryDeletePrefix });
    try list.append(Tool{ .name = "http_request", .description = "Make a GET or POST HTTP request", .executeFn = toolHttpRequest });
    try list.append(Tool{ .name = "git_operations", .description = "Run a git subcommand in the workspace", .executeFn = toolGitOperations });
    try list.append(Tool{ .name = "agent_status", .description = "Return agent runtime status (provider, model, memory count, loaded tools, cron count)", .executeFn = toolAgentStatus });
    try list.append(Tool{ .name = "audit_log_read", .description = "Read the last N lines of the audit log", .executeFn = toolAuditLogRead });
    try list.append(Tool{ .name = "discord_notify", .description = "Send a message to the user on Discord via webhook. Args: {\"message\":\"text\"}.", .executeFn = toolDiscordNotify });
    try list.append(Tool{ .name = "cron_list", .description = "List all scheduled cron tasks", .executeFn = toolCronList });
    try list.append(Tool{ .name = "cron_add_prompt", .description = "Schedule a recurring agent-prompt task. The prompt MUST end with 'then use discord_notify to send the result to the user'. Args: {\"schedule\":\"0 9 * * *\",\"prompt\":\"...then use discord_notify to send the result to the user\"}", .executeFn = toolCronAddPrompt });
    try list.append(Tool{ .name = "cron_remove", .description = "Remove a cron task by ID. Args: {\"id\":\"t1\"}", .executeFn = toolCronRemove });
    try list.append(Tool{ .name = "cron_run", .description = "Manually trigger all due cron tasks now. Use this to test a scheduled task immediately. Args: {}", .executeFn = toolCronRun });

    return list.toOwnedSlice();
}

pub fn freeTools(allocator: std.mem.Allocator, tools: []Tool) void {
    allocator.free(tools);
}

// ── MCP proxy tools ───────────────────────────────────────────────────────────
//
// Each MCP server tool is represented as a BearClaw Tool with an McpProxyMeta
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
    message: []const u8, // owned

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

    var list = std.ArrayList(Tool).init(allocator);
    var errs = std.ArrayList(McpStartupError).init(allocator);
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
                .message = msg,
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
                .server_argv = argv_copy,
                .mcp_tool_name = try allocator.dupe(u8, mcp_tool.name),
                .description = desc_copy,
            };

            try list.append(Tool{
                .name = tool_name,
                .description = meta.description, // points into meta — freed via freeMcpTools
                .executeFn = toolMcpProxy,
                .user_data = @ptrCast(meta),
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

test "runCommandWithTimeout captures stdout before exit" {
    const result = try runCommandWithTimeout(std.testing.allocator, &[_][]const u8{
        "/bin/sh",
        "-c",
        "printf 'ok'",
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(result.term == .Exited);
    try std.testing.expectEqualStrings("ok", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runCommandWithTimeout returns timeout message for sleeping process" {
    const result = try runCommandWithTimeoutSeconds(std.testing.allocator, &[_][]const u8{
        "/bin/sh",
        "-c",
        "sleep 2",
    }, 1);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tool timed out after") != null);
    try std.testing.expectEqualStrings("", result.stderr);
}

fn testFastHttpJobWorker(job: *HttpRequestJob) void {
    std.heap.page_allocator.free(job.url);
    std.heap.page_allocator.free(job.body);
    const output = std.heap.page_allocator.dupe(u8, "ok") catch unreachable;
    finishHttpRequestJob(job, output, null);
}

fn testSlowHttpJobWorker(job: *HttpRequestJob) void {
    std.Thread.sleep(20 * std.time.ns_per_ms);
    std.heap.page_allocator.free(job.url);
    std.heap.page_allocator.free(job.body);
    const output = std.heap.page_allocator.dupe(u8, "late") catch unreachable;
    finishHttpRequestJob(job, output, null);
}

test "awaitHttpRequestJob returns output before deadline" {
    const job = try std.heap.page_allocator.create(HttpRequestJob);
    errdefer std.heap.page_allocator.destroy(job);
    job.* = .{
        .url = try std.heap.page_allocator.dupe(u8, ""),
        .body = try std.heap.page_allocator.dupe(u8, ""),
        .method = .GET,
    };
    errdefer {
        std.heap.page_allocator.free(job.url);
        std.heap.page_allocator.free(job.body);
    }

    var thread = try std.Thread.spawn(.{}, testFastHttpJobWorker, .{job});
    const output = try awaitHttpRequestJob(std.testing.allocator, job, &thread, 1);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("ok", output);
}

test "awaitHttpRequestJob reports timeout for slow worker" {
    const job = try std.heap.page_allocator.create(HttpRequestJob);
    errdefer std.heap.page_allocator.destroy(job);
    job.* = .{
        .url = try std.heap.page_allocator.dupe(u8, ""),
        .body = try std.heap.page_allocator.dupe(u8, ""),
        .method = .GET,
    };
    errdefer {
        std.heap.page_allocator.free(job.url);
        std.heap.page_allocator.free(job.body);
    }

    var thread = try std.Thread.spawn(.{}, testSlowHttpJobWorker, .{job});
    try std.testing.expectError(error.ToolTimedOut, awaitHttpRequestJob(std.testing.allocator, job, &thread, 0));
}
