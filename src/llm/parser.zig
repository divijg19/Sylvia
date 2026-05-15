const std = @import("std");

pub const ToolCall = struct {
    name: []const u8,
    args: std.StringHashMap([]const u8),
};

pub const ParseResultTag = enum {
    tool_call,
    final_answer,
    none,
};

pub const ParseResult = union(ParseResultTag) {
    tool_call: ToolCall,
    final_answer: []const u8,
    none: void,
};

/// Parses the LLM response looking for <sylvia_tool> XML blocks or FINAL ANSWER.
pub fn parseAction(allocator: std.mem.Allocator, response: []const u8) !ParseResult {
    const start_tag = "<sylvia_tool>";
    const end_tag = "</sylvia_tool>";

    // 1. Check for Final Answer first — if present anywhere, it wins.
    const final_tag = "FINAL ANSWER:";
    if (std.mem.indexOf(u8, response, final_tag)) |f_idx| {
        // Only trim newlines/carriage returns, not spaces!
        const ans = std.mem.trim(u8, response[f_idx + final_tag.len ..], "\r\n ");
        return ParseResult{ .final_answer = ans };
    }

    // 2. Check for a Tool Call
    if (std.mem.indexOf(u8, response, start_tag)) |start_idx| {
        const inner_start = start_idx + start_tag.len;
        if (std.mem.indexOfPos(u8, response, inner_start, end_tag)) |end_idx| {
            const inner_content = response[inner_start..end_idx];

            // Extract the tool name
            const tool_name = extractTag(inner_content, "name");
            if (tool_name == null) return ParseResult{ .none = {} }; // Malformed tag

            var args = std.StringHashMap([]const u8).init(allocator);

            // Extract predefined arguments we expect tools might use
            const known_keys = [_][]const u8{ "path", "old_text", "new_text", "command", "start_line", "end_line", "query" };
            for (known_keys) |key| {
                if (extractTag(inner_content, key)) |val| {
                    try args.put(key, val);
                }
            }

            return ParseResult{ .tool_call = .{ .name = tool_name.?, .args = args } };
        }
    }

    // 3. Model rambled without acting
    return ParseResult{ .none = {} };
}

/// Helper to extract <tag>value</tag>. Only trims newlines, preserving internal code indentation!
fn extractTag(content: []const u8, tag_name: []const u8) ?[]const u8 {
    var open_buf: [32]u8 = undefined;
    const open_tag = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag_name}) catch return null;

    var close_buf: [33]u8 = undefined;
    const close_tag = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag_name}) catch return null;

    if (std.mem.indexOf(u8, content, open_tag)) |start_idx| {
        const inner_start = start_idx + open_tag.len;
        if (std.mem.indexOfPos(u8, content, inner_start, close_tag)) |end_idx| {
            // Trim ONLY newlines so we don't destroy python/zig indentation inside code blocks
            return std.mem.trim(u8, content[inner_start..end_idx], "\r\n");
        }
    }
    return null;
}

// --- Tests ---
// Run via: zig test src/llm/parser.zig
test "Parser extracts tool call and preserves indentation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const mock_llm_response =
        \\THOUGHT: I need to replace the function.
        \\<sylvia_tool>
        \\<name>replace_in_file</name>
        \\<path>src/main.zig</path>
        \\<old_text>
        \\fn foo() {
        \\    return true;
        \\}
        \\</old_text>
        \\</sylvia_tool>
    ;

    // Use 'var' so we can call the mutating .deinit() method later
    var result = try parseAction(allocator, mock_llm_response);

    // We must deinitialize the hashmap memory to prevent leaks during tests
    defer if (result == .tool_call) result.tool_call.args.deinit();

    try testing.expect(result == .tool_call);
    try testing.expectEqualStrings("replace_in_file", result.tool_call.name);

    const path = result.tool_call.args.get("path").?;
    try testing.expectEqualStrings("src/main.zig", path);

    const old_text = result.tool_call.args.get("old_text").?;
    // Notice the 4 spaces of indentation are preserved perfectly!
    try testing.expectEqualStrings("fn foo() {\n    return true;\n}", old_text);
}

test "Parser prioritizes FINAL ANSWER over tool call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const mock_llm_response =
        \\Some thought here
        \\<sylvia_tool>
        \\<name>replace_lines</name>
        \\<path>dummy.zig</path>
        \\<start_line>1</start_line>
        \\<end_line>2</end_line>
        \\<new_text>// replaced</new_text>
        \\</sylvia_tool>
        \\
        \\FINAL ANSWER: The task is done.
    ;

    var result = try parseAction(allocator, mock_llm_response);
    defer if (result == .tool_call) result.tool_call.args.deinit();

    try testing.expect(result == .final_answer);
    try testing.expectEqualStrings("The task is done.", result.final_answer);
}

test "Parser extracts replace_lines arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const mock_llm_response =
        \\ACTION:
        \\<sylvia_tool>
        \\<name>replace_lines</name>
        \\<path>dummy.zig</path>
        \\<start_line>5</start_line>
        \\<end_line>7</end_line>
        \\<new_text>// replaced content</new_text>
        \\</sylvia_tool>
    ;

    var result = try parseAction(allocator, mock_llm_response);
    defer if (result == .tool_call) result.tool_call.args.deinit();

    try testing.expect(result == .tool_call);
    const tc = result.tool_call;
    const s = tc.args.get("start_line").?;
    const e = tc.args.get("end_line").?;
    try testing.expectEqualStrings("5", s);
    try testing.expectEqualStrings("7", e);
}
