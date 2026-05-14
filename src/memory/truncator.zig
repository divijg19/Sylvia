const std = @import("std");

/// Truncates a string if it exceeds `max_len`, keeping the beginning and the end.
/// Returns a newly allocated string. The caller owns the memory.
pub fn truncate(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]const u8 {
    if (text.len <= max_len) {
        return try allocator.dupe(u8, text);
    }

    const keep_len = max_len / 2;
    const start_chunk = text[0..keep_len];
    const end_chunk = text[text.len - keep_len .. text.len];
    const omitted = text.len - max_len;

    return try std.fmt.allocPrint(allocator, "{s}\n...[SYLVIA: TRUNCATED {d} BYTES TO PROTECT CONTEXT. DO NOT REPEAT THIS ACTION. USE WHAT YOU HAVE OR REFINE YOUR SEARCH.]...\n{s}", .{ start_chunk, omitted, end_chunk });
}

// --- Tests ---
// You can run this test via: zig test src/memory/truncator.zig
test "Truncator halves large text" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const large_text = "AAAAABBBBB"; // 10 chars
    const result = try truncate(allocator, large_text, 6);
    defer allocator.free(result);

    // Should keep 3 from start, 3 from end
    try testing.expect(std.mem.startsWith(u8, result, "AAA"));
    try testing.expect(std.mem.endsWith(u8, result, "BBB"));
    try testing.expect(std.mem.indexOf(u8, result, "[SYLVIA: TRUNCATED 4 BYTES") != null);
}
