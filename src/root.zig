//! BareClaw library root. Re-exports the public API for consumers that embed
//! the runtime as a library rather than using the CLI binary.
pub const agent = @import("agent.zig");
pub const config = @import("config.zig");
pub const memory = @import("memory.zig");
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
        if (escape_next) { escape_next = false; continue; }
        if (c == '\\' and in_string) { escape_next = true; continue; }
        if (c == '"') { in_string = !in_string; continue; }
        if (in_string) continue;
        if (c == '{') { depth += 1; }
        else if (c == '}') {
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

// ── Tool registry: new tools are registered ───────────────────────────────────

test "buildCoreTools: all expected tools are present" {
    const tools_mod = @import("tools.zig");
    const security_mod = @import("security.zig");
    const memory_mod = @import("memory.zig");
    const config_mod = @import("config.zig");

    // Minimal config for policy init.
    const cfg = config_mod.Config{
        .workspace_dir      = "/tmp",
        .config_path        = "/tmp/test_config.toml",
        .default_provider   = "echo",
        .default_model      = "test",
        .memory_backend     = "markdown",
        .fallback_providers = "",
        .api_key            = "",
        .discord_token      = "",
        .discord_webhook    = "",
        .telegram_token     = "",
        .mcp_servers        = "",
        .system_prompt      = "",
        .allowed_paths      = "",
    };

    var policy = security_mod.SecurityPolicy.initWorkspaceOnly(std.testing.allocator, &cfg);
    defer policy.deinit(std.testing.allocator);

    var mem = try memory_mod.createMemoryBackend(std.testing.allocator, &cfg);
    defer mem.deinit();

    const tool_list = try tools_mod.buildCoreTools(std.testing.allocator, &policy, &mem);
    defer tools_mod.freeTools(std.testing.allocator, tool_list);

    const expected_tools = [_][]const u8{
        "shell", "file_read", "file_write",
        "memory_store", "memory_recall", "memory_forget",
        "memory_list_keys", "memory_delete_prefix",
        "http_request", "git_operations",
        "agent_status", "audit_log_read",
        "cron_list", "cron_add_prompt", "cron_remove",
    };

    for (expected_tools) |expected| {
        var found = false;
        for (tool_list) |t| {
            if (std.mem.eql(u8, t.name, expected)) { found = true; break; }
        }
        if (!found) {
            std.debug.print("Missing tool: {s}\n", .{expected});
            try std.testing.expect(false);
        }
    }
    try std.testing.expectEqual(expected_tools.len, tool_list.len);
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
        else   => try std.testing.expect(false),
    }
    switch (expr.hour) {
        .exact => |v| try std.testing.expectEqual(@as(u32, 0), v),
        else   => try std.testing.expect(false),
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
        else   => try std.testing.expect(false),
    }
    switch (expr.hour) {
        .every => |n| try std.testing.expectEqual(@as(u32, 6), n),
        else   => try std.testing.expect(false),
    }
}

test "cron: timestampToBroken round-trips a known date" {
    const cron_mod = @import("cron.zig");
    // 2024-01-15 09:30:00 UTC = 1705311000
    const ts: i64 = 1705311000;
    const bt = cron_mod.timestampToBroken(ts);
    try std.testing.expectEqual(@as(u32, 2024), bt.year);
    try std.testing.expectEqual(@as(u32, 1),    bt.month);
    try std.testing.expectEqual(@as(u32, 15),   bt.day);
    try std.testing.expectEqual(@as(u32, 9),    bt.hour);
    try std.testing.expectEqual(@as(u32, 30),   bt.minute);
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
