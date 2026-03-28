const std = @import("std");
const memory_mod = @import("memory.zig");
const provider_mod = @import("provider.zig");

pub const MAX_PLAN_STEPS: usize = 8;

pub const ToolDescriptor = struct {
    name: []const u8,
    description: []const u8,
};

pub const ExecutionResult = struct {
    success: bool,
    output: []const u8,
    allocated: bool = false,

    pub fn owned(success: bool, output: []const u8) ExecutionResult {
        return .{ .success = success, .output = output, .allocated = true };
    }

    pub fn literal(success: bool, output: []const u8) ExecutionResult {
        return .{ .success = success, .output = output, .allocated = false };
    }
};

pub const ExecuteStepFn = *const fn (
    ctx: *anyopaque,
    tool_name: []const u8,
    args_json: []const u8,
) anyerror!ExecutionResult;

pub const PlanStep = struct {
    tool: []u8,
    args_json: []u8,
    rationale: []u8,

    pub fn deinit(self: *PlanStep, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);
        allocator.free(self.args_json);
        allocator.free(self.rationale);
        self.* = undefined;
    }
};

const ReflectionAction = enum {
    continue_run,
    stop,
    append_steps,
};

const ReflectionDecision = struct {
    action: ReflectionAction = .continue_run,
    reason: []u8,
    appended_steps: []PlanStep,

    fn deinit(self: *ReflectionDecision, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        for (self.appended_steps) |*step| step.deinit(allocator);
        allocator.free(self.appended_steps);
        self.* = undefined;
    }
};

pub fn planAndExecute(
    allocator: std.mem.Allocator,
    provider: provider_mod.AnyProvider,
    model: []const u8,
    memory: *memory_mod.MemoryBackend,
    tool_descriptors: []const ToolDescriptor,
    execute_ctx: *anyopaque,
    execute_step: ExecuteStepFn,
    goal: []const u8,
) ![]u8 {
    const latest_reflection = try loadLatestReflection(allocator, memory);
    defer if (latest_reflection) |value| allocator.free(value);

    const plan_prompt = try buildPlanningPrompt(allocator, goal, tool_descriptors, latest_reflection);
    defer allocator.free(plan_prompt);

    const plan_reply = try provider.chatOnce(
        plannerSystemPrompt(),
        plan_prompt,
        model,
        0.2,
    );
    defer allocator.free(plan_reply);

    var steps = try parsePlanSteps(allocator, plan_reply);
    defer {
        for (steps.items) |*step| step.deinit(allocator);
        steps.deinit();
    }

    var execution_log = std.ArrayList(u8).init(allocator);
    defer execution_log.deinit();

    var idx: usize = 0;
    while (idx < steps.items.len and idx < MAX_PLAN_STEPS) : (idx += 1) {
        const step = steps.items[idx];
        const result = execute_step(execute_ctx, step.tool, step.args_json) catch |err| blk: {
            const msg = try std.fmt.allocPrint(allocator, "tool error: {}", .{err});
            break :blk ExecutionResult.owned(false, msg);
        };
        defer if (result.allocated) allocator.free(result.output);

        try execution_log.writer().print(
            "Step {d}: {s}\nRationale: {s}\nResult: [{s}] {s}\n\n",
            .{
                idx + 1,
                step.tool,
                if (step.rationale.len > 0) step.rationale else "(none given)",
                if (result.success) @as([]const u8, "ok") else "error",
                result.output,
            },
        );

        var decision = try reflectAfterStep(
            allocator,
            provider,
            model,
            goal,
            steps.items[idx..],
            result,
        );
        defer decision.deinit(allocator);

        if (decision.reason.len > 0) {
            try execution_log.writer().print("Planner reflection: {s}\n\n", .{decision.reason});
        }

        if (decision.action == .append_steps and decision.appended_steps.len > 0) {
            const remaining_capacity = MAX_PLAN_STEPS - @min(steps.items.len, MAX_PLAN_STEPS);
            const to_append = @min(remaining_capacity, decision.appended_steps.len);
            var append_idx: usize = 0;
            while (append_idx < to_append) : (append_idx += 1) {
                const appended = decision.appended_steps[append_idx];
                try steps.append(.{
                    .tool = try allocator.dupe(u8, appended.tool),
                    .args_json = try allocator.dupe(u8, appended.args_json),
                    .rationale = try allocator.dupe(u8, appended.rationale),
                });
            }
        }

        if (decision.action == .stop) break;
    }

    const final_reflection = try buildFinalReflection(
        allocator,
        provider,
        model,
        goal,
        execution_log.items,
    );
    defer allocator.free(final_reflection);

    try storeReflection(memory, final_reflection);

    return std.fmt.allocPrint(
        allocator,
        "Planner goal: {s}\n\nExecution Log\n-------------\n{s}Final Reflection\n----------------\n{s}\n",
        .{ goal, execution_log.items, final_reflection },
    );
}

fn plannerSystemPrompt() []const u8 {
    return "You are BearClaw's planning module.\n" ++
        "Return ONLY JSON. No prose, no markdown fences.\n" ++
        "Planning format:\n" ++
        "{\"steps\":[{\"tool\":\"tool_name\",\"args\":{},\"rationale\":\"why\"}]}\n" ++
        "Use between 1 and 8 steps. Prefer the smallest useful plan.\n" ++
        "Every step must reference one of the provided tools exactly by name.";
}

fn reflectionSystemPrompt() []const u8 {
    return "You are BearClaw's step reflector.\n" ++
        "Return ONLY JSON. No prose.\n" ++
        "Format:\n" ++
        "{\"action\":\"continue|stop|append_steps\",\"reason\":\"short reason\",\"steps\":[{\"tool\":\"name\",\"args\":{},\"rationale\":\"why\"}]}\n" ++
        "Use append_steps only when the latest result clearly changes the remaining work.";
}

fn finalReflectionSystemPrompt() []const u8 {
    return "You are BearClaw's reflective summary module.\n" ++
        "Write concise markdown with exactly these headings:\n" ++
        "## What Worked\n" ++
        "## What Failed\n" ++
        "## Remember Next Time";
}

fn buildPlanningPrompt(
    allocator: std.mem.Allocator,
    goal: []const u8,
    tools: []const ToolDescriptor,
    latest_reflection: ?[]const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.writer().print("Goal:\n{s}\n\nAvailable tools:\n", .{goal});
    for (tools) |tool| {
        try buf.writer().print("- {s}", .{tool.name});
        if (tool.description.len > 0) try buf.writer().print(": {s}", .{tool.description});
        try buf.append('\n');
    }

    if (latest_reflection) |reflection| {
        const trimmed = std.mem.trim(u8, reflection, " \t\r\n");
        if (trimmed.len > 0) {
            try buf.writer().print("\nLatest reflection:\n{s}\n", .{trimmed});
        }
    }

    return buf.toOwnedSlice();
}

fn reflectAfterStep(
    allocator: std.mem.Allocator,
    provider: provider_mod.AnyProvider,
    model: []const u8,
    goal: []const u8,
    remaining_steps: []const PlanStep,
    result: ExecutionResult,
) !ReflectionDecision {
    var prompt = std.ArrayList(u8).init(allocator);
    defer prompt.deinit();

    try prompt.writer().print(
        "Goal:\n{s}\n\nLatest result:\n[{s}] {s}\n\nRemaining planned steps:\n",
        .{ goal, if (result.success) @as([]const u8, "ok") else "error", result.output },
    );
    for (remaining_steps[1..], 0..) |step, idx| {
        try prompt.writer().print("{d}. {s} — {s}\n", .{
            idx + 1,
            step.tool,
            if (step.rationale.len > 0) step.rationale else "(no rationale)",
        });
    }

    const reply = try provider.chatOnce(
        reflectionSystemPrompt(),
        prompt.items,
        model,
        0.2,
    );
    defer allocator.free(reply);

    return parseReflectionDecision(allocator, reply);
}

fn buildFinalReflection(
    allocator: std.mem.Allocator,
    provider: provider_mod.AnyProvider,
    model: []const u8,
    goal: []const u8,
    execution_log: []const u8,
) ![]u8 {
    const prompt = try std.fmt.allocPrint(
        allocator,
        "Goal:\n{s}\n\nExecution log:\n{s}",
        .{ goal, execution_log },
    );
    defer allocator.free(prompt);

    return provider.chatOnce(
        finalReflectionSystemPrompt(),
        prompt,
        model,
        0.3,
    );
}

fn storeReflection(memory: *memory_mod.MemoryBackend, reflection: []const u8) !void {
    const ts = std.time.timestamp();
    var key_buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "reflection/{d}", .{ts});
    try memory.store(key, reflection);
    try memory.store("reflection/latest", reflection);
}

fn loadLatestReflection(allocator: std.mem.Allocator, memory: *memory_mod.MemoryBackend) !?[]u8 {
    const raw = memory.recall("reflection/latest") catch return null;
    if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "(no matching memory found)")) {
        allocator.free(raw);
        return null;
    }
    return raw;
}

fn parsePlanSteps(allocator: std.mem.Allocator, raw: []const u8) !std.ArrayList(PlanStep) {
    const json = extractJsonBlock(raw) orelse return error.InvalidPlan;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const steps_val = switch (parsed.value) {
        .array => parsed.value,
        .object => parsed.value.object.get("steps") orelse return error.InvalidPlan,
        else => return error.InvalidPlan,
    };
    if (steps_val != .array) return error.InvalidPlan;

    var steps = std.ArrayList(PlanStep).init(allocator);
    errdefer {
        for (steps.items) |*step| step.deinit(allocator);
        steps.deinit();
    }

    for (steps_val.array.items[0..@min(steps_val.array.items.len, MAX_PLAN_STEPS)]) |item| {
        if (item != .object) continue;

        const tool_val = item.object.get("tool") orelse item.object.get("function") orelse continue;
        const tool_name = switch (tool_val) {
            .string => |s| s,
            else => continue,
        };

        const rationale = if (item.object.get("rationale")) |rationale_val| switch (rationale_val) {
            .string => |s| s,
            else => "",
        } else "";

        const args_json = if (item.object.get("args")) |args_val|
            try serializeJsonValue(allocator, args_val)
        else if (item.object.get("arguments")) |args_val|
            try serializeJsonValue(allocator, args_val)
        else
            try allocator.dupe(u8, "{}");

        try steps.append(.{
            .tool = try allocator.dupe(u8, tool_name),
            .args_json = args_json,
            .rationale = try allocator.dupe(u8, rationale),
        });
    }

    if (steps.items.len == 0) return error.InvalidPlan;
    return steps;
}

fn parseReflectionDecision(allocator: std.mem.Allocator, raw: []const u8) !ReflectionDecision {
    const json = extractJsonBlock(raw) orelse {
        return .{
            .action = .continue_run,
            .reason = try allocator.dupe(u8, ""),
            .appended_steps = try allocator.alloc(PlanStep, 0),
        };
    };

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return .{
            .action = .continue_run,
            .reason = try allocator.dupe(u8, ""),
            .appended_steps = try allocator.alloc(PlanStep, 0),
        };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{
            .action = .continue_run,
            .reason = try allocator.dupe(u8, ""),
            .appended_steps = try allocator.alloc(PlanStep, 0),
        };
    }

    const action_raw = if (parsed.value.object.get("action")) |val| switch (val) {
        .string => |s| s,
        else => "continue",
    } else "continue";

    const action: ReflectionAction = if (std.mem.eql(u8, action_raw, "stop"))
        .stop
    else if (std.mem.eql(u8, action_raw, "append_steps"))
        .append_steps
    else
        .continue_run;

    const reason = if (parsed.value.object.get("reason")) |val| switch (val) {
        .string => |s| try allocator.dupe(u8, s),
        else => try allocator.dupe(u8, ""),
    } else try allocator.dupe(u8, "");

    var appended_steps = try allocator.alloc(PlanStep, 0);
    if (parsed.value.object.get("steps") != null) {
        var parsed_steps = try parsePlanSteps(allocator, json);
        appended_steps = try parsed_steps.toOwnedSlice();
    }

    return .{
        .action = action,
        .reason = reason,
        .appended_steps = appended_steps,
    };
}

fn serializeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |s| allocator.dupe(u8, s),
        else => blk: {
            var buf = std.ArrayList(u8).init(allocator);
            errdefer buf.deinit();
            try std.json.stringify(value, .{}, buf.writer());
            break :blk buf.toOwnedSlice();
        },
    };
}

fn extractJsonBlock(input: []const u8) ?[]const u8 {
    var src = input;
    if (std.mem.indexOf(u8, src, "```")) |fence_start| {
        const after_fence = fence_start + 3;
        const newline = std.mem.indexOfScalarPos(u8, src, after_fence, '\n') orelse after_fence;
        const content_start = newline + 1;
        if (std.mem.lastIndexOf(u8, src, "```")) |fence_end| {
            if (fence_end > content_start) {
                src = std.mem.trim(u8, src[content_start..fence_end], " \t\r\n");
            }
        }
    }

    const obj_start = std.mem.indexOfScalar(u8, src, '{');
    const arr_start = std.mem.indexOfScalar(u8, src, '[');
    const start = switch (obj_start != null and arr_start != null) {
        true => @min(obj_start.?, arr_start.?),
        false => obj_start orelse arr_start orelse return null,
    };

    var brace_depth: usize = 0;
    var array_depth: usize = 0;
    var in_string = false;
    var escape_next = false;
    var started = false;

    var i = start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape_next) {
            escape_next = false;
            continue;
        }
        if (c == '\\' and in_string) {
            escape_next = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        switch (c) {
            '{' => {
                brace_depth += 1;
                started = true;
            },
            '[' => {
                array_depth += 1;
                started = true;
            },
            '}' => brace_depth -|= 1,
            ']' => array_depth -|= 1,
            else => {},
        }

        if (started and brace_depth == 0 and array_depth == 0) {
            return src[start .. i + 1];
        }
    }

    return null;
}
