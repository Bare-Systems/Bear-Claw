/// Channel implementations for BareClaw.
///
/// Channels:
///   CLI      – stdin/stdout, single-turn or interactive loop
///   Discord  – Bot via HTTP REST (send) + Gateway WebSocket (receive)
///   Telegram – Bot via HTTP long-polling
///
/// Each channel receives messages from the platform and routes them through
/// the agent, then sends the reply back.

const std = @import("std");
const agent_mod    = @import("agent.zig");
const config_mod   = @import("config.zig");
const provider_mod = @import("provider.zig");
const memory_mod   = @import("memory.zig");
const mcp_mod      = @import("mcp_client.zig");
const tools_mod    = @import("tools.zig");
const security_mod = @import("security.zig");

pub const ChannelMessage = struct {
    content: []const u8,
};

// ── shared helper: build the full agent stack ─────────────────────────────────

const AgentStack = struct {
    provider:      provider_mod.Provider,
    mem_backend:   memory_mod.MemoryBackend,
    policy:        security_mod.SecurityPolicy,
    tool_registry: []tools_mod.Tool,
    // NOTE: any_provider is NOT stored here — its internal pointer becomes
    // dangling if AgentStack is returned by value and moved. Callers must
    // call provider_mod.AnyProvider.fromProvider(&stack.provider) themselves
    // after the stack is in its final memory location.

    pub fn deinit(self: *AgentStack, allocator: std.mem.Allocator) void {
        self.provider.deinit();
        self.mem_backend.deinit();
        self.policy.deinit(allocator);
        tools_mod.freeTools(allocator, self.tool_registry);
    }
};

fn buildStack(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !AgentStack {
    var stack: AgentStack = undefined;
    stack.provider      = try provider_mod.createDefaultProvider(allocator, cfg);
    stack.mem_backend   = try memory_mod.createMemoryBackend(allocator, cfg);
    stack.policy        = security_mod.SecurityPolicy.initWorkspaceOnly(allocator, cfg);
    stack.tool_registry = try tools_mod.buildCoreTools(allocator, &stack.policy, &stack.mem_backend);
    return stack;
}

// ── CLI channel ───────────────────────────────────────────────────────────────

/// Single-turn: read one line from stdin, run agent, print reply.
pub fn runCliChannelOnce(cfg: *const config_mod.Config) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin  = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    try stdout.print("BareClaw CLI channel – type a message and press Enter.\n> ", .{});

    var buf: [4096]u8 = undefined;
    const line = (try stdin.readUntilDelimiterOrEof(&buf, '\n')) orelse return;

    var stack = try buildStack(allocator, cfg);
    defer stack.deinit(allocator);
    const any_provider = provider_mod.AnyProvider.fromProvider(&stack.provider);

    try agent_mod.runAgentOnce(
        allocator, cfg, any_provider,
        &stack.mem_backend, stack.tool_registry, &stack.policy, null, line,
    );
}

/// Interactive loop: keep reading lines until EOF / "exit".
pub fn runCliChannelLoop(cfg: *const config_mod.Config) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin  = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var stack = try buildStack(allocator, cfg);
    defer stack.deinit(allocator);
    const any_provider = provider_mod.AnyProvider.fromProvider(&stack.provider);

    // Build MCP tools once, reuse the session pool across all messages.
    var mcp_pool: mcp_mod.McpSessionPool = undefined;
    var mcp_tools: []tools_mod.Tool = &[_]tools_mod.Tool{};
    var has_mcp = false;

    const server_defs = try config_mod.parseMcpServers(cfg, allocator);
    defer {
        for (@constCast(server_defs)) |*s| s.deinit(allocator);
        allocator.free(server_defs);
    }

    if (server_defs.len > 0) {
        var mcp_errors: []tools_mod.McpStartupError = &[_]tools_mod.McpStartupError{};
        mcp_tools = try tools_mod.buildMcpTools(allocator, server_defs, &mcp_pool, &mcp_errors);
        defer {
            for (mcp_errors) |*e| @constCast(e).deinit(allocator);
            allocator.free(mcp_errors);
        }
        for (mcp_errors) |e| {
            std.debug.print("⚠ MCP server '{s}' failed to start: {s}\n", .{ e.server_name, e.message });
        }
        has_mcp = true;
    }
    defer if (has_mcp) {
        tools_mod.freeMcpTools(allocator, mcp_tools);
        mcp_pool.deinit();
    };

    // Combine core tools + MCP tools into one registry.
    var all_tools = std.ArrayList(tools_mod.Tool).init(allocator);
    defer all_tools.deinit();
    try all_tools.appendSlice(stack.tool_registry);
    try all_tools.appendSlice(mcp_tools);

    try stdout.print("BareClaw interactive CLI – type 'exit' to quit.\n", .{});

    // T2-1: Initialise conversation history for this session.
    var history = agent_mod.ConversationHistory.init(allocator);
    defer history.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        try stdout.print("> ", .{});
        const line_opt = try stdin.readUntilDelimiterOrEof(&buf, '\n');
        const line = line_opt orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) break;

        // T2-1: Use history-aware agent call so each turn sees prior context.
        agent_mod.runAgentWithHistory(
            allocator, cfg, any_provider,
            &stack.mem_backend, all_tools.items, &stack.policy,
            if (has_mcp) &mcp_pool else null,
            trimmed,
            &history,
            &stdout,
        ) catch |err| {
            try stdout.print("agent error: {}\n", .{err});
        };
    }

    // T2-2: Store session transcript in memory when the session ends.
    // Only bother if there were actual messages exchanged.
    if (history.messages.items.len > 0) {
        const transcript = history.toTranscript(allocator) catch null;
        if (transcript) |t| {
            defer allocator.free(t);
            const ts = std.time.timestamp();
            const bt = @import("cron.zig").timestampToBroken(ts);
            const mem_key = std.fmt.allocPrint(
                allocator,
                "session/{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}",
                .{ bt.year, bt.month, bt.day, bt.hour, bt.minute },
            ) catch null;
            if (mem_key) |k| {
                defer allocator.free(k);
                stack.mem_backend.store(k, t) catch |err| {
                    // Non-fatal — don't propagate storage errors to the user.
                    std.debug.print("session transcript store failed: {}\n", .{err});
                };
            }
        }
    }
}

// ── Discord channel ───────────────────────────────────────────────────────────
//
// Discord uses two APIs:
//   - REST API  (https://discord.com/api/v10/...) for sending messages
//   - Gateway   (WebSocket) for receiving events in real-time
//
// A full Gateway WebSocket connection requires:
//   1. GET /gateway/bot → get WSS URL
//   2. Connect WebSocket, send Identify payload
//   3. Handle Hello (opcode 10), send heartbeat every heartbeat_interval ms
//   4. Receive Dispatch events (opcode 0) of type MESSAGE_CREATE
//
// Zig's std does not include a WebSocket client, so we implement a minimal
// one over std.net.Stream (TLS via std.crypto.tls) for the Gateway connection.
// For sending messages we use the standard HTTP REST endpoint.
//
// Bot token is read from:
//   config.discord_token  (config.toml)
//   DISCORD_BOT_TOKEN     (env var, takes precedence)

const DISCORD_API = "https://discord.com/api/v10";
const DISCORD_GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json";

/// Run the Discord channel — connects to Gateway and processes MESSAGE_CREATE
/// events until the process is killed.
/// Pass debug=true (via `bareclaw --debug channel discord`) for verbose logging.
pub fn runDiscordChannel(cfg: *const config_mod.Config, debug: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Resolve bot token.
    const token = std.process.getEnvVarOwned(allocator, "DISCORD_BOT_TOKEN") catch
                  (if (cfg.discord_token.len > 0)
                      try allocator.dupe(u8, cfg.discord_token)
                  else {
                      try stdout.print("Discord: no bot token (set DISCORD_BOT_TOKEN or discord_token in config)\n", .{});
                      return;
                  });
    defer allocator.free(token);

    var stack = try buildStack(allocator, cfg);
    defer stack.deinit(allocator);
    const any_provider = provider_mod.AnyProvider.fromProvider(&stack.provider);

    // Build MCP tools once at startup — reused across all messages.
    var mcp_pool: mcp_mod.McpSessionPool = undefined;
    var mcp_tools: []tools_mod.Tool = &[_]tools_mod.Tool{};
    var has_mcp = false;

    const server_defs = try config_mod.parseMcpServers(cfg, allocator);
    defer {
        for (@constCast(server_defs)) |*s| s.deinit(allocator);
        allocator.free(server_defs);
    }

    if (server_defs.len > 0) {
        var mcp_errors: []tools_mod.McpStartupError = &[_]tools_mod.McpStartupError{};
        mcp_tools = try tools_mod.buildMcpTools(allocator, server_defs, &mcp_pool, &mcp_errors);
        defer {
            for (mcp_errors) |*e| @constCast(e).deinit(allocator);
            allocator.free(mcp_errors);
        }
        for (mcp_errors) |e| {
            try stdout.print("⚠ MCP server '{s}' failed to start: {s}\n", .{ e.server_name, e.message });
        }
        has_mcp = true;
        try stdout.print("Discord: loaded {d} MCP tool(s)\n", .{mcp_tools.len});
    }
    defer if (has_mcp) {
        tools_mod.freeMcpTools(allocator, mcp_tools);
        mcp_pool.deinit();
    };

    // Combine core tools + MCP tools into one registry.
    var all_tools = std.ArrayList(tools_mod.Tool).init(allocator);
    defer all_tools.deinit();
    try all_tools.appendSlice(stack.tool_registry);
    try all_tools.appendSlice(mcp_tools);

    try stdout.print("Discord channel: connecting to Gateway...\n", .{});

    // Reconnect loop: Discord closes connections periodically (opcode 8, network
    // hiccups, session invalidation). Back off and reconnect instead of exiting.
    var attempt: u32 = 0;
    while (true) {
        discordGatewayLoop(
            allocator, cfg, token, any_provider,
            &stack.mem_backend, &stack.policy,
            all_tools.items, if (has_mcp) &mcp_pool else null,
            stdout, debug,
        ) catch |err| {
            const delay_s: u64 = @min(30, @as(u64, attempt) * 5 + 5);
            try stdout.print("Discord gateway error: {} — reconnecting in {d}s...\n",
                .{ err, delay_s });
            std.time.sleep(delay_s * std.time.ns_per_s);
        };
        attempt += 1;
        try stdout.print("Discord: reconnect attempt {d}...\n", .{attempt});
    }
}

/// Minimal Discord Gateway loop.
/// Opens a TCP+TLS connection to gateway.discord.gg:443, performs the WebSocket
/// handshake, then processes frames.
///
/// Zig 0.14 TLS API note: std.crypto.tls.Client does NOT store the underlying
/// stream — callers must pass the TCP stream to every read/write call.
fn discordGatewayLoop(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    token: []const u8,
    any_provider: provider_mod.AnyProvider,
    memory: *memory_mod.MemoryBackend,
    policy: *security_mod.SecurityPolicy,
    tools: []const tools_mod.Tool,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    stdout: anytype,
    debug: bool,
) !void {
    // ── 1. TCP + TLS connection ──────────────────────────────────────────────
    const host = "gateway.discord.gg";
    const port: u16 = 443;

    if (debug) try stdout.print("[DEBUG] Resolving DNS for {s}:{d}...\n", .{ host, port });
    const addr_list = try std.net.getAddressList(allocator, host, port);
    defer addr_list.deinit();
    if (addr_list.addrs.len == 0) return error.DnsResolutionFailed;
    if (debug) try stdout.print("[DEBUG] DNS resolved, {d} address(es). Connecting TCP...\n", .{addr_list.addrs.len});

    var tcp = try std.net.tcpConnectToAddress(addr_list.addrs[0]);
    defer tcp.close();
    if (debug) try stdout.print("[DEBUG] TCP connected.\n", .{});

    // In Zig 0.14 tls.Client, every read/write takes the underlying stream.
    if (debug) try stdout.print("[DEBUG] Loading TLS certificates...\n", .{});
    var bundle = std.crypto.Certificate.Bundle{};
    try bundle.rescan(allocator);
    defer bundle.deinit(allocator);

    if (debug) try stdout.print("[DEBUG] Initiating TLS handshake...\n", .{});
    var tls = try std.crypto.tls.Client.init(tcp, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = bundle },
    });
    // tls.deinit() is called automatically on the stack frame exit.
    if (debug) try stdout.print("[DEBUG] TLS handshake complete.\n", .{});

    // ── 2. WebSocket upgrade handshake ───────────────────────────────────────
    var key_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&key_bytes);
    var key_b64_buf: [24]u8 = undefined;
    const key_b64 = std.base64.standard.Encoder.encode(&key_b64_buf, &key_bytes);

    const upgrade_req = try std.fmt.allocPrint(
        allocator,
        "GET /?v=10&encoding=json HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n",
        .{ host, key_b64 },
    );
    defer allocator.free(upgrade_req);
    if (debug) try stdout.print("[DEBUG] Sending WebSocket upgrade request...\n", .{});
    try tls.writeAll(tcp, upgrade_req);

    // Read HTTP response headers.
    if (debug) try stdout.print("[DEBUG] Reading WebSocket upgrade response...\n", .{});
    var hdr_buf: [2048]u8 = undefined;
    var hdr_len: usize = 0;
    while (hdr_len < hdr_buf.len) {
        const n = try tls.read(tcp, hdr_buf[hdr_len..]);
        if (n == 0) return error.ConnectionClosed;
        hdr_len += n;
        if (std.mem.indexOf(u8, hdr_buf[0..hdr_len], "\r\n\r\n") != null) break;
    }
    if (std.mem.indexOf(u8, hdr_buf[0..hdr_len], "101") == null) {
        if (debug) try stdout.print("[DEBUG] Upgrade response: {s}\n", .{hdr_buf[0..hdr_len]});
        return error.WebSocketUpgradeFailed;
    }

    try stdout.print("Discord: WebSocket connected\n", .{});

    // Set a read timeout on the socket so the event loop can fire heartbeats
    // even when Discord sends no messages. Without this, tls.readAtLeast()
    // blocks forever and the heartbeat check at the top of the loop never runs,
    // causing Discord to close the connection due to missed heartbeats.
    // 5-second timeout: short enough to keep heartbeats on time (interval ~41s).
    if (debug) try stdout.print("[DEBUG] Setting SO_RCVTIMEO = 5s on socket fd={d}...\n", .{tcp.handle});
    const timeout_tv = std.posix.timeval{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(
        tcp.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout_tv),
    );
    if (debug) try stdout.print("[DEBUG] SO_RCVTIMEO set. Entering event loop.\n", .{});

    // ── 3. Send Identify payload ─────────────────────────────────────────────
    // Intents:
    //   512   = GUILD_MESSAGES    (messages in servers)
    //   4096  = DIRECT_MESSAGES   (DMs to the bot)
    //   32768 = MESSAGE_CONTENT   (privileged — enabled in Discord Dev Portal)
    // Total: 37376
    const identify = try std.fmt.allocPrint(allocator,
        "{{\"op\":2,\"d\":{{\"token\":\"{s}\"," ++
        "\"intents\":37376," ++
        "\"properties\":{{\"os\":\"linux\",\"browser\":\"bareclaw\",\"device\":\"bareclaw\"}}}}}}",
        .{token},
    );
    defer allocator.free(identify);
    try tlsWsSendText(&tls, tcp, allocator, identify);

    // ── 4. Event loop ────────────────────────────────────────────────────────
    var heartbeat_interval_ms: u64 = 41250;
    var sequence: i64 = 0;
    var last_heartbeat = std.time.milliTimestamp();
    var frame_buf = std.ArrayList(u8).init(allocator);
    defer frame_buf.deinit();

    // Bot's own user ID — populated from the READY event.
    // Used to filter out messages sent by ourselves.
    var bot_id: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(bot_id);

    // Per-channel conversation history.
    // Keyed by channel_id string (owned). Each value is a ConversationHistory
    // that accumulates turns so Bear has context across messages in the same
    // channel or DM thread.
    var channel_histories = std.StringHashMap(agent_mod.ConversationHistory).init(allocator);
    defer {
        var it = channel_histories.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        channel_histories.deinit();
    }

    while (true) {
        const now = std.time.milliTimestamp();
        if (now - last_heartbeat >= @as(i64, @intCast(heartbeat_interval_ms))) {
            if (debug) try stdout.print("[DEBUG] Sending heartbeat (seq={d}, interval={d}ms)...\n",
                .{ sequence, heartbeat_interval_ms });
            const hb = try std.fmt.allocPrint(allocator, "{{\"op\":1,\"d\":{d}}}", .{sequence});
            defer allocator.free(hb);
            try tlsWsSendText(&tls, tcp, allocator, hb);
            last_heartbeat = now;
            if (debug) try stdout.print("[DEBUG] Heartbeat sent.\n", .{});
        }

        const payload = tlsWsReadFrame(allocator, &tls, tcp, &frame_buf) catch |err| switch (err) {
            // Timeout fired (SO_RCVTIMEO) — no data yet, loop back to check heartbeat.
            error.WouldBlock, error.ConnectionTimedOut => {
                if (debug) try stdout.print("[DEBUG] Read timeout (no data), looping for heartbeat check.\n", .{});
                continue;
            },
            else => return err,
        };
        if (payload.len == 0) continue;
        defer allocator.free(payload);

        if (debug) try stdout.print("[DEBUG] Frame received ({d} bytes): {s}\n",
            .{ payload.len, if (payload.len > 200) payload[0..200] else payload });

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
            if (debug) try stdout.print("[DEBUG] Failed to parse frame as JSON, skipping.\n", .{});
            continue;
        };
        defer parsed.deinit();

        const op_val = parsed.value.object.get("op") orelse continue;
        const op: i64 = switch (op_val) { .integer => |i| i, else => continue };

        if (debug) try stdout.print("[DEBUG] Gateway op={d}\n", .{op});

        if (parsed.value.object.get("s")) |sv| {
            if (sv == .integer) sequence = sv.integer;
        }

        switch (op) {
            10 => {
                const d = parsed.value.object.get("d") orelse continue;
                if (d.object.get("heartbeat_interval")) |hbi| {
                    if (hbi == .integer) heartbeat_interval_ms = @intCast(hbi.integer);
                }
                if (debug) try stdout.print("[DEBUG] Hello received, heartbeat_interval={d}ms\n",
                    .{heartbeat_interval_ms});
            },
            0 => {
                const t_val = parsed.value.object.get("t") orelse continue;
                const event_type = switch (t_val) { .string => |s| s, else => continue };
                if (debug) try stdout.print("[DEBUG] Dispatch event: {s}\n", .{event_type});

                if (std.mem.eql(u8, event_type, "READY")) {
                    // READY payload contains the bot's own user object.
                    const d = parsed.value.object.get("d") orelse continue;
                    if (d.object.get("user")) |user| {
                        if (user.object.get("id")) |id_val| {
                            if (id_val == .string) {
                                allocator.free(bot_id);
                                bot_id = try allocator.dupe(u8, id_val.string);
                            }
                        }
                        const username = if (user.object.get("username")) |u|
                            switch (u) { .string => |s| s, else => "unknown" }
                        else "unknown";
                        try stdout.print("Discord: logged in as {s} (id={s})\n", .{ username, bot_id });
                    }
                } else if (std.mem.eql(u8, event_type, "MESSAGE_CREATE")) {
                    const d = parsed.value.object.get("d") orelse continue;

                    // Webhooks have a webhook_id field — allow them through (they're
                    // used for testing and integrations). Only skip actual bot accounts.
                    const is_webhook = d.object.get("webhook_id") != null;

                    if (!is_webhook) {
                        if (d.object.get("author")) |author| {
                            // Skip our own messages.
                            if (author.object.get("id")) |id_val| {
                                if (id_val == .string and std.mem.eql(u8, id_val.string, bot_id)) continue;
                            }
                            // Skip other bots (but not webhooks — handled above).
                            if (author.object.get("bot")) |bot_flag| {
                                if (bot_flag == .bool and bot_flag.bool) continue;
                            }
                        }
                    }

                    const content_val = d.object.get("content") orelse continue;
                    const content_raw = switch (content_val) { .string => |s| s, else => continue };
                    const channel_id_val = d.object.get("channel_id") orelse continue;
                    const channel_id = switch (channel_id_val) { .string => |s| s, else => continue };
                    if (content_raw.len == 0) continue;

                    // Detect Direct Messages:
                    //   Discord DMs have no guild_id field (or it is null/missing).
                    //   channel_type == 1 also signals a DM channel.
                    //   In a DM the bot should always respond — no @mention required.
                    const is_dm = blk: {
                        // guild_id absent → DM
                        const gid = d.object.get("guild_id");
                        if (gid == null or gid.? == .null) break :blk true;
                        // channel_type == 1 → DM channel
                        if (d.object.get("channel_type")) |ct| {
                            if (ct == .integer and ct.integer == 1) break :blk true;
                        }
                        break :blk false;
                    };

                    if (debug) try stdout.print("[DEBUG] MESSAGE_CREATE ch={s} is_dm={} content=\"{s}\"\n",
                        .{ channel_id, is_dm, if (content_raw.len > 100) content_raw[0..100] else content_raw });

                    // Determine whether the bot was mentioned. Discord sends
                    // three kinds of mentions we want to catch:
                    //   <@BOT_ID>   — direct user mention
                    //   <@!BOT_ID>  — nickname-based user mention (older clients)
                    //   <@&ROLE_ID> — role mention (bot has that role)
                    //
                    // Strategy (most reliable to least):
                    //   1. d.mentions[] array: Discord populates this with user
                    //      objects for every direct user mention. Check if bot_id
                    //      appears here.
                    //   2. d.mention_roles[]: if non-empty, a role was @mentioned.
                    //      Since the bot presumably has that role, respond.
                    //   3. Content string fallback: search for <@BOT_ID> or
                    //      <@!BOT_ID> in case the arrays are missing.
                    const mention        = try std.fmt.allocPrint(allocator, "<@{s}>",  .{bot_id});
                    defer allocator.free(mention);
                    const mention_nick   = try std.fmt.allocPrint(allocator, "<@!{s}>", .{bot_id});
                    defer allocator.free(mention_nick);

                    const is_mentioned = is_dm or detect: {
                        if (bot_id.len == 0) break :detect true; // READY not yet received

                        // 1. Check d.mentions[] for the bot's user ID.
                        if (d.object.get("mentions")) |mentions_val| {
                            if (mentions_val == .array) {
                                for (mentions_val.array.items) |m| {
                                    if (m != .object) continue;
                                    if (m.object.get("id")) |id_val| {
                                        if (id_val == .string and
                                            std.mem.eql(u8, id_val.string, bot_id))
                                        {
                                            break :detect true;
                                        }
                                    }
                                }
                            }
                        }

                        // 2. Check d.mention_roles[]: any role mention → respond.
                        if (d.object.get("mention_roles")) |roles_val| {
                            if (roles_val == .array and roles_val.array.items.len > 0) {
                                break :detect true;
                            }
                        }

                        // 3. Content string fallback (<@BOT_ID> or <@!BOT_ID>).
                        if (std.mem.indexOf(u8, content_raw, mention)      != null) break :detect true;
                        if (std.mem.indexOf(u8, content_raw, mention_nick) != null) break :detect true;

                        break :detect false;
                    };

                    if (debug) try stdout.print(
                        "[DEBUG] bot_id=\"{s}\" is_dm={} is_mentioned={}\n",
                        .{ bot_id, is_dm, is_mentioned },
                    );

                    // In a guild channel: only respond when mentioned.
                    // In a DM: always respond (is_mentioned == true from the is_dm shortcut above).
                    if (!is_mentioned) {
                        if (debug) try stdout.print("[DEBUG] Not mentioned — skipping message.\n", .{});
                        continue;
                    }

                    // Strip the leading @mention token so the LLM gets clean input.
                    // Handles <@BOT_ID>, <@!BOT_ID>, and <@&ROLE_ID> prefixes.
                    const content = blk: {
                        var stripped = content_raw;
                        // Try to strip any leading mention token (user, nickname, or role).
                        if (std.mem.startsWith(u8, stripped, mention)) {
                            stripped = std.mem.trim(u8, stripped[mention.len..], " \t");
                        } else if (std.mem.startsWith(u8, stripped, mention_nick)) {
                            stripped = std.mem.trim(u8, stripped[mention_nick.len..], " \t");
                        } else if (std.mem.startsWith(u8, stripped, "<@&")) {
                            // Role mention: find the closing '>' and strip past it.
                            if (std.mem.indexOf(u8, stripped, ">")) |end| {
                                stripped = std.mem.trim(u8, stripped[end + 1..], " \t");
                            }
                        }
                        break :blk stripped;
                    };
                    if (content.len == 0) continue;

                    // Get author username for logging.
                    const author_name = if (d.object.get("author")) |a|
                        if (a.object.get("username")) |u|
                            switch (u) { .string => |s| s, else => "unknown" }
                        else "unknown"
                    else "unknown";

                    try stdout.print("Discord [{s}] {s}: {s}\n", .{ channel_id, author_name, content });
                    try stdout.print("Discord: generating reply...\n", .{});

                    // Look up (or create) the ConversationHistory for this channel.
                    // This gives Bear multi-turn context within the same channel/DM.
                    const history_entry = try channel_histories.getOrPut(channel_id);
                    if (!history_entry.found_existing) {
                        // New channel — own a copy of the key and initialise history.
                        history_entry.key_ptr.* = try allocator.dupe(u8, channel_id);
                        history_entry.value_ptr.* = agent_mod.ConversationHistory.init(allocator);
                    }
                    const history = history_entry.value_ptr;

                    // Capture reply into a buffer so we can send it to Discord.
                    var reply_buf = std.ArrayList(u8).init(allocator);
                    errdefer reply_buf.deinit();
                    var reply_writer = reply_buf.writer();

                    agent_mod.runAgentWithHistory(
                        allocator, cfg, any_provider,
                        memory, tools, policy, mcp_pool,
                        content, history, &reply_writer,
                    ) catch |err| {
                        reply_buf.clearRetainingCapacity();
                        try reply_buf.writer().print("error: {}", .{err});
                    };

                    const reply = try reply_buf.toOwnedSlice();
                    defer allocator.free(reply);

                    try stdout.print("Discord: sending reply: {s}\n", .{reply});
                    discordSendMessage(allocator, token, channel_id, reply) catch |err| {
                        try stdout.print("Discord send error: {}\n", .{err});
                    };
                    try stdout.print("Discord: reply sent.\n", .{});
                }
            },
            11 => {
                if (debug) try stdout.print("[DEBUG] Heartbeat ACK received.\n", .{});
            },
            else => {
                if (debug) try stdout.print("[DEBUG] Unknown op={d}, ignoring.\n", .{op});
            },
        }
    }
}

/// Send a masked text WebSocket frame over a TLS connection.
fn tlsWsSendText(
    tls: *std.crypto.tls.Client,
    tcp: std.net.Stream,
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    var frame = std.ArrayList(u8).init(allocator);
    defer frame.deinit();

    try frame.append(0x81); // FIN=1, opcode=1 (text)

    if (text.len <= 125) {
        try frame.append(@as(u8, 0x80) | @as(u8, @intCast(text.len)));
    } else if (text.len <= 65535) {
        try frame.append(0xFE);
        try frame.append(@as(u8, @intCast((text.len >> 8) & 0xFF)));
        try frame.append(@as(u8, @intCast(text.len & 0xFF)));
    } else {
        try frame.append(0xFF);
        var i: u3 = 7;
        while (true) {
            try frame.append(@as(u8, @intCast((text.len >> (@as(u6, 8) * @as(u6, i))) & 0xFF)));
            if (i == 0) break;
            i -= 1;
        }
    }

    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);
    try frame.appendSlice(&mask);
    for (text, 0..) |byte, idx| try frame.append(byte ^ mask[idx % 4]);

    try tls.writeAll(tcp, frame.items);
}

/// Read a WebSocket frame from a TLS connection; return allocated payload.
fn tlsWsReadFrame(
    allocator: std.mem.Allocator,
    tls: *std.crypto.tls.Client,
    tcp: std.net.Stream,
    buf: *std.ArrayList(u8),
) ![]u8 {
    buf.clearRetainingCapacity();

    var hdr: [2]u8 = undefined;
    _ = try tls.readAtLeast(tcp, &hdr, 2);

    // const fin = (hdr[0] & 0x80) != 0;
    const opcode = hdr[0] & 0x0F;
    const masked  = (hdr[1] & 0x80) != 0;
    var payload_len: u64 = hdr[1] & 0x7F;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        _ = try tls.readAtLeast(tcp, &ext, 2);
        payload_len = (@as(u64, ext[0]) << 8) | ext[1];
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        _ = try tls.readAtLeast(tcp, &ext, 8);
        payload_len = 0;
        for (ext) |b| payload_len = (payload_len << 8) | b;
    }

    var mask_key: [4]u8 = undefined;
    if (masked) _ = try tls.readAtLeast(tcp, &mask_key, 4);

    try buf.resize(@intCast(payload_len));
    _ = try tls.readAtLeast(tcp, buf.items, @intCast(payload_len));

    if (masked) {
        for (buf.items, 0..) |*byte, i| byte.* ^= mask_key[i % 4];
    }

    // Handle close / ping frames.
    if (opcode == 8) return error.ConnectionClosed;
    if (opcode == 9) { // ping → pong
        var pong: [2]u8 = .{ 0x8A, 0x00 };
        try tls.writeAll(tcp, &pong);
        return buf.items[0..0];
    }

    // Return allocated copy.
    return allocator.dupe(u8, buf.items);
}

/// Send a message to a Discord channel via REST API.
fn discordSendMessage(
    allocator:  std.mem.Allocator,
    token:      []const u8,
    channel_id: []const u8,
    content:    []const u8,
) !void {
    // Chunk to 2000 chars (Discord limit).
    const chunk = if (content.len > 2000) content[0..2000] else content;

    var body_buf = std.ArrayList(u8).init(allocator);
    defer body_buf.deinit();
    var jw = std.json.writeStream(body_buf.writer(), .{ .whitespace = .minified });
    try jw.beginObject();
    try jw.objectField("content"); try jw.write(chunk);
    try jw.endObject();
    const body = try body_buf.toOwnedSlice();
    defer allocator.free(body);

    const url = try std.fmt.allocPrint(
        allocator, "{s}/channels/{s}/messages", .{ DISCORD_API, channel_id },
    );
    defer allocator.free(url);

    const auth = try std.fmt.allocPrint(allocator, "Bot {s}", .{token});
    defer allocator.free(auth);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var resp_buf = std.ArrayList(u8).init(allocator);
    defer resp_buf.deinit();

    _ = try client.fetch(.{
        .method   = .POST,
        .location = .{ .uri = uri },
        .headers  = .{
            .content_type  = .{ .override = "application/json" },
            .authorization = .{ .override = auth },
        },
        .payload          = body,
        .response_storage = .{ .dynamic = &resp_buf },
    });
}

// ── Telegram channel ──────────────────────────────────────────────────────────
//
// Telegram bot API uses long-polling: GET /bot<token>/getUpdates?offset=<N>&timeout=30
// For each update with a message, we run the agent and call sendMessage.
//
// Token is read from:
//   TELEGRAM_BOT_TOKEN (env var, precedence)
//   config.telegram_token (config.toml)

const TELEGRAM_API = "https://api.telegram.org";

pub fn runTelegramChannel(cfg: *const config_mod.Config) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    const token = std.process.getEnvVarOwned(allocator, "TELEGRAM_BOT_TOKEN") catch
                  (if (cfg.telegram_token.len > 0)
                      try allocator.dupe(u8, cfg.telegram_token)
                  else {
                      try stdout.print("Telegram: no bot token (set TELEGRAM_BOT_TOKEN or telegram_token in config)\n", .{});
                      return;
                  });
    defer allocator.free(token);

    var stack = try buildStack(allocator, cfg);
    defer stack.deinit(allocator);
    const any_provider = provider_mod.AnyProvider.fromProvider(&stack.provider);

    try stdout.print("Telegram channel: starting long-poll loop...\n", .{});
    try telegramPollLoop(allocator, cfg, token, any_provider, stdout);
}

fn telegramPollLoop(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    token: []const u8,
    any_provider: provider_mod.AnyProvider,
    stdout: anytype,
) !void {
    var offset: i64 = 0;

    while (true) {
        // GET /bot<token>/getUpdates?offset=<offset>&timeout=30
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/bot{s}/getUpdates?offset={d}&timeout=30",
            .{ TELEGRAM_API, token, offset },
        );
        defer allocator.free(url);

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);
        var resp_buf = std.ArrayList(u8).init(allocator);
        defer resp_buf.deinit();

        const result = client.fetch(.{
            .method   = .GET,
            .location = .{ .uri = uri },
            .response_storage = .{ .dynamic = &resp_buf },
        }) catch |err| {
            try stdout.print("Telegram poll error: {}\n", .{err});
            std.time.sleep(5 * std.time.ns_per_s);
            continue;
        };

        if (result.status != .ok) {
            try stdout.print("Telegram HTTP {d}\n", .{@intFromEnum(result.status)});
            std.time.sleep(5 * std.time.ns_per_s);
            continue;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp_buf.items, .{}) catch {
            std.time.sleep(2 * std.time.ns_per_s);
            continue;
        };
        defer parsed.deinit();

        const ok_val = parsed.value.object.get("ok") orelse continue;
        if (ok_val != .bool or !ok_val.bool) continue;

        const results_val = parsed.value.object.get("result") orelse continue;
        const updates = switch (results_val) { .array => |a| a, else => continue };

        for (updates.items) |update| {
            // Advance offset past this update.
            if (update.object.get("update_id")) |uid| {
                if (uid == .integer) offset = uid.integer + 1;
            }

            const message = update.object.get("message") orelse continue;
            const text_val = message.object.get("text") orelse continue;
            const text = switch (text_val) { .string => |s| s, else => continue };
            const chat_val = message.object.get("chat") orelse continue;
            const chat_id_val = chat_val.object.get("id") orelse continue;
            const chat_id: i64 = switch (chat_id_val) { .integer => |i| i, else => continue };

            try stdout.print("Telegram [{d}]: {s}\n", .{ chat_id, text });

            // Run agent.
            const reply = any_provider.chatOnce(
                "You are BareClaw, a fast, bear-themed AI assistant.",
                text,
                cfg.default_model,
                0.7,
            ) catch |err| blk: {
                break :blk try std.fmt.allocPrint(allocator, "error: {}", .{err});
            };
            defer allocator.free(reply);

            // Send reply.
            telegramSendMessage(allocator, token, chat_id, reply) catch |err| {
                try stdout.print("Telegram send error: {}\n", .{err});
            };
        }
    }
}

fn telegramSendMessage(
    allocator: std.mem.Allocator,
    token:     []const u8,
    chat_id:   i64,
    text:      []const u8,
) !void {
    // Telegram message limit is 4096 chars.
    const chunk = if (text.len > 4096) text[0..4096] else text;

    const url = try std.fmt.allocPrint(
        allocator, "{s}/bot{s}/sendMessage", .{ TELEGRAM_API, token },
    );
    defer allocator.free(url);

    var body_buf = std.ArrayList(u8).init(allocator);
    defer body_buf.deinit();
    var jw = std.json.writeStream(body_buf.writer(), .{ .whitespace = .minified });
    try jw.beginObject();
    try jw.objectField("chat_id"); try jw.write(chat_id);
    try jw.objectField("text");    try jw.write(chunk);
    try jw.endObject();
    const body = try body_buf.toOwnedSlice();
    defer allocator.free(body);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var resp_buf = std.ArrayList(u8).init(allocator);
    defer resp_buf.deinit();

    _ = try client.fetch(.{
        .method   = .POST,
        .location = .{ .uri = uri },
        .headers  = .{ .content_type = .{ .override = "application/json" } },
        .payload          = body,
        .response_storage = .{ .dynamic = &resp_buf },
    });
}
