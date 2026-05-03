const std = @import("std");
const builtin = @import("builtin");

pub fn runShell(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    // Setup cross-platform argv
    const argv = if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/c", command }
    else
        [_][]const u8{ "/bin/sh", "-c", command };

    // Create and configure child process
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    // Spawn the process
    try child.spawn();

    // Wait for the process to complete
    // Note: In production, implement proper timeout using OS-level APIs or threading
    // For now, this will wait indefinitely for the process to finish
    const term = try child.wait();
    _ = term; // suppress unused variable warning

    // Read stdout and stderr (capped at 5MB each)
    const max_output = 5 * 1024 * 1024;
    const stdout_data = try child.stdout.?.readToEndAlloc(allocator, max_output);
    defer allocator.free(stdout_data);

    const stderr_data = try child.stderr.?.readToEndAlloc(allocator, max_output);
    defer allocator.free(stderr_data);

    // Format output: "STDOUT:\n[stdout]\nSTDERR:\n[stderr]"
    return std.fmt.allocPrint(allocator, "STDOUT:\n{s}\nSTDERR:\n{s}", .{ stdout_data, stderr_data });
}
