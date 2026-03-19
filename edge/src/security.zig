const std = @import("std");
const config_mod = @import("config.zig");

pub const SecurityPolicy = struct {
    allocator:          std.mem.Allocator,
    workspace_dir:      []const u8,
    owns_workspace_dir: bool,
    /// Parsed allowed_paths from config — each entry is an owned slice.
    extra_paths:        []const []const u8,

    pub fn initWorkspaceOnly(allocator: std.mem.Allocator, cfg: *const config_mod.Config) SecurityPolicy {
        const duped = allocator.dupe(u8, cfg.workspace_dir) catch cfg.workspace_dir;
        const owns = duped.ptr != cfg.workspace_dir.ptr;

        // Parse cfg.allowed_paths (comma-separated) into a slice of owned strings.
        var paths = std.ArrayList([]const u8).init(allocator);
        if (cfg.allowed_paths.len > 0) {
            var it = std.mem.splitScalar(u8, cfg.allowed_paths, ',');
            while (it.next()) |entry| {
                const trimmed = std.mem.trim(u8, entry, " \t");
                if (trimmed.len == 0) continue;
                const p = allocator.dupe(u8, trimmed) catch continue;
                paths.append(p) catch {
                    allocator.free(p);
                };
            }
        }
        const extra = paths.toOwnedSlice() catch &[_][]const u8{};

        return SecurityPolicy{
            .allocator          = allocator,
            .workspace_dir      = duped,
            .owns_workspace_dir = owns,
            .extra_paths        = extra,
        };
    }

    pub fn deinit(self: *SecurityPolicy, allocator: std.mem.Allocator) void {
        if (self.owns_workspace_dir) {
            allocator.free(self.workspace_dir);
        }
        for (self.extra_paths) |p| allocator.free(p);
        allocator.free(self.extra_paths);
    }

    /// Return true if the path is safe to access.
    /// Absolute paths must be inside the workspace or one of the extra_paths.
    /// Relative paths are always permitted (they resolve under the workspace cwd).
    pub fn allowPath(self: *const SecurityPolicy, path: []const u8) bool {
        // Reject obvious directory traversal.
        if (std.mem.indexOf(u8, path, "..") != null) return false;

        // Permanently forbidden prefixes — these are never overridable via config.
        const forbidden = [_][]const u8{
            "/etc/", "/etc",
            "/root/", "/root",
            "/usr/", "/proc/",
            "/sys/", "/dev/",
        };
        for (forbidden) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return false;
        }

        // Reject sensitive hidden dirs regardless of position in path.
        const sensitive = [_][]const u8{ "/.ssh", "/.gnupg", "/.aws", "/.bareclaw/secrets" };
        for (sensitive) |suf| {
            if (std.mem.indexOf(u8, path, suf) != null) return false;
        }

        if (std.fs.path.isAbsolute(path)) {
            // Always allow the workspace itself.
            if (std.mem.startsWith(u8, path, self.workspace_dir)) return true;
            // Also allow any explicitly configured extra paths.
            for (self.extra_paths) |allowed| {
                if (std.mem.startsWith(u8, path, allowed)) return true;
            }
            return false;
        }

        // Relative paths are permitted (resolve under cwd = workspace).
        return true;
    }

    pub fn allowShellCommand(self: *SecurityPolicy, cmd: []const u8) bool {
        _ = self;
        // Blocklist of destructive or dangerous patterns. This checks the
        // trimmed command start and common bypass forms. Not a sandbox —
        // a full sandbox requires OS-level isolation. These checks catch
        // accidental or naive misuse.
        const trimmed = std.mem.trim(u8, cmd, " \t");

        // Blocked command prefixes and their common absolute-path variants.
        const blocked = [_][]const u8{
            "rm ",      "rm\t",
            "/bin/rm",  "/usr/bin/rm",
            "unlink ",  "unlink\t",
            "rmdir ",   "rmdir\t",
            "shred ",   "shred\t",
            "dd ",      // overwrite/wipe
            "> /",      // redirect-truncate to absolute path
            "mkfs",     // format filesystem
            "fdisk",
            "parted",
            ":(){",     // fork bomb
        };

        for (blocked) |pattern| {
            if (std.mem.startsWith(u8, trimmed, pattern)) return false;
            // Also catch mid-command piped or chained forms.
            if (std.mem.indexOf(u8, trimmed, pattern) != null and
                std.mem.indexOf(u8, trimmed, "echo") == null) return false;
        }

        return true;
    }

    /// Append an entry to the audit log at <workspace>/audit.log.
    /// Format per line:  unix_timestamp TAB tool TAB detail NEWLINE
    /// Errors are silently ignored so they never interrupt the calling tool.
    pub fn auditLog(self: *const SecurityPolicy, tool: []const u8, detail: []const u8) !void {
        var path_buf = std.ArrayList(u8).init(self.allocator);
        defer path_buf.deinit();
        try path_buf.appendSlice(self.workspace_dir);
        try path_buf.append(std.fs.path.sep);
        try path_buf.appendSlice("audit.log");

        std.fs.cwd().makePath(self.workspace_dir) catch {};

        var file = try std.fs.cwd().createFile(path_buf.items, .{
            .truncate = false,
            .read    = false,
        });
        defer file.close();
        try file.seekFromEnd(0);

        const ts = std.time.timestamp();
        const w = file.writer();
        try w.print("{d}\t{s}\t{s}\n", .{ ts, tool, detail });
    }
};

// T1-4: SecretStore removed.
// It wrote API keys as plaintext files with no file-permission enforcement
// and no encryption. It was never wired to any command path, but was dangerous
// to activate in that state. If a secrets backend is needed in the future,
// enforce 0o600 permissions at minimum and warn the user about plaintext storage,
// or integrate with OS keychain APIs.

