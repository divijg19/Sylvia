const std = @import("std");

/// Returns a string tree of the directory. Ignores .git, node_modules, and zig-cache.
pub fn listFiles(allocator: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening directory: {any}", .{err});
    };
    defer dir.close();

    // Zig 0.15.2: Use unmanaged ArrayList
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    // Pass the allocator directly to the writer
    const writer = output.writer(allocator);

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

    // Zig 0.15.2: Use unmanaged ArrayList
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    // Pass the allocator directly to the writer
    const writer = output.writer(allocator);

    // Read entire file
    const file_content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(file_content);

    var line_number: usize = 1;
    var start: usize = 0;

    // Process each line
    for (file_content, 0..) |char, i| {
        if (char == '\n') {
            const line = file_content[start..i];
            try writer.print("{d:>4} | {s}\n", .{ line_number, line });
            line_number += 1;
            start = i + 1;
        }
    }

    // Handle the last line if it doesn't end with newline
    if (start < file_content.len) {
        const line = file_content[start..];
        try writer.print("{d:>4} | {s}\n", .{ line_number, line });
    }

    if (output.items.len == 0) {
        return allocator.dupe(u8, "File is empty.");
    }
    return allocator.dupe(u8, output.items);
}

// Note: `askPermission` has been moved to `src/ui/prompt.zig`.

pub fn replaceInFile(allocator: std.mem.Allocator, file_path: []const u8, old_text: []const u8, new_text: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{ .mode = .read_write }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening file: {any}", .{err});
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    if (std.mem.indexOf(u8, content, old_text) == null) {
        return allocator.dupe(u8, "Error: old_text not found in file.");
    }

    const replaced_size = std.mem.replacementSize(u8, content, old_text, new_text);
    const replaced = try allocator.alloc(u8, replaced_size);
    defer allocator.free(replaced);
    _ = std.mem.replace(u8, content, old_text, new_text, replaced);

    try file.seekTo(0);
    try file.setEndPos(0);
    try file.writeAll(replaced);

    return std.fmt.allocPrint(allocator, "Successfully replaced text in {s}.", .{file_path});
}
