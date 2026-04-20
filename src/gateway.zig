/// BearClaw internal gateway.
///
/// Endpoints:
///   GET  /health   -> 200 {"status":"ok","service":"bareclaw"}
///   POST /webhook  -> 200 {"received":true}
///   POST /v1/chat  -> 200 ChatResponse envelope
///   GET  /v1/runs  -> 200 recent run summaries
///   GET  /v1/runs/:id -> 200 run artifact detail
///   GET  /v1/runs/:id/stream -> 200 SSE replay/tail of run artifact
///
/// Security model:
/// - Binds to localhost only (127.0.0.1)
/// - Operator routes require asserted identity headers from Tardigrade.
const std = @import("std");
const agent_mod = @import("agent.zig");
const config_mod = @import("config.zig");
const provider_mod = @import("provider.zig");
const memory_mod = @import("memory.zig");
const planner_mod = @import("planner.zig");
const security_mod = @import("security.zig");
const tools_mod = @import("tools.zig");

const MAX_REQUEST_BYTES: usize = 256 * 1024;
const MAX_MESSAGE_CHARS: usize = 4000;
const AGENT_EXECUTION_TIMEOUT_SECONDS: u64 = 120;
const MAX_RUN_EVENT_CHARS: usize = 4096;
const MAX_RUN_ARTIFACT_BYTES: usize = 2 * 1024 * 1024;
const MAX_LISTED_RUNS: usize = 32;
const RUN_STREAM_IDLE_TIMEOUT_MS: i64 = 15_000;
const RUN_STREAM_POLL_INTERVAL_MS: u64 = 200;
const REQUIRED_OPERATOR_SCOPE = "bearclaw.operator";

const AssertedIdentity = struct {
    user_id: []const u8,
    device_id: ?[]const u8,
    scopes: []const u8,
};

const RunRoute = struct {
    run_id: []const u8,
    stream: bool,
};

const RunSummary = struct {
    id: []u8,
    user_id: []u8,
    device_id: ?[]u8,
    scopes: []u8,
    status: []u8,
    started_at: i64,
    updated_at: i64,
    event_count: usize,

    fn deinit(self: RunSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.user_id);
        if (self.device_id) |value| allocator.free(value);
        allocator.free(self.scopes);
        allocator.free(self.status);
    }
};

const GatewayRunSink = struct {
    allocator: std.mem.Allocator,
    run_id: []u8,
    user_id: []u8,
    device_id: ?[]u8,
    scopes: []u8,
    artifact_path: []u8,
    artifact_file: std.fs.File,
    stream: ?std.net.Stream = null,
    mutex: std.Thread.Mutex = .{},
    active: bool = true,

    fn init(
        allocator: std.mem.Allocator,
        workspace_dir: []const u8,
        run_id: []const u8,
        asserted_identity: AssertedIdentity,
        stream: ?std.net.Stream,
    ) !*GatewayRunSink {
        const runs_dir = try std.fmt.allocPrint(allocator, "{s}/runs", .{workspace_dir});
        defer allocator.free(runs_dir);
        try std.fs.cwd().makePath(runs_dir);

        const artifact_path = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ runs_dir, run_id });
        errdefer allocator.free(artifact_path);

        const artifact_file = try std.fs.cwd().createFile(artifact_path, .{ .truncate = true });
        errdefer artifact_file.close();

        const sink = try allocator.create(GatewayRunSink);
        sink.* = .{
            .allocator = allocator,
            .run_id = try allocator.dupe(u8, run_id),
            .user_id = try allocator.dupe(u8, asserted_identity.user_id),
            .device_id = if (asserted_identity.device_id) |value| try allocator.dupe(u8, value) else null,
            .scopes = try allocator.dupe(u8, asserted_identity.scopes),
            .artifact_path = artifact_path,
            .artifact_file = artifact_file,
            .stream = stream,
        };
        return sink;
    }

    fn deinit(self: *GatewayRunSink) void {
        self.artifact_file.close();
        self.allocator.free(self.run_id);
        self.allocator.free(self.user_id);
        if (self.device_id) |value| self.allocator.free(value);
        self.allocator.free(self.scopes);
        self.allocator.free(self.artifact_path);
        self.allocator.destroy(self);
    }

    fn emitPrompt(self: *GatewayRunSink, prompt: []const u8) void {
        self.emitEvent(.{
            .event_type = "prompt",
            .content = prompt,
        });
    }

    fn emitToolCall(self: *GatewayRunSink, tool_name: []const u8, args_json: []const u8) void {
        self.emitEvent(.{
            .event_type = "tool_call",
            .tool_name = tool_name,
            .arguments = args_json,
        });
    }

    fn emitToolResult(self: *GatewayRunSink, tool_name: []const u8, success: bool, output: []const u8) void {
        self.emitEvent(.{
            .event_type = "tool_result",
            .tool_name = tool_name,
            .success = success,
            .content = output,
        });
    }

    fn emitModelOutput(self: *GatewayRunSink, content: []const u8) void {
        self.emitEvent(.{
            .event_type = "model_output",
            .content = content,
        });
    }

    fn emitError(self: *GatewayRunSink, code: []const u8, message: []const u8) void {
        self.emitEvent(.{
            .event_type = "error",
            .code = code,
            .message = message,
        });
    }

    fn finishStream(self: *GatewayRunSink) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.active) return;

        self.writeEventLocked(.{ .event_type = "done" });
        self.active = false;
    }

    fn cancelWithError(self: *GatewayRunSink, code: []const u8, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.active) return;
        self.writeEventLocked(.{
            .event_type = "error",
            .code = code,
            .message = message,
        });
        self.active = false;
    }

    const EventInput = struct {
        event_type: []const u8,
        tool_name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
        success: ?bool = null,
        content: ?[]const u8 = null,
        code: ?[]const u8 = null,
        message: ?[]const u8 = null,
    };

    fn emitEvent(self: *GatewayRunSink, input: EventInput) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.active) return;
        self.writeEventLocked(input);
    }

    fn writeEventLocked(self: *GatewayRunSink, input: EventInput) void {
        const json = buildRunEventJson(
            self.allocator,
            self.run_id,
            self.user_id,
            self.device_id,
            self.scopes,
            input.event_type,
            input.tool_name,
            input.arguments,
            input.success,
            input.content,
            input.code,
            input.message,
        ) catch return;
        defer self.allocator.free(json);

        self.artifact_file.writer().print("{s}\n", .{json}) catch {};
        if (self.stream) |stream| {
            sendSseFrame(stream, input.event_type, json) catch {};
        }
    }
};

fn gatewayObserverPrompt(ctx: *anyopaque, prompt: []const u8) void {
    const sink: *GatewayRunSink = @ptrCast(@alignCast(ctx));
    sink.emitPrompt(prompt);
}

fn gatewayObserverToolCall(ctx: *anyopaque, tool_name: []const u8, args_json: []const u8) void {
    const sink: *GatewayRunSink = @ptrCast(@alignCast(ctx));
    sink.emitToolCall(tool_name, args_json);
}

fn gatewayObserverToolResult(ctx: *anyopaque, tool_name: []const u8, success: bool, output: []const u8) void {
    const sink: *GatewayRunSink = @ptrCast(@alignCast(ctx));
    sink.emitToolResult(tool_name, success, output);
}

fn gatewayObserverModelOutput(ctx: *anyopaque, content: []const u8) void {
    const sink: *GatewayRunSink = @ptrCast(@alignCast(ctx));
    sink.emitModelOutput(content);
}

fn gatewayObserverError(ctx: *anyopaque, code: []const u8, message: []const u8) void {
    const sink: *GatewayRunSink = @ptrCast(@alignCast(ctx));
    sink.emitError(code, message);
}

fn buildGatewayRunObserver(sink: *GatewayRunSink) planner_mod.RunObserver {
    return .{
        .ctx = sink,
        .on_prompt = gatewayObserverPrompt,
        .on_tool_call = gatewayObserverToolCall,
        .on_tool_result = gatewayObserverToolResult,
        .on_model_output = gatewayObserverModelOutput,
        .on_error = gatewayObserverError,
    };
}

pub fn runGateway(port: u16) !void {
    const stdout = std.io.getStdOut().writer();

    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    try stdout.print("BearClaw gateway listening on http://127.0.0.1:{d}\n", .{port});
    try stdout.print("Endpoints: GET /health  POST /webhook  POST /v1/chat  POST /v1/chat/stream  GET /v1/runs  GET /v1/runs/:id  GET /v1/runs/:id/stream\n", .{});

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

    if (std.mem.eql(u8, path, "/v1/runs")) {
        if (!std.mem.eql(u8, method, "GET")) {
            const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"invalid_request\",\"message\":\"method not allowed\",\"request_id\":\"{s}\"}}", .{request_id});
            defer allocator.free(payload);
            try sendJson(conn.stream, "405 Method Not Allowed", payload, request_id);
            return;
        }

        _ = parseAssertedIdentity(request[0..headers_end]) orelse {
            const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"forbidden\",\"message\":\"asserted tardigrade identity required\",\"request_id\":\"{s}\"}}", .{request_id});
            defer allocator.free(payload);
            try sendJson(conn.stream, "403 Forbidden", payload, request_id);
            return;
        };

        var workspace_cfg = try config_mod.loadOrInit(allocator);
        defer workspace_cfg.deinit(allocator);

        const payload = try buildRunsListResponse(allocator, workspace_cfg.workspace_dir);
        defer allocator.free(payload);
        try sendJson(conn.stream, "200 OK", payload, request_id);
        return;
    }

    if (parseRunRoute(path)) |run_route| {
        if (!std.mem.eql(u8, method, "GET")) {
            const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"invalid_request\",\"message\":\"method not allowed\",\"request_id\":\"{s}\"}}", .{request_id});
            defer allocator.free(payload);
            try sendJson(conn.stream, "405 Method Not Allowed", payload, request_id);
            return;
        }

        _ = parseAssertedIdentity(request[0..headers_end]) orelse {
            const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"forbidden\",\"message\":\"asserted tardigrade identity required\",\"request_id\":\"{s}\"}}", .{request_id});
            defer allocator.free(payload);
            try sendJson(conn.stream, "403 Forbidden", payload, request_id);
            return;
        };

        var workspace_cfg = try config_mod.loadOrInit(allocator);
        defer workspace_cfg.deinit(allocator);

        if (run_route.stream) {
            streamRunArtifact(conn.stream, allocator, workspace_cfg.workspace_dir, run_route.run_id) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRunId => {
                    const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"not_found\",\"message\":\"run not found\",\"request_id\":\"{s}\"}}", .{request_id});
                    defer allocator.free(payload);
                    try sendJson(conn.stream, "404 Not Found", payload, request_id);
                    return;
                },
                else => return err,
            };
            return;
        }

        const payload = buildRunDetailResponse(allocator, workspace_cfg.workspace_dir, run_route.run_id) catch |err| switch (err) {
            error.FileNotFound, error.InvalidRunId => {
                const not_found = try std.fmt.allocPrint(allocator, "{{\"code\":\"not_found\",\"message\":\"run not found\",\"request_id\":\"{s}\"}}", .{request_id});
                defer allocator.free(not_found);
                try sendJson(conn.stream, "404 Not Found", not_found, request_id);
                return;
            },
            else => return err,
        };
        defer allocator.free(payload);
        try sendJson(conn.stream, "200 OK", payload, request_id);
        return;
    }

    const is_chat = std.mem.eql(u8, path, "/v1/chat");
    const is_chat_stream = std.mem.eql(u8, path, "/v1/chat/stream");

    if (is_chat or is_chat_stream) {
        if (!std.mem.eql(u8, method, "POST")) {
            const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"invalid_request\",\"message\":\"method not allowed\",\"request_id\":\"{s}\"}}", .{request_id});
            defer allocator.free(payload);
            try sendJson(conn.stream, "405 Method Not Allowed", payload, request_id);
            return;
        }

        const asserted_identity = parseAssertedIdentity(request[0..headers_end]) orelse {
            const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"forbidden\",\"message\":\"asserted tardigrade identity required\",\"request_id\":\"{s}\"}}", .{request_id});
            defer allocator.free(payload);
            try sendJson(conn.stream, "403 Forbidden", payload, request_id);
            return;
        };

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

        var workspace_cfg = try config_mod.loadOrInit(allocator);
        defer workspace_cfg.deinit(allocator);

        const sink = try GatewayRunSink.init(
            allocator,
            workspace_cfg.workspace_dir,
            request_id,
            asserted_identity,
            if (is_chat_stream) conn.stream else null,
        );
        var sink_owned_here = true;
        defer if (sink_owned_here) sink.deinit();

        if (is_chat_stream) {
            try sendSseHeaders(conn.stream, request_id);
        }

        const observer = buildGatewayRunObserver(sink);
        const reply = runAgentForPromptWithTimeout(allocator, message, AGENT_EXECUTION_TIMEOUT_SECONDS, observer, sink) catch |err| switch (err) {
            error.AgentTimedOut => {
                sink_owned_here = false;
                if (!is_chat_stream) {
                    const payload = try std.fmt.allocPrint(
                        allocator,
                        "{{\"code\":\"agent_timeout\",\"message\":\"agent timed out after {d} seconds\",\"retryable\":false,\"request_id\":\"{s}\"}}",
                        .{ AGENT_EXECUTION_TIMEOUT_SECONDS, request_id },
                    );
                    defer allocator.free(payload);
                    try sendJson(conn.stream, "504 Gateway Timeout", payload, request_id);
                }
                return;
            },
            error.ProviderUnavailable => {
                sink.emitError("provider_unavailable", "upstream provider is unavailable");
                if (!is_chat_stream) {
                    const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"provider_unavailable\",\"message\":\"upstream provider is unavailable\",\"retryable\":true,\"request_id\":\"{s}\"}}", .{request_id});
                    defer allocator.free(payload);
                    try sendJson(conn.stream, "503 Service Unavailable", payload, request_id);
                }
                return;
            },
            error.ProviderUpstreamError => {
                sink.emitError("provider_error", "upstream provider returned an error");
                if (!is_chat_stream) {
                    const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"provider_error\",\"message\":\"upstream provider returned an error\",\"retryable\":false,\"request_id\":\"{s}\"}}", .{request_id});
                    defer allocator.free(payload);
                    try sendJson(conn.stream, "502 Bad Gateway", payload, request_id);
                }
                return;
            },
            error.ProviderRateLimited => {
                sink.emitError("provider_rate_limited", "upstream provider rate limit exceeded");
                if (!is_chat_stream) {
                    const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"provider_rate_limited\",\"message\":\"upstream provider rate limit exceeded\",\"retryable\":true,\"request_id\":\"{s}\"}}", .{request_id});
                    defer allocator.free(payload);
                    try sendJson(conn.stream, "429 Too Many Requests", payload, request_id);
                }
                return;
            },
            error.ProviderAuthFailed => {
                sink.emitError("provider_error", "upstream provider authentication failed");
                if (!is_chat_stream) {
                    const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"provider_error\",\"message\":\"upstream provider authentication failed\",\"retryable\":false,\"request_id\":\"{s}\"}}", .{request_id});
                    defer allocator.free(payload);
                    try sendJson(conn.stream, "502 Bad Gateway", payload, request_id);
                }
                return;
            },
            else => {
                sink.emitError("internal_error", "agent execution failed");
                if (!is_chat_stream) {
                    const payload = try std.fmt.allocPrint(allocator, "{{\"code\":\"internal_error\",\"message\":\"agent execution failed\",\"retryable\":false,\"request_id\":\"{s}\"}}", .{request_id});
                    defer allocator.free(payload);
                    try sendJson(conn.stream, "500 Internal Server Error", payload, request_id);
                }
                return;
            },
        };
        defer allocator.free(reply);

        if (is_chat_stream) {
            sink.finishStream();
            return;
        }

        sink.finishStream();

        const response_payload = try buildChatResponse(allocator, reply);
        defer allocator.free(response_payload);
        try sendJson(conn.stream, "200 OK", response_payload, request_id);
        return;
    }

    const not_found = try std.fmt.allocPrint(allocator, "{{\"code\":\"invalid_request\",\"message\":\"not found\",\"request_id\":\"{s}\"}}", .{request_id});
    defer allocator.free(not_found);
    try sendJson(conn.stream, "404 Not Found", not_found, request_id);
}

fn runAgentForPrompt(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    observer: ?*const planner_mod.RunObserver,
) ![]u8 {
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

    try agent_mod.runAgentSingleTurnWithTranscriptObserved(
        allocator,
        &cfg,
        any_provider,
        &mem_backend,
        tools,
        &policy,
        null,
        prompt,
        observer,
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
    observer: ?planner_mod.RunObserver = null,
    sink: ?*GatewayRunSink = null,
};

fn runAgentWorker(job: *AgentRunJob) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    defer std.heap.page_allocator.free(job.prompt);

    const reply = runAgentForPrompt(
        allocator,
        job.prompt,
        if (job.observer) |*observer| observer else null,
    ) catch |err| {
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
        if (job.sink) |sink| sink.deinit();
        std.heap.page_allocator.destroy(job);
    }
}

fn runAgentForPromptWithTimeout(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    timeout_seconds: u64,
    observer: planner_mod.RunObserver,
    sink: *GatewayRunSink,
) ![]u8 {
    const job = try std.heap.page_allocator.create(AgentRunJob);
    errdefer std.heap.page_allocator.destroy(job);

    job.* = .{
        .prompt = try std.heap.page_allocator.dupe(u8, prompt),
        .observer = observer,
        .sink = sink,
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
                if (job.sink) |sink| {
                    sink.cancelWithError("agent_timeout", "agent timed out");
                }
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
        // Map provider-level error names to typed errors so the gateway can
        // return the correct HTTP status code and retryable flag.
        if (std.mem.eql(u8, err_name, "ProviderRateLimited")) return error.ProviderRateLimited;
        if (std.mem.eql(u8, err_name, "ProviderAuthFailed")) return error.ProviderAuthFailed;
        if (std.mem.eql(u8, err_name, "ProviderUpstreamError")) return error.ProviderUpstreamError;
        // Connection-level failures: provider process not running, network down, etc.
        if (std.mem.eql(u8, err_name, "ConnectionRefused") or
            std.mem.eql(u8, err_name, "NetworkUnreachable") or
            std.mem.eql(u8, err_name, "ConnectionTimedOut") or
            std.mem.eql(u8, err_name, "TemporaryNameServerFailure") or
            std.mem.eql(u8, err_name, "UnknownHostName")) return error.ProviderUnavailable;
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

fn buildRunsListResponse(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    var summaries = try loadRunSummaries(allocator, workspace_dir);
    defer {
        for (summaries.items) |summary| summary.deinit(allocator);
        summaries.deinit();
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("{\"runs\":[");
    for (summaries.items, 0..) |summary, index| {
        if (index > 0) try out.append(',');
        try appendRunSummaryJson(out.writer(), summary);
    }
    try out.appendSlice("]}");
    return out.toOwnedSlice();
}

fn buildRunDetailResponse(allocator: std.mem.Allocator, workspace_dir: []const u8, run_id: []const u8) ![]u8 {
    const artifact = try readRunArtifact(allocator, workspace_dir, run_id);
    defer allocator.free(artifact);

    const summary = try inspectRunArtifact(allocator, run_id, artifact);
    defer summary.deinit(allocator);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("{\"run\":");
    try appendRunSummaryJson(out.writer(), summary);
    try out.appendSlice(",\"events\":[");

    var line_it = std.mem.splitScalar(u8, artifact, '\n');
    var event_index: usize = 0;
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (event_index > 0) try out.append(',');
        try out.appendSlice(line);
        event_index += 1;
    }

    try out.appendSlice("]}");
    return out.toOwnedSlice();
}

fn loadRunSummaries(allocator: std.mem.Allocator, workspace_dir: []const u8) !std.ArrayList(RunSummary) {
    var summaries = std.ArrayList(RunSummary).init(allocator);
    errdefer {
        for (summaries.items) |summary| summary.deinit(allocator);
        summaries.deinit();
    }

    const runs_dir = try std.fmt.allocPrint(allocator, "{s}/runs", .{workspace_dir});
    defer allocator.free(runs_dir);

    var dir = std.fs.cwd().openDir(runs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return summaries,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const run_id = entry.name[0 .. entry.name.len - ".jsonl".len];
        if (!isValidRunId(run_id)) continue;

        const artifact_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ runs_dir, entry.name });
        defer allocator.free(artifact_path);

        const artifact = try std.fs.cwd().readFileAlloc(allocator, artifact_path, MAX_RUN_ARTIFACT_BYTES);
        defer allocator.free(artifact);

        try summaries.append(try inspectRunArtifact(allocator, run_id, artifact));
    }

    std.mem.sort(RunSummary, summaries.items, {}, struct {
        fn lessThan(_: void, a: RunSummary, b: RunSummary) bool {
            if (a.updated_at == b.updated_at) return std.mem.order(u8, a.id, b.id) == .lt;
            return a.updated_at > b.updated_at;
        }
    }.lessThan);

    if (summaries.items.len > MAX_LISTED_RUNS) {
        var i = MAX_LISTED_RUNS;
        while (i < summaries.items.len) : (i += 1) summaries.items[i].deinit(allocator);
        summaries.shrinkRetainingCapacity(MAX_LISTED_RUNS);
    }

    return summaries;
}

fn inspectRunArtifact(allocator: std.mem.Allocator, run_id: []const u8, artifact: []const u8) !RunSummary {
    var first_user_id: ?[]u8 = null;
    errdefer if (first_user_id) |value| allocator.free(value);

    var first_device_id: ?[]u8 = null;
    errdefer if (first_device_id) |value| allocator.free(value);

    var first_scopes: ?[]u8 = null;
    errdefer if (first_scopes) |value| allocator.free(value);

    var last_status: ?[]u8 = null;
    errdefer if (last_status) |value| allocator.free(value);

    var started_at: i64 = 0;
    var updated_at: i64 = 0;
    var event_count: usize = 0;

    var line_it = std.mem.splitScalar(u8, artifact, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        if (first_user_id == null) {
            const user_value = obj.get("user_id") orelse return error.InvalidRunArtifact;
            if (user_value != .string or user_value.string.len == 0) return error.InvalidRunArtifact;
            first_user_id = try allocator.dupe(u8, user_value.string);
        }

        if (first_scopes == null) {
            const scopes_value = obj.get("scopes") orelse return error.InvalidRunArtifact;
            if (scopes_value != .string) return error.InvalidRunArtifact;
            first_scopes = try allocator.dupe(u8, scopes_value.string);
        }

        if (first_device_id == null) {
            if (obj.get("device_id")) |device_value| {
                switch (device_value) {
                    .null => {},
                    .string => first_device_id = try allocator.dupe(u8, device_value.string),
                    else => return error.InvalidRunArtifact,
                }
            }
        }

        const ts_value = obj.get("ts") orelse return error.InvalidRunArtifact;
        const ts = switch (ts_value) {
            .integer => ts_value.integer,
            else => return error.InvalidRunArtifact,
        };

        const type_value = obj.get("type") orelse return error.InvalidRunArtifact;
        if (type_value != .string) return error.InvalidRunArtifact;

        if (event_count == 0) started_at = ts;
        updated_at = ts;
        event_count += 1;

        if (last_status) |value| allocator.free(value);
        last_status = try allocator.dupe(u8, statusForRunEventType(type_value.string));
    }

    const user_id = first_user_id orelse return error.InvalidRunArtifact;
    const scopes = first_scopes orelse return error.InvalidRunArtifact;
    const status = last_status orelse try allocator.dupe(u8, "unknown");

    return .{
        .id = try allocator.dupe(u8, run_id),
        .user_id = user_id,
        .device_id = first_device_id,
        .scopes = scopes,
        .status = status,
        .started_at = started_at,
        .updated_at = updated_at,
        .event_count = event_count,
    };
}

fn appendRunSummaryJson(writer: anytype, summary: RunSummary) !void {
    try writer.print(
        "{{\"id\":{s},\"user_id\":{s},\"device_id\":",
        .{ std.json.fmt(summary.id, .{}), std.json.fmt(summary.user_id, .{}) },
    );
    if (summary.device_id) |value| {
        try writer.print("{s}", .{std.json.fmt(value, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"scopes\":{s},\"status\":{s},\"started_at\":{d},\"updated_at\":{d},\"event_count\":{d}}}",
        .{
            std.json.fmt(summary.scopes, .{}),
            std.json.fmt(summary.status, .{}),
            summary.started_at,
            summary.updated_at,
            summary.event_count,
        },
    );
}

fn readRunArtifact(allocator: std.mem.Allocator, workspace_dir: []const u8, run_id: []const u8) ![]u8 {
    if (!isValidRunId(run_id)) return error.InvalidRunId;
    const artifact_path = try std.fmt.allocPrint(allocator, "{s}/runs/{s}.jsonl", .{ workspace_dir, run_id });
    defer allocator.free(artifact_path);
    return std.fs.cwd().readFileAlloc(allocator, artifact_path, MAX_RUN_ARTIFACT_BYTES);
}

fn parseRunRoute(path: []const u8) ?RunRoute {
    const prefix = "/v1/runs/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;

    const remainder = path[prefix.len..];
    if (remainder.len == 0) return null;

    const slash_index = std.mem.indexOfScalar(u8, remainder, '/') orelse return .{
        .run_id = remainder,
        .stream = false,
    };

    if (slash_index == 0) return null;
    if (!std.mem.eql(u8, remainder[slash_index + 1 ..], "stream")) return null;

    return .{
        .run_id = remainder[0..slash_index],
        .stream = true,
    };
}

fn isValidRunId(run_id: []const u8) bool {
    if (run_id.len == 0) return false;
    for (run_id) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') continue;
        return false;
    }
    return true;
}

fn statusForRunEventType(event_type: []const u8) []const u8 {
    if (std.mem.eql(u8, event_type, "done")) return "done";
    if (std.mem.eql(u8, event_type, "error")) return "error";
    return "in_progress";
}

fn streamRunArtifact(stream: std.net.Stream, allocator: std.mem.Allocator, workspace_dir: []const u8, run_id: []const u8) !void {
    if (!isValidRunId(run_id)) return error.InvalidRunId;

    const artifact_path = try std.fmt.allocPrint(allocator, "{s}/runs/{s}.jsonl", .{ workspace_dir, run_id });
    defer allocator.free(artifact_path);

    _ = try std.fs.cwd().statFile(artifact_path);
    try sendSseHeaders(stream, run_id);

    var sent_bytes: usize = 0;
    const deadline_ms = std.time.milliTimestamp() + RUN_STREAM_IDLE_TIMEOUT_MS;

    while (true) {
        const artifact = try std.fs.cwd().readFileAlloc(allocator, artifact_path, MAX_RUN_ARTIFACT_BYTES);
        defer allocator.free(artifact);

        if (artifact.len > sent_bytes) {
            var terminal_seen = false;
            try appendArtifactSseFrames(stream.writer(), allocator, artifact[sent_bytes..], &terminal_seen);
            sent_bytes = artifact.len;
            if (terminal_seen) return;
        }

        if (std.time.milliTimestamp() >= deadline_ms) return;
        std.Thread.sleep(RUN_STREAM_POLL_INTERVAL_MS * std.time.ns_per_ms);
    }
}

fn appendArtifactSseFrames(writer: anytype, allocator: std.mem.Allocator, artifact_delta: []const u8, terminal_seen: *bool) !void {
    var line_it = std.mem.splitScalar(u8, artifact_delta, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        const type_value = obj.get("type") orelse return error.InvalidRunArtifact;
        if (type_value != .string) return error.InvalidRunArtifact;

        try appendSseFrame(writer, type_value.string, line);
        if (std.mem.eql(u8, type_value.string, "done") or std.mem.eql(u8, type_value.string, "error")) {
            terminal_seen.* = true;
        }
    }
}

fn isBearerSecretByte(c: u8) bool {
    return !std.ascii.isWhitespace(c) and c != '"' and c != '\'' and c != ',' and c != '}' and c != ']';
}

fn redactBearerTokens(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (i + 7 <= input.len and std.ascii.eqlIgnoreCase(input[i .. i + 7], "Bearer ")) {
            try out.appendSlice(input[i .. i + 7]);
            var j = i + 7;
            while (j < input.len and isBearerSecretByte(input[j])) : (j += 1) {}
            if (j > i + 7) {
                try out.appendSlice("[REDACTED]");
                i = j;
                continue;
            }
        }

        try out.append(input[i]);
        i += 1;
    }

    return out.toOwnedSlice();
}

fn sanitizeRunEventText(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const redacted = try redactBearerTokens(allocator, input);
    if (redacted.len <= MAX_RUN_EVENT_CHARS) return redacted;

    defer allocator.free(redacted);
    const omitted = redacted.len - MAX_RUN_EVENT_CHARS;
    return std.fmt.allocPrint(
        allocator,
        "{s}... [truncated {d} chars]",
        .{ redacted[0..MAX_RUN_EVENT_CHARS], omitted },
    );
}

fn buildMinimalRunEventJson(
    allocator: std.mem.Allocator,
    run_id: []const u8,
    user_id: []const u8,
    device_id: ?[]const u8,
    scopes: []const u8,
    event_type: []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try buf.writer().print(
        "{{\"type\":{s},\"run_id\":{s},\"user_id\":{s},\"ts\":{d}",
        .{ std.json.fmt(event_type, .{}), std.json.fmt(run_id, .{}), std.json.fmt(user_id, .{}), std.time.timestamp() },
    );
    if (device_id) |value| try buf.writer().print(",\"device_id\":{s}", .{std.json.fmt(value, .{})});
    if (scopes.len > 0) try buf.writer().print(",\"scopes\":{s}", .{std.json.fmt(scopes, .{})});
    try buf.append('}');
    return buf.toOwnedSlice();
}

fn buildRunEventJson(
    allocator: std.mem.Allocator,
    run_id: []const u8,
    user_id: []const u8,
    device_id: ?[]const u8,
    scopes: []const u8,
    event_type: []const u8,
    tool_name: ?[]const u8,
    arguments: ?[]const u8,
    success: ?bool,
    content: ?[]const u8,
    code: ?[]const u8,
    message: ?[]const u8,
) ![]u8 {
    const safe_tool = if (tool_name) |value| try sanitizeRunEventText(allocator, value) else null;
    defer if (safe_tool) |value| allocator.free(value);
    const safe_args = if (arguments) |value| try sanitizeRunEventText(allocator, value) else null;
    defer if (safe_args) |value| allocator.free(value);
    const safe_content = if (content) |value| try sanitizeRunEventText(allocator, value) else null;
    defer if (safe_content) |value| allocator.free(value);
    const safe_code = if (code) |value| try sanitizeRunEventText(allocator, value) else null;
    defer if (safe_code) |value| allocator.free(value);
    const safe_message = if (message) |value| try sanitizeRunEventText(allocator, value) else null;
    defer if (safe_message) |value| allocator.free(value);

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.writer().print(
        "{{\"type\":{s},\"run_id\":{s},\"user_id\":{s},\"ts\":{d}",
        .{ std.json.fmt(event_type, .{}), std.json.fmt(run_id, .{}), std.json.fmt(user_id, .{}), std.time.timestamp() },
    );
    if (device_id) |value| try buf.writer().print(",\"device_id\":{s}", .{std.json.fmt(value, .{})});
    if (scopes.len > 0) try buf.writer().print(",\"scopes\":{s}", .{std.json.fmt(scopes, .{})});
    if (safe_tool) |value| try buf.writer().print(",\"tool\":{s}", .{std.json.fmt(value, .{})});
    if (safe_args) |value| try buf.writer().print(",\"arguments\":{s}", .{std.json.fmt(value, .{})});
    if (success) |value| try buf.writer().print(",\"success\":{}", .{value});
    if (safe_content) |value| try buf.writer().print(",\"content\":{s}", .{std.json.fmt(value, .{})});
    if (safe_code) |value| try buf.writer().print(",\"code\":{s}", .{std.json.fmt(value, .{})});
    if (safe_message) |value| try buf.writer().print(",\"message\":{s}", .{std.json.fmt(value, .{})});
    try buf.append('}');
    return buf.toOwnedSlice();
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

fn parseAssertedIdentity(headers: []const u8) ?AssertedIdentity {
    const user_id = parseHeaderValue(headers, "x-tardigrade-user-id") orelse return null;
    const trimmed_user_id = std.mem.trim(u8, user_id, " \t");
    if (trimmed_user_id.len == 0) return null;

    const scopes = parseHeaderValue(headers, "x-tardigrade-scopes") orelse return null;
    const trimmed_scopes = std.mem.trim(u8, scopes, " \t");
    if (!scopesContain(trimmed_scopes, REQUIRED_OPERATOR_SCOPE)) return null;

    const device_id = if (parseHeaderValue(headers, "x-tardigrade-device-id")) |value|
        std.mem.trim(u8, value, " \t")
    else
        null;

    return .{
        .user_id = trimmed_user_id,
        .device_id = if (device_id) |value| if (value.len > 0) value else null else null,
        .scopes = trimmed_scopes,
    };
}

fn scopesContain(scopes: []const u8, required: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, scopes, " ,");
    while (it.next()) |scope| {
        if (std.mem.eql(u8, scope, required)) return true;
    }
    return false;
}

fn parseContentLength(headers: []const u8) ?usize {
    const value = parseHeaderValue(headers, "content-length") orelse return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn sendSseHeaders(stream: std.net.Stream, run_id: []const u8) !void {
    const w = stream.writer();
    try w.print(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: close\r\n" ++
            "X-Correlation-ID: {s}\r\n" ++
            "X-Run-ID: {s}\r\n" ++
            "\r\n",
        .{ run_id, run_id },
    );
}

fn appendSseFrame(writer: anytype, event_type: []const u8, json_payload: []const u8) !void {
    try writer.print("event: {s}\n", .{event_type});
    try writer.print("data: {s}\n\n", .{json_payload});
}

fn sendSseFrame(stream: std.net.Stream, event_type: []const u8, json_payload: []const u8) !void {
    try appendSseFrame(stream.writer(), event_type, json_payload);
}

fn sendJson(stream: std.net.Stream, status: []const u8, body: []const u8, request_id: ?[]const u8) !void {
    const w = stream.writer();
    if (request_id) |rid| {
        try w.print(
            "HTTP/1.1 {s}\r\n" ++
                "Content-Type: application/json\r\n" ++
                "X-Correlation-ID: {s}\r\n" ++
                "X-Run-ID: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "{s}",
            .{ status, rid, rid, body.len, body },
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

test "buildChatResponse keeps the non-streaming assistant envelope" {
    const allocator = std.testing.allocator;
    const payload = try buildChatResponse(allocator, "still ok");
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const message = obj.get("message") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("assistant", message.object.get("role").?.string);
    try std.testing.expectEqualStrings("still ok", message.object.get("content").?.string);
    try std.testing.expectEqual(false, obj.get("requires_confirmation").?.bool);
    try std.testing.expectEqual(.null, obj.get("confirmation_reason").?);
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

fn createTestWorkspaceDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const workspace_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    errdefer allocator.free(workspace_dir);
    try std.fs.cwd().makePath(workspace_dir);
    return workspace_dir;
}

fn testAssertedIdentity() AssertedIdentity {
    return .{
        .user_id = "user-42",
        .device_id = "bearclaw-web",
        .scopes = "bearclaw.operator",
    };
}

fn findFreeLocalPort() !u16 {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();
    return listener.listen_address.getPort();
}

fn wakeGatewayListener(port: u16) void {
    const address = std.net.Address.parseIp4("127.0.0.1", port) catch return;
    var stream = std.net.tcpConnectToAddress(address) catch return;
    defer stream.close();
    stream.writeAll("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") catch {};
}

fn sendRawGatewayRequest(allocator: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    var stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();
    try stream.writeAll(request);

    var response = std.ArrayList(u8).init(allocator);
    errdefer response.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;
        try response.appendSlice(buf[0..n]);
    }
    return response.toOwnedSlice();
}

test "appendSseFrame matches the gateway stream fixture" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try appendSseFrame(buf.writer(), "model_output", "{\"type\":\"model_output\",\"run_id\":\"run-123\",\"content\":\"ok\"}");

    try std.testing.expectEqualStrings(
        "event: model_output\n" ++
            "data: {\"type\":\"model_output\",\"run_id\":\"run-123\",\"content\":\"ok\"}\n\n",
        buf.items,
    );
}

test "parseAssertedIdentity requires tardigrade operator assertions" {
    const headers =
        "POST /v1/chat HTTP/1.1\r\n" ++
        "X-Tardigrade-User-ID: user-42\r\n" ++
        "X-Tardigrade-Device-ID: bearclaw-web\r\n" ++
        "X-Tardigrade-Scopes: bearclaw.operator bearclaw.admin\r\n\r\n";
    const asserted = parseAssertedIdentity(headers) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("user-42", asserted.user_id);
    try std.testing.expectEqualStrings("bearclaw-web", asserted.device_id.?);
    try std.testing.expectEqualStrings("bearclaw.operator bearclaw.admin", asserted.scopes);
}

test "parseAssertedIdentity rejects missing operator scope" {
    const headers =
        "POST /v1/chat HTTP/1.1\r\n" ++
        "X-Tardigrade-User-ID: user-42\r\n" ++
        "X-Tardigrade-Scopes: bearclaw.viewer\r\n\r\n";
    try std.testing.expect(parseAssertedIdentity(headers) == null);
}

test "chat requests without tardigrade assertions return 403" {
    const allocator = std.testing.allocator;
    const port = try findFreeLocalPort();
    var shutdown = std.atomic.Value(bool).init(false);
    var thread = try std.Thread.spawn(.{}, runGatewayWithShutdown, .{ port, &shutdown });
    defer {
        shutdown.store(true, .release);
        wakeGatewayListener(port);
        thread.join();
    }

    std.time.sleep(50 * std.time.ns_per_ms);

    const raw_response = try sendRawGatewayRequest(
        allocator,
        port,
        "POST /v1/chat HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 19\r\n" ++
            "Connection: close\r\n\r\n" ++
            "{\"message\":\"hi\"}",
    );
    defer allocator.free(raw_response);

    try std.testing.expect(std.mem.indexOf(u8, raw_response, "403 Forbidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw_response, "asserted tardigrade identity required") != null);
}

test "sanitizeRunEventText redacts bearer tokens and truncates long output" {
    const allocator = std.testing.allocator;
    var raw = std.ArrayList(u8).init(allocator);
    defer raw.deinit();

    try raw.appendSlice("Authorization: Bearer super-secret-token ");
    try raw.appendNTimes('a', MAX_RUN_EVENT_CHARS + 64);

    const sanitized = try sanitizeRunEventText(allocator, raw.items);
    defer allocator.free(sanitized);

    try std.testing.expect(std.mem.indexOf(u8, sanitized, "super-secret-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, sanitized, "Bearer [REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sanitized, "[truncated ") != null);
}

test "run artifacts are written and readable after observer events" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_dir = try createTestWorkspaceDir(allocator, &tmp);
    defer allocator.free(workspace_dir);

    const run_id = "run-artifact";
    const artifact_path = try std.fmt.allocPrint(allocator, "{s}/runs/{s}.jsonl", .{ workspace_dir, run_id });
    defer allocator.free(artifact_path);

    const sink = try GatewayRunSink.init(allocator, workspace_dir, run_id, testAssertedIdentity(), null);
    const observer = buildGatewayRunObserver(sink);

    planner_mod.RunObserver.emitPrompt(&observer, "hello");
    planner_mod.RunObserver.emitToolCall(&observer, "file_read", "{\"path\":\"README.md\"}");
    planner_mod.RunObserver.emitToolResult(&observer, "file_read", true, "contents");
    planner_mod.RunObserver.emitModelOutput(&observer, "final answer");
    sink.finishStream();
    sink.deinit();

    const artifact = try std.fs.cwd().readFileAlloc(allocator, artifact_path, 64 * 1024);
    defer allocator.free(artifact);

    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"type\":\"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"type\":\"tool_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"type\":\"model_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"type\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"run_id\":\"run-artifact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"user_id\":\"user-42\"") != null);
}

test "run artifact jsonl never stores raw bearer tokens" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_dir = try createTestWorkspaceDir(allocator, &tmp);
    defer allocator.free(workspace_dir);

    const run_id = "run-redaction";
    const artifact_path = try std.fmt.allocPrint(allocator, "{s}/runs/{s}.jsonl", .{ workspace_dir, run_id });
    defer allocator.free(artifact_path);

    const sink = try GatewayRunSink.init(allocator, workspace_dir, run_id, testAssertedIdentity(), null);
    sink.emitToolCall("http_request", "{\"headers\":{\"Authorization\":\"Bearer token-123\"}}");
    sink.emitError("provider_error", "Bearer token-123 should not persist");
    sink.deinit();

    const artifact = try std.fs.cwd().readFileAlloc(allocator, artifact_path, 64 * 1024);
    defer allocator.free(artifact);

    try std.testing.expect(std.mem.indexOf(u8, artifact, "token-123") == null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "Bearer [REDACTED]") != null);
}

test "parseRunRoute recognizes detail and stream routes" {
    const detail = parseRunRoute("/v1/runs/run-123") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("run-123", detail.run_id);
    try std.testing.expectEqual(false, detail.stream);

    const stream = parseRunRoute("/v1/runs/run-123/stream") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("run-123", stream.run_id);
    try std.testing.expectEqual(true, stream.stream);
}

test "buildRunDetailResponse returns metadata and event history" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_dir = try createTestWorkspaceDir(allocator, &tmp);
    defer allocator.free(workspace_dir);

    const sink = try GatewayRunSink.init(allocator, workspace_dir, "run-detail", testAssertedIdentity(), null);
    sink.emitPrompt("inspect koala");
    sink.emitToolCall("koala__snapshot", "{\"camera\":\"front\"}");
    sink.emitModelOutput("snapshot queued");
    sink.finishStream();
    sink.deinit();

    const payload = try buildRunDetailResponse(allocator, workspace_dir, "run-detail");
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"id\":\"run-detail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"status\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool\":\"koala__snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"done\"") != null);
}
