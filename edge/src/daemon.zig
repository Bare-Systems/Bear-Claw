/// BearClaw daemon — runs the HTTP gateway and cron scheduler concurrently.
///
/// The gateway serves /health and /webhook on a background thread.
/// The cron loop fires due tasks every ~60 seconds on the main thread.
/// SIGTERM or SIGINT sets the atomic shutdown flag; both loops exit cleanly.

const std = @import("std");
const posix = std.posix;
const gateway_mod = @import("gateway.zig");
const cron_mod = @import("cron.zig");

/// Atomic shutdown flag shared between the signal handler, gateway thread,
/// and cron loop. The signal handler only sets this (store) and the loops
/// only read it (load) — no races.
var g_shutdown = std.atomic.Value(bool).init(false);

/// POSIX signal handler — sets g_shutdown and returns immediately.
/// Must be async-signal-safe (only atomic store is used).
fn signalHandler(_: c_int) callconv(.C) void {
    g_shutdown.store(true, .release);
}

/// Arguments passed to the gateway background thread.
const GatewayArgs = struct {
    port: u16,
};

fn gatewayThread(args: GatewayArgs) void {
    gateway_mod.runGatewayWithShutdown(args.port, &g_shutdown) catch |err| {
        std.debug.print("daemon: gateway error: {}\n", .{err});
    };
}

pub fn runDaemon(allocator: std.mem.Allocator, port: u16) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("BearClaw daemon starting (gateway port {d})...\n", .{port});

    // Install SIGTERM and SIGINT handlers so the daemon exits gracefully.
    var sa = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.INT, &sa, null);

    // Spawn the gateway on a background thread.
    const thread = try std.Thread.spawn(.{}, gatewayThread, .{GatewayArgs{ .port = port }});
    defer thread.join();

    try stdout.print("Daemon running. Send SIGTERM or Ctrl-C to stop.\n", .{});

    // Cron loop: run due tasks every 60 seconds.
    // Sleep in 1-second increments so we notice a shutdown signal promptly.
    while (!g_shutdown.load(.acquire)) {
        var elapsed: u32 = 0;
        while (elapsed < 60 and !g_shutdown.load(.acquire)) {
            std.time.sleep(std.time.ns_per_s);
            elapsed += 1;
        }
        if (g_shutdown.load(.acquire)) break;
        cron_mod.runCronOnce(allocator) catch |err| {
            try stdout.print("daemon: cron error: {}\n", .{err});
        };
    }

    try stdout.print("BearClaw daemon stopped.\n", .{});
}
