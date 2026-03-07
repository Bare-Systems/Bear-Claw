/// BearClaw -> Tardigrade integration entrypoint (`bareclaw tardigrade`).
///
/// Important architecture note:
/// - This is a process orchestration integration, not a direct Zig library link.
/// - BearClaw does NOT call Tardigrade functions in-process.
/// - BearClaw spawns three processes and wires them together:
///   1) `bareclaw gateway` on localhost (agent endpoint)
///   2) `tardigrade` as internal edge runtime (HTTP on internal port)
///   3) `caddy` as public TLS reverse proxy in front of Tardigrade
///
/// Request flow:
/// iPhone (HTTPS) -> caddy -> tardigrade -> bareclaw gateway (/v1/chat)
const std = @import("std");

pub fn run(allocator: std.mem.Allocator, self_bin: []const u8, args: []const []const u8) !void {
    var public_host: []const u8 = "0.0.0.0";
    var public_port: u16 = 8069;
    const internal_host: []const u8 = "127.0.0.1";
    var internal_port: u16 = 18069;
    var upstream: []const u8 = "http://127.0.0.1:8080";
    var tls_cert: []const u8 = "";
    var tls_key: []const u8 = "";
    var tardigrade_bin: []const u8 = "tardigrade";
    var caddy_bin: []const u8 = "caddy";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            public_host = args[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            public_port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--internal-port")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            internal_port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--upstream")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            upstream = args[i];
        } else if (std.mem.eql(u8, arg, "--tls-cert")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            tls_cert = args[i];
        } else if (std.mem.eql(u8, arg, "--tls-key")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            tls_key = args[i];
        } else if (std.mem.eql(u8, arg, "--tardigrade-bin")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            tardigrade_bin = args[i];
        } else if (std.mem.eql(u8, arg, "--caddy-bin")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            caddy_bin = args[i];
        } else {
            return error.UnknownArgument;
        }
    }

    if ((tls_cert.len == 0) != (tls_key.len == 0)) return error.TlsCertKeyMustBePaired;

    const token = try generateSecretToken(allocator);
    defer allocator.free(token);
    const token_hash = try sha256Hex(allocator, token);
    defer allocator.free(token_hash);

    var gateway_child = try spawnGateway(allocator, self_bin);
    defer {
        _ = gateway_child.kill() catch null;
        _ = gateway_child.wait() catch {};
    }
    try waitForBearClawReady(allocator, upstream);

    var cert_owned: ?[]u8 = null;
    var key_owned: ?[]u8 = null;
    if (tls_cert.len == 0) {
        const generated = try ensureSelfSignedCert(allocator);
        cert_owned = generated.cert_path;
        key_owned = generated.key_path;
        tls_cert = generated.cert_path;
        tls_key = generated.key_path;
    }
    defer if (cert_owned) |p| allocator.free(p);
    defer if (key_owned) |p| allocator.free(p);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const internal_port_str = try std.fmt.allocPrint(allocator, "{d}", .{internal_port});
    defer allocator.free(internal_port_str);

    try env_map.put("TARDIGRADE_LISTEN_HOST", internal_host);
    try env_map.put("TARDIGRADE_LISTEN_PORT", internal_port_str);
    try env_map.put("TARDIGRADE_UPSTREAM_BASE_URL", upstream);
    try env_map.put("TARDIGRADE_AUTH_TOKEN_HASHES", token_hash);

    const tardi_argv = [_][]const u8{tardigrade_bin};
    var tardi_child = std.process.Child.init(&tardi_argv, allocator);
    tardi_child.stdin_behavior = .Ignore;
    tardi_child.stdout_behavior = .Inherit;
    tardi_child.stderr_behavior = .Inherit;
    tardi_child.env_map = &env_map;
    try tardi_child.spawn();
    defer {
        _ = tardi_child.kill() catch null;
        _ = tardi_child.wait() catch {};
    }

    try waitForTardigradeReady(allocator, internal_host, internal_port);

    var caddy_child = try spawnCaddyTlsProxy(allocator, caddy_bin, public_host, public_port, internal_host, internal_port, tls_cert, tls_key);
    defer {
        _ = caddy_child.kill() catch null;
        _ = caddy_child.wait() catch {};
    }

    const public_ip = detectPublicIp(allocator) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(public_ip);
    const endpoint = try std.fmt.allocPrint(allocator, "https://{s}:{d}", .{ public_ip, public_port });
    defer allocator.free(endpoint);
    const cert_sha256 = try certFingerprintSha256(allocator, tls_cert);
    defer allocator.free(cert_sha256);
    const pairing_json = try buildPairingPayloadJson(allocator, endpoint, token, cert_sha256);
    defer allocator.free(pairing_json);
    const pairing_code = try buildPairingCode(allocator, pairing_json);
    defer allocator.free(pairing_code);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("BearClaw + Tardigrade are up (HTTPS default).\n", .{});
    try stdout.print("Public endpoint: {s}\n", .{endpoint});
    try stdout.print("Bearer token (copy into iPhone): {s}\n", .{token});
    try stdout.print("TLS cert SHA256: {s}\n", .{cert_sha256});
    try stdout.print("Pairing payload JSON:\n{s}\n", .{pairing_json});
    try stdout.print("Pairing code:\n{s}\n", .{pairing_code});
    if (cert_owned != null) {
        try stdout.print("TLS cert: self-signed ({s})\n", .{tls_cert});
        try stdout.print("Note: iPhone app can trust via pinned cert fingerprint from pairing payload.\n", .{});
    }

    _ = try caddy_child.wait();
}

fn generateSecretToken(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [24]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&bytes)});
}

fn sha256Hex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

fn spawnGateway(allocator: std.mem.Allocator, self_bin: []const u8) !std.process.Child {
    const argv = [_][]const u8{ self_bin, "gateway" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn waitForBearClawReady(allocator: std.mem.Allocator, upstream: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/health", .{upstream});
    defer allocator.free(url);

    var retries: usize = 0;
    while (retries < 30) : (retries += 1) {
        if (probeHealth(allocator, url)) return;
        std.time.sleep(200 * std.time.ns_per_ms);
    }
    return error.BearClawNotReady;
}

fn waitForTardigradeReady(allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/health", .{ host, port });
    defer allocator.free(url);

    var retries: usize = 0;
    while (retries < 30) : (retries += 1) {
        if (probeHealth(allocator, url)) return;
        std.time.sleep(200 * std.time.ns_per_ms);
    }
    return error.TardigradeNotReady;
}

fn probeHealth(allocator: std.mem.Allocator, url: []const u8) bool {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_storage = .{ .dynamic = &body },
    }) catch return false;
    return result.status == .ok;
}

const GeneratedCert = struct {
    cert_path: []u8,
    key_path: []u8,
};

fn ensureSelfSignedCert(allocator: std.mem.Allocator) !GeneratedCert {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const tls_dir = try std.fs.path.join(allocator, &.{ home, ".bareclaw", "tls" });
    defer allocator.free(tls_dir);
    try std.fs.cwd().makePath(tls_dir);

    const cert_path = try std.fs.path.join(allocator, &.{ tls_dir, "tardi-selfsigned.crt" });
    const key_path = try std.fs.path.join(allocator, &.{ tls_dir, "tardi-selfsigned.key" });

    if (pathExists(cert_path) and pathExists(key_path)) {
        return .{ .cert_path = cert_path, .key_path = key_path };
    }

    const argv = [_][]const u8{
        "openssl",
        "req",
        "-x509",
        "-nodes",
        "-newkey",
        "rsa:2048",
        "-keyout",
        key_path,
        "-out",
        cert_path,
        "-days",
        "3650",
        "-subj",
        "/CN=tardi.local",
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 32 * 1024,
    }) catch return error.OpensslRequired;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.OpensslFailed;
    }

    return .{ .cert_path = cert_path, .key_path = key_path };
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn spawnCaddyTlsProxy(
    allocator: std.mem.Allocator,
    caddy_bin: []const u8,
    public_host: []const u8,
    public_port: u16,
    internal_host: []const u8,
    internal_port: u16,
    cert_path: []const u8,
    key_path: []const u8,
) !std.process.Child {
    const caddyfile = try buildCaddyfile(allocator, public_host, public_port, internal_host, internal_port, cert_path, key_path);
    defer allocator.free(caddyfile);

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const caddyfile_path = try std.fs.path.join(allocator, &.{ home, ".bareclaw", "tls", "Caddyfile" });
    defer allocator.free(caddyfile_path);

    var file = try std.fs.cwd().createFile(caddyfile_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(caddyfile);

    const argv = [_][]const u8{ caddy_bin, "run", "--config", caddyfile_path };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn buildCaddyfile(
    allocator: std.mem.Allocator,
    public_host: []const u8,
    public_port: u16,
    internal_host: []const u8,
    internal_port: u16,
    cert_path: []const u8,
    key_path: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}:{d} {{\n" ++
            "  tls {s} {s}\n" ++
            "  reverse_proxy {s}:{d}\n" ++
            "}}\n",
        .{ public_host, public_port, cert_path, key_path, internal_host, internal_port },
    );
}

fn detectPublicIp(allocator: std.mem.Allocator) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://api.ipify.org" },
        .method = .GET,
        .response_storage = .{ .dynamic = &body },
    });
    if (result.status != .ok) return error.PublicIpLookupFailed;

    const text = std.mem.trim(u8, body.items, " \t\r\n");
    return allocator.dupe(u8, text);
}

fn certFingerprintSha256(allocator: std.mem.Allocator, cert_path: []const u8) ![]u8 {
    const argv = [_][]const u8{
        "openssl",
        "x509",
        "-in",
        cert_path,
        "-noout",
        "-fingerprint",
        "-sha256",
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 16 * 1024,
    }) catch return error.OpensslRequired;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.OpensslFingerprintFailed;
    }

    const line = std.mem.trim(u8, result.stdout, " \t\r\n");
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidFingerprintOutput;
    const raw = line[eq + 1 ..];

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (raw) |c| {
        if (c == ':') continue;
        if (!std.ascii.isHex(c)) return error.InvalidFingerprintOutput;
        try out.append(std.ascii.toLower(c));
    }

    if (out.items.len != 64) return error.InvalidFingerprintOutput;
    return out.toOwnedSlice();
}

fn buildPairingPayloadJson(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    token: []const u8,
    cert_sha256: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"endpoint\":{s},\"bearer_token\":{s},\"cert_sha256\":{s}}}",
        .{
            std.json.fmt(endpoint, .{}),
            std.json.fmt(token, .{}),
            std.json.fmt(cert_sha256, .{}),
        },
    );
}

fn buildPairingCode(allocator: std.mem.Allocator, pairing_json: []const u8) ![]u8 {
    const b64 = std.base64.url_safe_no_pad.Encoder;
    const out_len = b64.calcSize(pairing_json.len);
    const out = try allocator.alloc(u8, out_len);
    defer allocator.free(out);
    _ = b64.encode(out, pairing_json);
    return std.fmt.allocPrint(allocator, "tardi1:{s}", .{out});
}

test "sha256Hex returns 64 hex chars" {
    const allocator = std.testing.allocator;
    const digest = try sha256Hex(allocator, "abc");
    defer allocator.free(digest);
    try std.testing.expectEqual(@as(usize, 64), digest.len);
}

test "buildCaddyfile includes tls and reverse proxy" {
    const allocator = std.testing.allocator;
    const cfg = try buildCaddyfile(allocator, "0.0.0.0", 8069, "127.0.0.1", 18069, "/tmp/cert.pem", "/tmp/key.pem");
    defer allocator.free(cfg);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "tls /tmp/cert.pem /tmp/key.pem") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "reverse_proxy 127.0.0.1:18069") != null);
}

test "buildPairingPayloadJson includes endpoint and cert hash" {
    const allocator = std.testing.allocator;
    const payload = try buildPairingPayloadJson(allocator, "https://1.2.3.4:8069", "tok", "abcd");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"endpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"cert_sha256\"") != null);
}
