const std = @import("std");
const tui = @import("./tui.zig");

/// Pauses execution and asks for terminal approval.
pub fn askPermission(action_desc: []const u8) !bool {
    var empty: [0]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(empty[0..0]);
    const stdout = &stdout_writer.interface;

    const stdin_file = std.fs.File.stdin();

    try stdout.print("\n{s}⚠️  [BLAST RADIUS] Sylvia requested a dangerous action:{s}\n", .{ tui.yellow, tui.reset });
    try stdout.print("{s}-> {s}{s}\n", .{ tui.yellow, action_desc, tui.reset });
    try stdout.print("{s}Allow this action? [y/N]: {s}", .{ tui.yellow, tui.reset });

    var buf: [16]u8 = undefined;
    const bytes_read = try stdin_file.read(&buf);

    if (bytes_read > 0) {
        const line = buf[0..bytes_read];
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y")) {
            return true;
        }
    }

    return false;
}
