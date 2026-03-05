/// Minimal HTTP/1.1 gateway for BearClaw.
///
/// Endpoints:
///   GET  /health    → 200 JSON {"status":"ok","service":"bareclaw"}
///   POST /webhook   → 200 JSON {"received":true}  (body is ignored for now)
///   *               → 404
///
/// The server runs synchronously in a single-threaded accept loop.
/// Press Ctrl-C to stop.

const std = @import("std");

const MAX_REQUEST_BYTES: usize = 64 * 1024;

pub fn runGateway(port: u16) !void {
    const stdout = std.io.getStdOut().writer();

    // Bind to 127.0.0.1:<port>.
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    try stdout.print("BearClaw gateway listening on http://127.0.0.1:{d}\n", .{port});
    try stdout.print("Endpoints: GET /health  POST /webhook   (Ctrl-C to stop)\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    while (true) {
        const conn = server.accept() catch |err| {
            try stdout.print("accept error: {}\n", .{err});
            continue;
        };
        handleConnection(allocator, conn) catch |err| {
            try stdout.print("connection error: {}\n", .{err});
        };
    }
}

/// Like runGateway but polls for connections in 500ms windows so the daemon
/// can stop it cleanly by setting shutdown=true.
pub fn runGatewayWithShutdown(port: u16, shutdown: *const std.atomic.Value(bool)) !void {
    const stdout = std.io.getStdOut().writer();

    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    try stdout.print("BearClaw gateway listening on http://127.0.0.1:{d}\n", .{port});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Poll the listening socket in 500ms windows so the thread can exit when
    // the daemon sets the shutdown flag.
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
        if (ready == 0) continue; // timeout — check shutdown and loop
        if (shutdown.load(.acquire)) break;
        const conn = server.accept() catch continue;
        handleConnection(allocator, conn) catch {};
    }
}

fn handleConnection(allocator: std.mem.Allocator, conn: std.net.Server.Connection) !void {
    defer conn.stream.close();

    // Read request (enough to parse the first line).
    var buf: [MAX_REQUEST_BYTES]u8 = undefined;
    const n = conn.stream.read(&buf) catch return;
    const request = buf[0..n];

    // Parse method and path from "METHOD /path HTTP/1.x\r\n..."
    const method, const path = parseMethodPath(request) orelse {
        try sendResponse(conn.stream, "400 Bad Request", "text/plain", "bad request");
        return;
    };

    const body, const status = route(allocator, method, path) catch |err| blk: {
        const msg = try std.fmt.allocPrint(allocator, "internal error: {}", .{err});
        break :blk .{ msg, "500 Internal Server Error" };
    };
    defer allocator.free(body);

    try sendResponse(conn.stream, status, "application/json", body);
}

/// Return (method, path) slices into `request`, or null if unparseable.
fn parseMethodPath(request: []const u8) ?struct { []const u8, []const u8 } {
    // First line is like "GET /health HTTP/1.1\r\n"
    const line_end = std.mem.indexOfScalar(u8, request, '\n') orelse return null;
    const line = std.mem.trim(u8, request[0..line_end], " \r");

    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return null;
    const path   = it.next() orelse return null;
    return .{ method, path };
}

/// Route a request and return an allocated body + status string.
fn route(allocator: std.mem.Allocator, method: []const u8, path: []const u8) !struct { []u8, []const u8 } {
    if (std.mem.eql(u8, path, "/health")) {
        if (!std.mem.eql(u8, method, "GET")) {
            return .{
                try allocator.dupe(u8, "{\"error\":\"method not allowed\"}"),
                "405 Method Not Allowed",
            };
        }
        return .{
            try allocator.dupe(u8, "{\"status\":\"ok\",\"service\":\"bareclaw\"}"),
            "200 OK",
        };
    }

    if (std.mem.eql(u8, path, "/webhook")) {
        if (!std.mem.eql(u8, method, "POST")) {
            return .{
                try allocator.dupe(u8, "{\"error\":\"method not allowed\"}"),
                "405 Method Not Allowed",
            };
        }
        return .{
            try allocator.dupe(u8, "{\"received\":true}"),
            "200 OK",
        };
    }

    return .{
        try std.fmt.allocPrint(allocator, "{{\"error\":\"not found\",\"path\":\"{s}\"}}", .{path}),
        "404 Not Found",
    };
}

/// Write a minimal HTTP/1.1 response.
fn sendResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    const w = stream.writer();
    try w.print(
        "HTTP/1.1 {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{s}",
        .{ status, content_type, body.len, body },
    );
}
