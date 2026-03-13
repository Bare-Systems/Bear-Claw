/// BearClaw -> Tardigrade integration entrypoint (`bareclaw tardigrade`).
///
/// Important architecture note:
/// - This is a process orchestration integration, not a direct Zig library link.
/// - BearClaw does NOT call Tardigrade functions in-process.
/// - BearClaw currently spawns two processes and wires them together:
///   1) `bareclaw gateway` on localhost (agent endpoint)
///   2) `tardigrade` as the public HTTPS edge in front of BearClaw
///
/// Request flow:
/// iPhone (HTTPS) -> tardigrade -> bareclaw gateway (/v1/chat)
const std = @import("std");

pub fn run(allocator: std.mem.Allocator, self_bin: []const u8, args: []const []const u8) !void {
    var public_host: []const u8 = "0.0.0.0";
    var public_port: u16 = 8069;
    var upstream: []const u8 = "http://127.0.0.1:8080";
    var endpoint_host: []const u8 = "";
    var tls_cert: []const u8 = "";
    var tls_key: []const u8 = "";
    var tardigrade_bin: []const u8 = "tardigrade";
    var print_deploy_env = false;
    var print_deploy_json = false;
    var write_deploy_env_path: []const u8 = "";

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
        } else if (std.mem.eql(u8, arg, "--upstream")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            upstream = args[i];
        } else if (std.mem.eql(u8, arg, "--endpoint-host")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            endpoint_host = args[i];
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
        } else if (std.mem.eql(u8, arg, "--print-deploy-env")) {
            print_deploy_env = true;
        } else if (std.mem.eql(u8, arg, "--print-deploy-json")) {
            print_deploy_json = true;
        } else if (std.mem.eql(u8, arg, "--write-deploy-env")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            write_deploy_env_path = args[i];
        } else {
            return error.UnknownArgument;
        }
    }

    if ((tls_cert.len == 0) != (tls_key.len == 0)) return error.TlsCertKeyMustBePaired;

    const token = try generateSecretToken(allocator);
    defer allocator.free(token);
    const token_hash = try sha256Hex(allocator, token);
    defer allocator.free(token_hash);

    var cert_owned: ?[]u8 = null;
    var key_owned: ?[]u8 = null;
    const cert_host = if (endpoint_host.len > 0)
        endpoint_host
    else if (std.mem.eql(u8, public_host, "0.0.0.0"))
        "127.0.0.1"
    else
        public_host;
    if (tls_cert.len == 0) {
        const generated = try ensureSelfSignedCert(allocator, cert_host);
        cert_owned = generated.cert_path;
        key_owned = generated.key_path;
        tls_cert = generated.cert_path;
        tls_key = generated.key_path;
    }
    defer if (cert_owned) |p| allocator.free(p);
    defer if (key_owned) |p| allocator.free(p);

    const public_ip = detectPublicIp(allocator) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(public_ip);
    const resolved_endpoint_host = if (endpoint_host.len > 0)
        endpoint_host
    else if (std.mem.eql(u8, public_host, "0.0.0.0"))
        public_ip
    else
        public_host;
    const endpoint = try std.fmt.allocPrint(allocator, "https://{s}:{d}", .{ resolved_endpoint_host, public_port });
    defer allocator.free(endpoint);
    const cert_sha256 = try certFingerprintSha256(allocator, tls_cert);
    defer allocator.free(cert_sha256);
    const pairing_json = try buildPairingPayloadJson(allocator, endpoint, token, cert_sha256);
    defer allocator.free(pairing_json);
    const pairing_code = try buildPairingCode(allocator, pairing_json);
    defer allocator.free(pairing_code);
    const deploy_env = try buildDeployEnvFile(allocator, public_host, public_port, upstream, token_hash, tls_cert, tls_key);
    defer allocator.free(deploy_env);
    const smoke_cmd = try buildSmokeCurlCommand(allocator, endpoint, token, tls_cert);
    defer allocator.free(smoke_cmd);
    const deploy_json = try buildDeployJson(
        allocator,
        endpoint,
        token,
        cert_sha256,
        tls_cert,
        tls_key,
        deploy_env,
        if (write_deploy_env_path.len > 0) write_deploy_env_path else null,
    );
    defer allocator.free(deploy_json);

    if (write_deploy_env_path.len > 0) {
        var file = try std.fs.cwd().createFile(write_deploy_env_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(deploy_env);
    }

    if (print_deploy_json) {
        try std.io.getStdOut().writer().print("{s}\n", .{deploy_json});
        return;
    }

    if (print_deploy_env or write_deploy_env_path.len > 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Deployment mode: generated direct Tardigrade env/config.\n", .{});
        try stdout.print("Public endpoint: {s}\n", .{endpoint});
        try stdout.print("Bearer token: {s}\n", .{token});
        try stdout.print("TLS cert SHA256: {s}\n", .{cert_sha256});
        try stdout.print("Pairing payload JSON:\n{s}\n", .{pairing_json});
        try stdout.print("Pairing code:\n{s}\n", .{pairing_code});
        try stdout.print("Tardigrade env file contents:\n{s}\n", .{deploy_env});
        if (write_deploy_env_path.len > 0) {
            try stdout.print("Wrote env file: {s}\n", .{write_deploy_env_path});
        }
        try stdout.print("Auth smoke command:\n{s}\n", .{smoke_cmd});
        return;
    }

    var gateway_child = try spawnGateway(allocator, self_bin);
    defer {
        _ = gateway_child.kill() catch null;
        _ = gateway_child.wait() catch {};
    }
    try waitForBearClawReady(allocator, upstream);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const public_port_str = try std.fmt.allocPrint(allocator, "{d}", .{public_port});
    defer allocator.free(public_port_str);

    try env_map.put("TARDIGRADE_LISTEN_HOST", public_host);
    try env_map.put("TARDIGRADE_LISTEN_PORT", public_port_str);
    try env_map.put("TARDIGRADE_UPSTREAM_BASE_URL", upstream);
    try env_map.put("TARDIGRADE_AUTH_TOKEN_HASHES", token_hash);
    try env_map.put("TARDIGRADE_TLS_CERT_PATH", tls_cert);
    try env_map.put("TARDIGRADE_TLS_KEY_PATH", tls_key);

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
    // Tardigrade is now expected to terminate TLS itself. We avoid a strict
    // health probe here because self-signed certs and external host bindings
    // make local HTTPS verification unreliable without Tardigrade's exact CA
    // and hostname contract available in-process.
    std.time.sleep(500 * std.time.ns_per_ms);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("BearClaw + Tardigrade are up (Tardigrade HTTPS edge).\n", .{});
    try stdout.print("Public endpoint: {s}\n", .{endpoint});
    try stdout.print("Bearer token (copy into iPhone): {s}\n", .{token});
    try stdout.print("TLS cert SHA256: {s}\n", .{cert_sha256});
    try stdout.print("Pairing payload JSON:\n{s}\n", .{pairing_json});
    try stdout.print("Pairing code:\n{s}\n", .{pairing_code});
    if (cert_owned != null) {
        try stdout.print("TLS cert: self-signed ({s})\n", .{tls_cert});
        try stdout.print("Note: iPhone app can trust via pinned cert fingerprint from pairing payload.\n", .{});
    }
    try stdout.print("Auth smoke command:\n{s}\n", .{smoke_cmd});

    _ = try tardi_child.wait();
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

fn ensureSelfSignedCert(allocator: std.mem.Allocator, host: []const u8) !GeneratedCert {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const tls_dir = try std.fs.path.join(allocator, &.{ home, ".bareclaw", "tls" });
    defer allocator.free(tls_dir);
    try std.fs.cwd().makePath(tls_dir);

    const safe_host = try sanitizeFilenameComponent(allocator, if (host.len > 0) host else "tardi.local");
    defer allocator.free(safe_host);
    const cert_name = try std.fmt.allocPrint(allocator, "tardi-selfsigned-{s}.crt", .{safe_host});
    defer allocator.free(cert_name);
    const key_name = try std.fmt.allocPrint(allocator, "tardi-selfsigned-{s}.key", .{safe_host});
    defer allocator.free(key_name);
    const cert_path = try std.fs.path.join(allocator, &.{ tls_dir, cert_name });
    const key_path = try std.fs.path.join(allocator, &.{ tls_dir, key_name });

    if (pathExists(cert_path) and pathExists(key_path)) {
        return .{ .cert_path = cert_path, .key_path = key_path };
    }

    const subject_host = if (host.len > 0) host else "tardi.local";
    const san_ext = try buildSubjectAltName(allocator, subject_host);
    defer allocator.free(san_ext);
    const subject = try std.fmt.allocPrint(allocator, "/CN={s}", .{subject_host});
    defer allocator.free(subject);

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
        subject,
        "-addext",
        san_ext,
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

fn sanitizeFilenameComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') {
            try out.append(c);
        } else {
            try out.append('_');
        }
    }
    if (out.items.len == 0) try out.appendSlice("default");
    return out.toOwnedSlice();
}

fn buildSubjectAltName(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    if (std.net.Address.parseIp(host, 0)) |_| {
        return std.fmt.allocPrint(
            allocator,
            "subjectAltName=IP:{s},DNS:localhost,IP:127.0.0.1,DNS:tardi.local",
            .{host},
        );
    } else |_| {}

    return std.fmt.allocPrint(
        allocator,
        "subjectAltName=DNS:{s},DNS:localhost,IP:127.0.0.1,DNS:tardi.local",
        .{host},
    );
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn detectPublicIp(allocator: std.mem.Allocator) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();

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

fn buildDeployEnvFile(
    allocator: std.mem.Allocator,
    listen_host: []const u8,
    listen_port: u16,
    upstream: []const u8,
    token_hash: []const u8,
    tls_cert: []const u8,
    tls_key: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "TARDIGRADE_LISTEN_HOST={s}\n" ++
            "TARDIGRADE_LISTEN_PORT={d}\n" ++
            "TARDIGRADE_UPSTREAM_BASE_URL={s}\n" ++
            "TARDIGRADE_AUTH_TOKEN_HASHES={s}\n" ++
            "TARDIGRADE_TLS_CERT_PATH={s}\n" ++
            "TARDIGRADE_TLS_KEY_PATH={s}\n",
        .{ listen_host, listen_port, upstream, token_hash, tls_cert, tls_key },
    );
}

fn buildSmokeCurlCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    token: []const u8,
    tls_cert: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "curl --cacert {s} -H \"Authorization: Bearer {s}\" -H \"Content-Type: application/json\" {s}/v1/chat -d '{{\"message\":\"ping from smoke test\"}}'",
        .{ tls_cert, token, endpoint },
    );
}

fn buildDeployJson(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    token: []const u8,
    cert_sha256: []const u8,
    tls_cert: []const u8,
    tls_key: []const u8,
    deploy_env: []const u8,
    deploy_env_path: ?[]const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.writer().print(
        "{{\"endpoint\":{},\"bearer_token\":{},\"cert_sha256\":{},\"tls_cert_path\":{},\"tls_key_path\":{},\"deploy_env\":{},\"deploy_env_path\":",
        .{
            std.json.fmt(endpoint, .{}),
            std.json.fmt(token, .{}),
            std.json.fmt(cert_sha256, .{}),
            std.json.fmt(tls_cert, .{}),
            std.json.fmt(tls_key, .{}),
            std.json.fmt(deploy_env, .{}),
        },
    );
    if (deploy_env_path) |path| {
        try out.writer().print("{}", .{std.json.fmt(path, .{})});
    } else {
        try out.writer().writeAll("null");
    }
    try out.writer().writeAll("}");
    return out.toOwnedSlice();
}

test "sha256Hex returns 64 hex chars" {
    const allocator = std.testing.allocator;
    const digest = try sha256Hex(allocator, "abc");
    defer allocator.free(digest);
    try std.testing.expectEqual(@as(usize, 64), digest.len);
}

test "buildPairingPayloadJson includes endpoint and cert hash" {
    const allocator = std.testing.allocator;
    const payload = try buildPairingPayloadJson(allocator, "https://1.2.3.4:8069", "tok", "abcd");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"endpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"cert_sha256\"") != null);
}

test "buildDeployEnvFile includes auth hash and tls paths" {
    const allocator = std.testing.allocator;
    const env_file = try buildDeployEnvFile(allocator, "127.0.0.1", 18069, "http://127.0.0.1:8080", "hash", "/tmp/cert.pem", "/tmp/key.pem");
    defer allocator.free(env_file);
    try std.testing.expect(std.mem.indexOf(u8, env_file, "TARDIGRADE_AUTH_TOKEN_HASHES=hash") != null);
    try std.testing.expect(std.mem.indexOf(u8, env_file, "TARDIGRADE_TLS_CERT_PATH=/tmp/cert.pem") != null);
}

test "buildSmokeCurlCommand uses bearer auth header" {
    const allocator = std.testing.allocator;
    const cmd = try buildSmokeCurlCommand(allocator, "https://1.2.3.4:8069", "tok", "/tmp/cert.pem");
    defer allocator.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "Authorization: Bearer tok") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "--cacert /tmp/cert.pem") != null);
}

test "buildDeployJson includes deploy metadata" {
    const allocator = std.testing.allocator;
    const payload = try buildDeployJson(
        allocator,
        "https://127.0.0.1:8443",
        "tok",
        "hash",
        "/tmp/cert.pem",
        "/tmp/key.pem",
        "TARDIGRADE_LISTEN_PORT=8443\n",
        "/tmp/tardigrade.env",
    );
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"endpoint\":\"https://127.0.0.1:8443\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tls_cert_path\":\"/tmp/cert.pem\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"deploy_env_path\":\"/tmp/tardigrade.env\"") != null);
}

test "buildPairingPayloadJson reflects endpoint host override" {
    const allocator = std.testing.allocator;
    const payload = try buildPairingPayloadJson(allocator, "https://127.0.0.1:8443", "tok", "abcd");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "127.0.0.1:8443") != null);
}

test "buildSubjectAltName includes ip host and localhost defaults" {
    const allocator = std.testing.allocator;
    const san = try buildSubjectAltName(allocator, "127.0.0.1");
    defer allocator.free(san);
    try std.testing.expect(std.mem.indexOf(u8, san, "IP:127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, san, "DNS:localhost") != null);
}
