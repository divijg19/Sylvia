const std = @import("std");
const builtin = @import("builtin");

pub fn runShell(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    // Setup cross-platform argv
    const argv = if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/c", command }
    else
        [_][]const u8{ "/bin/sh", "-c", command };

    // Use high-level Child.run helper to avoid manual pipe/null panics and deadlocks.
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 5 * 1024 * 1024,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return std.fmt.allocPrint(allocator, "STDOUT:\n{s}\nSTDERR:\n{s}", .{ result.stdout, result.stderr });
}
