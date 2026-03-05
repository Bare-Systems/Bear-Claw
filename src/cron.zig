/// Cron scheduler for BearClaw.
///
/// Tasks are stored as one-per-line TSV in  ~/.bareclaw/cron.tsv:
///   id TAB schedule TAB command TAB enabled TAB last_run_ts TAB next_run_ts TAB prompt NEWLINE
///
/// The 'command' field holds a shell command (for shell tasks) or is "-" (for prompt tasks).
/// The 'prompt'  field holds the agent prompt (for prompt tasks) or is "" (for shell tasks).
///
/// Supported subcommands (from main.zig / args):
///   cron add <schedule> <command>       – add a shell task
///   cron add-prompt <schedule> <prompt> – add an agent-prompt task
///   cron list                           – print all tasks
///   cron remove <id>                    – delete a task by id
///   cron pause  <id>                    – set enabled=false
///   cron resume <id>                    – set enabled=true
///   cron run                            – execute all due/enabled tasks right now
///
/// Schedule formats:
///   @hourly   – every hour  (0 * * * *)
///   @daily    – every day   (0 0 * * *)
///   @weekly   – every week  (0 0 * * 0)
///   @monthly  – every month (0 0 1 * *)
///   M H * * * – standard 5-field cron (minute, hour, dom, month, dow)
///             – fields support: * (any), */N (every N), or an exact integer

const std = @import("std");

const config_mod   = @import("config.zig");
const agent_mod    = @import("agent.zig");
const provider_mod = @import("provider.zig");
const memory_mod   = @import("memory.zig");
const tools_mod    = @import("tools.zig");
const security_mod = @import("security.zig");
const mcp_mod      = @import("mcp_client.zig");

// ── data model ──────────────────────────────────────────────────────────────

pub const CronTask = struct {
    id:         []const u8,  // allocated
    schedule:   []const u8,  // allocated – e.g. "@daily", "0 * * * *"
    command:    []const u8,  // allocated – shell command, or "-" for prompt tasks
    enabled:    bool,
    last_run:   i64,         // unix timestamp, 0 = never
    next_run:   i64,         // unix timestamp, 0 = run immediately
    prompt:     []const u8,  // allocated – agent prompt, or "" for shell tasks

    /// Returns true if this is an agent-prompt task (not a shell task).
    pub fn isPromptTask(self: *const CronTask) bool {
        return self.prompt.len > 0;
    }

    pub fn deinit(self: *CronTask, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.schedule);
        allocator.free(self.command);
        allocator.free(self.prompt);
    }
};

// ── cron expression parser ───────────────────────────────────────────────────

/// A parsed 5-field cron expression.
/// Each field is either:
///   .any       – matches any value
///   .every{n}  – matches every n-th value
///   .exact{v}  – matches only v
pub const CronField = union(enum) {
    any:   void,
    every: u32,
    exact: u32,
};

pub const CronExpr = struct {
    minute: CronField, // 0–59
    hour:   CronField, // 0–23
    dom:    CronField, // 1–31  (day of month)
    month:  CronField, // 1–12
    dow:    CronField, // 0–6   (day of week, 0=Sunday)
};

/// Parse a single cron field token.
/// Supported: "*", "*/N", or a plain integer.
fn parseField(token: []const u8) !CronField {
    if (std.mem.eql(u8, token, "*")) return CronField{ .any = {} };
    if (std.mem.startsWith(u8, token, "*/")) {
        const n = std.fmt.parseInt(u32, token[2..], 10) catch return error.InvalidCronExpr;
        if (n == 0) return error.InvalidCronExpr;
        return CronField{ .every = n };
    }
    const v = std.fmt.parseInt(u32, token, 10) catch return error.InvalidCronExpr;
    return CronField{ .exact = v };
}

/// Parse a full schedule string into a CronExpr.
/// Returns error.InvalidCronExpr if the format is not recognised.
pub fn parseCronExpr(schedule: []const u8) !CronExpr {
    // Handle @ aliases.
    if (std.mem.eql(u8, schedule, "@hourly"))  return parseCronExpr("0 * * * *");
    if (std.mem.eql(u8, schedule, "@daily"))   return parseCronExpr("0 0 * * *");
    if (std.mem.eql(u8, schedule, "@weekly"))  return parseCronExpr("0 0 * * 0");
    if (std.mem.eql(u8, schedule, "@monthly")) return parseCronExpr("0 0 1 * *");

    var it = std.mem.tokenizeScalar(u8, schedule, ' ');
    const f0 = it.next() orelse return error.InvalidCronExpr;
    const f1 = it.next() orelse return error.InvalidCronExpr;
    const f2 = it.next() orelse return error.InvalidCronExpr;
    const f3 = it.next() orelse return error.InvalidCronExpr;
    const f4 = it.next() orelse return error.InvalidCronExpr;
    // Reject trailing tokens.
    if (it.next() != null) return error.InvalidCronExpr;

    return CronExpr{
        .minute = try parseField(f0),
        .hour   = try parseField(f1),
        .dom    = try parseField(f2),
        .month  = try parseField(f3),
        .dow    = try parseField(f4),
    };
}

/// Check whether a CronField matches a given value.
fn fieldMatches(field: CronField, value: u32) bool {
    return switch (field) {
        .any       => true,
        .every     => |n| value % n == 0,
        .exact     => |v| value == v,
    };
}

/// Broken-down calendar time (UTC).  We only carry what cron needs.
const BrokenTime = struct {
    year:   u32,
    month:  u32, // 1–12
    day:    u32, // 1–31
    hour:   u32, // 0–23
    minute: u32, // 0–59
    dow:    u32, // 0–6, Sunday=0
};

/// Days in a month (ignores leap years — close enough for scheduling).
fn daysInMonth(month: u32, year: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11            => 30,
        2 => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) @as(u32, 29) else 28,
        else => 30, // shouldn't happen
    };
}

/// Convert a unix timestamp to a BrokenTime (UTC).
/// Uses the proleptic Gregorian calendar algorithm.
pub fn timestampToBroken(ts: i64) BrokenTime {
    // Days since Unix epoch (1970-01-01).
    const secs_per_day: i64 = 86400;
    const day_num = @divFloor(ts, secs_per_day);
    const day_sec = @mod(ts, secs_per_day);

    const hour:   u32 = @intCast(@divFloor(day_sec, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(day_sec, 3600), 60));

    // Day of week: Jan 1 1970 was a Thursday = 4.
    const dow: u32 = @intCast(@mod(day_num + 4, 7));

    // Gregorian calendar conversion (civil date from day number).
    // Algorithm: https://www.howardhinnant.com/date_algorithms.html
    const z = day_num + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u32 = @intCast(z - era * 146097);          // day-of-era  [0, 146096]
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // year-of-era [0, 399]
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);  // day-of-year [0, 365]
    const mp  = (5 * doy + 2) / 153;                       // month prime
    const d   = doy - (153 * mp + 2) / 5 + 1;             // day          [1, 31]
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;       // month        [1, 12]
    const year: u32 = @intCast(y + @as(i64, if (m <= 2) 1 else 0));

    return BrokenTime{
        .year   = year,
        .month  = m,
        .day    = d,
        .hour   = hour,
        .minute = minute,
        .dow    = dow,
    };
}

/// Convert a BrokenTime (UTC) back to a unix timestamp.
/// Using the inverse of the Gregorian algorithm above.
fn brokenToTimestamp(bt: BrokenTime) i64 {
    // Shift year so March is month 0 of the internal calendar.
    const y: i64 = @as(i64, bt.year) - @as(i64, if (bt.month <= 2) 1 else 0);
    const m: u32 = if (bt.month <= 2) bt.month + 9 else bt.month - 3;
    const era = @divFloor(y, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const doy = (153 * m + 2) / 5 + bt.day - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    const day_num: i64 = era * 146097 + @as(i64, doe) - 719468;
    return day_num * 86400 + @as(i64, bt.hour) * 3600 + @as(i64, bt.minute) * 60;
}

/// Compute the next unix timestamp ≥ (from_ts + 60) when expr would fire.
/// We advance minute-by-minute (up to 366 days) to find the next match.
/// This is intentionally simple and allocation-free.
pub fn nextRunAfter(expr: CronExpr, from_ts: i64) i64 {
    // Start one full minute after from_ts, rounded to the next minute boundary.
    const base = from_ts + 60;
    const start_min = @divFloor(base, 60) * 60;

    var ts = start_min;
    const limit = start_min + 366 * 24 * 3600; // give up after 1 year
    while (ts < limit) : (ts += 60) {
        const bt = timestampToBroken(ts);
        if (!fieldMatches(expr.minute, bt.minute)) continue;
        if (!fieldMatches(expr.hour,   bt.hour))   continue;
        if (!fieldMatches(expr.month,  bt.month))  continue;
        if (!fieldMatches(expr.dom,    bt.day))    continue;
        if (!fieldMatches(expr.dow,    bt.dow))    continue;
        return ts;
    }
    // Fallback: one week from now (should never happen for valid expressions).
    return from_ts + 7 * 24 * 3600;
}

/// Compute next_run from a schedule string and a reference timestamp.
/// Returns 0 (run immediately) for unknown/parse-error schedules.
pub fn computeNextRun(schedule: []const u8, from_ts: i64) i64 {
    const expr = parseCronExpr(schedule) catch return 0;
    return nextRunAfter(expr, from_ts);
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn cronFilePath(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".bareclaw", "cron.tsv" });
}

/// Ensure ~/.bareclaw exists.
fn ensureDir(allocator: std.mem.Allocator) !void {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const dir = try std.fs.path.join(allocator, &.{ home, ".bareclaw" });
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
}

/// Load all tasks from disk. Caller owns the returned slice and each CronTask.
fn loadTasks(allocator: std.mem.Allocator) ![]CronTask {
    const path = try cronFilePath(allocator);
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(CronTask, 0),
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    var tasks = std.ArrayList(CronTask).init(allocator);
    errdefer {
        for (tasks.items) |*t| t.deinit(allocator);
        tasks.deinit();
    }

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, trimmed, '\t');
        const id       = fields.next() orelse continue;
        const schedule = fields.next() orelse continue;
        const command  = fields.next() orelse continue;
        const en_str   = fields.next() orelse "1";
        const lr_str   = fields.next() orelse "0";
        const nr_str   = fields.next() orelse "0";
        const prompt   = fields.next() orelse "";

        const task = CronTask{
            .id       = try allocator.dupe(u8, id),
            .schedule = try allocator.dupe(u8, schedule),
            .command  = try allocator.dupe(u8, command),
            .enabled  = !std.mem.eql(u8, en_str, "0"),
            .last_run = std.fmt.parseInt(i64, lr_str, 10) catch 0,
            .next_run = std.fmt.parseInt(i64, nr_str, 10) catch 0,
            .prompt   = try allocator.dupe(u8, prompt),
        };
        try tasks.append(task);
    }

    return tasks.toOwnedSlice();
}

/// Public wrapper so other modules (e.g. main.zig status/doctor) can read tasks.
pub fn loadTasksPublic(allocator: std.mem.Allocator) ![]CronTask {
    return loadTasks(allocator);
}

/// Write tasks slice back to disk (full rewrite).
fn saveTasks(allocator: std.mem.Allocator, tasks: []const CronTask) !void {
    try ensureDir(allocator);
    const path = try cronFilePath(allocator);
    defer allocator.free(path);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    const w = file.writer();
    for (tasks) |t| {
        try w.print("{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{s}\n", .{
            t.id,
            t.schedule,
            t.command,
            @intFromBool(t.enabled),
            t.last_run,
            t.next_run,
            t.prompt,
        });
    }
}

/// Generate a short unique id like "t1", "t2", …
fn nextId(allocator: std.mem.Allocator, tasks: []const CronTask) ![]u8 {
    var max: usize = 0;
    for (tasks) |t| {
        if (t.id.len > 1 and t.id[0] == 't') {
            const n = std.fmt.parseInt(usize, t.id[1..], 10) catch continue;
            if (n > max) max = n;
        }
    }
    return std.fmt.allocPrint(allocator, "t{d}", .{max + 1});
}

// ── agent prompt task execution ───────────────────────────────────────────────

/// Run an agent-prompt task.  Builds a minimal agent stack from config, calls
/// runAgentOnceCaptured, then stores the result in memory under
/// "cron/<task_id>/<timestamp>" so it can be recalled later.
fn runPromptTask(
    allocator: std.mem.Allocator,
    task:      *const CronTask,
    now:       i64,
    stdout:    anytype,
) !void {
    // Load config from disk.
    var cfg = config_mod.loadOrInit(allocator) catch |err| {
        try stdout.print("[cron] {s}: config load failed: {}\n", .{ task.id, err });
        return;
    };
    defer cfg.deinit(allocator);

    // Build provider.
    var provider = provider_mod.createDefaultProvider(allocator, &cfg) catch |err| {
        try stdout.print("[cron] {s}: provider init failed: {}\n", .{ task.id, err });
        return;
    };
    defer provider.deinit();
    const any_provider = provider_mod.AnyProvider.fromProvider(&provider);

    // Build memory backend.
    var mem_backend = memory_mod.createMemoryBackend(allocator, &cfg) catch |err| {
        try stdout.print("[cron] {s}: memory init failed: {}\n", .{ task.id, err });
        return;
    };
    defer mem_backend.deinit();

    // Build security policy.
    var policy = security_mod.SecurityPolicy.initWorkspaceOnly(allocator, &cfg);
    defer policy.deinit(allocator);

    // Build core tools (no MCP for cron tasks — keeps things simple and fast).
    const core_tools = tools_mod.buildCoreTools(allocator, &policy, &mem_backend) catch |err| {
        try stdout.print("[cron] {s}: tools init failed: {}\n", .{ task.id, err });
        return;
    };
    defer tools_mod.freeTools(allocator, core_tools);

    try stdout.print("[cron] {s}: running agent prompt: {s}\n", .{ task.id, task.prompt });

    // Run the agent and capture its reply.
    const reply = agent_mod.runAgentOnceCaptured(
        allocator,
        &cfg,
        any_provider,
        &mem_backend,
        core_tools,
        &policy,
        null, // no MCP pool for cron tasks
        task.prompt,
    ) catch |err| {
        try stdout.print("[cron] {s}: agent run failed: {}\n", .{ task.id, err });
        return;
    };
    defer allocator.free(reply);

    if (reply.len > 0) try stdout.print("{s}\n", .{reply});

    // Store result in memory under "cron/<id>/<timestamp>".
    const mem_key = std.fmt.allocPrint(allocator, "cron/{s}/{d}", .{ task.id, now }) catch return;
    defer allocator.free(mem_key);

    const mem_value = std.fmt.allocPrint(allocator,
        "# Cron task {s} — {d}\nSchedule: {s}\nPrompt: {s}\n\n## Response\n{s}\n",
        .{ task.id, now, task.schedule, task.prompt, reply },
    ) catch return;
    defer allocator.free(mem_value);

    mem_backend.store(mem_key, mem_value) catch |err| {
        try stdout.print("[cron] {s}: memory store failed: {}\n", .{ task.id, err });
    };
}

// ── public interface ─────────────────────────────────────────────────────────

/// Entry point called from main.zig with the remaining args after "cron".
/// args[0] is the subcommand (add / add-prompt / list / remove / pause / resume / run).
pub fn dispatchCron(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var stdout = std.io.getStdOut().writer();

    const sub = if (args.len > 0) args[0] else "list";

    if (std.mem.eql(u8, sub, "list")) {
        try cmdList(allocator, stdout);
    } else if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 3) {
            try stdout.print("Usage: cron add <schedule> <command>\n", .{});
            return;
        }
        try cmdAdd(allocator, args[1], args[2], stdout);
    } else if (std.mem.eql(u8, sub, "add-prompt")) {
        if (args.len < 3) {
            try stdout.print("Usage: cron add-prompt <schedule> <prompt>\n", .{});
            return;
        }
        try cmdAddPrompt(allocator, args[1], args[2], stdout);
    } else if (std.mem.eql(u8, sub, "remove") or std.mem.eql(u8, sub, "rm")) {
        if (args.len < 2) {
            try stdout.print("Usage: cron remove <id>\n", .{});
            return;
        }
        try cmdRemove(allocator, args[1], stdout);
    } else if (std.mem.eql(u8, sub, "pause")) {
        if (args.len < 2) {
            try stdout.print("Usage: cron pause <id>\n", .{});
            return;
        }
        try cmdSetEnabled(allocator, args[1], false, stdout);
    } else if (std.mem.eql(u8, sub, "resume")) {
        if (args.len < 2) {
            try stdout.print("Usage: cron resume <id>\n", .{});
            return;
        }
        try cmdSetEnabled(allocator, args[1], true, stdout);
    } else if (std.mem.eql(u8, sub, "run")) {
        try cmdRun(allocator, stdout);
    } else {
        try stdout.print("Unknown cron subcommand: {s}\n", .{sub});
        try stdout.print("Subcommands: list | add | add-prompt | remove | pause | resume | run\n", .{});
    }
}

/// Legacy: no-args cron just runs all due tasks.
pub fn runCronOnce(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    try cmdRun(allocator, stdout);
}

// ── subcommands ──────────────────────────────────────────────────────────────

fn cmdList(allocator: std.mem.Allocator, stdout: anytype) !void {
    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| @constCast(t).deinit(allocator);
        allocator.free(tasks);
    }

    if (tasks.len == 0) {
        try stdout.print("No cron tasks. Add one with: cron add <schedule> <command>\n", .{});
        return;
    }

    const now = std.time.timestamp();
    try stdout.print("{s:<8} {s:<6} {s:<14} {s:<10} {s}\n", .{ "ID", "TYPE", "SCHEDULE", "DUE IN", "TASK" });
    try stdout.print("{s}\n", .{"-" ** 70});
    for (tasks) |t| {
        var due_buf: [24]u8 = undefined;
        const due_str: []const u8 = if (!t.enabled)
            "paused"
        else if (t.next_run <= now)
            "NOW"
        else blk: {
            const secs_left = t.next_run - now;
            if (secs_left < 3600) {
                const s = std.fmt.bufPrint(&due_buf, "{d}m", .{@divFloor(secs_left, 60)}) catch "?";
                break :blk s;
            } else if (secs_left < 86400) {
                const s = std.fmt.bufPrint(&due_buf, "{d}h", .{@divFloor(secs_left, 3600)}) catch "?";
                break :blk s;
            } else {
                const s = std.fmt.bufPrint(&due_buf, "{d}d", .{@divFloor(secs_left, 86400)}) catch "?";
                break :blk s;
            }
        };
        const kind = if (t.isPromptTask()) "agent" else "shell";
        const task_str = if (t.isPromptTask()) t.prompt else t.command;
        try stdout.print("{s:<8} {s:<6} {s:<14} {s:<10} {s}\n", .{ t.id, kind, t.schedule, due_str, task_str });
    }
}

fn cmdAdd(allocator: std.mem.Allocator, schedule: []const u8, command: []const u8, stdout: anytype) !void {
    // Validate schedule before persisting.
    _ = parseCronExpr(schedule) catch {
        try stdout.print("Invalid schedule '{s}'. Supported: @hourly @daily @weekly @monthly, or 5-field cron (e.g. '0 * * * *').\n", .{schedule});
        return;
    };

    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| @constCast(t).deinit(allocator);
        allocator.free(tasks);
    }

    const id = try nextId(allocator, tasks);
    defer allocator.free(id);

    const now = std.time.timestamp();
    const nr = computeNextRun(schedule, now);

    var new_tasks = try std.ArrayList(CronTask).initCapacity(allocator, tasks.len + 1);
    defer new_tasks.deinit();
    for (tasks) |t| try new_tasks.append(t);
    try new_tasks.append(CronTask{
        .id       = id,
        .schedule = schedule,
        .command  = command,
        .enabled  = true,
        .last_run = 0,
        .next_run = nr,
        .prompt   = "",
    });

    try saveTasks(allocator, new_tasks.items);
    try stdout.print("Added cron task {s}: [{s}] {s}\n", .{ id, schedule, command });
    try stdout.print("Next run in: {d}s\n", .{nr - now});
}

fn cmdAddPrompt(allocator: std.mem.Allocator, schedule: []const u8, prompt: []const u8, stdout: anytype) !void {
    // Validate schedule.
    _ = parseCronExpr(schedule) catch {
        try stdout.print("Invalid schedule '{s}'. Supported: @hourly @daily @weekly @monthly, or 5-field cron.\n", .{schedule});
        return;
    };

    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| @constCast(t).deinit(allocator);
        allocator.free(tasks);
    }

    const id = try nextId(allocator, tasks);
    defer allocator.free(id);

    const now = std.time.timestamp();
    const nr = computeNextRun(schedule, now);

    var new_tasks = try std.ArrayList(CronTask).initCapacity(allocator, tasks.len + 1);
    defer new_tasks.deinit();
    for (tasks) |t| try new_tasks.append(t);
    try new_tasks.append(CronTask{
        .id       = id,
        .schedule = schedule,
        .command  = "-",   // sentinel: no shell command
        .enabled  = true,
        .last_run = 0,
        .next_run = nr,
        .prompt   = prompt,
    });

    try saveTasks(allocator, new_tasks.items);
    try stdout.print("Added agent-prompt cron task {s}: [{s}] {s}\n", .{ id, schedule, prompt });
    try stdout.print("Next run in: {d}s\n", .{nr - now});
}

fn cmdRemove(allocator: std.mem.Allocator, id: []const u8, stdout: anytype) !void {
    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| @constCast(t).deinit(allocator);
        allocator.free(tasks);
    }

    var kept = std.ArrayList(CronTask).init(allocator);
    defer kept.deinit();
    var found = false;
    for (tasks) |t| {
        if (std.mem.eql(u8, t.id, id)) { found = true; continue; }
        try kept.append(t);
    }

    if (!found) {
        try stdout.print("Cron task '{s}' not found.\n", .{id});
        return;
    }

    try saveTasks(allocator, kept.items);
    try stdout.print("Removed cron task {s}.\n", .{id});
}

fn cmdSetEnabled(allocator: std.mem.Allocator, id: []const u8, enabled: bool, stdout: anytype) !void {
    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| t.deinit(allocator);
        allocator.free(tasks);
    }

    var found = false;
    for (tasks) |*t| {
        if (std.mem.eql(u8, t.id, id)) {
            t.enabled = enabled;
            // When resuming a paused task, recompute next_run from now if it expired.
            if (enabled and t.next_run == 0) {
                t.next_run = computeNextRun(t.schedule, std.time.timestamp());
            }
            found = true;
        }
    }

    if (!found) {
        try stdout.print("Cron task '{s}' not found.\n", .{id});
        return;
    }

    try saveTasks(allocator, tasks);
    const verb = if (enabled) "resumed" else "paused";
    try stdout.print("Cron task {s} {s}.\n", .{ id, verb });
}

/// Run all enabled tasks that are currently due (next_run <= now).
/// After each run, updates last_run and computes next_run for the task.
/// Prompt tasks call the agent; shell tasks exec the command.
fn cmdRun(allocator: std.mem.Allocator, stdout: anytype) !void {
    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| t.deinit(allocator);
        allocator.free(tasks);
    }

    if (tasks.len == 0) {
        try stdout.print("No cron tasks to run.\n", .{});
        return;
    }

    const now = std.time.timestamp();
    var ran: usize = 0;
    var skipped: usize = 0;

    for (tasks) |*t| {
        if (!t.enabled) continue;

        // Tasks with next_run == 0 are considered immediately due.
        const due = (t.next_run == 0) or (now >= t.next_run);
        if (!due) {
            skipped += 1;
            continue;
        }

        if (t.isPromptTask()) {
            // Agent prompt task.
            try runPromptTask(allocator, t, now, stdout);
        } else {
            // Shell command task.
            try stdout.print("[cron] running {s}: {s}\n", .{ t.id, t.command });

            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "/bin/sh", "-c", t.command },
            }) catch |err| {
                try stdout.print("[cron] {s} error: {}\n", .{ t.id, err });
                t.last_run = now;
                t.next_run = computeNextRun(t.schedule, now);
                continue;
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            const out = if (result.stdout.len > 0) result.stdout else result.stderr;
            if (out.len > 0) try stdout.print("{s}", .{out});
        }

        t.last_run = now;
        t.next_run = computeNextRun(t.schedule, now);
        ran += 1;
    }

    try saveTasks(allocator, tasks);
    if (skipped > 0) {
        try stdout.print("[cron] ran {d} task(s), skipped {d} not yet due.\n", .{ ran, skipped });
    } else {
        try stdout.print("[cron] ran {d} task(s).\n", .{ran});
    }
}
