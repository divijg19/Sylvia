const std = @import("std");
const Config = @import("../main.zig").Config;
const Context = @import("../memory/context.zig").Context;
const parser = @import("../llm/parser.zig");
const fs = @import("../tools/fs.zig");
const prompt = @import("../ui/prompt.zig");
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
    } else if (std.mem.eql(u8, tc.name, "replace_in_file")) {
        const path = tc.args.get("path") orelse return allocator.dupe(u8, "Error: Missing 'path' argument.");
        const old_text = tc.args.get("old_text") orelse return allocator.dupe(u8, "Error: Missing 'old_text' argument.");
        const new_text = tc.args.get("new_text") orelse return allocator.dupe(u8, "Error: Missing 'new_text' argument.");

        const action_desc = try std.fmt.allocPrint(allocator, "Modify file: {s}", .{path});
        defer allocator.free(action_desc);

        const allowed = prompt.askPermission(action_desc) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };
        if (!allowed) {
            return allocator.dupe(u8, "Observation: User denied this action. Try another approach.");
        }

        return fs.replaceInFile(allocator, path, old_text, new_text) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool error: {any}", .{err});
        };
    }
    return std.fmt.allocPrint(allocator, "Error: Tool '{s}' not found. Available: list_files, read_file, replace_in_file", .{tc.name});
}

pub fn runLoop(allocator: std.mem.Allocator, config: Config, task: []const u8) !void {
    std.log.info("Initializing Sylvia Cognitive Loop...", .{});

    // Global memory for the loop (System Prompt + Ring Buffer)
    var ctx = try Context.init(allocator, task, 8); // Max 8 turns rolling
    defer ctx.deinit();

    // The user task kicks off the interaction
    try ctx.appendTurn("user", task);

    var step: usize = 0;
    const max_steps: usize = 15;

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

        std.log.info("[Sylvia's Output]\n{s}\n", .{llm_response});

        // Save the thought to global context (copies out of the dying arena)
        try ctx.appendTurn("assistant", llm_response);

        // 3. Parse action
        const action = try parser.parseAction(turn_alloc, llm_response);

        switch (action) {
            .final_answer => |ans| {
                std.log.info("\n🎉 FINAL ANSWER:\n{s}\n", .{ans});
                break;
            },
            .none => {
                // The agent rambled without formatting properly. Steer it back.
                const obs = "SYSTEM WARNING: You did not format a tool call correctly or provide a FINAL ANSWER. Please use the <sylvia_tool> format.";
                try ctx.appendTurn("user", obs);
            },
            .tool_call => |tc| {
                std.log.info("[Executing Tool]: {s}", .{tc.name});

                // Execute and protect context with truncator
                const raw_obs = try executeTool(turn_alloc, tc);
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
