const std = @import("std");
const tui = @import("./tui.zig");

/// Pauses execution and asks for terminal approval.
pub fn askPermission(action_desc: []const u8) !bool {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stdin_buf: [1024]u8 = undefined;
    const stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var stdin = stdin_reader.interface;

    try stdout.print("\n{s}[BLAST RADIUS] Sylvia requested a dangerous action: {s}\n", .{ tui.yellow, tui.reset });
    try stdout.print("-> {s}\n", .{action_desc});
    try stdout.print("Allow this action? [y/N]: ", .{});
    try stdout.flush();

    if (try stdin.takeDelimiter('\n')) |line| {
        const trimmed = std.mem.trim(u8, line, "\r ");
        if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y")) {
            return true;
        }
    }

    return false;
}
