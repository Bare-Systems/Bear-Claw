const std = @import("std");

const config_mod = @import("config.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const memory_mod = @import("memory.zig");
const tools_mod = @import("tools.zig");
const security_mod = @import("security.zig");
const gateway_mod = @import("gateway.zig");
const daemon_mod = @import("daemon.zig");
const cron_mod = @import("cron.zig");
const channels_mod = @import("channels.zig");
const peripherals_mod = @import("peripherals.zig");
const migration_mod = @import("migration.zig");
const mcp_mod = @import("mcp_client.zig");
const tardigrade_cmd_mod = @import("tardigrade_cmd.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout = std.io.getStdOut().writer();

    if (args.len <= 1) {
        try stdout.print("BearClaw – zero-compromise AI claws, bear edition.\n", .{});
        try stdout.print("Usage: {s} [--api-key <key>] <command> [options]\n", .{args[0]});
        try stdout.print("Commands: onboard | agent | status | doctor | config | mcp | gateway | daemon | tardigrade | cron | channel | peripheral | migrate\n", .{});
        return;
    }

    var cfg = try config_mod.loadOrInit(allocator);
    defer cfg.deinit(allocator);

    // Parse global flags before the command: --api-key, --debug
    var cmd_idx: usize = 1;
    var debug_mode = false;
    while (cmd_idx < args.len) {
        if (std.mem.eql(u8, args[cmd_idx], "--api-key") and cmd_idx + 1 < args.len) {
            allocator.free(cfg.api_key);
            cfg.api_key = try allocator.dupe(u8, args[cmd_idx + 1]);
            cmd_idx += 2;
        } else if (std.mem.eql(u8, args[cmd_idx], "--debug")) {
            debug_mode = true;
            cmd_idx += 1;
        } else {
            break;
        }
    }
    if (cmd_idx >= args.len) {
        try stdout.print("BearClaw – no command given.\n", .{});
        return;
    }
    const cmd = args[cmd_idx];

    if (std.mem.eql(u8, cmd, "status")) {
        try printStatus(allocator, &cfg, stdout);
        return;
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        try runDoctor(allocator, &cfg, stdout);
        return;
    } else if (std.mem.eql(u8, cmd, "onboard")) {
        try config_mod.quickOnboard(&cfg, allocator, stdout);
        cfg.save() catch {};
        return;
    } else if (std.mem.eql(u8, cmd, "agent")) {
        // Build provider: use router if fallback_providers is set, else single.
        var single_provider: provider_mod.Provider = undefined;
        var router: provider_mod.Router = undefined;
        var use_router = false;

        const any_provider: provider_mod.AnyProvider = blk: {
            if (cfg.fallback_providers.len > 0) {
                // Split "anthropic,openai,ollama" into a slice of names.
                var names = std.ArrayList([]const u8).init(allocator);
                defer names.deinit();
                // Always prepend the default provider.
                try names.append(cfg.default_provider);
                var it = std.mem.splitScalar(u8, cfg.fallback_providers, ',');
                while (it.next()) |n| {
                    const trimmed = std.mem.trim(u8, n, " \t");
                    if (trimmed.len > 0) try names.append(trimmed);
                }
                router = try provider_mod.createRouterWithKey(allocator, names.items, cfg.api_key);
                use_router = true;
                break :blk provider_mod.AnyProvider.fromRouter(&router);
            } else {
                single_provider = try provider_mod.createDefaultProvider(allocator, &cfg);
                break :blk provider_mod.AnyProvider.fromProvider(&single_provider);
            }
        };
        defer if (use_router) router.deinit() else single_provider.deinit();

        var mem_backend = try memory_mod.createMemoryBackend(allocator, &cfg);
        defer mem_backend.deinit();

        var policy = security_mod.SecurityPolicy.initWorkspaceOnly(allocator, &cfg);
        defer policy.deinit(allocator);

        // Build core tools.
        var all_tools = std.ArrayList(tools_mod.Tool).init(allocator);
        defer all_tools.deinit();

        const core_tools = try tools_mod.buildCoreTools(allocator, &policy, &mem_backend);
        defer tools_mod.freeTools(allocator, core_tools);
        try all_tools.appendSlice(core_tools);

        // Build MCP tools (if any servers are configured).
        var mcp_pool: mcp_mod.McpSessionPool = undefined;
        var mcp_tools: []tools_mod.Tool = &[_]tools_mod.Tool{};
        var has_mcp = false;

        const server_defs = try config_mod.parseMcpServers(&cfg, allocator);
        defer {
            for (@constCast(server_defs)) |*s| s.deinit(allocator);
            allocator.free(server_defs);
        }

        if (server_defs.len > 0) {
            // T1-5: Collect MCP startup errors and surface them to the user
            // before starting the agent loop — don't silently drop failed servers.
            var mcp_errors: []tools_mod.McpStartupError = &[_]tools_mod.McpStartupError{};
            mcp_tools = try tools_mod.buildMcpTools(allocator, server_defs, &mcp_pool, &mcp_errors);
            defer {
                for (mcp_errors) |*e| @constCast(e).deinit(allocator);
                allocator.free(mcp_errors);
            }
            for (mcp_errors) |e| {
                try stdout.print("⚠ MCP server '{s}' failed to start: {s}\n", .{ e.server_name, e.message });
            }
            has_mcp = true;
            try all_tools.appendSlice(mcp_tools);
        }
        defer if (has_mcp) {
            tools_mod.freeMcpTools(allocator, mcp_tools);
            mcp_pool.deinit();
        };

        const input = if (args.len > cmd_idx + 1)
            args[cmd_idx + 1]
        else
            "Hello from BearClaw. How can you help me today?";

        var stdout_writer = std.io.getStdOut().writer();
        try agent_mod.runAgentSingleTurnWithTranscript(
            allocator,
            &cfg,
            any_provider,
            &mem_backend,
            all_tools.items,
            &policy,
            if (has_mcp) &mcp_pool else null,
            input,
            &stdout_writer,
        );
        return;
    } else if (std.mem.eql(u8, cmd, "gateway")) {
        const port: u16 = 8080;
        try gateway_mod.runGateway(port);
        return;
    } else if (std.mem.eql(u8, cmd, "daemon")) {
        const port: u16 = 8080;
        try daemon_mod.runDaemon(allocator, port);
        return;
    } else if (std.mem.eql(u8, cmd, "tardigrade")) {
        const tardi_args = if (args.len > cmd_idx + 1) args[cmd_idx + 1 ..] else &[_][]const u8{};
        try tardigrade_cmd_mod.run(allocator, args[0], tardi_args);
        return;
    } else if (std.mem.eql(u8, cmd, "cron")) {
        // Pass remaining args after "cron" as subcommand + params.
        const cron_args = if (args.len > 2) args[2..] else &[_][]const u8{};
        try cron_mod.dispatchCron(allocator, cron_args);
        return;
    } else if (std.mem.eql(u8, cmd, "channel")) {
        // Subcommands: cli (default), discord, telegram, loop
        const sub = if (args.len > cmd_idx + 1) args[cmd_idx + 1] else "cli";
        if (std.mem.eql(u8, sub, "discord")) {
            try channels_mod.runDiscordChannel(&cfg, debug_mode);
        } else if (std.mem.eql(u8, sub, "telegram")) {
            try channels_mod.runTelegramChannel(&cfg);
        } else if (std.mem.eql(u8, sub, "loop")) {
            try channels_mod.runCliChannelLoop(&cfg);
        } else {
            try channels_mod.runCliChannelOnce(&cfg);
        }
        return;
    } else if (std.mem.eql(u8, cmd, "peripheral")) {
        try peripherals_mod.listConfiguredPeripherals(allocator);
        return;
    } else if (std.mem.eql(u8, cmd, "config")) {
        const sub = if (args.len > cmd_idx + 1) args[cmd_idx + 1] else "";
        if (std.mem.eql(u8, sub, "set")) {
            if (args.len < cmd_idx + 4) {
                try stdout.print("Usage: bareclaw config set <key> <value>\n", .{});
                try stdout.print("Keys:  default_provider, default_model, memory_backend,\n", .{});
                try stdout.print("       fallback_providers, api_key, discord_token, discord_webhook,\n", .{});
                try stdout.print("       discord_notify_channel, telegram_token, mcp_servers,\n", .{});
                try stdout.print("       system_prompt, allowed_paths\n", .{});
                return;
            }
            const key = args[cmd_idx + 2];
            const value = args[cmd_idx + 3];
            if (try cfg.setKey(allocator, key, value)) |err_msg| {
                defer allocator.free(err_msg);
                try stdout.print("Error: {s}\n", .{err_msg});
            } else {
                try stdout.print("✓ {s} = \"{s}\"\n", .{ key, value });
                try stdout.print("  Saved to {s}\n", .{cfg.config_path});
            }
        } else if (std.mem.eql(u8, sub, "get")) {
            const key = if (args.len > cmd_idx + 2) args[cmd_idx + 2] else "";
            if (key.len == 0) {
                // Print all
                try stdout.print("default_provider   = \"{s}\"\n", .{cfg.default_provider});
                try stdout.print("default_model      = \"{s}\"\n", .{cfg.default_model});
                try stdout.print("memory_backend     = \"{s}\"\n", .{cfg.memory_backend});
                try stdout.print("fallback_providers = \"{s}\"\n", .{cfg.fallback_providers});
                try stdout.print("api_key            = \"{s}\"\n", .{if (cfg.api_key.len > 0) "***" else ""});
                try stdout.print("discord_token      = \"{s}\"\n", .{if (cfg.discord_token.len > 0) "***" else ""});
                try stdout.print("discord_webhook    = \"{s}\"\n", .{if (cfg.discord_webhook.len > 0) "***" else ""});
                try stdout.print("discord_notify_channel = \"{s}\"\n", .{cfg.discord_notify_channel});
                try stdout.print("telegram_token     = \"{s}\"\n", .{if (cfg.telegram_token.len > 0) "***" else ""});
                try stdout.print("mcp_servers        = \"{s}\"\n", .{cfg.mcp_servers});
                try stdout.print("system_prompt      = \"{s}\"\n", .{if (cfg.system_prompt.len > 0) "(custom)" else ""});
                try stdout.print("allowed_paths      = \"{s}\"\n", .{cfg.allowed_paths});
            } else {
                try stdout.print("Usage: bareclaw config get  (no key = show all)\n", .{});
            }
        } else {
            try stdout.print("Usage: bareclaw config <set|get> [key] [value]\n", .{});
            try stdout.print("  bareclaw config set discord_token \"Bot.xxx...\"\n", .{});
            try stdout.print("  bareclaw config set api_key \"sk-...\"\n", .{});
            try stdout.print("  bareclaw config get\n", .{});
        }
        return;
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        // Subcommands: list-servers, list-tools [server], call <server> <tool> [args_json]
        const sub = if (args.len > cmd_idx + 1) args[cmd_idx + 1] else "list-servers";

        if (std.mem.eql(u8, sub, "list-servers")) {
            const server_defs = try config_mod.parseMcpServers(&cfg, allocator);
            defer {
                for (@constCast(server_defs)) |*s| s.deinit(allocator);
                allocator.free(server_defs);
            }
            if (server_defs.len == 0) {
                try stdout.print("No MCP servers configured.\n", .{});
                try stdout.print("Add one with: bareclaw config set mcp_servers \"name=command args\"\n", .{});
            } else {
                try stdout.print("{d} MCP server(s):\n", .{server_defs.len});
                for (server_defs) |def| {
                    const cmd_str = try std.mem.join(allocator, " ", def.argv);
                    defer allocator.free(cmd_str);
                    try stdout.print("  {s} → {s}\n", .{ def.name, cmd_str });
                }
            }
        } else if (std.mem.eql(u8, sub, "list-tools")) {
            // Filter by server name if provided.
            const filter = if (args.len > cmd_idx + 2) args[cmd_idx + 2] else "";
            const server_defs = try config_mod.parseMcpServers(&cfg, allocator);
            defer {
                for (@constCast(server_defs)) |*s| s.deinit(allocator);
                allocator.free(server_defs);
            }
            if (server_defs.len == 0) {
                try stdout.print("No MCP servers configured.\n", .{});
            }
            for (server_defs) |def| {
                if (filter.len > 0 and !std.mem.eql(u8, filter, def.name)) continue;
                try stdout.print("Server: {s}\n", .{def.name});
                var session = mcp_mod.McpSession.start(allocator, def.argv) catch |err| {
                    try stdout.print("  (error starting server: {})\n", .{err});
                    continue;
                };
                const discovered = session.listTools() catch &[_]mcp_mod.McpTool{};
                session.deinit();
                if (discovered.len == 0) {
                    try stdout.print("  (no tools found)\n", .{});
                }
                for (discovered) |t| {
                    try stdout.print("  {s}__{s}\n    {s}\n", .{ def.name, t.name, t.description });
                }
                for (@constCast(discovered)) |*t| t.deinit(allocator);
                allocator.free(discovered);
            }
        } else if (std.mem.eql(u8, sub, "call")) {
            // Usage: bareclaw mcp call <server> <tool> [args_json]
            if (args.len < cmd_idx + 4) {
                try stdout.print("Usage: bareclaw mcp call <server> <tool> [args_json]\n", .{});
                return;
            }
            const server_name = args[cmd_idx + 2];
            const tool_name = args[cmd_idx + 3];
            const call_args = if (args.len > cmd_idx + 4) args[cmd_idx + 4] else "{}";

            const server_defs = try config_mod.parseMcpServers(&cfg, allocator);
            defer {
                for (@constCast(server_defs)) |*s| s.deinit(allocator);
                allocator.free(server_defs);
            }

            var found_def: ?config_mod.McpServerDef = null;
            for (server_defs) |def| {
                if (std.mem.eql(u8, def.name, server_name)) {
                    found_def = def;
                    break;
                }
            }
            if (found_def == null) {
                try stdout.print("Server '{s}' not found. Run: bareclaw mcp list-servers\n", .{server_name});
                return;
            }

            var session = try mcp_mod.McpSession.start(allocator, found_def.?.argv);
            defer session.deinit();

            const result = try session.callTool(tool_name, call_args);
            defer allocator.free(result);
            try stdout.print("{s}\n", .{result});
        } else {
            try stdout.print("Usage: bareclaw mcp <list-servers|list-tools|call>\n", .{});
            try stdout.print("  bareclaw mcp list-servers\n", .{});
            try stdout.print("  bareclaw mcp list-tools [server]\n", .{});
            try stdout.print("  bareclaw mcp call <server> <tool> [args_json]\n", .{});
        }
        return;
    } else if (std.mem.eql(u8, cmd, "migrate")) {
        const source_path = if (args.len > cmd_idx + 1) args[cmd_idx + 1] else "~/.openclaw/workspace";
        try migration_mod.migrateFromOpenClaw(allocator, source_path);
        return;
    } else {
        try stdout.print("Unknown command: {s}\n", .{cmd});
        return;
    }
}

fn printStatus(allocator: std.mem.Allocator, cfg: *const config_mod.Config, stdout: anytype) !void {
    try stdout.print("🐻 BearClaw Status\n\n", .{});
    try stdout.print("Workspace:  {s}\n", .{cfg.workspace_dir});
    try stdout.print("Config:     {s}\n", .{cfg.config_path});
    try stdout.print("Provider:   {s}\n", .{cfg.default_provider});
    try stdout.print("Model:      {s}\n", .{cfg.default_model});
    try stdout.print("Memory:     {s}\n", .{cfg.memory_backend});

    // API key configured? Ollama is keyless by design; all other providers need one.
    const is_keyless = std.mem.eql(u8, cfg.default_provider, "ollama");
    const has_key = is_keyless or blk: {
        const k = std.process.getEnvVarOwned(allocator, "BARECLAW_API_KEY") catch
            std.process.getEnvVarOwned(allocator, "API_KEY") catch
            try allocator.dupe(u8, "");
        defer allocator.free(k);
        break :blk k.len > 0 or cfg.api_key.len > 0;
    };
    const key_status = if (is_keyless) "local (no key needed)" else if (has_key) "configured ✓" else "NOT SET (echo mode)";
    try stdout.print("API key:    {s}\n", .{key_status});

    // Count memory files.
    const mem_dir = try std.fs.path.join(allocator, &.{ cfg.workspace_dir, "memory" });
    defer allocator.free(mem_dir);
    var mem_count: usize = 0;
    if (std.fs.cwd().openDir(mem_dir, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind == .file) mem_count += 1;
        }
    } else |_| {}
    try stdout.print("Memory:     {d} file(s)\n", .{mem_count});

    // Count cron tasks.
    const cron_tasks = cron_mod.loadTasksPublic(allocator) catch &[_]cron_mod.CronTask{};
    defer {
        for (cron_tasks) |*t| @constCast(t).deinit(allocator);
        allocator.free(cron_tasks);
    }
    const enabled_count = blk: {
        var n: usize = 0;
        for (cron_tasks) |t| {
            if (t.enabled) n += 1;
        }
        break :blk n;
    };
    try stdout.print("Cron tasks: {d} total, {d} enabled\n", .{ cron_tasks.len, enabled_count });

    const server_defs = try config_mod.parseMcpServers(cfg, allocator);
    defer {
        for (@constCast(server_defs)) |*s| s.deinit(allocator);
        allocator.free(server_defs);
    }
    try stdout.print("MCP:        {d} server(s) configured\n", .{server_defs.len});

    if (peripherals_mod.loadPeripheralSection(allocator, cfg.config_path)) |section_loaded| {
        var section = section_loaded;
        defer section.deinit(allocator);
        const peripheral_status = if (!section.enabled)
            "disabled"
        else if (section.boards.len == 0)
            "enabled, 0 board(s)"
        else
            try std.fmt.allocPrint(allocator, "enabled, {d} board(s)", .{section.boards.len});
        defer if (!std.mem.eql(u8, peripheral_status, "disabled") and !std.mem.eql(u8, peripheral_status, "enabled, 0 board(s)")) allocator.free(peripheral_status);
        try stdout.print("Peripherals:{s:>18}\n", .{peripheral_status});
    } else |_| {
        try stdout.print("Peripherals:{s:>18}\n", .{"config unavailable"});
    }

    const prompt_status = if (cfg.system_prompt.len > 0) "custom" else "built-in";
    try stdout.print("Prompt:     {s}\n", .{prompt_status});
    if (cfg.allowed_paths.len > 0) {
        try stdout.print("Allowed:    {s}\n", .{cfg.allowed_paths});
    }
}

/// Doctor command: check health of key subsystems and report issues.
fn runDoctor(allocator: std.mem.Allocator, cfg: *const config_mod.Config, stdout: anytype) !void {
    try stdout.print("🐻 BearClaw Doctor\n\n", .{});

    var all_ok = true;

    // 1. Workspace directory exists and is writable.
    {
        const test_path = try std.fs.path.join(allocator, &.{ cfg.workspace_dir, ".doctor_probe" });
        defer allocator.free(test_path);
        std.fs.cwd().makePath(cfg.workspace_dir) catch {};
        const probe = std.fs.cwd().createFile(test_path, .{ .truncate = true });
        if (probe) |f| {
            f.close();
            std.fs.cwd().deleteFile(test_path) catch {};
            try stdout.print("  ✓ Workspace writable: {s}\n", .{cfg.workspace_dir});
        } else |err| {
            try stdout.print("  ✗ Workspace NOT writable ({s}): {}\n", .{ cfg.workspace_dir, err });
            all_ok = false;
        }
    }

    // 2. Config file present.
    {
        const exists = if (std.fs.cwd().openFile(cfg.config_path, .{})) |f| blk: {
            f.close();
            break :blk true;
        } else |_| false;
        if (exists) {
            try stdout.print("  ✓ Config file: {s}\n", .{cfg.config_path});
        } else {
            try stdout.print("  ⚠ Config file missing (defaults in use): {s}\n", .{cfg.config_path});
        }
    }

    // 3. API key.
    {
        const k = std.process.getEnvVarOwned(allocator, "BARECLAW_API_KEY") catch
            std.process.getEnvVarOwned(allocator, "API_KEY") catch
            try allocator.dupe(u8, "");
        defer allocator.free(k);
        if (k.len > 0) {
            try stdout.print("  ✓ API key configured\n", .{});
        } else {
            try stdout.print("  ⚠ No API key found – running in echo mode\n", .{});
        }
    }

    // 4. Audit log writable.
    {
        const log_path = try std.fs.path.join(allocator, &.{ cfg.workspace_dir, "audit.log" });
        defer allocator.free(log_path);
        const f = std.fs.cwd().createFile(log_path, .{ .truncate = false, .read = false });
        if (f) |file| {
            file.close();
            try stdout.print("  ✓ Audit log writable\n", .{});
        } else |err| {
            try stdout.print("  ✗ Audit log NOT writable: {}\n", .{err});
            all_ok = false;
        }
    }

    // 5. Cron tasks.
    {
        const tasks = cron_mod.loadTasksPublic(allocator) catch &[_]cron_mod.CronTask{};
        defer {
            for (tasks) |*t| @constCast(t).deinit(allocator);
            allocator.free(tasks);
        }
        try stdout.print("  ✓ Cron: {d} task(s) configured\n", .{tasks.len});
    }

    // 6. Peripherals config.
    {
        if (peripherals_mod.loadPeripheralSection(allocator, cfg.config_path)) |section_loaded| {
            var section = section_loaded;
            defer section.deinit(allocator);

            const issues = try peripherals_mod.validatePeripheralSection(allocator, &section);
            defer {
                for (issues) |*issue| @constCast(issue).deinit(allocator);
                allocator.free(issues);
            }

            if (!section.enabled) {
                try stdout.print("  ✓ Peripherals: disabled\n", .{});
            } else if (section.boards.len == 0) {
                try stdout.print("  ⚠ Peripherals: enabled but no boards configured\n", .{});
            } else if (issues.len == 0) {
                try stdout.print("  ✓ Peripherals: {d} board(s) configured\n", .{section.boards.len});
            } else {
                try stdout.print("  ⚠ Peripherals: {d} issue(s) found across {d} board(s)\n", .{ issues.len, section.boards.len });
                for (issues) |issue| {
                    try stdout.print("      - board #{d}: {s}\n", .{ issue.index + 1, issue.message });
                }
            }
        } else |err| switch (err) {
            error.FileNotFound => {
                try stdout.print("  ⚠ Peripherals: config file missing, skipping peripheral checks\n", .{});
            },
            else => {
                try stdout.print("  ✗ Peripherals config unreadable: {}\n", .{err});
                all_ok = false;
            },
        }
    }

    // 7. Default OpenClaw migration source.
    {
        if (migration_mod.defaultSourceWorkspaceExists(allocator)) {
            try stdout.print("  ✓ OpenClaw migration source available: {s}\n", .{migration_mod.DEFAULT_OPENCLAW_WORKSPACE});
        } else {
            try stdout.print("  ⚠ OpenClaw migration source not found: {s}\n", .{migration_mod.DEFAULT_OPENCLAW_WORKSPACE});
        }
    }

    // 8. MCP servers.
    {
        const server_defs = try config_mod.parseMcpServers(cfg, allocator);
        defer {
            for (@constCast(server_defs)) |*s| s.deinit(allocator);
            allocator.free(server_defs);
        }

        if (server_defs.len == 0) {
            try stdout.print("  ✓ MCP: no servers configured\n", .{});
        } else {
            var ok_count: usize = 0;
            for (server_defs) |def| {
                var session = mcp_mod.McpSession.startProbe(allocator, def.argv) catch |err| {
                    try stdout.print("  ⚠ MCP '{s}' probe failed: {}\n", .{ def.name, err });
                    continue;
                };
                defer session.deinit();

                const tools = session.listTools() catch |err| {
                    try stdout.print("  ⚠ MCP '{s}' tools/list failed: {}\n", .{ def.name, err });
                    continue;
                };
                defer {
                    for (tools) |*tool| @constCast(tool).deinit(allocator);
                    allocator.free(tools);
                }

                ok_count += 1;
                try stdout.print("  ✓ MCP '{s}': {d} tool(s) discovered\n", .{ def.name, tools.len });
            }
            if (ok_count == 0) all_ok = false;
        }
    }

    try stdout.print("\n", .{});
    if (all_ok) {
        try stdout.print("All checks passed.\n", .{});
    } else {
        try stdout.print("Some checks FAILED – see above.\n", .{});
    }
}
