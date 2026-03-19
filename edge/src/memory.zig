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
            .sqlite => try storeSqlite(self, key, content),
        }
    }

    /// Recall memory for a key.
    /// Exact match first; falls back to fuzzy/substring search.
    pub fn recall(self: *MemoryBackend, key: []const u8) ![]u8 {
        return switch (self.kind) {
            .markdown => recallMarkdown(self, key),
            .sqlite => recallSqlite(self, key),
        };
    }

    /// Delete the stored value for the given key.
    pub fn forget(self: *MemoryBackend, key: []const u8) !void {
        switch (self.kind) {
            .markdown => try forgetMarkdown(self, key),
            .sqlite => try forgetSqlite(self, key),
        }
    }

    pub fn search(self: *MemoryBackend, query: []const u8, limit: usize) ![]SearchResult {
        return switch (self.kind) {
            .markdown => searchMarkdown(self, query, limit),
            .sqlite => searchSqlite(self, query, limit),
        };
    }
};

pub const SearchResult = struct {
    key: []u8,
    score: f64,
    preview: []u8,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.preview);
        self.* = undefined;
    }
};

const MemoryDocument = struct {
    key: []u8,
    content: []u8,

    fn deinit(self: *MemoryDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.content);
        self.* = undefined;
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

fn searchMarkdown(self: *MemoryBackend, query: []const u8, limit: usize) ![]SearchResult {
    const docs = try collectMarkdownDocuments(self);
    defer freeDocuments(self.allocator, docs);
    return scoreDocuments(self.allocator, docs, query, limit);
}

// ---------------------------------------------------------------------------
// SQLite backend
// ---------------------------------------------------------------------------
//
// Uses the system libsqlite3 via C interop (linked in build.zig).
// Schema: CREATE TABLE memory (key TEXT PRIMARY KEY, content TEXT NOT NULL)
// ---------------------------------------------------------------------------

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
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

fn searchSqlite(self: *MemoryBackend, query: []const u8, limit: usize) ![]SearchResult {
    const docs = try collectSqliteDocuments(self);
    defer freeDocuments(self.allocator, docs);
    return scoreDocuments(self.allocator, docs, query, limit);
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
        .allocator = allocator,
        .workspace_dir = ws,
        .kind = kind,
    };
}

fn collectMarkdownDocuments(self: *MemoryBackend) ![]MemoryDocument {
    var mem_dir_buf = std.ArrayList(u8).init(self.allocator);
    defer mem_dir_buf.deinit();
    try mem_dir_buf.appendSlice(self.workspace_dir);
    try mem_dir_buf.append(std.fs.path.sep);
    try mem_dir_buf.appendSlice("memory");

    var dir = std.fs.cwd().openDir(mem_dir_buf.items, .{ .iterate = true }) catch {
        return try self.allocator.alloc(MemoryDocument, 0);
    };
    defer dir.close();

    var walker = try dir.walk(self.allocator);
    defer walker.deinit();

    var docs = std.ArrayList(MemoryDocument).init(self.allocator);
    errdefer {
        for (docs.items) |*doc| doc.deinit(self.allocator);
        docs.deinit();
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const key_len = entry.path.len - 3;
        const key = try self.allocator.dupe(u8, entry.path[0..key_len]);

        const file = dir.openFile(entry.path, .{}) catch {
            self.allocator.free(key);
            continue;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch {
            self.allocator.free(key);
            continue;
        };

        try docs.append(.{
            .key = key,
            .content = content,
        });
    }

    return docs.toOwnedSlice();
}

fn collectSqliteDocuments(self: *MemoryBackend) ![]MemoryDocument {
    const db = try openSqlite(self);
    const sql = "SELECT key, content FROM memory ORDER BY key;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) {
        return try self.allocator.alloc(MemoryDocument, 0);
    }
    defer _ = c.sqlite3_finalize(stmt);

    var docs = std.ArrayList(MemoryDocument).init(self.allocator);
    errdefer {
        for (docs.items) |*doc| doc.deinit(self.allocator);
        docs.deinit();
    }

    while (c.sqlite3_step(stmt) == SQLITE_ROW) {
        const k_raw: [*c]const u8 = c.sqlite3_column_text(stmt, 0);
        const k_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        const v_raw: [*c]const u8 = c.sqlite3_column_text(stmt, 1);
        const v_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));

        try docs.append(.{
            .key = try self.allocator.dupe(u8, k_raw[0..k_len]),
            .content = try self.allocator.dupe(u8, v_raw[0..v_len]),
        });
    }

    return docs.toOwnedSlice();
}

fn freeDocuments(allocator: std.mem.Allocator, docs: []MemoryDocument) void {
    for (docs) |*doc| @constCast(doc).deinit(allocator);
    allocator.free(docs);
}

fn scoreDocuments(
    allocator: std.mem.Allocator,
    docs: []const MemoryDocument,
    query: []const u8,
    limit: usize,
) ![]SearchResult {
    const terms = try parseUniqueTerms(allocator, query);
    defer {
        for (terms) |term| allocator.free(term);
        allocator.free(terms);
    }

    if (terms.len == 0 or docs.len == 0 or limit == 0) {
        return try allocator.alloc(SearchResult, 0);
    }

    const doc_freqs = try allocator.alloc(usize, terms.len);
    defer allocator.free(doc_freqs);
    @memset(doc_freqs, 0);

    for (docs) |doc| {
        for (terms, 0..) |term, idx| {
            if (countTermOccurrences(doc.key, term) > 0 or countTermOccurrences(doc.content, term) > 0) {
                doc_freqs[idx] += 1;
            }
        }
    }

    var results = std.ArrayList(SearchResult).init(allocator);
    errdefer {
        for (results.items) |*result| result.deinit(allocator);
        results.deinit();
    }

    const doc_count_f: f64 = @floatFromInt(docs.len);
    for (docs) |doc| {
        var score: f64 = 0.0;
        for (terms, 0..) |term, idx| {
            const key_hits = countTermOccurrences(doc.key, term);
            const body_hits = countTermOccurrences(doc.content, term);
            const tf: usize = key_hits * 3 + body_hits;
            if (tf == 0) continue;

            const df_f: f64 = @floatFromInt(doc_freqs[idx]);
            const tf_f: f64 = @floatFromInt(tf);
            const idf = std.math.log(f64, std.math.e, 1.0 + (doc_count_f / (1.0 + df_f))) + 1.0;
            score += tf_f * idf;
        }

        if (score <= 0.0) continue;
        try results.append(.{
            .key = try allocator.dupe(u8, doc.key),
            .score = score,
            .preview = try makePreview(allocator, doc.content),
        });
    }

    std.mem.sort(SearchResult, results.items, {}, struct {
        fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
            return a.score > b.score;
        }
    }.lessThan);

    if (results.items.len > limit) {
        var i = limit;
        while (i < results.items.len) : (i += 1) {
            results.items[i].deinit(allocator);
        }
        results.shrinkRetainingCapacity(limit);
    }

    return results.toOwnedSlice();
}

fn parseUniqueTerms(allocator: std.mem.Allocator, query: []const u8) ![][]u8 {
    var terms = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (terms.items) |term| allocator.free(term);
        terms.deinit();
    }

    var i: usize = 0;
    while (i < query.len) {
        while (i < query.len and !std.ascii.isAlphanumeric(query[i])) : (i += 1) {}
        const start = i;
        while (i < query.len and std.ascii.isAlphanumeric(query[i])) : (i += 1) {}
        if (i <= start) continue;

        const term = try allocator.dupe(u8, query[start..i]);
        _ = std.ascii.lowerString(term, term);
        if (term.len < 2) {
            allocator.free(term);
            continue;
        }

        var duplicate = false;
        for (terms.items) |existing| {
            if (std.mem.eql(u8, existing, term)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            allocator.free(term);
            continue;
        }
        try terms.append(term);
    }

    return terms.toOwnedSlice();
}

fn countTermOccurrences(text: []const u8, term: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !std.ascii.isAlphanumeric(text[i])) : (i += 1) {}
        const start = i;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) : (i += 1) {}
        if (i <= start) continue;

        const token = text[start..i];
        if (token.len != term.len) continue;
        if (std.ascii.eqlIgnoreCase(token, term)) count += 1;
    }
    return count;
}

fn makePreview(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "(empty)");

    const first_line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const line = std.mem.trim(u8, trimmed[0..first_line_end], " \t\r");
    const max_len: usize = 160;
    if (line.len <= max_len) return allocator.dupe(u8, line);

    return std.fmt.allocPrint(allocator, "{s}...", .{line[0..max_len]});
}
