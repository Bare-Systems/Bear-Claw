const std = @import("std");

const Entry = struct {
    key: []u8,
    value: []u8,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub fn profilePath(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace_dir, "profile.md" });
}

pub fn loadProfile(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    const path = try profilePath(allocator, workspace_dir);
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, ""),
        else => return err,
    };
    defer file.close();

    return file.readToEndAlloc(allocator, 64 * 1024);
}

pub fn getValue(allocator: std.mem.Allocator, workspace_dir: []const u8, key: []const u8) !?[]u8 {
    const contents = try loadProfile(allocator, workspace_dir);
    defer allocator.free(contents);

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const sep = std.mem.indexOf(u8, line, ":") orelse continue;
        const entry_key = std.mem.trim(u8, line[0..sep], " \t");
        const entry_value = std.mem.trim(u8, line[sep + 1 ..], " \t");
        if (std.mem.eql(u8, entry_key, key)) {
            const duped = try allocator.dupe(u8, entry_value);
            return duped;
        }
    }
    return null;
}

pub fn setValue(allocator: std.mem.Allocator, workspace_dir: []const u8, key: []const u8, value: []const u8) !void {
    var entries = try parseEntries(allocator, workspace_dir);
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            allocator.free(entry.value);
            entry.value = try allocator.dupe(u8, value);
            try writeEntries(allocator, workspace_dir, entries.items);
            return;
        }
    }

    try entries.append(.{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    });
    try writeEntries(allocator, workspace_dir, entries.items);
}

fn parseEntries(allocator: std.mem.Allocator, workspace_dir: []const u8) !std.ArrayList(Entry) {
    var entries = std.ArrayList(Entry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    const contents = try loadProfile(allocator, workspace_dir);
    defer allocator.free(contents);

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const sep = std.mem.indexOf(u8, line, ":") orelse continue;
        try entries.append(.{
            .key = try allocator.dupe(u8, std.mem.trim(u8, line[0..sep], " \t")),
            .value = try allocator.dupe(u8, std.mem.trim(u8, line[sep + 1 ..], " \t")),
        });
    }

    return entries;
}

fn writeEntries(allocator: std.mem.Allocator, workspace_dir: []const u8, entries: []const Entry) !void {
    const path = try profilePath(allocator, workspace_dir);
    defer allocator.free(path);

    std.fs.cwd().makePath(workspace_dir) catch {};
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    const writer = file.writer();
    for (entries) |entry| {
        try writer.print("{s}: {s}\n", .{ entry.key, entry.value });
    }
}
