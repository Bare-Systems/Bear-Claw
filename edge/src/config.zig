const std = @import("std");

pub const Config = struct {
    workspace_dir: []const u8,
    config_path:   []const u8,

    default_provider:   []const u8,
    default_model:      []const u8,
    memory_backend:     []const u8,
    /// Comma-separated fallback provider names, e.g. "anthropic,openai,ollama"
    fallback_providers: []const u8,

    /// API key for the default provider. Env vars (BARECLAW_API_KEY, ANTHROPIC_API_KEY,
    /// etc.) take precedence at runtime; this is the config-file fallback.
    api_key: []const u8,

    /// Discord bot token (optional)
    discord_token: []const u8,
    /// Discord webhook URL for integration testing (optional)
    discord_webhook: []const u8,
    /// Discord channel ID to send proactive notifications to (e.g. cron reports).
    /// Set to the DM channel ID or any channel ID the bot has access to.
    /// Set via: bareclaw config set discord_notify_channel "1473668167397019823"
    discord_notify_channel: []const u8,
    /// Telegram bot token (optional)
    telegram_token: []const u8,

    /// Pipe-separated list of MCP server definitions.
    /// Each entry: "name=command arg1 arg2..."
    /// Example: "autotrader=trader mcp serve|mybot=python bot.py"
    mcp_servers: []const u8,

    /// Optional custom system prompt override.
    /// Empty string (default) means: use the built-in factual system prompt.
    /// Set via `bareclaw config set system_prompt "..."` or in config.toml.
    system_prompt: []const u8,

    /// Comma-separated list of additional absolute paths Bear may read/write
    /// beyond the workspace. The workspace is always allowed.
    /// Example: "/Users/joe/Downloads,/Users/joe/Documents"
    /// Set via `bareclaw config set allowed_paths "/path1,/path2"`
    /// Bear will tell users this value when asked about its access.
    allowed_paths: []const u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_dir);
        allocator.free(self.config_path);
        allocator.free(self.default_provider);
        allocator.free(self.default_model);
        allocator.free(self.memory_backend);
        allocator.free(self.fallback_providers);
        allocator.free(self.api_key);
        allocator.free(self.discord_token);
        allocator.free(self.discord_webhook);
        allocator.free(self.discord_notify_channel);
        allocator.free(self.telegram_token);
        allocator.free(self.mcp_servers);
        allocator.free(self.system_prompt);
        allocator.free(self.allowed_paths);
        self.* = undefined;
    }

    pub fn save(self: *const Config) !void {
        var file = try std.fs.cwd().createFile(self.config_path, .{ .truncate = true });
        defer file.close();
        const w = file.writer();
        try w.print(
            "default_provider   = \"{s}\"\n" ++
            "default_model      = \"{s}\"\n" ++
            "memory_backend     = \"{s}\"\n" ++
            "fallback_providers = \"{s}\"\n" ++
            "api_key            = \"{s}\"\n" ++
            "\n" ++
            "# Channel tokens\n" ++
            "discord_token          = \"{s}\"\n" ++
            "discord_webhook        = \"{s}\"\n" ++
            "# Channel ID for proactive notifications (cron reports, alerts)\n" ++
            "# Set to your DM channel ID with Bear, or any channel Bear has access to.\n" ++
            "discord_notify_channel = \"{s}\"\n" ++
            "telegram_token         = \"{s}\"\n" ++
            "\n" ++
            "# MCP servers (pipe-separated: name=command arg1 arg2...)\n" ++
            "mcp_servers = \"{s}\"\n" ++
            "\n" ++
            "# Custom system prompt (leave empty to use built-in default)\n" ++
            "system_prompt = \"{s}\"\n" ++
            "\n" ++
            "# Extra paths Bear can read/write beyond the workspace (comma-separated)\n" ++
            "# Example: allowed_paths = \"/Users/joe/Downloads,/Users/joe/Documents\"\n" ++
            "allowed_paths = \"{s}\"\n",
            .{
                self.default_provider, self.default_model,
                self.memory_backend,   self.fallback_providers,
                self.api_key,
                self.discord_token,    self.discord_webhook,  self.discord_notify_channel,  self.telegram_token,
                self.mcp_servers,
                self.system_prompt,
                self.allowed_paths,
            },
        );
    }

    /// Update a single config key in memory and persist to disk.
    /// Returns an error string (caller frees) on unknown key, null on success.
    pub fn setKey(self: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !?[]u8 {
        const known_keys = [_][]const u8{
            "default_provider", "default_model", "memory_backend",
            "fallback_providers", "api_key", "discord_token", "discord_webhook",
            "discord_notify_channel", "telegram_token",
            "mcp_servers", "system_prompt", "allowed_paths",
        };
        var found = false;
        for (known_keys) |k| {
            if (std.mem.eql(u8, key, k)) { found = true; break; }
        }
        if (!found) {
            return try std.fmt.allocPrint(
                allocator,
                "Unknown config key: \"{s}\"\nValid keys: default_provider, default_model, memory_backend, fallback_providers, api_key, discord_token, discord_webhook, discord_notify_channel, telegram_token, mcp_servers, system_prompt, allowed_paths",
                .{key},
            );
        }

        const duped = try allocator.dupe(u8, value);

        if (std.mem.eql(u8, key, "default_provider")) {
            allocator.free(self.default_provider);
            self.default_provider = duped;
        } else if (std.mem.eql(u8, key, "default_model")) {
            allocator.free(self.default_model);
            self.default_model = duped;
        } else if (std.mem.eql(u8, key, "memory_backend")) {
            allocator.free(self.memory_backend);
            self.memory_backend = duped;
        } else if (std.mem.eql(u8, key, "fallback_providers")) {
            allocator.free(self.fallback_providers);
            self.fallback_providers = duped;
        } else if (std.mem.eql(u8, key, "api_key")) {
            allocator.free(self.api_key);
            self.api_key = duped;
        } else if (std.mem.eql(u8, key, "discord_token")) {
            allocator.free(self.discord_token);
            self.discord_token = duped;
        } else if (std.mem.eql(u8, key, "discord_webhook")) {
            allocator.free(self.discord_webhook);
            self.discord_webhook = duped;
        } else if (std.mem.eql(u8, key, "discord_notify_channel")) {
            allocator.free(self.discord_notify_channel);
            self.discord_notify_channel = duped;
        } else if (std.mem.eql(u8, key, "telegram_token")) {
            allocator.free(self.telegram_token);
            self.telegram_token = duped;
        } else if (std.mem.eql(u8, key, "mcp_servers")) {
            allocator.free(self.mcp_servers);
            self.mcp_servers = duped;
        } else if (std.mem.eql(u8, key, "system_prompt")) {
            allocator.free(self.system_prompt);
            self.system_prompt = duped;
        } else if (std.mem.eql(u8, key, "allowed_paths")) {
            allocator.free(self.allowed_paths);
            self.allowed_paths = duped;
        } else {
            allocator.free(duped);
        }

        try self.save();
        return null; // success
    }
};

pub fn loadOrInit(allocator: std.mem.Allocator) !Config {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const c_allocator = std.heap.c_allocator;
    const workspace_dir_buf = try std.fs.path.join(c_allocator, &.{ home, ".bareclaw", "workspace" });
    defer c_allocator.free(workspace_dir_buf);
    const config_path_buf = try std.fs.path.join(c_allocator, &.{ home, ".bareclaw", "config.toml" });
    defer c_allocator.free(config_path_buf);

    // Ensure workspace directory exists.
    {
        var cwd = std.fs.cwd();
        _ = cwd.makePath(workspace_dir_buf) catch {};
    }

    var cfg = Config{
        .workspace_dir      = try allocator.dupe(u8, workspace_dir_buf),
        .config_path        = try allocator.dupe(u8, config_path_buf),
        .default_provider   = try allocator.dupe(u8, "openai-compatible"),
        .default_model      = try allocator.dupe(u8, "gpt-4.1-mini"),
        .memory_backend     = try allocator.dupe(u8, "markdown"),
        .fallback_providers = try allocator.dupe(u8, ""),
        .api_key            = try allocator.dupe(u8, ""),
        .discord_token          = try allocator.dupe(u8, ""),
        .discord_webhook        = try allocator.dupe(u8, ""),
        .discord_notify_channel = try allocator.dupe(u8, ""),
        .telegram_token         = try allocator.dupe(u8, ""),
        .mcp_servers        = try allocator.dupe(u8, ""),
        .system_prompt      = try allocator.dupe(u8, ""),
        .allowed_paths      = try allocator.dupe(u8, ""),
    };

    // Best-effort: parse existing config.toml for a few keys.
    var file = std.fs.cwd().openFile(config_path_buf, .{}) catch |err| switch (err) {
        error.FileNotFound => return cfg,
        else => return cfg,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 16 * 1024);
    defer allocator.free(contents);

    parseSimpleToml(&cfg, contents, allocator) catch {};
    return cfg;
}

fn parseSimpleToml(cfg: *Config, contents: []u8, allocator: std.mem.Allocator) !void {
    var it = std.mem.tokenizeScalar(u8, contents, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "default_provider")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.default_provider);
                cfg.default_provider = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "default_model")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.default_model);
                cfg.default_model = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "memory_backend")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.memory_backend);
                cfg.memory_backend = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "fallback_providers")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.fallback_providers);
                cfg.fallback_providers = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "api_key")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.api_key);
                cfg.api_key = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "discord_notify_channel")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.discord_notify_channel);
                cfg.discord_notify_channel = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "discord_webhook")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.discord_webhook);
                cfg.discord_webhook = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "discord_token")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.discord_token);
                cfg.discord_token = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "telegram_token")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.telegram_token);
                cfg.telegram_token = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "mcp_servers")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.mcp_servers);
                cfg.mcp_servers = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "system_prompt")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.system_prompt);
                cfg.system_prompt = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "allowed_paths")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.allowed_paths);
                cfg.allowed_paths = try allocator.dupe(u8, val);
            }
        }
    }
}

fn parseValue(line: []const u8) ?[]const u8 {
    const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    var rest = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
    if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') {
        rest = rest[1 .. rest.len - 1];
    }
    return rest;
}

pub fn quickOnboard(cfg: *Config, allocator: std.mem.Allocator, writer: anytype) !void {
    _ = allocator;
    try writer.print("BearClaw quick onboarding...\n", .{});
    try writer.print("Using workspace at {s}\n", .{cfg.workspace_dir});
    try writer.print("Default provider: {s}\n", .{cfg.default_provider});
    try writer.print("Default model:    {s}\n", .{cfg.default_model});
    try writer.print("Memory backend:   {s}\n", .{cfg.memory_backend});
    if (cfg.allowed_paths.len > 0) {
        try writer.print("Allowed paths:    {s}\n", .{cfg.allowed_paths});
    }
}

/// A parsed MCP server definition.
pub const McpServerDef = struct {
    name: []const u8,   // owned
    argv: [][]const u8, // owned slice of owned strings

    pub fn deinit(self: *McpServerDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        self.* = undefined;
    }
};

/// Parse cfg.mcp_servers into a slice of McpServerDef.
/// Format: "name=command arg1 arg2|name2=cmd2 ..."
/// Caller owns the returned slice and each McpServerDef.
pub fn parseMcpServers(cfg: *const Config, allocator: std.mem.Allocator) ![]McpServerDef {
    if (cfg.mcp_servers.len == 0) return &[_]McpServerDef{};

    var list = std.ArrayList(McpServerDef).init(allocator);
    errdefer {
        for (list.items) |*s| s.deinit(allocator);
        list.deinit();
    }

    var it = std.mem.splitScalar(u8, cfg.mcp_servers, '|');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0) continue;

        // Split on first '=' to get name and command string.
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const name    = std.mem.trim(u8, trimmed[0..eq],      " \t");
        const cmd_str = std.mem.trim(u8, trimmed[eq + 1 ..],  " \t");
        if (name.len == 0 or cmd_str.len == 0) continue;

        // Split command string on spaces to build argv.
        var args_list = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (args_list.items) |a| allocator.free(a);
            args_list.deinit();
        }
        var word_it = std.mem.splitScalar(u8, cmd_str, ' ');
        while (word_it.next()) |word| {
            const w = std.mem.trim(u8, word, " \t");
            if (w.len > 0) try args_list.append(try allocator.dupe(u8, w));
        }
        if (args_list.items.len == 0) {
            for (args_list.items) |a| allocator.free(a);
            args_list.deinit();
            continue;
        }

        try list.append(McpServerDef{
            .name = try allocator.dupe(u8, name),
            .argv = try args_list.toOwnedSlice(),
        });
    }

    return list.toOwnedSlice();
}
