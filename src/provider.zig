/// Provider abstraction for BearClaw.
///
/// Supported backends (selected via config.default_provider):
///   "anthropic"        – Claude API  (POST /v1/messages, x-api-key auth)
///   "openai"           – OpenAI API  (POST /v1/chat/completions, Bearer auth)
///   "openai-compatible"– Any OpenAI-clone (BARECLAW_API_URL override)
///   "ollama"           – Local Ollama (http://localhost:11434)
///   "openrouter"       – OpenRouter meta-router (Bearer auth, OR-specific headers)
///   "echo"             – No network, echoes input (testing/no-key fallback)
///
/// Routing + fallback: createRouter() returns a Router that tries providers in
/// order and returns the first successful response.

const std = @import("std");
const config_mod = @import("config.zig");

// ── Provider kind ─────────────────────────────────────────────────────────────

pub const ProviderKind = enum {
    anthropic,
    openai,
    openai_compatible,
    ollama,
    openrouter,
    echo,
};

// ── Single provider ───────────────────────────────────────────────────────────

pub const Provider = struct {
    allocator: std.mem.Allocator,
    kind:      ProviderKind,
    api_key:   []const u8,   // owned
    base_url:  []const u8,   // owned

    pub fn deinit(self: *Provider) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
    }

    /// Send a single chat turn and return the assistant's text reply.
    /// Returned slice is allocated and owned by the caller.
    pub fn chatOnce(
        self: *Provider,
        system: []const u8,
        user:   []const u8,
        model:  []const u8,
        temperature: f32,
    ) ![]u8 {
        // Ollama is keyless by design — skip the key guard for it.
        const needs_key = self.kind != .echo and self.kind != .ollama;
        if (self.kind == .echo or (needs_key and self.api_key.len == 0)) {
            return echoResponse(self.allocator, user);
        }

        return switch (self.kind) {
            .anthropic        => chatAnthropic(self, system, user, model, temperature),
            .openai,
            .openai_compatible,
            .openrouter       => chatOpenAI(self, system, user, model, temperature),
            .ollama           => chatOllama(self, system, user, model, temperature),
            .echo             => echoResponse(self.allocator, user),
        };
    }
};

// ── Router (fallback chain) ───────────────────────────────────────────────────

pub const Router = struct {
    allocator: std.mem.Allocator,
    providers: []Provider,   // owned slice, in priority order

    pub fn deinit(self: *Router) void {
        for (self.providers) |*p| p.deinit();
        self.allocator.free(self.providers);
    }

    /// Try each provider in order; return first successful response.
    pub fn chatOnce(
        self: *Router,
        system: []const u8,
        user:   []const u8,
        model:  []const u8,
        temperature: f32,
    ) ![]u8 {
        var last_err: anyerror = error.NoProviders;
        for (self.providers) |*p| {
            const reply = p.chatOnce(system, user, model, temperature) catch |err| {
                last_err = err;
                continue;
            };
            return reply;
        }
        return last_err;
    }
};

// ── AnyProvider vtable ────────────────────────────────────────────────────────
//
// A type-erased wrapper so agent.zig can call chatOnce() without caring
// whether the underlying backend is a single Provider or a Router.
//
// Usage:
//   var p = try createDefaultProvider(allocator, &cfg);
//   var any = AnyProvider.fromProvider(&p);
//   const reply = try any.chatOnce(system, user, model, temp);

const ChatOnceFn = *const fn (
    ptr:         *anyopaque,
    system:      []const u8,
    user:        []const u8,
    model:       []const u8,
    temperature: f32,
    allocator:   std.mem.Allocator,
) anyerror![]u8;

pub const AnyProvider = struct {
    ptr:      *anyopaque,
    chatFn:   ChatOnceFn,
    allocator: std.mem.Allocator,

    pub fn chatOnce(
        self: AnyProvider,
        system: []const u8,
        user:   []const u8,
        model:  []const u8,
        temperature: f32,
    ) ![]u8 {
        return self.chatFn(self.ptr, system, user, model, temperature, self.allocator);
    }

    pub fn fromProvider(p: *Provider) AnyProvider {
        return .{
            .ptr       = p,
            .chatFn    = providerChatFn,
            .allocator = p.allocator,
        };
    }

    pub fn fromRouter(r: *Router) AnyProvider {
        return .{
            .ptr       = r,
            .chatFn    = routerChatFn,
            .allocator = r.allocator,
        };
    }
};

fn providerChatFn(
    ptr: *anyopaque,
    system: []const u8,
    user:   []const u8,
    model:  []const u8,
    temperature: f32,
    _alloc: std.mem.Allocator,
) ![]u8 {
    _ = _alloc;
    const p: *Provider = @ptrCast(@alignCast(ptr));
    return p.chatOnce(system, user, model, temperature);
}

fn routerChatFn(
    ptr: *anyopaque,
    system: []const u8,
    user:   []const u8,
    model:  []const u8,
    temperature: f32,
    _alloc: std.mem.Allocator,
) ![]u8 {
    _ = _alloc;
    const r: *Router = @ptrCast(@alignCast(ptr));
    return r.chatOnce(system, user, model, temperature);
}

// ── Factory functions ─────────────────────────────────────────────────────────

/// Create a single provider from the config's default_provider field.
/// Priority: provider-specific env var → BARECLAW_API_KEY env var → cfg.api_key → empty (echo).
pub fn createDefaultProvider(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !Provider {
    return createProviderByNameWithKey(allocator, cfg.default_provider, cfg.api_key);
}

/// Create a provider by name string, with no config-key fallback.
pub fn createProviderByName(allocator: std.mem.Allocator, name: []const u8) !Provider {
    return createProviderByNameWithKey(allocator, name, "");
}

/// Create a provider by name string.
/// Key resolution order: provider env var → BARECLAW_API_KEY env var → config_key → empty.
pub fn createProviderByNameWithKey(allocator: std.mem.Allocator, name: []const u8, config_key: []const u8) !Provider {
    if (std.mem.eql(u8, name, "anthropic")) {
        const key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch
                    std.process.getEnvVarOwned(allocator, "BARECLAW_API_KEY") catch
                    (if (config_key.len > 0) try allocator.dupe(u8, config_key)
                     else try allocator.dupe(u8, ""));
        return Provider{
            .allocator = allocator,
            .kind      = .anthropic,
            .api_key   = key,
            .base_url  = try allocator.dupe(u8, "https://api.anthropic.com/v1/messages"),
        };
    }

    if (std.mem.eql(u8, name, "openai")) {
        const key = std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch
                    std.process.getEnvVarOwned(allocator, "BARECLAW_API_KEY") catch
                    (if (config_key.len > 0) try allocator.dupe(u8, config_key)
                     else try allocator.dupe(u8, ""));
        return Provider{
            .allocator = allocator,
            .kind      = .openai,
            .api_key   = key,
            .base_url  = try allocator.dupe(u8, "https://api.openai.com/v1/chat/completions"),
        };
    }

    if (std.mem.eql(u8, name, "ollama")) {
        const url = std.process.getEnvVarOwned(allocator, "OLLAMA_URL") catch
                    try allocator.dupe(u8, "http://localhost:11434/api/chat");
        return Provider{
            .allocator = allocator,
            .kind      = .ollama,
            .api_key   = try allocator.dupe(u8, ""),  // no key required
            .base_url  = url,
        };
    }

    if (std.mem.eql(u8, name, "openrouter")) {
        const key = std.process.getEnvVarOwned(allocator, "OPENROUTER_API_KEY") catch
                    std.process.getEnvVarOwned(allocator, "BARECLAW_API_KEY") catch
                    (if (config_key.len > 0) try allocator.dupe(u8, config_key)
                     else try allocator.dupe(u8, ""));
        return Provider{
            .allocator = allocator,
            .kind      = .openrouter,
            .api_key   = key,
            .base_url  = try allocator.dupe(u8, "https://openrouter.ai/api/v1/chat/completions"),
        };
    }

    // Default: openai-compatible (reads BARECLAW_API_URL for custom endpoint)
    const key = std.process.getEnvVarOwned(allocator, "BARECLAW_API_KEY") catch
                std.process.getEnvVarOwned(allocator, "API_KEY") catch
                (if (config_key.len > 0) try allocator.dupe(u8, config_key)
                 else try allocator.dupe(u8, ""));
    const url = std.process.getEnvVarOwned(allocator, "BARECLAW_API_URL") catch
                try allocator.dupe(u8, "https://api.openai.com/v1/chat/completions");
    return Provider{
        .allocator = allocator,
        .kind      = .openai_compatible,
        .api_key   = key,
        .base_url  = url,
    };
}

/// Build a Router that tries providers in order.
/// config_key is used as a fallback when no env var is set for a provider.
pub fn createRouter(allocator: std.mem.Allocator, names: []const []const u8) !Router {
    return createRouterWithKey(allocator, names, "");
}

pub fn createRouterWithKey(allocator: std.mem.Allocator, names: []const []const u8, config_key: []const u8) !Router {
    var list = try std.ArrayList(Provider).initCapacity(allocator, names.len);
    errdefer {
        for (list.items) |*p| p.deinit();
        list.deinit();
    }
    for (names) |name| {
        const p = try createProviderByNameWithKey(allocator, name, config_key);
        try list.append(p);
    }
    return Router{
        .allocator = allocator,
        .providers = try list.toOwnedSlice(),
    };
}

// ── Echo (no-network) ─────────────────────────────────────────────────────────

fn echoResponse(allocator: std.mem.Allocator, user: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "BearClaw echo (no API key configured): {s}",
        .{user},
    );
}

// ── OpenAI-compatible (also used for OpenRouter) ──────────────────────────────

fn chatOpenAI(
    self: *Provider,
    system: []const u8,
    user:   []const u8,
    model:  []const u8,
    temperature: f32,
) ![]u8 {
    const body = try buildOpenAIBody(self.allocator, model, temperature, system, user);
    defer self.allocator.free(body);

    // OpenRouter requires extra headers; add them if this is an OR provider.
    const extra_header: ?[]const u8 = if (self.kind == .openrouter)
        "HTTP-Referer: https://bareclaw.local\r\nX-Title: BearClaw\r\n"
    else
        null;

    const raw = try postBearer(self.allocator, self.base_url, self.api_key, body, extra_header);
    defer self.allocator.free(raw);

    return extractOpenAIContent(self.allocator, raw);
}

fn buildOpenAIBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    temperature: f32,
    system: []const u8,
    user: []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var jw = std.json.writeStream(buf.writer(), .{ .whitespace = .minified });
    try jw.beginObject();
    try jw.objectField("model");       try jw.write(model);
    try jw.objectField("temperature"); try jw.write(temperature);
    try jw.objectField("messages");
    try jw.beginArray();
    // System message
    try jw.beginObject();
    try jw.objectField("role");    try jw.write("system");
    try jw.objectField("content"); try jw.write(system);
    try jw.endObject();
    // User message
    try jw.beginObject();
    try jw.objectField("role");    try jw.write("user");
    try jw.objectField("content"); try jw.write(user);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();

    return buf.toOwnedSlice();
}

fn extractOpenAIContent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        return allocator.dupe(u8, raw);
    };
    defer parsed.deinit();

    const choices = parsed.value.object.get("choices") orelse return allocator.dupe(u8, raw);
    if (choices.array.items.len == 0) return allocator.dupe(u8, raw);
    const first   = choices.array.items[0];
    const message = first.object.get("message") orelse return allocator.dupe(u8, raw);
    const content = message.object.get("content") orelse return allocator.dupe(u8, raw);
    return switch (content) {
        .string => |s| allocator.dupe(u8, s),
        else    => allocator.dupe(u8, raw),
    };
}

// ── Anthropic (Claude) ────────────────────────────────────────────────────────
//
// Request format (https://docs.anthropic.com/en/api/messages):
//   POST /v1/messages
//   Headers: x-api-key, anthropic-version, content-type
//   Body:
//     { "model": "...", "max_tokens": N, "system": "...",
//       "messages": [{"role":"user","content":"..."}] }
//
// Response:
//   { "content": [{"type":"text","text":"..."}], ... }
//   or tool_use blocks: { "content": [{"type":"tool_use","name":"...","input":{...}}] }

fn chatAnthropic(
    self: *Provider,
    system: []const u8,
    user:   []const u8,
    model:  []const u8,
    temperature: f32,
) ![]u8 {
    const body = try buildAnthropicBody(self.allocator, model, temperature, system, user);
    defer self.allocator.free(body);

    const raw = try postAnthropic(self.allocator, self.base_url, self.api_key, body);
    defer self.allocator.free(raw);

    return extractAnthropicContent(self.allocator, raw);
}

fn buildAnthropicBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    temperature: f32,
    system: []const u8,
    user: []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var jw = std.json.writeStream(buf.writer(), .{ .whitespace = .minified });
    try jw.beginObject();
    try jw.objectField("model");       try jw.write(model);
    try jw.objectField("max_tokens");  try jw.write(@as(u32, 8096));
    try jw.objectField("temperature"); try jw.write(temperature);
    try jw.objectField("system");      try jw.write(system);
    try jw.objectField("messages");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("role");    try jw.write("user");
    try jw.objectField("content"); try jw.write(user);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();

    return buf.toOwnedSlice();
}

fn postAnthropic(
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    body: []const u8,
) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // Anthropic requires specific headers (NOT Bearer auth).
    // std.http.Client.fetch supports extra_headers via server_header_buffer
    // workaround: we inject them via the fetch options.
    // We build a combined header string but std.http only lets us override
    // content_type and authorization. For the x-api-key and anthropic-version
    // headers we use the server_header_buffer trick by pre-building the request
    // manually if needed. For simplicity we use authorization override to carry
    // x-api-key and patch the version header via a secondary header buffer.
    //
    // Practical approach: use the `extra_headers` field available in Zig 0.14.
    const version_header  = "2023-06-01";
    _ = version_header;

    var response_buf = std.ArrayList(u8).init(allocator);
    // Use defer (not errdefer) so it always fires on non-2xx paths.
    // On the success path we call toOwnedSlice() which transfers ownership.
    errdefer response_buf.deinit();

    const result = try client.fetch(.{
        .method   = .POST,
        .location = .{ .uri = uri },
        .headers  = .{
            .content_type  = .{ .override = "application/json" },
            // x-api-key is non-standard; pass via authorization field as a
            // workaround (server ignores Authorization, reads x-api-key).
            // We inject as a custom header using extra_headers below.
            .authorization = .{ .override = "" },
        },
        .extra_headers = &[_]std.http.Header{
            .{ .name = "x-api-key",         .value = api_key },
            .{ .name = "anthropic-version",  .value = "2023-06-01" },
        },
        .payload          = body,
        .response_storage = .{ .dynamic = &response_buf },
    });

    if (result.status != .ok) {
        defer response_buf.deinit();
        return std.fmt.allocPrint(
            allocator,
            "Anthropic HTTP {d}: {s}",
            .{ @intFromEnum(result.status), response_buf.items },
        );
    }

    return response_buf.toOwnedSlice();
}

/// Parse an Anthropic /v1/messages response.
/// Content is an array of blocks; text blocks have {"type":"text","text":"..."}.
/// Tool-use blocks have {"type":"tool_use","name":"...","input":{...}}.
/// We return text content directly, or serialize tool_use blocks into the
/// OpenAI tool_calls format so the agent loop stays format-agnostic.
fn extractAnthropicContent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        return allocator.dupe(u8, raw);
    };
    defer parsed.deinit();

    const content_arr = parsed.value.object.get("content") orelse return allocator.dupe(u8, raw);
    if (content_arr.array.items.len == 0) return allocator.dupe(u8, raw);

    var text_buf    = std.ArrayList(u8).init(allocator);
    errdefer text_buf.deinit();
    var tool_calls  = std.ArrayList(u8).init(allocator);
    errdefer tool_calls.deinit();
    var tool_count: usize = 0;

    for (content_arr.array.items) |block| {
        const type_val = block.object.get("type") orelse continue;
        const block_type = switch (type_val) {
            .string => |s| s,
            else    => continue,
        };

        if (std.mem.eql(u8, block_type, "text")) {
            const text_val = block.object.get("text") orelse continue;
            const text = switch (text_val) {
                .string => |s| s,
                else    => continue,
            };
            if (text_buf.items.len > 0) try text_buf.append('\n');
            try text_buf.appendSlice(text);

        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            // Translate to OpenAI tool_calls format so agent.zig works unchanged.
            const name_val  = block.object.get("name")  orelse continue;
            const input_val = block.object.get("input") orelse continue;
            const name = switch (name_val) {
                .string => |s| s,
                else    => continue,
            };

            // Serialise input object → JSON string for "arguments".
            var args_buf = std.ArrayList(u8).init(allocator);
            defer args_buf.deinit();
            var jw = std.json.writeStream(args_buf.writer(), .{ .whitespace = .minified });
            try jw.write(input_val);

            if (tool_count > 0) try tool_calls.appendSlice(",");
            try tool_calls.writer().print(
                "{{\"function\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
                .{ name, args_buf.items },
            );
            tool_count += 1;
        }
    }

    // If there were tool_use blocks, return an OpenAI-style tool_calls JSON
    // so agent.zig's dispatchAllToolCalls() handles it transparently.
    if (tool_count > 0) {
        const tc_json = try std.fmt.allocPrint(
            allocator,
            "{{\"tool_calls\":[{s}]}}",
            .{tool_calls.items},
        );
        text_buf.deinit();
        return tc_json;
    }

    if (text_buf.items.len == 0) return allocator.dupe(u8, raw);
    return text_buf.toOwnedSlice();
}

// ── Ollama ────────────────────────────────────────────────────────────────────
//
// Request: POST /api/chat
//   { "model": "...", "stream": false,
//     "messages": [{"role":"system","content":"..."},{"role":"user","content":"..."}] }
// Response: { "message": { "content": "..." } }

fn chatOllama(
    self: *Provider,
    system: []const u8,
    user:   []const u8,
    model:  []const u8,
    temperature: f32,
) ![]u8 {
    _ = temperature;

    var buf = std.ArrayList(u8).init(self.allocator);
    errdefer buf.deinit();

    var jw = std.json.writeStream(buf.writer(), .{ .whitespace = .minified });
    try jw.beginObject();
    try jw.objectField("model");  try jw.write(model);
    try jw.objectField("stream"); try jw.write(false);
    try jw.objectField("messages");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("role");    try jw.write("system");
    try jw.objectField("content"); try jw.write(system);
    try jw.endObject();
    try jw.beginObject();
    try jw.objectField("role");    try jw.write("user");
    try jw.objectField("content"); try jw.write(user);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();

    const body = try buf.toOwnedSlice();
    defer self.allocator.free(body);

    // Ollama: no auth header needed.
    const raw = try postBearer(self.allocator, self.base_url, "", body, null);
    defer self.allocator.free(raw);

    // Parse: { "message": { "content": "..." } }
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
        return self.allocator.dupe(u8, raw);
    };
    defer parsed.deinit();

    const msg = parsed.value.object.get("message") orelse return self.allocator.dupe(u8, raw);
    const content = msg.object.get("content") orelse return self.allocator.dupe(u8, raw);
    return switch (content) {
        .string => |s| self.allocator.dupe(u8, s),
        else    => self.allocator.dupe(u8, raw),
    };
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────

/// POST with Bearer auth. extra_raw_headers is appended verbatim (ignored here;
/// we handle Anthropic's custom headers via extra_headers in postAnthropic).
fn postBearer(
    allocator: std.mem.Allocator,
    url:       []const u8,
    api_key:   []const u8,
    body:      []const u8,
    _extra:    ?[]const u8,
) ![]u8 {
    _ = _extra;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var response_buf = std.ArrayList(u8).init(allocator);
    errdefer response_buf.deinit();

    const auth_header = if (api_key.len > 0)
        try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(auth_header);

    const fetch_opts = std.http.Client.FetchOptions{
        .method   = .POST,
        .location = .{ .uri = uri },
        .headers  = .{
            .content_type  = .{ .override = "application/json" },
            .authorization = if (api_key.len > 0)
                .{ .override = auth_header }
            else
                .default,
        },
        .payload          = body,
        .response_storage = .{ .dynamic = &response_buf },
    };

    const result = try client.fetch(fetch_opts);

    if (result.status != .ok) {
        defer response_buf.deinit();
        return std.fmt.allocPrint(
            allocator,
            "HTTP {d}: {s}",
            .{ @intFromEnum(result.status), response_buf.items },
        );
    }

    return response_buf.toOwnedSlice();
}
