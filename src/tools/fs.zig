const std = @import("std");

/// Returns a string tree of the directory. Ignores .git, node_modules, and zig-cache.
pub fn listFiles(allocator: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening directory: {any}", .{err});
    };
    defer dir.close();

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // Ignore noisy directories to protect the LLM context window
        if (std.mem.indexOf(u8, entry.path, ".git") != null or
            std.mem.indexOf(u8, entry.path, "node_modules") != null or
            std.mem.indexOf(u8, entry.path, ".zig-cache") != null or
            std.mem.indexOf(u8, entry.path, "zig-out") != null)
        {
            continue;
        }
        try writer.print("{s}\n", .{entry.path});
    }

    if (output.items.len == 0) {
        return allocator.dupe(u8, "Directory is empty.");
    }
    return allocator.dupe(u8, output.items);
}

/// Reads a file and prepends line numbers to each line.
pub fn readFile(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening file: {any}", .{err});
    };
    defer file.close();

    // Read file up to 1MB max for safety
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        return std.fmt.allocPrint(allocator, "Error reading file: {any}", .{err});
    };
    defer allocator.free(content);

    // Prepend line numbers
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();

    var line_num: usize = 1;
    var lines = std.mem.splitSequence(u8, content, "\n");

    while (lines.next()) |line| {
        try writer.print("{d} | {s}\n", .{ line_num, line });
        line_num += 1;
    }

    return allocator.dupe(u8, output.items);
}
