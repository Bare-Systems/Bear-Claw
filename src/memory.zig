const std = @import("std");
const config_mod = @import("config.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const BackendKind = enum {
    markdown,
    sqlite,
};

pub const MemoryBackend = struct {
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    kind: BackendKind,
    /// Open SQLite handle — non-null only when kind == .sqlite.
    db: ?*c.sqlite3 = null,

    pub fn deinit(self: *MemoryBackend) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
        self.allocator.free(self.workspace_dir);
    }

    pub fn store(self: *MemoryBackend, key: []const u8, content: []const u8) !void {
        switch (self.kind) {
            .markdown => try storeMarkdown(self, key, content),
            .sqlite   => try storeSqlite(self, key, content),
        }
    }

    /// Recall memory for a key.
    /// Exact match first; falls back to fuzzy/substring search.
    pub fn recall(self: *MemoryBackend, key: []const u8) ![]u8 {
        return switch (self.kind) {
            .markdown => recallMarkdown(self, key),
            .sqlite   => recallSqlite(self, key),
        };
    }

    /// Delete the stored value for the given key.
    pub fn forget(self: *MemoryBackend, key: []const u8) !void {
        switch (self.kind) {
            .markdown => try forgetMarkdown(self, key),
            .sqlite   => try forgetSqlite(self, key),
        }
    }
};

// ---------------------------------------------------------------------------
// Markdown backend
// ---------------------------------------------------------------------------

fn storeMarkdown(self: *MemoryBackend, key: []const u8, content: []const u8) !void {
    var path_buf = std.ArrayList(u8).init(self.allocator);
    defer path_buf.deinit();

    try path_buf.appendSlice(self.workspace_dir);
    try path_buf.append(std.fs.path.sep);
    try path_buf.appendSlice("memory");
    try path_buf.append(std.fs.path.sep);
    try path_buf.appendSlice(key);
    try path_buf.appendSlice(".md");

    var cwd = std.fs.cwd();
    // Ensure the full parent directory chain exists.
    // This handles nested keys like "cron/t1/1700000000".
    if (std.fs.path.dirname(path_buf.items)) |parent| {
        cwd.makePath(parent) catch {};
    }

    var file = try cwd.createFile(path_buf.items, .{ .truncate = true, .read = false });
    defer file.close();

    try file.writeAll(content);
    try file.writeAll("\n");
}

fn recallMarkdown(self: *MemoryBackend, key: []const u8) ![]u8 {
    var path_buf = std.ArrayList(u8).init(self.allocator);
    defer path_buf.deinit();

    try path_buf.appendSlice(self.workspace_dir);
    try path_buf.append(std.fs.path.sep);
    try path_buf.appendSlice("memory");
    try path_buf.append(std.fs.path.sep);
    try path_buf.appendSlice(key);
    try path_buf.appendSlice(".md");

    // Try exact key match first.
    const file = std.fs.cwd().openFile(path_buf.items, .{}) catch null;
    if (file) |f| {
        defer f.close();
        return f.readToEndAlloc(self.allocator, 1024 * 1024);
    }

    // Fall back: scan memory dir for any file whose name contains key as a substring.
    var mem_dir_buf = std.ArrayList(u8).init(self.allocator);
    defer mem_dir_buf.deinit();
    try mem_dir_buf.appendSlice(self.workspace_dir);
    try mem_dir_buf.append(std.fs.path.sep);
    try mem_dir_buf.appendSlice("memory");

    var dir = std.fs.cwd().openDir(mem_dir_buf.items, .{ .iterate = true }) catch {
        return self.allocator.dupe(u8, "(no memory yet)");
    };
    defer dir.close();

    var results = std.ArrayList(u8).init(self.allocator);
    errdefer results.deinit();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.name, key) == null) continue;

        const entry_file = dir.openFile(entry.name, .{}) catch continue;
        defer entry_file.close();
        const content = entry_file.readToEndAlloc(self.allocator, 1024 * 1024) catch continue;
        defer self.allocator.free(content);

        if (results.items.len > 0) try results.appendSlice("\n---\n");
        try results.appendSlice(entry.name);
        try results.appendSlice(":\n");
        try results.appendSlice(content);
    }

    if (results.items.len == 0) {
        return self.allocator.dupe(u8, "(no matching memory found)");
    }
    return results.toOwnedSlice();
}

fn forgetMarkdown(self: *MemoryBackend, key: []const u8) !void {
    var path_buf = std.ArrayList(u8).init(self.allocator);
    defer path_buf.deinit();

    try path_buf.appendSlice(self.workspace_dir);
    try path_buf.append(std.fs.path.sep);
    try path_buf.appendSlice("memory");
    try path_buf.append(std.fs.path.sep);
    try path_buf.appendSlice(key);
    try path_buf.appendSlice(".md");

    std.fs.cwd().deleteFile(path_buf.items) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// SQLite backend
// ---------------------------------------------------------------------------
//
// Uses the system libsqlite3 via C interop (linked in build.zig).
// Schema: CREATE TABLE memory (key TEXT PRIMARY KEY, content TEXT NOT NULL)
// ---------------------------------------------------------------------------

const SQLITE_OK   = 0;
const SQLITE_ROW  = 100;
const SQLITE_DONE = 101;

fn sqliteDbPath(self: *MemoryBackend) ![:0]u8 {
    var buf = std.ArrayList(u8).init(self.allocator);
    defer buf.deinit();
    try buf.appendSlice(self.workspace_dir);
    try buf.append(std.fs.path.sep);
    try buf.appendSlice("memory.db");
    try buf.append(0); // null terminator for C string
    const owned = try buf.toOwnedSlice();
    return owned[0 .. owned.len - 1 :0];
}

fn openSqlite(self: *MemoryBackend) !*c.sqlite3 {
    if (self.db) |db| return db;

    const path = try sqliteDbPath(self);
    defer self.allocator.free(path);

    // Ensure workspace dir exists.
    std.fs.cwd().makePath(self.workspace_dir) catch {};

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path.ptr, &db) != SQLITE_OK) {
        return error.SqliteOpenFailed;
    }
    self.db = db.?;

    // Create the table if it doesn't exist yet.
    const ddl = "CREATE TABLE IF NOT EXISTS memory (key TEXT PRIMARY KEY, content TEXT NOT NULL);";
    if (c.sqlite3_exec(self.db, ddl, null, null, null) != SQLITE_OK) {
        return error.SqliteExecFailed;
    }
    return self.db.?;
}

fn storeSqlite(self: *MemoryBackend, key: []const u8, content: []const u8) !void {
    const db = try openSqlite(self);
    const sql = "INSERT OR REPLACE INTO memory (key, content) VALUES (?, ?);";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, content.ptr, @intCast(content.len), c.SQLITE_STATIC);

    const rc = c.sqlite3_step(stmt);
    if (rc != SQLITE_DONE) return error.SqliteStepFailed;
}

fn recallSqlite(self: *MemoryBackend, key: []const u8) ![]u8 {
    const db = try openSqlite(self);

    // Exact match first.
    {
        const sql = "SELECT content FROM memory WHERE key = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) == SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), c.SQLITE_STATIC);
            if (c.sqlite3_step(stmt) == SQLITE_ROW) {
                const raw: [*c]const u8 = c.sqlite3_column_text(stmt, 0);
                const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
                return self.allocator.dupe(u8, raw[0..len]);
            }
        }
    }

    // Fuzzy fallback: all rows whose key contains the search term.
    {
        const sql = "SELECT key, content FROM memory WHERE key LIKE '%' || ? || '%' ORDER BY key;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) {
            return self.allocator.dupe(u8, "(no matching memory found)");
        }
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), c.SQLITE_STATIC);

        var results = std.ArrayList(u8).init(self.allocator);
        errdefer results.deinit();

        while (c.sqlite3_step(stmt) == SQLITE_ROW) {
            const k_raw: [*c]const u8 = c.sqlite3_column_text(stmt, 0);
            const k_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const v_raw: [*c]const u8 = c.sqlite3_column_text(stmt, 1);
            const v_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));

            if (results.items.len > 0) try results.appendSlice("\n---\n");
            try results.appendSlice(k_raw[0..k_len]);
            try results.appendSlice(":\n");
            try results.appendSlice(v_raw[0..v_len]);
        }

        if (results.items.len == 0) {
            return self.allocator.dupe(u8, "(no matching memory found)");
        }
        return results.toOwnedSlice();
    }
}

fn forgetSqlite(self: *MemoryBackend, key: []const u8) !void {
    const db = try openSqlite(self);
    const sql = "DELETE FROM memory WHERE key = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), c.SQLITE_STATIC);
    _ = c.sqlite3_step(stmt);
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn createMemoryBackend(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !MemoryBackend {
    const ws = try allocator.dupe(u8, cfg.workspace_dir);
    const kind: BackendKind = blk: {
        if (std.mem.eql(u8, cfg.memory_backend, "sqlite")) break :blk .sqlite;
        break :blk .markdown;
    };
    return MemoryBackend{
        .allocator     = allocator,
        .workspace_dir = ws,
        .kind          = kind,
    };
}
