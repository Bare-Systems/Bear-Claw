const std = @import("std");
const config_mod = @import("config.zig");
const memory_mod = @import("memory.zig");

pub const MigrationSummary = struct {
    source_workspace: []const u8,
    source_memory_dir: []const u8,
    target_workspace: []const u8,
    imported_entries: usize,
    skipped_entries: usize,
};

pub const DEFAULT_OPENCLAW_WORKSPACE = "~/.openclaw/workspace";

pub fn migrateFromOpenClaw(allocator: std.mem.Allocator, source_path: []const u8) !void {
    var stdout = std.io.getStdOut().writer();

    var cfg = try config_mod.loadOrInit(allocator);
    defer cfg.deinit(allocator);

    var mem_backend = try memory_mod.createMemoryBackend(allocator, &cfg);
    defer mem_backend.deinit();

    const summary = try importOpenClawWorkspace(allocator, source_path, &mem_backend, cfg.workspace_dir);
    defer allocator.free(summary.source_workspace);
    defer allocator.free(summary.source_memory_dir);
    defer allocator.free(summary.target_workspace);

    try stdout.print(
        "Imported {d} OpenClaw memory entr{s} from {s} into {s}/memory",
        .{
            summary.imported_entries,
            if (summary.imported_entries == 1) @as([]const u8, "y") else "ies",
            summary.source_memory_dir,
            summary.target_workspace,
        },
    );
    if (summary.skipped_entries > 0) {
        try stdout.print(" ({d} non-markdown file{s} skipped)", .{
            summary.skipped_entries,
            if (summary.skipped_entries == 1) @as([]const u8, "") else "s",
        });
    }
    try stdout.print(".\n", .{});
}

pub fn importOpenClawWorkspace(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    mem_backend: *memory_mod.MemoryBackend,
    target_workspace_dir: []const u8,
) !MigrationSummary {
    const source_workspace = try resolveSourceWorkspace(allocator, source_path);
    errdefer allocator.free(source_workspace);

    const source_memory_dir = try std.fs.path.join(allocator, &.{ source_workspace, "memory" });
    errdefer allocator.free(source_memory_dir);

    var source_dir = std.fs.openDirAbsolute(source_memory_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SourceMemoryDirNotFound,
        else => return err,
    };
    defer source_dir.close();

    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    var imported_entries: usize = 0;
    var skipped_entries: usize = 0;

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => {},
            else => continue,
        }

        if (!std.mem.endsWith(u8, entry.path, ".md")) {
            skipped_entries += 1;
            continue;
        }

        const key = entry.path[0 .. entry.path.len - 3];
        if (key.len == 0) continue;

        const file = try source_dir.openFile(entry.path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const trimmed_content = std.mem.trimRight(u8, content, "\r\n");
        try mem_backend.store(key, trimmed_content);
        imported_entries += 1;
    }

    return MigrationSummary{
        .source_workspace = source_workspace,
        .source_memory_dir = source_memory_dir,
        .target_workspace = try allocator.dupe(u8, target_workspace_dir),
        .imported_entries = imported_entries,
        .skipped_entries = skipped_entries,
    };
}

fn resolveSourceWorkspace(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    const expanded = try expandHomePrefix(allocator, source_path);
    defer allocator.free(expanded);
    return std.fs.realpathAlloc(allocator, expanded);
}

pub fn defaultSourceWorkspaceExists(allocator: std.mem.Allocator) bool {
    const expanded = expandHomePrefix(allocator, DEFAULT_OPENCLAW_WORKSPACE) catch return false;
    defer allocator.free(expanded);

    const real = std.fs.realpathAlloc(allocator, expanded) catch return false;
    defer allocator.free(real);

    const memory_dir = std.fs.path.join(allocator, &.{ real, "memory" }) catch return false;
    defer allocator.free(memory_dir);

    if (std.fs.openDirAbsolute(memory_dir, .{})) |dir_opened| {
        var dir = dir_opened;
        dir.close();
        return true;
    } else |_| {
        return false;
    }
}

fn expandHomePrefix(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, path, "~")) return allocator.dupe(u8, path);

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    if (path.len == 1) return allocator.dupe(u8, home);
    if (path[1] != std.fs.path.sep) return error.UnsupportedHomeSyntax;

    return std.fs.path.join(allocator, &.{ home, path[2..] });
}
