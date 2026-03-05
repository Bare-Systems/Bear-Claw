const std = @import("std");

pub fn migrateFromOpenClaw(source_path: []const u8) !void {
    var stdout = std.io.getStdOut().writer();
    try stdout.print("BearClaw migration stub – would import from {s}\n", .{source_path});
}

