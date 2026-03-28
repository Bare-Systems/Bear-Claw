//! BearClaw library root. Re-exports the public API for consumers that embed
//! the runtime as a library rather than using the CLI binary.
pub const agent = @import("agent.zig");
pub const config = @import("config.zig");
pub const memory = @import("memory.zig");
pub const planner = @import("planner.zig");
pub const provider = @import("provider.zig");
pub const security = @import("security.zig");
pub const tools = @import("tools.zig");

// ── T1-7: Agent loop unit tests ───────────────────────────────────────────────

const std = @import("std");

/// Tests for the JSON extractor added in T1-1.
/// extractJsonObject is private to agent.zig, so we duplicate the logic here
/// under test to verify it handles all documented edge cases.
/// The real function is exercised indirectly via dispatchAllToolCalls.
fn extractJsonObjectTest(input: []const u8) ?[]const u8 {
    var src = input;
    if (std.mem.indexOf(u8, src, "```")) |fence_start| {
        const after_fence = fence_start + 3;
        const newline = std.mem.indexOfScalarPos(u8, src, after_fence, '\n') orelse after_fence;
        const content_start = newline + 1;
        if (std.mem.lastIndexOf(u8, src, "```")) |fence_end| {
            if (fence_end > content_start) {
                src = std.mem.trim(u8, src[content_start..fence_end], " \t\r\n");
            }
        }
    }
    const obj_start = std.mem.indexOfScalar(u8, src, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escape_next = false;
    var i = obj_start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape_next) {
            escape_next = false;
            continue;
        }
        if (c == '\\' and in_string) {
            escape_next = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return src[obj_start .. i + 1];
        }
    }
    return null;
}

test "extractJsonObject: bare JSON passes through" {
    const input = "{\"tool_calls\":[]}";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"tool_calls\":[]}", result.?);
}

test "extractJsonObject: prose-wrapped JSON is extracted" {
    const input = "Sure, let me do that!\n{\"tool_calls\":[{\"function\":\"shell\"}]}\nHope that helps.";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"tool_calls\":[{\"function\":\"shell\"}]}", result.?);
}

test "extractJsonObject: markdown fenced JSON is extracted" {
    const input = "Here is the call:\n```json\n{\"tool_calls\":[]}\n```\nDone.";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"tool_calls\":[]}", result.?);
}

test "extractJsonObject: plain text with no JSON returns null" {
    const input = "I cannot help with that.";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result == null);
}

test "extractJsonObject: nested braces parsed correctly" {
    const input = "{\"tool_calls\":[{\"function\":{\"name\":\"shell\",\"arguments\":{\"command\":\"ls\"}}}]}";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(input, result.?);
}

test "extractJsonObject: escaped quote inside string does not break depth tracking" {
    const input = "{\"key\":\"value with \\\"quotes\\\"\"}";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(input, result.?);
}

test "context budget: MAX_CONTEXT_CHARS constant is sane" {
    // Verify the constant exists and is in a reasonable range for model context windows.
    const max = @import("agent.zig").MAX_CONTEXT_CHARS_EXPORTED;
    try std.testing.expect(max >= 4_000);
    try std.testing.expect(max <= 64_000);
}

test "tool output cap: MAX_TOOL_OUTPUT_CHARS constant is sane" {
    const max = @import("tools.zig").MAX_TOOL_OUTPUT_CHARS;
    try std.testing.expect(max >= 1_000);
    try std.testing.expect(max <= 32_000);
}

// ── T2-1: ConversationHistory unit tests ─────────────────────────────────────

test "ConversationHistory: init and deinit" {
    const agent_mod = @import("agent.zig");
    var h = agent_mod.ConversationHistory.init(std.testing.allocator);
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 0), h.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.totalChars());
}

test "ConversationHistory: append accumulates messages" {
    const agent_mod = @import("agent.zig");
    var h = agent_mod.ConversationHistory.init(std.testing.allocator);
    defer h.deinit();

    try h.append(.user, "hello");
    try h.append(.assistant, "hi there");

    try std.testing.expectEqual(@as(usize, 2), h.messages.items.len);
    try std.testing.expectEqual(agent_mod.MessageRole.user, h.messages.items[0].role);
    try std.testing.expectEqualStrings("hello", h.messages.items[0].content);
    try std.testing.expectEqual(agent_mod.MessageRole.assistant, h.messages.items[1].role);
    try std.testing.expectEqualStrings("hi there", h.messages.items[1].content);
    try std.testing.expectEqual(@as(usize, 13), h.totalChars()); // "hello" + "hi there"
}

test "ConversationHistory: trim evicts oldest messages to fit budget" {
    const agent_mod = @import("agent.zig");
    var h = agent_mod.ConversationHistory.init(std.testing.allocator);
    defer h.deinit();

    // Add three messages of 10 chars each (30 total).
    try h.append(.user, "0123456789");
    try h.append(.assistant, "0123456789");
    try h.append(.user, "0123456789");

    try std.testing.expectEqual(@as(usize, 30), h.totalChars());

    // Trim to 15 chars — should evict oldest messages until ≤ 15.
    h.trim(15);

    // Must retain at least the most recent message.
    try std.testing.expect(h.messages.items.len >= 1);
    try std.testing.expect(h.totalChars() <= 15);
}

test "ConversationHistory: trim keeps single message even if over budget" {
    const agent_mod = @import("agent.zig");
    var h = agent_mod.ConversationHistory.init(std.testing.allocator);
    defer h.deinit();

    try h.append(.user, "this message is longer than the budget");
    h.trim(5); // budget smaller than single message

    // Still keeps the one message — never evicts below 1.
    try std.testing.expectEqual(@as(usize, 1), h.messages.items.len);
}

test "storeSessionTranscript stores transcript under timestamped memory key" {
    const agent_mod = @import("agent.zig");
    const memory_mod = @import("memory.zig");
    const config_mod = @import("config.zig");

    var tmp_name_buf: [96]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(
        &tmp_name_buf,
        "zig-cache/test-session-{d}",
        .{std.crypto.random.int(u64)},
    );
    defer std.fs.cwd().deleteTree(tmp_name) catch {};
    try std.fs.cwd().makePath(tmp_name);

    const workspace_dir = try std.testing.allocator.dupe(u8, tmp_name);
    defer std.testing.allocator.free(workspace_dir);
    const config_path = try std.testing.allocator.dupe(u8, "zig-cache/test-session-config.toml");
    defer std.testing.allocator.free(config_path);

    const cfg = config_mod.Config{
        .workspace_dir = workspace_dir,
        .config_path = config_path,
        .default_provider = "echo",
        .default_model = "test",
        .memory_backend = "markdown",
        .fallback_providers = "",
        .api_key = "",
        .discord_token = "",
        .discord_webhook = "",
        .discord_notify_channel = "",
        .telegram_token = "",
        .mcp_servers = "",
        .system_prompt = "",
        .allowed_paths = "",
    };

    var mem = try memory_mod.createMemoryBackend(std.testing.allocator, &cfg);
    defer mem.deinit();

    var history = agent_mod.ConversationHistory.init(std.testing.allocator);
    defer history.deinit();
    try history.append(.user, "hello");
    try history.append(.assistant, "hi there");

    const stored = try agent_mod.storeSessionTranscript(std.testing.allocator, &mem, &history, 0);
    try std.testing.expect(stored);

    const recalled = try mem.recall("session/1970-01-01T00:00");
    defer std.testing.allocator.free(recalled);
    try std.testing.expect(std.mem.indexOf(u8, recalled, "**User:**") != null);
    try std.testing.expect(std.mem.indexOf(u8, recalled, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, recalled, "**Assistant:**") != null);
    try std.testing.expect(std.mem.indexOf(u8, recalled, "hi there") != null);
}

test "importOpenClawWorkspace imports nested markdown memory files" {
    const migration_mod = @import("migration.zig");
    const memory_mod = @import("memory.zig");
    const config_mod = @import("config.zig");

    var source_name_buf: [96]u8 = undefined;
    const source_workspace = try std.fmt.bufPrint(
        &source_name_buf,
        "zig-cache/test-openclaw-source-{d}",
        .{std.crypto.random.int(u64)},
    );
    defer std.fs.cwd().deleteTree(source_workspace) catch {};
    try std.fs.cwd().makePath("zig-cache");
    try std.fs.cwd().makePath(source_workspace);
    const source_notes_dir = try std.fs.path.join(std.testing.allocator, &.{ source_workspace, "memory", "notes" });
    defer std.testing.allocator.free(source_notes_dir);
    try std.fs.cwd().makePath(source_notes_dir);

    const nested_path = try std.fs.path.join(std.testing.allocator, &.{ source_workspace, "memory", "notes", "idea.md" });
    defer std.testing.allocator.free(nested_path);
    {
        var file = try std.fs.cwd().createFile(nested_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("build the importer\n");
    }

    var target_name_buf: [96]u8 = undefined;
    const target_workspace = try std.fmt.bufPrint(
        &target_name_buf,
        "zig-cache/test-openclaw-target-{d}",
        .{std.crypto.random.int(u64)},
    );
    defer std.fs.cwd().deleteTree(target_workspace) catch {};
    try std.fs.cwd().makePath(target_workspace);

    const workspace_dir = try std.testing.allocator.dupe(u8, target_workspace);
    defer std.testing.allocator.free(workspace_dir);
    const config_path = try std.testing.allocator.dupe(u8, "zig-cache/test-openclaw-config.toml");
    defer std.testing.allocator.free(config_path);

    const cfg = config_mod.Config{
        .workspace_dir = workspace_dir,
        .config_path = config_path,
        .default_provider = "echo",
        .default_model = "test",
        .memory_backend = "markdown",
        .fallback_providers = "",
        .api_key = "",
        .discord_token = "",
        .discord_webhook = "",
        .discord_notify_channel = "",
        .telegram_token = "",
        .mcp_servers = "",
        .system_prompt = "",
        .allowed_paths = "",
    };

    var mem = try memory_mod.createMemoryBackend(std.testing.allocator, &cfg);
    defer mem.deinit();

    const summary = try migration_mod.importOpenClawWorkspace(
        std.testing.allocator,
        source_workspace,
        &mem,
        target_workspace,
    );
    defer std.testing.allocator.free(summary.source_workspace);
    defer std.testing.allocator.free(summary.source_memory_dir);
    defer std.testing.allocator.free(summary.target_workspace);

    try std.testing.expectEqual(@as(usize, 1), summary.imported_entries);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped_entries);

    const recalled = try mem.recall("notes/idea");
    defer std.testing.allocator.free(recalled);
    try std.testing.expect(std.mem.indexOf(u8, recalled, "build the importer") != null);
}

test "parsePeripheralConfig reads enabled flag and board entries" {
    const peripherals_mod = @import("peripherals.zig");

    const sample =
        \\[peripherals]
        \\enabled = true
        \\
        \\[[peripherals.boards]]
        \\board = "arduino-uno"
        \\transport = "serial"
        \\path = "/dev/ttyACM0"
        \\baud = 115200
        \\
        \\[[peripherals.boards]]
        \\board = "rpi-gpio"
        \\transport = "native"
    ;

    var section = try peripherals_mod.parsePeripheralConfig(std.testing.allocator, sample);
    defer section.deinit(std.testing.allocator);

    try std.testing.expect(section.enabled);
    try std.testing.expectEqual(@as(usize, 2), section.boards.len);
    try std.testing.expectEqualStrings("arduino-uno", section.boards[0].board);
    try std.testing.expectEqualStrings("serial", section.boards[0].transport);
    try std.testing.expectEqualStrings("/dev/ttyACM0", section.boards[0].path);
    try std.testing.expectEqual(@as(?u32, 115200), section.boards[0].baud);
    try std.testing.expectEqualStrings("rpi-gpio", section.boards[1].board);
    try std.testing.expectEqualStrings("native", section.boards[1].transport);
    try std.testing.expectEqualStrings("", section.boards[1].path);
    try std.testing.expectEqual(@as(?u32, null), section.boards[1].baud);
}

test "validatePeripheralSection reports missing serial device path" {
    const peripherals_mod = @import("peripherals.zig");

    const sample =
        \\[peripherals]
        \\enabled = true
        \\
        \\[[peripherals.boards]]
        \\board = "arduino-uno"
        \\transport = "serial"
    ;

    var section = try peripherals_mod.parsePeripheralConfig(std.testing.allocator, sample);
    defer section.deinit(std.testing.allocator);

    const issues = try peripherals_mod.validatePeripheralSection(std.testing.allocator, &section);
    defer {
        for (issues) |*issue| @constCast(issue).deinit(std.testing.allocator);
        std.testing.allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqual(@as(usize, 0), issues[0].index);
    try std.testing.expect(std.mem.indexOf(u8, issues[0].message, "requires a device path") != null);
}

test "profile set and get round-trip a value" {
    const profile_mod = @import("profile.zig");

    var workspace_buf: [96]u8 = undefined;
    const workspace = try std.fmt.bufPrint(
        &workspace_buf,
        "zig-cache/test-profile-{d}",
        .{std.crypto.random.int(u64)},
    );
    defer std.fs.cwd().deleteTree(workspace) catch {};
    try std.fs.cwd().makePath(workspace);

    try profile_mod.setValue(std.testing.allocator, workspace, "tone", "formal");
    const value = try profile_mod.getValue(std.testing.allocator, workspace, "tone");
    defer if (value) |v| std.testing.allocator.free(v);

    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("formal", value.?);
}

test "memory search ranks relevant entries first" {
    const memory_mod = @import("memory.zig");
    const config_mod = @import("config.zig");

    var workspace_buf: [96]u8 = undefined;
    const workspace = try std.fmt.bufPrint(
        &workspace_buf,
        "zig-cache/test-memory-search-{d}",
        .{std.crypto.random.int(u64)},
    );
    defer std.fs.cwd().deleteTree(workspace) catch {};
    try std.fs.cwd().makePath(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "zig-cache/test-memory-search-config.toml",
        .default_provider = "echo",
        .default_model = "test-model",
        .memory_backend = "markdown",
        .fallback_providers = "",
        .api_key = "",
        .discord_token = "",
        .discord_webhook = "",
        .discord_notify_channel = "",
        .telegram_token = "",
        .mcp_servers = "",
        .system_prompt = "",
        .allowed_paths = "",
    };

    var mem = try memory_mod.createMemoryBackend(std.testing.allocator, &cfg);
    defer mem.deinit();

    try mem.store("notes/market", "market market signal trend breakout");
    try mem.store("journal/cooking", "recipe ingredients oven dinner");
    try mem.store("notes/mixed", "market dinner overlap");

    const results = try mem.search("market signal", 3);
    defer {
        for (results) |*result| @constCast(result).deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    try std.testing.expect(results.len >= 2);
    try std.testing.expectEqualStrings("notes/market", results[0].key);
    try std.testing.expect(results[0].score >= results[1].score);
}

test "planner stores final reflection and returns execution summary" {
    const planner_mod = @import("planner.zig");
    const memory_mod = @import("memory.zig");
    const config_mod = @import("config.zig");
    const provider_mod = @import("provider.zig");

    const FakeProvider = struct {
        call_count: usize = 0,

        fn chat(
            ptr: *anyopaque,
            _: []const u8,
            _: []const u8,
            _: []const u8,
            _: f32,
            allocator: std.mem.Allocator,
        ) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            defer self.call_count += 1;

            return switch (self.call_count) {
                0 => allocator.dupe(
                    u8,
                    "{\"steps\":[{\"tool\":\"memory_store\",\"args\":{\"key\":\"notes/plan\",\"content\":\"done\"},\"rationale\":\"persist the result\"}]}",
                ),
                1 => allocator.dupe(u8, "{\"action\":\"continue\",\"reason\":\"the plan still looks good\"}"),
                else => allocator.dupe(
                    u8,
                    "## What Worked\nStored the result.\n\n## What Failed\nNothing significant.\n\n## Remember Next Time\nReuse the stored note if the user asks again.",
                ),
            };
        }
    };

    const ExecCtx = struct {
        saw_tool: bool = false,

        fn exec(ptr: *anyopaque, tool_name: []const u8, args_json: []const u8) !planner_mod.ExecutionResult {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.saw_tool = true;
            try std.testing.expectEqualStrings("memory_store", tool_name);
            try std.testing.expect(std.mem.indexOf(u8, args_json, "\"notes/plan\"") != null);
            return planner_mod.ExecutionResult.owned(true, try std.testing.allocator.dupe(u8, "stored"));
        }
    };

    var workspace_buf: [96]u8 = undefined;
    const workspace = try std.fmt.bufPrint(
        &workspace_buf,
        "zig-cache/test-planner-{d}",
        .{std.crypto.random.int(u64)},
    );
    defer std.fs.cwd().deleteTree(workspace) catch {};
    try std.fs.cwd().makePath(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "zig-cache/test-planner-config.toml",
        .default_provider = "echo",
        .default_model = "test-model",
        .memory_backend = "markdown",
        .fallback_providers = "",
        .api_key = "",
        .discord_token = "",
        .discord_webhook = "",
        .discord_notify_channel = "",
        .telegram_token = "",
        .mcp_servers = "",
        .system_prompt = "",
        .allowed_paths = "",
    };

    var mem = try memory_mod.createMemoryBackend(std.testing.allocator, &cfg);
    defer mem.deinit();

    var fake = FakeProvider{};
    const any_provider = provider_mod.AnyProvider{
        .ptr = &fake,
        .chatFn = FakeProvider.chat,
        .allocator = std.testing.allocator,
    };

    var exec_ctx = ExecCtx{};
    const summary = try planner_mod.planAndExecute(
        std.testing.allocator,
        any_provider,
        "test-model",
        &mem,
        &[_]planner_mod.ToolDescriptor{
            .{ .name = "memory_store", .description = "Store a memory value" },
        },
        &exec_ctx,
        ExecCtx.exec,
        "Remember this result",
    );
    defer std.testing.allocator.free(summary);

    try std.testing.expect(exec_ctx.saw_tool);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Final Reflection") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Stored the result") != null);

    const latest = try mem.recall("reflection/latest");
    defer std.testing.allocator.free(latest);
    try std.testing.expect(std.mem.indexOf(u8, latest, "## Remember Next Time") != null);

    const reflection_dir = try std.fs.path.join(std.testing.allocator, &.{ workspace, "memory", "reflection" });
    defer std.testing.allocator.free(reflection_dir);
    var dir = try std.fs.cwd().openDir(reflection_dir, .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file) count += 1;
    }
    try std.testing.expect(count >= 2);
}

// ── Tool registry: new tools are registered ───────────────────────────────────

test "buildCoreTools: all expected tools are present" {
    const tools_mod = @import("tools.zig");
    const security_mod = @import("security.zig");
    const memory_mod = @import("memory.zig");
    const config_mod = @import("config.zig");

    // Minimal config for policy init.
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/test_config.toml",
        .default_provider = "echo",
        .default_model = "test",
        .memory_backend = "markdown",
        .fallback_providers = "",
        .api_key = "",
        .discord_token = "",
        .discord_webhook = "",
        .discord_notify_channel = "",
        .telegram_token = "",
        .mcp_servers = "",
        .system_prompt = "",
        .allowed_paths = "",
    };

    var policy = security_mod.SecurityPolicy.initWorkspaceOnly(std.testing.allocator, &cfg);
    defer policy.deinit(std.testing.allocator);

    var mem = try memory_mod.createMemoryBackend(std.testing.allocator, &cfg);
    defer mem.deinit();

    const tool_list = try tools_mod.buildCoreTools(std.testing.allocator, &policy, &mem);
    defer tools_mod.freeTools(std.testing.allocator, tool_list);

    const expected_tools = [_][]const u8{
        "shell",           "file_read",        "file_write",
        "memory_store",    "memory_recall",    "memory_forget",
        "memory_search",   "profile_get",      "profile_set",
        "planner_execute", "memory_list_keys", "memory_delete_prefix",
        "http_request",    "git_operations",   "agent_status",
        "audit_log_read",  "discord_notify",   "cron_list",
        "cron_add_prompt", "cron_remove",      "cron_run",
    };

    for (expected_tools) |expected| {
        var found = false;
        for (tool_list) |t| {
            if (std.mem.eql(u8, t.name, expected)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Missing tool: {s}\n", .{expected});
            try std.testing.expect(false);
        }
    }
    try std.testing.expectEqual(expected_tools.len, tool_list.len);
}

test "agent_status reports provider model and loaded tools" {
    const tools_mod = @import("tools.zig");
    const security_mod = @import("security.zig");
    const memory_mod = @import("memory.zig");
    const config_mod = @import("config.zig");

    const cfg = config_mod.Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/test_config.toml",
        .default_provider = "echo",
        .default_model = "test-model",
        .memory_backend = "markdown",
        .fallback_providers = "",
        .api_key = "",
        .discord_token = "",
        .discord_webhook = "",
        .discord_notify_channel = "",
        .telegram_token = "",
        .mcp_servers = "",
        .system_prompt = "",
        .allowed_paths = "",
    };

    var policy = security_mod.SecurityPolicy.initWorkspaceOnly(std.testing.allocator, &cfg);
    defer policy.deinit(std.testing.allocator);

    var mem = try memory_mod.createMemoryBackend(std.testing.allocator, &cfg);
    defer mem.deinit();

    const tool_list = try tools_mod.buildCoreTools(std.testing.allocator, &policy, &mem);
    defer tools_mod.freeTools(std.testing.allocator, tool_list);

    var ctx = tools_mod.ToolContext{
        .allocator = std.testing.allocator,
        .policy = &policy,
        .memory = &mem,
        .cfg = &cfg,
        .all_tools = tool_list,
    };

    const status_tool = for (tool_list) |tool| {
        if (std.mem.eql(u8, tool.name, "agent_status")) break tool;
    } else return error.TestUnexpectedResult;

    const result = try status_tool.executeFn(&ctx, "{}");
    defer if (result.allocated) std.testing.allocator.free(result.output);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "provider: echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "model: test-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "loaded_tools:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "agent_status") != null);
}

// ── T2-3: Cron expression parser unit tests ───────────────────────────────────

test "cron: parseCronExpr rejects garbage" {
    const cron_mod = @import("cron.zig");
    try std.testing.expectError(error.InvalidCronExpr, cron_mod.parseCronExpr("not-a-cron"));
    try std.testing.expectError(error.InvalidCronExpr, cron_mod.parseCronExpr("* * * *")); // only 4 fields
    try std.testing.expectError(error.InvalidCronExpr, cron_mod.parseCronExpr("*/0 * * * *")); // step of 0
}

test "cron: parseCronExpr accepts @ aliases" {
    const cron_mod = @import("cron.zig");
    // @daily should parse without error.
    const expr = try cron_mod.parseCronExpr("@daily");
    // @daily = "0 0 * * *" → minute=exact(0), hour=exact(0), others=any
    switch (expr.minute) {
        .exact => |v| try std.testing.expectEqual(@as(u32, 0), v),
        else => try std.testing.expect(false),
    }
    switch (expr.hour) {
        .exact => |v| try std.testing.expectEqual(@as(u32, 0), v),
        else => try std.testing.expect(false),
    }
    switch (expr.dom) {
        .any => {},
        else => try std.testing.expect(false),
    }
}

test "cron: parseCronExpr accepts every-N syntax" {
    const cron_mod = @import("cron.zig");
    const expr = try cron_mod.parseCronExpr("*/15 */6 * * *");
    switch (expr.minute) {
        .every => |n| try std.testing.expectEqual(@as(u32, 15), n),
        else => try std.testing.expect(false),
    }
    switch (expr.hour) {
        .every => |n| try std.testing.expectEqual(@as(u32, 6), n),
        else => try std.testing.expect(false),
    }
}

test "cron: timestampToBroken round-trips a known date" {
    const cron_mod = @import("cron.zig");
    // 2024-01-15 09:30:00 UTC = 1705311000
    const ts: i64 = 1705311000;
    const bt = cron_mod.timestampToBroken(ts);
    try std.testing.expectEqual(@as(u32, 2024), bt.year);
    try std.testing.expectEqual(@as(u32, 1), bt.month);
    try std.testing.expectEqual(@as(u32, 15), bt.day);
    try std.testing.expectEqual(@as(u32, 9), bt.hour);
    try std.testing.expectEqual(@as(u32, 30), bt.minute);
}

test "cron: nextRunAfter advances by at least 60s" {
    const cron_mod = @import("cron.zig");
    // "* * * * *" should fire every minute.
    const expr = try cron_mod.parseCronExpr("* * * * *");
    const now: i64 = 1705311000;
    const next = cron_mod.nextRunAfter(expr, now);
    try std.testing.expect(next > now);
    try std.testing.expect(next >= now + 60);
    // And it should be at most 2 minutes away.
    try std.testing.expect(next <= now + 120);
}

test "cron: nextRunAfter for @hourly fires within 1 hour" {
    const cron_mod = @import("cron.zig");
    const expr = try cron_mod.parseCronExpr("@hourly");
    const now: i64 = 1705311000;
    const next = cron_mod.nextRunAfter(expr, now);
    try std.testing.expect(next > now);
    try std.testing.expect(next <= now + 3600);
}

test "cron: nextRunAfter for @daily fires within 24 hours" {
    const cron_mod = @import("cron.zig");
    const expr = try cron_mod.parseCronExpr("@daily");
    const now: i64 = 1705311000;
    const next = cron_mod.nextRunAfter(expr, now);
    try std.testing.expect(next > now);
    try std.testing.expect(next <= now + 86400);
}
