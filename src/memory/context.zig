const std = @import("std");

pub const Turn = struct {
    role: []const u8,
    content: []const u8,
};

/// The Ring Buffer Context. Prevents LLM context bloat.
pub const Context = struct {
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    task_prompt: []const u8,

    // The rolling history of thought->action->observation
    // Zig 0.15.2: Unmanaged ArrayList
    history: std.ArrayList(Turn),
    max_turns: usize,

    pub fn init(allocator: std.mem.Allocator, task: []const u8, max_turns: usize) !Context {
        const sys_prompt =
            \\You are Sylvia, an expert coding agent.
            \\Available tools:
            \\1. list_files: <path>
            \\2. read_file: <path>
            \\3. replace_in_file: <path>, <old_text>, <new_text>
            \\
            \\Use this exact format to act:
            \\<sylvia_tool>
            \\<name>tool_name</name>
            \\<path>argument</path>
            \\<old_text>argument</old_text>
            \\<new_text>argument</new_text>
            \\</sylvia_tool>
            \\
            \\If you have finished the task, output:
            \\FINAL ANSWER: <your answer>
        ;

        return Context{
            .allocator = allocator,
            // We duplicate the prompts so the Context struct owns all its memory
            .system_prompt = try allocator.dupe(u8, sys_prompt),
            .task_prompt = try allocator.dupe(u8, task),
            .history = .empty,
            .max_turns = max_turns,
        };
    }

    pub fn deinit(self: *Context) void {
        self.allocator.free(self.system_prompt);
        self.allocator.free(self.task_prompt);

        for (self.history.items) |turn| {
            self.allocator.free(turn.role);
            self.allocator.free(turn.content);
        }
        // Zig 0.15.2: Pass allocator to deinit
        self.history.deinit(self.allocator);
    }

    /// Adds a turn. If history exceeds max_turns, evicts the oldest entry.
    pub fn appendTurn(self: *Context, role: []const u8, content: []const u8) !void {
        const new_turn = Turn{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
        };

        // Zig 0.15.2: Pass allocator to append
        try self.history.append(self.allocator, new_turn);

        // The Rolling Evictor Logic
        if (self.history.items.len > self.max_turns) {
            // Remove the oldest item at index 0 and free its strings
            const oldest = self.history.orderedRemove(0);
            self.allocator.free(oldest.role);
            self.allocator.free(oldest.content);
            std.log.info("[SYLVIA: Evicted oldest memory to preserve context window]", .{});
        }
    }
};

// --- Tests ---
// Run via: zig test src/memory/context.zig
test "Context rolling evictor respects max_turns" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try Context.init(allocator, "Find the bug.", 3);
    defer ctx.deinit();

    // Append 4 turns (exceeding the max of 3)
    try ctx.appendTurn("assistant", "Thought 1");
    try ctx.appendTurn("user", "Observation 1");
    try ctx.appendTurn("assistant", "Thought 2");
    try ctx.appendTurn("user", "Observation 2");

    // The length should be capped at 3
    try testing.expectEqual(@as(usize, 3), ctx.history.items.len);

    // The oldest ("Thought 1") should have been evicted.
    // Index 0 should now be "Observation 1"
    try testing.expectEqualStrings("user", ctx.history.items[0].role);
    try testing.expectEqualStrings("Observation 1", ctx.history.items[0].content);
}
