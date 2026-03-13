const std = @import("std");
const config_mod = @import("config.zig");

pub const PeripheralConfig = struct {
    board: []const u8,
    transport: []const u8,
    path: []const u8,
    baud: ?u32,

    pub fn deinit(self: *PeripheralConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.board);
        allocator.free(self.transport);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const PeripheralSection = struct {
    enabled: bool,
    boards: []PeripheralConfig,

    pub fn deinit(self: *PeripheralSection, allocator: std.mem.Allocator) void {
        for (self.boards) |*board| board.deinit(allocator);
        allocator.free(self.boards);
        self.* = undefined;
    }
};

pub const PeripheralIssue = struct {
    index: usize,
    message: []const u8,

    pub fn deinit(self: *PeripheralIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub fn listConfiguredPeripherals(allocator: std.mem.Allocator) !void {
    var stdout = std.io.getStdOut().writer();

    var cfg = try config_mod.loadOrInit(allocator);
    defer cfg.deinit(allocator);

    var section = loadPeripheralSection(allocator, cfg.config_path) catch |err| switch (err) {
        error.FileNotFound => {
            try stdout.print("No config file found at {s}.\n", .{cfg.config_path});
            return;
        },
        else => return err,
    };
    defer section.deinit(allocator);

    if (!section.enabled) {
        try stdout.print("Peripherals are disabled in {s}.\n", .{cfg.config_path});
        return;
    }

    if (section.boards.len == 0) {
        try stdout.print(
            "No peripherals configured in {s}.\nAdd [peripherals] and [[peripherals.boards]] entries to config.toml.\n",
            .{cfg.config_path},
        );
        return;
    }

    try stdout.print("{s:<18} {s:<10} {s:<18} {s}\n", .{ "BOARD", "TRANSPORT", "PATH", "DETAILS" });
    try stdout.print("{s}\n", .{"-" ** 72});
    for (section.boards) |board| {
        const path = if (board.path.len > 0) board.path else "-";
        var details_buf: [32]u8 = undefined;
        const details = if (board.baud) |baud|
            try std.fmt.bufPrint(&details_buf, "baud={d}", .{baud})
        else
            "-";
        try stdout.print("{s:<18} {s:<10} {s:<18} {s}\n", .{ board.board, board.transport, path, details });
    }
}

pub fn loadPeripheralSection(allocator: std.mem.Allocator, config_path: []const u8) !PeripheralSection {
    const file = try std.fs.cwd().openFile(config_path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(contents);

    return parsePeripheralConfig(allocator, contents);
}

pub fn parsePeripheralConfig(allocator: std.mem.Allocator, contents: []const u8) !PeripheralSection {
    var boards = std.ArrayList(PeripheralConfig).init(allocator);
    errdefer {
        for (boards.items) |*board| board.deinit(allocator);
        boards.deinit();
    }

    var enabled = true;
    var in_peripherals = false;
    var current_board: ?PeripheralConfig = null;

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[peripherals]")) {
            if (current_board) |board| {
                try boards.append(board);
                current_board = null;
            }
            in_peripherals = true;
            continue;
        }

        if (std.mem.eql(u8, line, "[[peripherals.boards]]")) {
            if (current_board) |board| try boards.append(board);
            current_board = PeripheralConfig{
                .board = try allocator.dupe(u8, ""),
                .transport = try allocator.dupe(u8, ""),
                .path = try allocator.dupe(u8, ""),
                .baud = null,
            };
            in_peripherals = true;
            continue;
        }

        if (line[0] == '[') {
            if (current_board) |board| {
                try boards.append(board);
                current_board = null;
            }
            in_peripherals = false;
            continue;
        }

        if (!in_peripherals) continue;

        if (current_board == null) {
            if (std.mem.startsWith(u8, line, "enabled")) {
                if (parseValue(line)) |value| {
                    enabled = std.mem.eql(u8, value, "true");
                }
            }
            continue;
        }

        if (parseValue(line)) |value| {
            if (std.mem.startsWith(u8, line, "board")) {
                allocator.free(current_board.?.board);
                current_board.?.board = try allocator.dupe(u8, value);
            } else if (std.mem.startsWith(u8, line, "transport")) {
                allocator.free(current_board.?.transport);
                current_board.?.transport = try allocator.dupe(u8, value);
            } else if (std.mem.startsWith(u8, line, "path")) {
                allocator.free(current_board.?.path);
                current_board.?.path = try allocator.dupe(u8, value);
            } else if (std.mem.startsWith(u8, line, "baud")) {
                current_board.?.baud = std.fmt.parseInt(u32, value, 10) catch null;
            }
        }
    }

    if (current_board) |board| try boards.append(board);

    return PeripheralSection{
        .enabled = enabled,
        .boards = try boards.toOwnedSlice(),
    };
}

pub fn validatePeripheralSection(
    allocator: std.mem.Allocator,
    section: *const PeripheralSection,
) ![]PeripheralIssue {
    var issues = std.ArrayList(PeripheralIssue).init(allocator);
    errdefer {
        for (issues.items) |*issue| issue.deinit(allocator);
        issues.deinit();
    }

    for (section.boards, 0..) |board, idx| {
        if (board.board.len == 0) {
            try issues.append(.{
                .index = idx,
                .message = try allocator.dupe(u8, "missing board name"),
            });
        }
        if (board.transport.len == 0) {
            try issues.append(.{
                .index = idx,
                .message = try allocator.dupe(u8, "missing transport"),
            });
        }
        if (std.mem.eql(u8, board.transport, "serial")) {
            if (board.path.len == 0) {
                try issues.append(.{
                    .index = idx,
                    .message = try allocator.dupe(u8, "serial transport requires a device path"),
                });
            } else {
                const exists = if (std.fs.cwd().openFile(board.path, .{})) |file| blk: {
                    file.close();
                    break :blk true;
                } else |_| false;
                if (!exists) {
                    const msg = try std.fmt.allocPrint(allocator, "serial device path not found: {s}", .{board.path});
                    try issues.append(.{
                        .index = idx,
                        .message = msg,
                    });
                }
            }
        }
    }

    return issues.toOwnedSlice();
}

fn parseValue(line: []const u8) ?[]const u8 {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const raw = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}
