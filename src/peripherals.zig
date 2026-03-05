const std = @import("std");

pub const PeripheralConfig = struct {
    board: []const u8,
    transport: []const u8,
    path: []const u8,
};

pub fn listConfiguredPeripherals() !void {
    var stdout = std.io.getStdOut().writer();
    try stdout.print("BearClaw peripherals stub – no boards configured yet.\n", .{});
}

