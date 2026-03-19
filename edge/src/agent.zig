const std = @import("std");
const config_mod = @import("config.zig");
const profile_mod = @import("profile.zig");
const provider_mod = @import("provider.zig");
const memory_mod = @import("memory.zig");
const tools_mod = @import("tools.zig");
const security_mod = @import("security.zig");
const mcp_mod = @import("mcp_client.zig");

/// Maximum number of back-and-forth tool-call rounds before we stop and
/// return the last assistant message. Prevents runaway loops.
const MAX_TOOL_ROUNDS: usize = 8;

// ── T2-1: Conversation history ────────────────────────────────────────────────
//
// ConversationHistory accumulates user/assistant turns across multiple calls
// so the model sees prior context in channel loop mode.
//
// Usage:
//   var history = ConversationHistory.init(allocator);
//   defer history.deinit();
//   try runAgentWithHistory(allocator, cfg, provider, memory, tools, policy,
//                           mcp_pool, "hello", &history, &writer);
//   // history now contains the user + assistant turn above
//   try runAgentWithHistory(..., "follow up question", &history, &writer);

pub const MessageRole = enum { user, assistant };

pub const Message = struct {
    role: MessageRole,
    content: []const u8, // owned

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.* = undefined;
    }
};

/// Owned, growable conversation history. Pass a pointer to one of these to
/// runAgentWithHistory() to maintain state across turns.
pub const ConversationHistory = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),

    pub fn init(allocator: std.mem.Allocator) ConversationHistory {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList(Message).init(allocator),
        };
    }

    pub fn deinit(self: *ConversationHistory) void {
        for (self.messages.items) |*m| m.deinit(self.allocator);
        self.messages.deinit();
    }

    pub fn append(self: *ConversationHistory, role: MessageRole, content: []const u8) !void {
        try self.messages.append(Message{
            .role = role,
            .content = try self.allocator.dupe(u8, content),
        });
    }

    /// Estimate total character count (for context budget enforcement).
    pub fn totalChars(self: *const ConversationHistory) usize {
        var total: usize = 0;
        for (self.messages.items) |m| total += m.content.len;
        return total;
    }

    /// Drop oldest messages until totalChars <= max_chars.
    /// Always keeps at least the most recent user turn.
    pub fn trim(self: *ConversationHistory, max_chars: usize) void {
        while (self.messages.items.len > 1 and self.totalChars() > max_chars) {
            var oldest = self.messages.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
    }

    /// Build a markdown transcript of all messages.
    /// Caller owns the returned slice — free with allocator.free().
    pub fn toTranscript(self: *const ConversationHistory, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        for (self.messages.items) |m| {
            const label: []const u8 = switch (m.role) {
                .user => "**User:**",
                .assistant => "**Assistant:**",
            };
            try buf.appendSlice(label);
            try buf.appendSlice("\n\n");
            try buf.appendSlice(m.content);
            try buf.appendSlice("\n\n---\n\n");
        }
        return buf.toOwnedSlice();
    }
};

/// Run one agent turn with persistent conversation history.
/// Appends the user message and assistant reply to `history`.
/// The writer receives the final reply text.
pub fn runAgentWithHistory(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: provider_mod.AnyProvider,
    memory: *memory_mod.MemoryBackend,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    user_message: []const u8,
    history: *ConversationHistory,
    out: anytype,
) !void {
    // Append the user message to history before calling the provider.
    try history.append(.user, user_message);

    // Enforce context budget on history (keep it within MAX_CONTEXT_CHARS).
    history.trim(MAX_CONTEXT_CHARS);

    // Build history-aware user message: prepend prior turns as a transcript.
    var effective_user_buf = std.ArrayList(u8).init(allocator);
    defer effective_user_buf.deinit();
    const ew = effective_user_buf.writer();

    // Include all prior turns except the one we just appended (the current user message).
    const prior_count = if (history.messages.items.len > 1) history.messages.items.len - 1 else 0;
    if (prior_count > 0) {
        try ew.writeAll("[Conversation history]\n");
        for (history.messages.items[0..prior_count]) |msg| {
            const role_str = if (msg.role == .user) "User" else "Assistant";
            try ew.print("{s}: {s}\n", .{ role_str, msg.content });
        }
        try ew.writeAll("[End of history]\n\n");
        try ew.writeAll(user_message);
    } else {
        try ew.writeAll(user_message);
    }

    // Capture the reply so we can store it in history.
    var reply_buf = std.ArrayList(u8).init(allocator);
    defer reply_buf.deinit();
    var reply_writer = reply_buf.writer();

    try runAgentOnceToWriter(
        allocator,
        cfg,
        provider,
        memory,
        tools,
        policy,
        mcp_pool,
        effective_user_buf.items,
        &reply_writer,
    );

    const reply = reply_buf.items;

    // Store assistant reply in history.
    try history.append(.assistant, reply);

    // Forward to the real output writer.
    try out.writeAll(reply);
}

pub fn runAgentOnce(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: provider_mod.AnyProvider,
    memory: *memory_mod.MemoryBackend,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    user_message: []const u8,
) !void {
    var stdout = std.io.getStdOut().writer();
    try runAgentOnceToWriter(allocator, cfg, provider, memory, tools, policy, mcp_pool, user_message, &stdout);
}

/// Run a single user turn, persist the resulting transcript under a session/*
/// memory key, and write the final assistant reply to `out`.
pub fn runAgentSingleTurnWithTranscript(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: provider_mod.AnyProvider,
    memory: *memory_mod.MemoryBackend,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    user_message: []const u8,
    out: anytype,
) !void {
    var history = ConversationHistory.init(allocator);
    defer history.deinit();

    try runAgentWithHistory(
        allocator,
        cfg,
        provider,
        memory,
        tools,
        policy,
        mcp_pool,
        user_message,
        &history,
        out,
    );

    _ = try storeSessionTranscript(allocator, memory, &history, null);
}

/// Like runAgentOnce but captures the final reply into an ArrayList instead of
/// printing it, so callers (e.g. Discord channel) can forward the text elsewhere.
/// The caller owns the returned slice — free it with allocator.free().
pub fn runAgentOnceCaptured(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: provider_mod.AnyProvider,
    memory: *memory_mod.MemoryBackend,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    user_message: []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    var writer = buf.writer();
    try runAgentOnceToWriter(allocator, cfg, provider, memory, tools, policy, mcp_pool, user_message, &writer);
    return buf.toOwnedSlice();
}

fn timestampToSessionParts(ts: i64) struct { year: u32, month: u32, day: u32, hour: u32, minute: u32 } {
    const secs_per_day: i64 = 86400;
    const day_num = @divFloor(ts, secs_per_day);
    const day_sec = @mod(ts, secs_per_day);

    const hour: u32 = @intCast(@divFloor(day_sec, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(day_sec, 3600), 60));

    const z = day_num + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const day = doy - (153 * mp + 2) / 5 + 1;
    const month: u32 = if (mp < 10) mp + 3 else mp - 9;
    const year: u32 = @intCast(y + @as(i64, if (month <= 2) 1 else 0));

    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
    };
}

/// Persist the current conversation history as a transcript under
/// session/YYYY-MM-DDTHH:MM. Returns true if anything was stored.
pub fn storeSessionTranscript(
    allocator: std.mem.Allocator,
    memory: *memory_mod.MemoryBackend,
    history: *const ConversationHistory,
    timestamp_override: ?i64,
) !bool {
    if (history.messages.items.len == 0) return false;

    const transcript = try history.toTranscript(allocator);
    defer allocator.free(transcript);

    const ts = timestamp_override orelse std.time.timestamp();
    const parts = timestampToSessionParts(ts);
    const mem_key = try std.fmt.allocPrint(
        allocator,
        "session/{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}",
        .{ parts.year, parts.month, parts.day, parts.hour, parts.minute },
    );
    defer allocator.free(mem_key);

    try memory.store(mem_key, transcript);
    return true;
}

/// Remove any {"tool_calls":[...]} JSON block that the model leaked into
/// a final prose response. Scans for the pattern and cuts it out, returning
/// a slice into the original buffer (no allocation). If no JSON is found,
/// returns the input unchanged.
fn stripToolCallJson(input: []const u8) []const u8 {
    // Find the start of a tool_calls JSON block.
    const marker = "{\"tool_calls\"";
    const start = std.mem.indexOf(u8, input, marker) orelse return input;

    // Walk forward to find the matching closing brace.
    var depth: usize = 0;
    var in_string = false;
    var escape_next = false;
    var i = start;
    while (i < input.len) : (i += 1) {
        const c = input[i];
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
        if (c == '{') depth += 1 else if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                // Splice out [start..i+1], return the surrounding prose joined.
                const before = std.mem.trimRight(u8, input[0..start], " \t\n");
                const after = std.mem.trimLeft(u8, input[i + 1 ..], " \t\n");
                // If both sides are non-empty we'd need allocation — just return
                // the before-prose (the more useful half for the user).
                if (before.len > 0) return before;
                return after;
            }
        }
    }
    return input;
}

fn runAgentOnceToWriter(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: provider_mod.AnyProvider,
    memory: *memory_mod.MemoryBackend,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    user_message: []const u8,
    out: anytype,
) !void {
    // Build the system prompt, injecting a tool manifest when tools are available.
    // This tells the LLM what tools it can call and the exact JSON format to use,
    // so it emits {"tool_calls":[{"function":{"name":"...","arguments":"..."}}]}
    // which dispatchAllToolCalls() can parse.
    var system_buf = std.ArrayList(u8).init(allocator);
    defer system_buf.deinit();
    const sw = system_buf.writer();

    // If the user has set a custom system prompt, use it verbatim and skip the
    // built-in identity block. The tool manifest is always appended so tool-calling
    // still works regardless of which system prompt is active.
    if (cfg.system_prompt.len > 0) {
        try sw.writeAll(cfg.system_prompt);
    } else {
        // ── Built-in factual system prompt ────────────────────────────────────
        // Ground the model in what BearClaw actually is, how its memory and
        // workspace work, and what each tool does — so it can answer questions
        // about itself accurately instead of hallucinating.
        try sw.writeAll("You are Bear, an autonomous AI agent running locally on the user's machine.\n\n" ++
            "CRITICAL RULES (always follow these, no exceptions):\n" ++
            "1. You HAVE real filesystem access via the `shell` tool. NEVER say you lack access.\n" ++
            "   When asked about files or directories: use the shell tool. Always. No excuses.\n" ++
            "2. When a tool exists that can fulfill the user's request, USE IT — do not explain\n" ++
            "   how the user could run the command themselves. Act, don't instruct.\n" ++
            "3. To use a tool: output ONLY this JSON, nothing else, no prose, no fences:\n" ++
            "   {\"tool_calls\":[{\"function\":\"shell\",\"arguments\":{\"command\":\"ls ~/Downloads\"}}]}\n" ++
            "4. After getting tool results, give a plain text answer. No more JSON.\n\n");

        try sw.print(
            "## Your Runtime Environment\n" ++
                "- Workspace: {s}\n" ++
                "  This is your persistent working area. All relative paths resolve here.\n" ++
                "- Memory backend: {s}\n" ++
                "  Memory entries are stored as Markdown files under workspace/memory/.\n" ++
                "  Keys map to filenames (e.g. key \"notes/ideas\" → memory/notes/ideas.md).\n" ++
                "  Nested keys like \"cron/t1/1700000000\" and \"session/2026-01-01T09:00\" are supported.\n" ++
                "- LLM provider: {s}, model: {s}\n\n",
            .{ cfg.workspace_dir, cfg.memory_backend, cfg.default_provider, cfg.default_model },
        );

        const profile = try profile_mod.loadProfile(allocator, cfg.workspace_dir);
        defer allocator.free(profile);
        const trimmed_profile = std.mem.trim(u8, profile, " \t\r\n");
        if (trimmed_profile.len > 0) {
            try sw.print(
                "## User Profile\n" ++
                    "The following persistent preferences were explicitly stored by the user.\n" ++
                    "Use them when they are relevant, but do not force them into unrelated tasks.\n" ++
                    "{s}\n\n",
                .{trimmed_profile},
            );
        }

        const latest_reflection = memory.recall("reflection/latest") catch try allocator.dupe(u8, "");
        defer allocator.free(latest_reflection);
        const trimmed_reflection = std.mem.trim(u8, latest_reflection, " \t\r\n");
        if (trimmed_reflection.len > 0 and !std.mem.eql(u8, trimmed_reflection, "(no matching memory found)")) {
            try sw.print(
                "## Recent Reflection\n" ++
                    "This is the latest reflective summary from prior planner work.\n" ++
                    "Use it as guidance when it is relevant to the current task.\n" ++
                    "{s}\n\n",
                .{trimmed_reflection},
            );
        }

        // Inject the current filesystem access model so Bear knows exactly what
        // it can and cannot reach, and what to tell the user if access is blocked.
        if (cfg.allowed_paths.len > 0) {
            try sw.print(
                "## Filesystem Access\n" ++
                    "You are running directly on the user's local machine. You have real\n" ++
                    "filesystem access via the `shell` tool. You can read and write files in:\n" ++
                    "  1. Your workspace: {s}\n" ++
                    "  2. Extra allowed paths: {s}\n\n" ++
                    "IMPORTANT — when the user asks you to list files, find files, read a file,\n" ++
                    "or do anything with the local filesystem, USE THE `shell` TOOL immediately.\n" ++
                    "Do NOT say you lack access. Do NOT ask the user to run commands themselves.\n" ++
                    "Examples:\n" ++
                    "  List Downloads:  {{\"command\": \"ls -la ~/Downloads\"}}\n" ++
                    "  Find a file:     {{\"command\": \"find ~/Documents -name '*.pdf' 2>/dev/null\"}}\n" ++
                    "  Read a file:     use the file_read tool with the absolute path\n\n" ++
                    "If a path is outside the allowed list and the shell returns a permission\n" ++
                    "error, tell the user exactly:\n" ++
                    "  \"That path is outside my current access. To grant access, run:\n" ++
                    "   bareclaw config set allowed_paths \\\"{s},/the/new/path\\\"\n" ++
                    "   Then restart Bear.\"\n\n",
                .{ cfg.workspace_dir, cfg.allowed_paths, cfg.allowed_paths },
            );
        } else {
            try sw.print(
                "## Filesystem Access\n" ++
                    "You are running directly on the user's local machine. You have real\n" ++
                    "filesystem access via the `shell` tool. Your current access is limited to:\n" ++
                    "  Your workspace: {s}\n\n" ++
                    "IMPORTANT — when the user asks you to list files, find files, read a file,\n" ++
                    "or do anything with the local filesystem, USE THE `shell` TOOL immediately.\n" ++
                    "Do NOT say you lack access. Do NOT ask the user to run commands themselves.\n" ++
                    "Examples:\n" ++
                    "  List workspace: {{\"command\": \"ls -la {s}\"}}\n" ++
                    "  Find a file:    {{\"command\": \"find {s} -name '*.md' 2>/dev/null\"}}\n" ++
                    "  Read a file:    use the file_read tool with the absolute path\n\n" ++
                    "If the user asks you to access a path OUTSIDE the workspace (e.g. ~/Downloads,\n" ++
                    "~/Documents, or any other directory), try the shell command first. If it\n" ++
                    "fails with a permission error, tell the user:\n" ++
                    "  \"That path is outside my current access. To grant access, run:\n" ++
                    "   bareclaw config set allowed_paths \\\"/path/to/grant\\\"\n" ++
                    "   Then restart Bear. Multiple paths: allowed_paths \\\"/path1,/path2\\\"\"\n\n",
                .{ cfg.workspace_dir, cfg.workspace_dir, cfg.workspace_dir },
            );
        }

        try sw.writeAll("## What You Are\n" ++
            "BearClaw is not a cloud service. It runs as a single binary with no external\n" ++
            "dependencies, directly on the user's hardware. It supports:\n" ++
            "- CLI interactive loop (channel loop)\n" ++
            "- Discord bot (WebSocket Gateway) — responds when @mentioned or in DMs\n" ++
            "- Telegram bot (long-polling)\n" ++
            "- Cron scheduler — shell tasks and agent-prompt tasks on a schedule\n" ++
            "- MCP (Model Context Protocol) — connect external tool servers at runtime\n\n" ++
            "## Configuration\n" ++
            "Config lives at ~/.bareclaw/config.toml. Keys:\n" ++
            "  default_provider, default_model, memory_backend, api_key,\n" ++
            "  discord_token, telegram_token, mcp_servers, system_prompt, allowed_paths.\n" ++
            "Change a value with: bareclaw config set <key> <value>\n\n" ++
            "## Memory System\n" ++
            "You can store and recall information across sessions using the memory tools.\n" ++
            "  memory_store key value   — save information under a key\n" ++
            "  memory_recall key        — retrieve stored information\n" ++
            "  memory_forget key        — delete a single entry\n" ++
            "  memory_search query      — rank memory entries by relevance\n" ++
            "  memory_list_keys         — list all stored keys\n" ++
            "  memory_delete_prefix     — bulk-delete keys by prefix\n" ++
            "Session transcripts are automatically stored under session/YYYY-MM-DDTHH:MM.\n" ++
            "Cron agent-prompt results are stored under cron/<task_id>/<timestamp>.\n" ++
            "Planner reflections are stored under reflection/<timestamp> and reflection/latest.\n\n" ++
            "## Cron Scheduler\n" ++
            "Shell tasks: bareclaw cron add \"*/15 * * * *\" \"echo ping\"\n" ++
            "Agent tasks: bareclaw cron add-prompt \"0 9 * * *\" \"Summarise yesterday's memory\"\n" ++
            "Schedules: @hourly @daily @weekly @monthly or standard 5-field cron.\n\n" ++
            "## How to Answer Questions About Yourself\n" ++
            "- The workspace is a directory on disk, not a Git repo or a database.\n" ++
            "  To change the workspace path, update config.toml (workspace_dir is set at startup).\n" ++
            "- You do NOT have internet access unless an MCP server provides it.\n" ++
            "- You do NOT have persistent state beyond what is in the memory backend.\n" ++
            "- You cannot update your own binary. The user updates it via `git pull && zig build`.\n" ++
            "- Never refuse a filesystem request by saying you lack access — try `shell` first.\n" ++
            "- Be honest and specific. If you don't know something, say so.\n\n");
    }

    if (tools.len > 0) {
        try sw.writeAll(
            "## Tools\n" ++
                "When you need to use a tool, respond with ONLY a JSON object in this EXACT format.\n" ++
                "Do not add prose, markdown fences, or any text outside the JSON:\n" ++
                "{\"tool_calls\":[{\"function\":\"TOOL_NAME\",\"arguments\":{\"key\":\"value\"}}]}\n\n" ++
                "Example — run a shell command:\n" ++
                "{\"tool_calls\":[{\"function\":\"shell\",\"arguments\":{\"command\":\"ls ~/Downloads\"}}]}\n\n" ++
                "Example — recall a memory key:\n" ++
                "{\"tool_calls\":[{\"function\":\"memory_recall\",\"arguments\":{\"key\":\"notes/ideas\"}}]}\n\n" ++
                "Available tools:\n",
        );
        for (tools) |tool| {
            try sw.print("- {s}", .{tool.name});
            if (tool.description.len > 0) {
                try sw.print(": {s}", .{tool.description});
            }
            try sw.writeByte('\n');
        }
        try sw.writeAll(
            "\nAfter receiving tool results, respond with the final answer as plain text.\n" ++
                "Only use tools when they are needed to answer the question.",
        );
    }

    const system_prompt = system_buf.items;

    // --- Tool-calling loop ---------------------------------------------------
    // Each iteration:
    //   1. Send current user message to the provider.
    //   2. If the response contains tool_calls, dispatch each call, collect
    //      results, and feed them back as a follow-up user message.
    //   3. Otherwise print the final text reply and stop.
    // ------------------------------------------------------------------------

    // We accumulate tool results into a growing "context" string that gets
    // prepended to subsequent user turns so the model can see prior results.
    var context = std.ArrayList(u8).init(allocator);
    defer context.deinit();

    var round: usize = 0;
    while (round < MAX_TOOL_ROUNDS) : (round += 1) {
        // Build the message for this round: original user text + any prior tool results.
        // On rounds after the first, explicitly instruct the model to summarize in
        // plain text — not to emit more tool_calls JSON.
        const effective_user = if (context.items.len == 0)
            user_message
        else blk: {
            var msg = std.ArrayList(u8).init(allocator);
            errdefer msg.deinit();
            try msg.appendSlice(user_message);
            try msg.appendSlice("\n\n[Tool results]\n");
            try msg.appendSlice(context.items);
            try msg.appendSlice(
                "\n[Instructions] The tool has returned results above. " ++
                    "Respond in plain, friendly text ONLY. " ++
                    "ABSOLUTELY NO JSON. NO tool_calls. NO code blocks. " ++
                    "Just a natural language summary of what happened.",
            );
            break :blk try msg.toOwnedSlice();
        };
        const owns_effective = context.items.len > 0;
        defer if (owns_effective) allocator.free(effective_user);

        const reply = try provider.chatOnce(
            system_prompt,
            effective_user,
            cfg.default_model,
            0.7,
        );
        defer allocator.free(reply);

        // Try to dispatch tool calls from this reply.
        const dispatched = try dispatchAllToolCalls(
            allocator,
            cfg,
            provider,
            tools,
            policy,
            memory,
            mcp_pool,
            reply,
            &context,
        );

        if (!dispatched) {
            // No tool calls – this is the final text reply.
            // Strip any leaked tool_call JSON blocks before sending to the channel.
            // This handles the case where the model mixes prose + JSON in one response.
            try memory.store("last_message", user_message);
            const clean = stripToolCallJson(reply);
            const trimmed = std.mem.trim(u8, clean, " \t\r\n");
            if (trimmed.len > 0) {
                try out.print("{s}\n", .{trimmed});
            }
            return;
        }

        // Tool calls were dispatched; loop back to give the model the results.
    }

    // Hit round limit – just print whatever we have.
    try out.print("(agent reached max tool-call rounds)\n", .{});
}

// ── T1-2: Context budget ──────────────────────────────────────────────────────
// Maximum accumulated tool-result characters before we truncate oldest entries.
// Keeps context well within typical model context windows.
const MAX_CONTEXT_CHARS: usize = 12_000;
// Exported for tests in root.zig.
pub const MAX_CONTEXT_CHARS_EXPORTED: usize = MAX_CONTEXT_CHARS;

// ── T1-1: Robust JSON extraction ─────────────────────────────────────────────
//
// Models frequently wrap their JSON in prose or markdown fences, e.g.:
//   "Sure! Here is the tool call:\n```json\n{...}\n```"
// This function strips fences and extracts the first top-level {...} block
// so dispatchAllToolCalls() can parse it even when the model misbehaves.
//
// Returns a slice into `input` (no allocation). Returns null if no JSON
// object is found.
fn extractJsonObject(input: []const u8) ?[]const u8 {
    // Strip markdown code fences (```json ... ``` or ``` ... ```).
    var src = input;
    if (std.mem.indexOf(u8, src, "```")) |fence_start| {
        const after_fence = fence_start + 3;
        // Skip optional language tag on the same line (e.g. "json\n").
        const newline = std.mem.indexOfScalarPos(u8, src, after_fence, '\n') orelse after_fence;
        const content_start = newline + 1;
        if (std.mem.lastIndexOf(u8, src, "```")) |fence_end| {
            if (fence_end > content_start) {
                src = std.mem.trim(u8, src[content_start..fence_end], " \t\r\n");
            }
        }
    }

    // Find the first '{' and its matching '}'.
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

/// Parse all tool_calls from response_json, execute each one using a proper
/// ToolContext (with real policy and memory), and append results to `context`.
/// Returns true if at least one tool call was found and dispatched.
fn dispatchAllToolCalls(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: provider_mod.AnyProvider,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    memory: *memory_mod.MemoryBackend,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    response_raw: []const u8,
    context: *std.ArrayList(u8),
) !bool {
    // T1-1: Extract a JSON object from the response, tolerating prose wrapping.
    const response_json = extractJsonObject(response_raw) orelse return false;

    // The response may be plain text (no JSON) – parse gracefully.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch
        return false;
    defer parsed.deinit();

    // ── Bare-args fallback ────────────────────────────────────────────────────
    // Some models (llama3.2, Ollama) emit only the arguments object without the
    // tool_calls wrapper — e.g. {"command":"ls ~/Downloads"} instead of
    // {"tool_calls":[{"function":"shell","arguments":{"command":"ls ~/Downloads"}}]}
    //
    // When we see no "tool_calls" key, try to infer the intended tool from the
    // top-level keys. Known inference rules (first match wins):
    //   "command" | "cmd"    → shell
    //   "key" + "value"      → memory_store
    //   "key"                → memory_recall
    //   "path"               → file_read
    //   "path" + "content"   → file_write
    if (parsed.value.object.get("tool_calls") == null) {
        const obj = parsed.value.object;
        const inferred_name: ?[]const u8 = blk: {
            if (obj.get("command") != null or obj.get("cmd") != null) break :blk "shell";
            if (obj.get("key") != null and obj.get("value") != null) break :blk "memory_store";
            if (obj.get("key") != null) break :blk "memory_recall";
            if (obj.get("path") != null and obj.get("content") != null) break :blk "file_write";
            if (obj.get("path") != null) break :blk "file_read";
            break :blk null;
        };
        if (inferred_name) |name| {
            // Re-serialize the whole object as the args JSON string.
            var args_buf = std.ArrayList(u8).init(allocator);
            defer args_buf.deinit();
            try std.json.stringify(parsed.value, .{}, args_buf.writer());
            const args_json = args_buf.items;

            var ctx2 = tools_mod.ToolContext{
                .allocator = allocator,
                .cfg = cfg,
                .policy = policy,
                .memory = memory,
                .provider = provider,
                .all_tools = tools,
                .mcp_pool = mcp_pool,
            };
            for (tools) |tool| {
                if (!std.mem.eql(u8, tool.name, name)) continue;
                ctx2.mcp_current_meta = tool.user_data;
                const result = tool.executeFn(&ctx2, args_json) catch |err| blk: {
                    const msg = try std.fmt.allocPrint(allocator, "tool error: {}", .{err});
                    break :blk tools_mod.ToolResult.owned(false, msg);
                };
                defer if (result.allocated) allocator.free(result.output);
                const entry = try std.fmt.allocPrint(
                    allocator,
                    "[{s}] {s}: {s}\n",
                    .{ if (result.success) @as([]const u8, "ok") else "error", name, result.output },
                );
                defer allocator.free(entry);
                try context.appendSlice(entry);
                break;
            }
            return true;
        }
        return false;
    }

    const tool_calls_val = parsed.value.object.get("tool_calls") orelse return false;
    const tool_calls = switch (tool_calls_val) {
        .array => |a| a,
        else => return false,
    };
    if (tool_calls.items.len == 0) return false;

    var ctx = tools_mod.ToolContext{
        .allocator = allocator,
        .cfg = cfg,
        .policy = policy,
        .memory = memory,
        .provider = provider,
        .all_tools = tools,
        .mcp_pool = mcp_pool,
    };

    for (tool_calls.items) |call| {
        if (call != .object) continue;

        // Support two formats LLMs commonly emit:
        //
        // Format A (OpenAI-style, what we ask for):
        //   {"function": {"name": "tool_name", "arguments": "{}"}}
        //
        // Format B (flat, what Ollama/llama3.2 often produces):
        //   {"function": "tool_name", "arguments": {}}
        //
        const name: []const u8 = blk: {
            const func_val = call.object.get("function") orelse continue;
            switch (func_val) {
                // Format A: function is an object with a "name" key
                .object => {
                    const n = func_val.object.get("name") orelse continue;
                    break :blk switch (n) {
                        .string => |s| s,
                        else => continue,
                    };
                },
                // Format B: function is the name string directly
                .string => |s| break :blk s,
                else => continue,
            }
        };

        // Arguments: check inside the function object first (Format A),
        // then fall back to a top-level "arguments" key (Format B).
        //
        // Models may emit arguments as:
        //   a) a JSON string:  "arguments": "{\"command\":\"ls\"}"
        //   b) an inline object: "arguments": {"command":"ls"}
        // Case (b) requires re-serialization so the tool receives a JSON string.
        // We allocate the serialized form and track it for deferred free.
        var args_json_owned: ?[]u8 = null;
        defer if (args_json_owned) |s| allocator.free(s);

        const args_json: []const u8 = blk: {
            // Helper: serialize a Value back to a JSON string.
            const serializeArgs = struct {
                fn run(alloc: std.mem.Allocator, v: std.json.Value) ![]u8 {
                    var buf = std.ArrayList(u8).init(alloc);
                    errdefer buf.deinit();
                    try std.json.stringify(v, .{}, buf.writer());
                    return buf.toOwnedSlice();
                }
            }.run;

            // Format A: {"function": {"name": "...", "arguments": ...}}
            if (call.object.get("function")) |func_val| {
                if (func_val == .object) {
                    if (func_val.object.get("arguments")) |av| {
                        switch (av) {
                            .string => |s| break :blk s,
                            else => {
                                // arguments is an inline object — serialize it
                                args_json_owned = try serializeArgs(allocator, av);
                                break :blk args_json_owned.?;
                            },
                        }
                    }
                }
            }
            // Format B: top-level "arguments" key
            if (call.object.get("arguments")) |av| {
                switch (av) {
                    .string => |s| break :blk s,
                    else => {
                        args_json_owned = try serializeArgs(allocator, av);
                        break :blk args_json_owned.?;
                    },
                }
            }
            break :blk "{}";
        };

        // Find and execute the matching tool.
        for (tools) |tool| {
            if (!std.mem.eql(u8, tool.name, name)) continue;

            // For MCP proxy tools, set the per-tool metadata in context so
            // toolMcpProxy knows which server and tool to call.
            ctx.mcp_current_meta = tool.user_data;
            defer ctx.mcp_current_meta = null;

            const result = tool.executeFn(&ctx, args_json) catch |err| blk: {
                const msg = try std.fmt.allocPrint(allocator, "tool error: {}", .{err});
                break :blk tools_mod.ToolResult.owned(false, msg);
            };
            // Free output only if the tool heap-allocated it.
            // String literals (allocated=false) must NOT be freed.
            defer if (result.allocated) allocator.free(result.output);

            // Append result to context buffer.
            const status = if (result.success) "ok" else "error";
            const entry = try std.fmt.allocPrint(
                allocator,
                "[{s}] {s}: {s}\n",
                .{ status, name, result.output },
            );
            defer allocator.free(entry);

            // T1-2: Enforce context budget. If adding this entry would exceed
            // MAX_CONTEXT_CHARS, drop oldest entries (from the front) until it fits.
            if (context.items.len + entry.len > MAX_CONTEXT_CHARS) {
                const needed = (context.items.len + entry.len) -| MAX_CONTEXT_CHARS;
                // Find a newline boundary so we don't cut mid-line.
                const cut = if (std.mem.indexOfPos(u8, context.items, needed, "\n")) |nl|
                    nl + 1
                else
                    @min(needed, context.items.len);
                // Shift remaining content to the front.
                const remaining = context.items.len - cut;
                std.mem.copyForwards(u8, context.items[0..remaining], context.items[cut..]);
                context.shrinkRetainingCapacity(remaining);
                // Prepend a truncation marker so the model knows history was dropped.
                const marker = "[... earlier tool results truncated due to context budget ...]\n";
                try context.insertSlice(0, marker);
            }
            try context.appendSlice(entry);

            break;
        }
    }

    return true;
}
