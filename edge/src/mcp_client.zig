/// mcp_client.zig — Generic MCP (Model Context Protocol) client.
///
/// Launches any MCP server as a subprocess (stdio transport), performs the
/// JSON-RPC 2.0 handshake, discovers tools via tools/list, and can invoke
/// tools via tools/call.
///
/// Design constraints:
///   - Zero external dependencies (Zig stdlib only)
///   - No knowledge of specific MCP servers — generic by construction
///   - Subprocess is spawned fresh per call session (stateless from caller POV)
///
/// Wire protocol (per MCP spec):
///   - Newline-delimited JSON-RPC 2.0 messages over stdin/stdout
///   - initialize → notifications/initialized → tools/list → tools/call
///
const std = @import("std");

/// A single discovered MCP tool with its name and description.
pub const McpTool = struct {
    name:        []const u8,
    description: []const u8,

    pub fn deinit(self: *McpTool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        self.* = undefined;
    }
};

/// Probe timeout: how long the tool-discovery probe waits for the server to respond.
/// Real (pool) sessions use blocking reads; probes use this deadline to avoid hangs.
const PROBE_TIMEOUT_MS: i32 = 8000;

/// A running MCP server session. Owns the child process and its stdio.
pub const McpSession = struct {
    allocator:  std.mem.Allocator,
    child:      std.process.Child,
    next_id:    u32,
    /// When > 0, readLine uses poll() with this timeout (ms) instead of blocking.
    /// 0 means block indefinitely (normal pool sessions).
    timeout_ms: i32,

    /// Start an MCP server and complete the handshake.
    /// `argv` must be the full command+args slice, e.g. &[_][]const u8{"trader","mcp","serve"}.
    /// Caller owns the returned McpSession and must call deinit().
    pub fn start(allocator: std.mem.Allocator, argv: []const []const u8) !McpSession {
        return startInternal(allocator, argv, 0);
    }

    /// Like start(), but readLine calls will time out after timeout_ms milliseconds.
    /// Used by the probe in buildMcpTools so a slow/dead server doesn't hang startup.
    pub fn startProbe(allocator: std.mem.Allocator, argv: []const []const u8) !McpSession {
        return startInternal(allocator, argv, PROBE_TIMEOUT_MS);
    }

    fn startInternal(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: i32) !McpSession {
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior  = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        var session = McpSession{
            .allocator  = allocator,
            .child      = child,
            .next_id    = 1,
            .timeout_ms = timeout_ms,
        };

        // Perform MCP handshake: initialize request → response → initialized notification.
        try session.handshake();
        return session;
    }

    pub fn deinit(self: *McpSession) void {
        // Close stdin to signal EOF to the child, then wait for it to exit.
        if (self.child.stdin) |stdin| {
            stdin.close();
            self.child.stdin = null;
        }
        _ = self.child.wait() catch {};
        self.* = undefined;
    }

    // ── JSON-RPC helpers ──────────────────────────────────────────────────────

    /// Send a JSON-RPC request (with id) and return the raw response line.
    /// Caller owns the returned slice.
    fn request(self: *McpSession, method: []const u8, params_json: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n",
            .{ id, method, params_json },
        );
        defer self.allocator.free(msg);

        const stdin = self.child.stdin orelse return error.NoStdin;
        try stdin.writeAll(msg);

        return self.readLine();
    }

    /// Send a JSON-RPC notification (no id, no response expected).
    fn notify(self: *McpSession, method: []const u8, params_json: []const u8) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}\n",
            .{ method, params_json },
        );
        defer self.allocator.free(msg);

        const stdin = self.child.stdin orelse return error.NoStdin;
        try stdin.writeAll(msg);
    }

    /// Read a single newline-terminated line from the child's stdout.
    /// Caller owns the returned slice (without the trailing \n).
    /// If self.timeout_ms > 0, each byte read is preceded by a poll() that
    /// returns error.TimedOut if the server doesn't respond within the deadline.
    fn readLine(self: *McpSession) ![]u8 {
        const stdout = self.child.stdout orelse return error.NoStdout;
        var line = std.ArrayList(u8).init(self.allocator);
        errdefer line.deinit();

        var byte: [1]u8 = undefined;
        while (true) {
            // If a timeout is set, poll before reading so we don't block forever.
            if (self.timeout_ms > 0) {
                var pfd = [1]std.posix.pollfd{.{
                    .fd      = stdout.handle,
                    .events  = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = try std.posix.poll(&pfd, self.timeout_ms);
                if (ready == 0) return error.TimedOut;
            }

            const n = try stdout.read(&byte);
            if (n == 0) break; // EOF
            if (byte[0] == '\n') break;
            try line.append(byte[0]);
        }
        return line.toOwnedSlice();
    }

    // ── MCP protocol ──────────────────────────────────────────────────────────

    fn handshake(self: *McpSession) !void {
        const init_params =
            \\{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bareclaw","version":"0.1.0"}}
        ;
        const resp = try self.request("initialize", init_params);
        defer self.allocator.free(resp);

        // Send the initialized notification (no response expected).
        try self.notify("notifications/initialized", "{}");
    }

    /// Discover all tools exposed by this MCP server.
    /// Caller owns the returned slice and each McpTool inside it.
    pub fn listTools(self: *McpSession) ![]McpTool {
        const resp = try self.request("tools/list", "{}");
        defer self.allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch
            return &[_]McpTool{};
        defer parsed.deinit();

        // Navigate: result.tools[]
        const result_val = parsed.value.object.get("result") orelse return &[_]McpTool{};
        const tools_val  = switch (result_val) {
            .object => |o| o.get("tools") orelse return &[_]McpTool{},
            else    => return &[_]McpTool{},
        };
        const tools_arr = switch (tools_val) {
            .array => |a| a,
            else   => return &[_]McpTool{},
        };

        var list = std.ArrayList(McpTool).init(self.allocator);
        errdefer {
            for (list.items) |*t| t.deinit(self.allocator);
            list.deinit();
        }

        for (tools_arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else    => continue,
            };

            const name_val = obj.get("name") orelse continue;
            const name_str = switch (name_val) {
                .string => |s| s,
                else    => continue,
            };

            const desc_str: []const u8 = blk: {
                if (obj.get("description")) |dv| {
                    if (dv == .string) break :blk dv.string;
                }
                break :blk "";
            };

            try list.append(McpTool{
                .name        = try self.allocator.dupe(u8, name_str),
                .description = try self.allocator.dupe(u8, desc_str),
            });
        }

        return list.toOwnedSlice();
    }

    /// Call an MCP tool by name with a JSON arguments object.
    /// Returns the text content from the first content block.
    /// Caller owns the returned slice.
    pub fn callTool(self: *McpSession, tool_name: []const u8, args_json: []const u8) ![]u8 {
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"name\":\"{s}\",\"arguments\":{s}}}",
            .{ tool_name, args_json },
        );
        defer self.allocator.free(params);

        const resp = try self.request("tools/call", params);
        defer self.allocator.free(resp);

        // Parse response and extract text from result.content[0].text
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch {
            return self.allocator.dupe(u8, "(mcp: invalid json response)");
        };
        defer parsed.deinit();

        // Check for JSON-RPC error
        if (parsed.value.object.get("error")) |err_val| {
            if (err_val == .object) {
                if (err_val.object.get("message")) |msg_val| {
                    if (msg_val == .string) {
                        return std.fmt.allocPrint(self.allocator, "(mcp error: {s})", .{msg_val.string});
                    }
                }
            }
            return self.allocator.dupe(u8, "(mcp: unknown error)");
        }

        const result_val = parsed.value.object.get("result") orelse
            return self.allocator.dupe(u8, "(mcp: no result)");

        // result may be an object with isError + content[]
        const is_error: bool = blk: {
            if (result_val == .object) {
                if (result_val.object.get("isError")) |ie| {
                    if (ie == .bool) break :blk ie.bool;
                }
            }
            break :blk false;
        };

        const content_val: std.json.Value = blk: {
            if (result_val == .object) {
                break :blk result_val.object.get("content") orelse result_val;
            }
            break :blk result_val;
        };

        // Collect all text content blocks into one string
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();

        switch (content_val) {
            .array => |arr| {
                for (arr.items) |item| {
                    if (item != .object) continue;
                    const type_val = item.object.get("type") orelse continue;
                    if (type_val != .string or !std.mem.eql(u8, type_val.string, "text")) continue;
                    const text_val = item.object.get("text") orelse continue;
                    if (text_val != .string) continue;
                    if (out.items.len > 0) try out.append('\n');
                    try out.appendSlice(text_val.string);
                }
            },
            .string => |s| try out.appendSlice(s),
            else => try out.appendSlice("(mcp: unrecognised result format)"),
        }

        if (out.items.len == 0) {
            try out.appendSlice(if (is_error) "(mcp: tool returned empty error)" else "(ok)");
        }

        return out.toOwnedSlice();
    }
};

// ── Persistent session pool ───────────────────────────────────────────────────
// For efficiency we keep one McpSession alive per server argv across the
// lifetime of the calling process. This avoids re-spawning+handshaking on
// every tool call.
//
// Implementation: a simple array of (key, *McpSession) pairs stored
// on the heap. Lifetime is managed by the caller (McpSessionPool.deinit).

pub const McpSessionPool = struct {
    allocator: std.mem.Allocator,
    entries:   std.ArrayList(PoolEntry),

    const PoolEntry = struct {
        key:     []const u8, // owned; the server command joined by " "
        session: *McpSession,
    };

    pub fn init(allocator: std.mem.Allocator) McpSessionPool {
        return .{
            .allocator = allocator,
            .entries   = std.ArrayList(PoolEntry).init(allocator),
        };
    }

    pub fn deinit(self: *McpSessionPool) void {
        for (self.entries.items) |*e| {
            e.session.deinit();
            self.allocator.destroy(e.session);
            self.allocator.free(e.key);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    /// Return an existing session or start a new one.
    pub fn getOrStart(self: *McpSessionPool, argv: []const []const u8) !*McpSession {
        const key = try std.mem.join(self.allocator, " ", argv);
        errdefer self.allocator.free(key);

        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                self.allocator.free(key);
                return e.session;
            }
        }

        // Not found — start a new session.
        const session = try self.allocator.create(McpSession);
        errdefer self.allocator.destroy(session);

        session.* = try McpSession.start(self.allocator, argv);

        try self.entries.append(.{ .key = key, .session = session });
        return session;
    }
};
