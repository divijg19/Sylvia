const std = @import("std");
const Config = @import("../main.zig").Config;
const Context = @import("../memory/context.zig").Context;
const parser = @import("../llm/parser.zig");
const fs = @import("../tools/fs.zig");
const shell = @import("../tools/shell.zig");
const prompt = @import("../ui/prompt.zig");
const tui = @import("../ui/tui.zig");
const client = @import("../llm/client.zig");
const truncator = @import("../memory/truncator.zig");

/// The dispatcher routes parsed tool calls to the actual Zig functions
fn executeTool(allocator: std.mem.Allocator, tc: parser.ToolCall) ![]const u8 {
    if (std.mem.eql(u8, tc.name, "list_files")) {
        const path = tc.args.get("path") orelse return allocator.dupe(u8, "Error: Missing 'path' argument.");
        return fs.listFiles(allocator, path) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };
    } else if (std.mem.eql(u8, tc.name, "read_file")) {
        const path = tc.args.get("path") orelse return allocator.dupe(u8, "Error: Missing 'path' argument.");
        return fs.readFile(allocator, path) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };
    } else if (std.mem.eql(u8, tc.name, "replace_lines")) {
        const path = tc.args.get("path") orelse return allocator.dupe(u8, "Error: Missing 'path' argument.");
        const start_line = tc.args.get("start_line") orelse return allocator.dupe(u8, "Error: Missing 'start_line' argument.");
        const end_line = tc.args.get("end_line") orelse return allocator.dupe(u8, "Error: Missing 'end_line' argument.");
        const new_text = tc.args.get("new_text") orelse return allocator.dupe(u8, "Error: Missing 'new_text' argument.");

        const start_int = std.fmt.parseInt(usize, start_line, 10) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };
        const end_int = std.fmt.parseInt(usize, end_line, 10) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };

        const old_text = try fs.extractLines(allocator, path, start_int, end_int);
        defer allocator.free(old_text);

        const action_desc = try std.fmt.allocPrint(allocator, "Replace lines {d}-{d} in {s}", .{ start_int, end_int, path });
        defer allocator.free(action_desc);

        tui.printDiff(old_text, new_text);

        const allowed = prompt.askPermission(action_desc) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };
        if (!allowed) {
            return allocator.dupe(u8, "Observation: User denied this action. Try another approach.");
        }

        return fs.replaceLines(allocator, path, start_int, end_int, new_text) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };
    } else if (std.mem.eql(u8, tc.name, "run_shell")) {
        const command = tc.args.get("command") orelse return allocator.dupe(u8, "Error: Missing 'command' argument.");

        const action_desc = try std.fmt.allocPrint(allocator, "Run shell command: {s}", .{command});
        defer allocator.free(action_desc);

        const allowed = prompt.askPermission(action_desc) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };
        if (!allowed) {
            return allocator.dupe(u8, "Observation: User denied this action.");
        }

        return shell.runShell(allocator, command) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };
    }
    return std.fmt.allocPrint(allocator, "Error: Tool '{s}' not found. Available: list_files, read_file, replace_lines, run_shell", .{tc.name});
}

pub fn runLoop(allocator: std.mem.Allocator, config: Config, task: []const u8) !void {
    std.log.info("Initializing Sylvia Cognitive Loop...", .{});

    tui.printColor(tui.yellow, "\n[PHASE 1: Generating Execution Plan...]");

    var plan_ctx = try Context.init(allocator, "You are a master software architect. Given the user's request, write a concise 3-step execution plan. Output ONLY the plan.", 2);
    defer plan_ctx.deinit();
    try plan_ctx.appendTurn("user", task);

    const plan_text = try client.getChatCompletion(allocator, config, &plan_ctx);
    defer allocator.free(plan_text);

    const enriched_task = try std.fmt.allocPrint(allocator, "TASK: {s}\n\nEXECUTION PLAN:\n{s}\n\nStick to this plan.", .{ task, plan_text });
    defer allocator.free(enriched_task);

    tui.printColor(tui.yellow, "\n[PHASE 2: Autonomous Execution...]");

    // Global memory for the loop (System Prompt + Ring Buffer)
    var ctx = try Context.init(allocator, enriched_task, 8); // Max 8 turns rolling
    defer ctx.deinit();

    // The user task kicks off the interaction
    try ctx.appendTurn("user", enriched_task);

    var step: usize = 0;
    const max_steps: usize = 15;
    var last_action_hash: u64 = 0;

    while (step < max_steps) : (step += 1) {
        std.log.info("\n================================", .{});
        std.log.info("          STEP {d} / {d}", .{ step + 1, max_steps });
        std.log.info("================================\n", .{});

        // 1. THE ISOLATION ARENA
        // All temporary API buffers, file reads, and parsed JSON trees live here.
        var turn_arena = std.heap.ArenaAllocator.init(allocator);
        defer turn_arena.deinit(); // Everything vanishes at the end of the `while` loop tick
        const turn_alloc = turn_arena.allocator();

        // 2. Fetch LLM response
        const llm_response = client.getChatCompletion(turn_alloc, config, &ctx) catch |err| {
            std.log.err("Failed to get LLM completion: {any}", .{err});
            break;
        };

        tui.printColor(tui.blue, llm_response);

        // Save the thought to global context (copies out of the dying arena)
        try ctx.appendTurn("assistant", llm_response);

        // 3. Parse action
        const action = try parser.parseAction(turn_alloc, llm_response);

        switch (action) {
            .final_answer => |ans| {
                tui.printColor(tui.green, ans);
                break;
            },
            .none => {
                // The agent rambled without formatting properly. Steer it back.
                const obs = "SYSTEM WARNING: You did not format a tool call correctly or provide a FINAL ANSWER. Please use the <sylvia_tool> format.";
                try ctx.appendTurn("user", obs);
            },
            .tool_call => |tc| {
                const tool_name = tc.name;
                tui.printColor(tui.magenta, tool_name);

                // Compute hash of the tool name + args to prevent immediate repetition
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(tc.name);
                var it = tc.args.iterator();
                while (it.next()) |entry| {
                    hasher.update(entry.key_ptr.*);
                    hasher.update(entry.value_ptr.*);
                }
                const current_hash = hasher.final();

                var raw_obs: []const u8 = undefined;

                if (current_hash == last_action_hash) {
                    const anti = "SYSTEM ERROR: You just attempted the exact same action and it failed or yielded no progress. You are stuck in a loop. Re-evaluate your strategy, use a different tool, or output FINAL ANSWER.";
                    tui.printColor(tui.yellow, "\n[ANTI-SPIRAL ACTIVATED: Blocked repeating action]");
                    raw_obs = try turn_alloc.dupe(u8, anti);
                } else {
                    last_action_hash = current_hash;
                    raw_obs = try executeTool(turn_alloc, tc);
                }

                const truncated_obs = try truncator.truncate(turn_alloc, raw_obs, 2000);

                std.log.info("[Observation]\n{s}\n", .{truncated_obs});

                // Feed observation back into global context
                const final_obs = try std.fmt.allocPrint(turn_alloc, "OBSERVATION:\n{s}", .{truncated_obs});
                try ctx.appendTurn("user", final_obs);
            },
        }
    }

    if (step == max_steps) {
        std.log.err("Loop terminated: Hard limit of {d} steps reached to prevent spiraling.", .{max_steps});
    }
}
