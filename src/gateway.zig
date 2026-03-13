/// BearClaw internal gateway.
///
/// Endpoints:
///   GET  /health   -> 200 {"status":"ok","service":"bareclaw"}
///   POST /webhook  -> 200 {"received":true}
///   POST /v1/chat  -> 200 ChatResponse envelope
///
/// Security model for MVP:
/// - Binds to localhost only (127.0.0.1)
/// - No auth at this layer; Tardigrade edge enforces auth externally.
const std = @import("std");
const agent_mod = @import("agent.zig");
const config_mod = @import("config.zig");
const provider_mod = @import("provider.zig");
const memory_mod = @import("memory.zig");
const security_mod = @import("security.zig");
const tools_mod = @import("tools.zig");

const MAX_REQUEST_BYTES: usize = 256 * 1024;
const MAX_MESSAGE_CHARS: usize = 4000;
const AGENT_EXECUTION_TIMEOUT_SECONDS: u64 = 30;

pub fn runGateway(port: u16) !void {
    const stdout = std.io.getStdOut().writer();

    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    try stdout.print("BearClaw gateway listening on http://127.0.0.1:{d}\n", .{port});
    try stdout.print("Endpoints: GET /health  POST /webhook  POST /v1/chat\n", .{});

    while (true) {
        const conn = server.accept() catch |err| {
            try stdout.print("accept error: {}\n", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{conn}) catch |err| {
            try stdout.print("connection thread spawn error: {}\n", .{err});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

pub fn runGatewayWithShutdown(port: u16, shutdown: *const std.atomic.Value(bool)) !void {
    const stdout = std.io.getStdOut().writer();

    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    try stdout.print("BearClaw gateway listening on http://127.0.0.1:{d}\n", .{port});

    const fd = server.stream.handle;
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    while (!shutdown.load(.acquire)) {
        const ready = std.posix.poll(&fds, 500) catch |err| switch (err) {
            error.SystemResources => continue,
            else => return err,
        };
        if (ready == 0) continue;
        if (shutdown.load(.acquire)) break;

        const conn = server.accept() catch continue;
        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{conn}) catch {
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnectionThread(conn: std.net.Server.Connection) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    handleConnection(allocator, conn) catch |err| {
        std.debug.print("connection error: {}\n", .{err});
    };
}

fn handleConnection(allocator: std.mem.Allocator, conn: std.net.Server.Connection) !void {
    defer conn.stream.close();

    var buf: [MAX_REQUEST_BYTES]u8 = undefined;
    const n = try readHttpRequest(conn.stream, buf[0..]);
    if (n == 0) return;

    const request = buf[0..n];
    const method, const path, const headers_end = parseMethodPathAndHeadersEnd(request) orelse {
        try sendJson(conn.stream, "400 Bad Request", "{\"code\":\"invalid_request\",\"message\":\"bad request\",\"request_id\":null}", null);
        return;
    };

    const request_id = parseHeaderValue(request[0..headers_end], "x-correlation-id") orelse try generateRequestId(allocator);
    defer if (parseHeaderValue(request[0..headers_end], "x-correlation-id") == null) allocator.free(request_id);

    const body = if (headers_end <= request.len) request[headers_end..] else "";

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/health")) {
        try sendJson(conn.stream, "200 OK", "{\"status\":\"ok\",\"service\":\"bareclaw\"}", request_id);
        return;
    }

    if (std.mem.eql(u8, path, "/webhook")) {
        if (!std.mem.eql(u8, method, "POST")) {
            try sendJson(conn.stream, "405 Method Not Allowed", "{\"code\":\"invalid_request\",\"message\":\"method not allowed\",\"request_id\":null}", request_id);
            return;
        }
        try sendJson(conn.stream, "200 OK", "{\"received\":true}", request_id);
        return;
    }

    if (std.mem.eql(u8, path, "/v1/chat")) {
        if (!std.mem.eql(u8, method, "POST")) {
            const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"invalid_request\",\"message\":\"method not allowed\",\"request_id\":\"{s}\"}}", .{request_id});
            defer allocator.free(payload);
            try sendJson(conn.stream, "405 Method Not Allowed", payload, request_id);
            return;
        }

        const content_type = parseHeaderValue(request[0..headers_end], "content-type");
        if (!isJsonContentType(content_type)) {
            const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"invalid_request\",\"message\":\"Content-Type must be application/json\",\"request_id\":\"{s}\"}}", .{request_id});
            defer allocator.free(payload);
            try sendJson(conn.stream, "400 Bad Request", payload, request_id);
            return;
        }

        const message = parseChatMessage(allocator, body) catch {
            const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"invalid_request\",\"message\":\"invalid chat payload\",\"request_id\":\"{s}\"}}", .{request_id});
            defer allocator.free(payload);
            try sendJson(conn.stream, "400 Bad Request", payload, request_id);
            return;
        };
        defer allocator.free(message);

        const reply = runAgentForPromptWithTimeout(allocator, message, AGENT_EXECUTION_TIMEOUT_SECONDS) catch |err| switch (err) {
            error.AgentTimedOut => {
                const payload = try std.fmt.allocPrint(
                    allocator,
                    "{{\"code\":\"agent_timeout\",\"message\":\"agent timed out after {d} seconds\",\"request_id\":\"{s}\"}}",
                    .{ AGENT_EXECUTION_TIMEOUT_SECONDS, request_id },
                );
                defer allocator.free(payload);
                try sendJson(conn.stream, "504 Gateway Timeout", payload, request_id);
                return;
            },
            else => {
                const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"internal_error\",\"message\":\"agent execution failed\",\"request_id\":\"{s}\"}}", .{request_id});
                defer allocator.free(payload);
                try sendJson(conn.stream, "500 Internal Server Error", payload, request_id);
                return;
            },
        };
        defer allocator.free(reply);

        const response_payload = try buildChatResponse(allocator, reply);
        defer allocator.free(response_payload);
        try sendJson(conn.stream, "200 OK", response_payload, request_id);
        return;
    }

    const not_found = try std.fmt.allocPrint(allocator, "{{\"code\":\"invalid_request\",\"message\":\"not found\",\"request_id\":\"{s}\"}}", .{request_id});
    defer allocator.free(not_found);
    try sendJson(conn.stream, "404 Not Found", not_found, request_id);
}

fn runAgentForPrompt(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    var cfg = try config_mod.loadOrInit(allocator);
    defer cfg.deinit(allocator);

    var provider = try provider_mod.createDefaultProvider(allocator, &cfg);
    defer provider.deinit();
    const any_provider = provider_mod.AnyProvider.fromProvider(&provider);

    var mem_backend = try memory_mod.createMemoryBackend(allocator, &cfg);
    defer mem_backend.deinit();

    var policy = security_mod.SecurityPolicy.initWorkspaceOnly(allocator, &cfg);
    defer policy.deinit(allocator);

    const tools = try tools_mod.buildCoreTools(allocator, &policy, &mem_backend);
    defer tools_mod.freeTools(allocator, tools);

    var reply_buf = std.ArrayList(u8).init(allocator);
    errdefer reply_buf.deinit();
    var reply_writer = reply_buf.writer();

    try agent_mod.runAgentSingleTurnWithTranscript(
        allocator,
        &cfg,
        any_provider,
        &mem_backend,
        tools,
        &policy,
        null,
        prompt,
        &reply_writer,
    );

    return reply_buf.toOwnedSlice();
}

const AgentRunJob = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    finished: bool = false,
    caller_timed_out: bool = false,
    prompt: []u8,
    reply: ?[]u8 = null,
    error_name: ?[]u8 = null,
};

fn runAgentWorker(job: *AgentRunJob) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    defer std.heap.page_allocator.free(job.prompt);

    const reply = runAgentForPrompt(allocator, job.prompt) catch |err| {
        const err_name = std.heap.page_allocator.dupe(u8, @errorName(err)) catch null;
        finishAgentJob(job, null, err_name);
        return;
    };
    defer allocator.free(reply);

    const reply_copy = std.heap.page_allocator.dupe(u8, reply) catch {
        const err_name = std.heap.page_allocator.dupe(u8, "OutOfMemory") catch null;
        finishAgentJob(job, null, err_name);
        return;
    };
    finishAgentJob(job, reply_copy, null);
}

fn finishAgentJob(job: *AgentRunJob, reply: ?[]u8, error_name: ?[]u8) void {
    var destroy_job = false;

    job.mutex.lock();
    job.reply = reply;
    job.error_name = error_name;
    job.finished = true;
    destroy_job = job.caller_timed_out;
    job.cond.broadcast();
    job.mutex.unlock();

    if (destroy_job) {
        if (job.reply) |owned_reply| std.heap.page_allocator.free(owned_reply);
        if (job.error_name) |owned_error| std.heap.page_allocator.free(owned_error);
        std.heap.page_allocator.destroy(job);
    }
}

fn runAgentForPromptWithTimeout(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    timeout_seconds: u64,
) ![]u8 {
    const job = try std.heap.page_allocator.create(AgentRunJob);
    errdefer std.heap.page_allocator.destroy(job);

    job.* = .{
        .prompt = try std.heap.page_allocator.dupe(u8, prompt),
    };
    errdefer std.heap.page_allocator.free(job.prompt);

    var thread = try std.Thread.spawn(.{}, runAgentWorker, .{job});
    return awaitAgentJob(allocator, job, &thread, timeout_seconds);
}

fn awaitAgentJob(
    allocator: std.mem.Allocator,
    job: *AgentRunJob,
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
                return error.AgentTimedOut;
            },
        };
    }

    job.mutex.unlock();
    thread.join();

    defer {
        if (job.reply) |owned_reply| std.heap.page_allocator.free(owned_reply);
        if (job.error_name) |owned_error| std.heap.page_allocator.free(owned_error);
        std.heap.page_allocator.destroy(job);
    }

    if (job.error_name) |err_name| {
        std.debug.print("agent worker failed: {s}\n", .{err_name});
        return error.AgentExecutionFailed;
    }

    const reply = job.reply orelse return error.AgentExecutionFailed;
    return allocator.dupe(u8, reply);
}

fn buildChatResponse(allocator: std.mem.Allocator, reply: []const u8) ![]u8 {
    const id = try generateUuidV4(allocator);
    defer allocator.free(id);

    const now_unix: f64 = @floatFromInt(std.time.timestamp());
    const apple_reference_offset: f64 = 978307200.0;
    const apple_ref_ts = now_unix - apple_reference_offset;

    return std.fmt.allocPrint(
        allocator,
        "{{\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"content\":{s},\"timestamp\":{d}}},\"requires_confirmation\":false,\"confirmation_reason\":null}}",
        .{ id, std.json.fmt(reply, .{}), apple_ref_ts },
    );
}

fn parseChatMessage(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const message_val = obj.get("message") orelse return error.InvalidPayload;
    if (message_val != .string) return error.InvalidPayload;

    const message = std.mem.trim(u8, message_val.string, " \t\r\n");
    if (message.len == 0 or message.len > MAX_MESSAGE_CHARS) return error.InvalidPayload;
    return allocator.dupe(u8, message);
}

fn isJsonContentType(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    var lower_buf: [128]u8 = undefined;
    const lower = if (ct.len <= lower_buf.len)
        std.ascii.lowerString(lower_buf[0..ct.len], ct)
    else
        ct;
    return std.mem.indexOf(u8, lower, "application/json") != null;
}

fn parseMethodPathAndHeadersEnd(request: []const u8) ?struct { []const u8, []const u8, usize } {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return null;
    const line = request[0..line_end];

    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return null;
    const path = it.next() orelse return null;

    const headers_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return null;
    return .{ method, path, headers_end + 4 };
}

fn readHttpRequest(stream: std.net.Stream, buf: []u8) !usize {
    var total_read: usize = 0;
    var headers_end: ?usize = null;

    while (total_read < buf.len) {
        const n = try stream.read(buf[total_read..]);
        if (n == 0) break;
        total_read += n;

        if (headers_end == null) {
            if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n")) |h_end| {
                headers_end = h_end + 4;
            }
        }

        if (headers_end) |h_end| {
            const content_length = parseContentLength(buf[0..h_end]) orelse 0;
            if (total_read >= h_end + content_length) break;
        }
    }

    return total_read;
}

fn parseHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;

        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn parseContentLength(headers: []const u8) ?usize {
    const value = parseHeaderValue(headers, "content-length") orelse return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn sendJson(stream: std.net.Stream, status: []const u8, body: []const u8, request_id: ?[]const u8) !void {
    const w = stream.writer();
    if (request_id) |rid| {
        try w.print(
            "HTTP/1.1 {s}\r\n" ++
                "Content-Type: application/json\r\n" ++
                "X-Correlation-ID: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "{s}",
            .{ status, rid, body.len, body },
        );
        return;
    }

    try w.print(
        "HTTP/1.1 {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status, body.len, body },
    );
}

fn generateRequestId(allocator: std.mem.Allocator) ![]u8 {
    const ts = std.time.timestamp();
    var random_bytes: [6]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    return std.fmt.allocPrint(allocator, "req-{d}-{s}", .{ ts, std.fmt.fmtSliceHexLower(&random_bytes) });
}

fn generateUuidV4(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15],
        },
    );
}

test "parseChatMessage accepts valid JSON" {
    const allocator = std.testing.allocator;
    const msg = try parseChatMessage(allocator, "{\"message\":\"hello\"}");
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("hello", msg);
}

test "parseChatMessage rejects empty" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPayload, parseChatMessage(allocator, "{\"message\":\"\"}"));
}

test "buildChatResponse returns envelope" {
    const allocator = std.testing.allocator;
    const payload = try buildChatResponse(allocator, "ok");
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "requires_confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "confirmation_reason") != null);
}

fn testFastJobWorker(job: *AgentRunJob) void {
    std.heap.page_allocator.free(job.prompt);
    const reply = std.heap.page_allocator.dupe(u8, "ok") catch unreachable;
    finishAgentJob(job, reply, null);
}

fn testSlowJobWorker(job: *AgentRunJob) void {
    std.Thread.sleep(20 * std.time.ns_per_ms);
    std.heap.page_allocator.free(job.prompt);
    const reply = std.heap.page_allocator.dupe(u8, "late") catch unreachable;
    finishAgentJob(job, reply, null);
}

test "awaitAgentJob returns reply before deadline" {
    const allocator = std.testing.allocator;
    const job = try std.heap.page_allocator.create(AgentRunJob);
    errdefer std.heap.page_allocator.destroy(job);
    job.* = .{
        .prompt = try std.heap.page_allocator.dupe(u8, ""),
    };
    errdefer std.heap.page_allocator.free(job.prompt);

    var thread = try std.Thread.spawn(.{}, testFastJobWorker, .{job});
    const reply = try awaitAgentJob(allocator, job, &thread, 1);
    defer allocator.free(reply);

    try std.testing.expectEqualStrings("ok", reply);
}

test "awaitAgentJob reports timeout for slow worker" {
    const allocator = std.testing.allocator;
    const job = try std.heap.page_allocator.create(AgentRunJob);
    errdefer std.heap.page_allocator.destroy(job);
    job.* = .{
        .prompt = try std.heap.page_allocator.dupe(u8, ""),
    };
    errdefer std.heap.page_allocator.free(job.prompt);

    var thread = try std.Thread.spawn(.{}, testSlowJobWorker, .{job});
    try std.testing.expectError(error.AgentTimedOut, awaitAgentJob(allocator, job, &thread, 0));
}
