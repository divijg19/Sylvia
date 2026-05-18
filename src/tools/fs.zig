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
            std.mem.indexOf(u8, entry.path, "zig-out") != null or
            std.mem.indexOf(u8, entry.path, "target") != null or
            std.mem.indexOf(u8, entry.path, "build") != null or
            std.mem.indexOf(u8, entry.path, "dist") != null or
            std.mem.indexOf(u8, entry.path, ".venv") != null or
            std.mem.indexOf(u8, entry.path, "__pycache__") != null or
            std.mem.indexOf(u8, entry.path, ".next") != null)
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

/// Searches code files for a query and returns path:line matches.
pub fn searchCode(allocator: std.mem.Allocator, dir_path: []const u8, query: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening directory: {any}", .{err});
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var match_count: usize = 0;

    outer: while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        if (std.mem.indexOf(u8, entry.path, ".git") != null or
            std.mem.indexOf(u8, entry.path, "node_modules") != null or
            std.mem.indexOf(u8, entry.path, ".zig-cache") != null or
            std.mem.indexOf(u8, entry.path, "zig-out") != null or
            std.mem.indexOf(u8, entry.path, "target") != null or
            std.mem.indexOf(u8, entry.path, "build") != null or
            std.mem.indexOf(u8, entry.path, "dist") != null or
            std.mem.indexOf(u8, entry.path, ".venv") != null or
            std.mem.indexOf(u8, entry.path, "__pycache__") != null or
            std.mem.indexOf(u8, entry.path, ".next") != null)
        {
            continue;
        }

        const file = dir.openFile(entry.path, .{}) catch {
            continue;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
            continue;
        };
        defer allocator.free(content);

        var line_num: usize = 1;
        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, query) != null) {
                try writer.print("{s}:{d}: {s}\n", .{ entry.path, line_num, std.mem.trim(u8, line, " \r") });
                match_count += 1;
                if (match_count > 100) {
                    try writer.writeAll("...[Truncated: Too many matches. DO NOT REPEAT THIS EXACT SEARCH. Refine your query to be more specific.]\n");
                    break :outer;
                }
            }
            line_num += 1;
        }
    }

    if (output.items.len == 0) {
        return allocator.dupe(u8, "No matches found for the query.");
    }
    return allocator.dupe(u8, output.items);
}

/// Extracts a 1-based inclusive line range from a file.
pub fn extractLines(allocator: std.mem.Allocator, file_path: []const u8, start_line: usize, end_line: usize) ![]const u8 {
    if (start_line == 0) {
        return allocator.dupe(u8, "Error: start_line must be >= 1.");
    }
    if (end_line == 0 or start_line > end_line) {
        return allocator.dupe(u8, "Error: Invalid line range.");
    }

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening file: {any}", .{err});
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Count total lines
    var total_lines: usize = 1;
    for (content) |char| {
        if (char == '\n') {
            total_lines += 1;
        }
    }

    if (start_line > total_lines) {
        return allocator.dupe(u8, "Error: start_line is beyond the end of the file.");
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    const writer = output.writer(allocator);
    var line_num: usize = 1;
    var iterator = std.mem.splitSequence(u8, content, "\n");

    while (iterator.next()) |line| {
        if (line_num >= start_line and line_num <= end_line) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
        line_num += 1;
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

/// Replaces a 1-based inclusive line range with new text.
pub fn replaceLines(allocator: std.mem.Allocator, file_path: []const u8, start_line: usize, end_line: usize, new_text: []const u8) ![]const u8 {
    if (start_line == 0) {
        return allocator.dupe(u8, "Error: start_line must be >= 1.");
    }
    if (end_line == 0 or start_line > end_line) {
        return allocator.dupe(u8, "Error: Invalid line range.");
    }

    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak", .{file_path});
    defer allocator.free(backup_path);
    std.fs.cwd().copyFile(file_path, std.fs.cwd(), backup_path, .{}) catch |err| std.log.warn("Could not create backup: {any}", .{err});

    const file = std.fs.cwd().openFile(file_path, .{ .mode = .read_write }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening file: {any}", .{err});
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Count total lines
    var total_lines: usize = 1;
    for (content) |char| {
        if (char == '\n') {
            total_lines += 1;
        }
    }

    if (start_line > total_lines) {
        return allocator.dupe(u8, "Error: start_line is beyond the end of the file. Cannot replace.");
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    const writer = output.writer(allocator);
    var line_num: usize = 1;
    var inserted = false;
    var iterator = std.mem.splitSequence(u8, content, "\n");
    const has_trailing_newline = content.len > 0 and content[content.len - 1] == '\n';

    while (iterator.next()) |line| {
        if (has_trailing_newline and line.len == 0 and line_num == total_lines) {
            break;
        }

        if (line_num < start_line or line_num > end_line) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
        } else if (!inserted and line_num == start_line) {
            try writer.writeAll(new_text);
            if (new_text.len == 0 or new_text[new_text.len - 1] != '\n') {
                try writer.writeByte('\n');
            }
            inserted = true;
        }

        line_num += 1;
    }

    try file.seekTo(0);
    try file.setEndPos(0);
    try file.writeAll(output.items);

    return std.fmt.allocPrint(allocator, "Successfully replaced lines in {s}. (Original saved as {s}.bak)", .{ file_path, file_path });
}

// --- Tests ---

test "fs tools: read, extract, replace, and backup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "test_dummy.zig";
    const backup_path = "test_dummy.zig.bak";
    defer std.fs.cwd().deleteFile(file_path) catch {};
    defer std.fs.cwd().deleteFile(backup_path) catch {};

    {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("Line 1\nLine 2\nLine 3\n");
    }

    const read_result = try readFile(allocator, file_path);
    defer allocator.free(read_result);
    try testing.expect(std.mem.indexOf(u8, read_result, "   2 | Line 2") != null);

    const extract_result = try extractLines(allocator, file_path, 2, 3);
    defer allocator.free(extract_result);
    try testing.expectEqualStrings("Line 2\nLine 3\n", extract_result);

    const replace_result = try replaceLines(allocator, file_path, 2, 2, "Replaced 2");
    defer allocator.free(replace_result);
    try testing.expect(std.mem.indexOf(u8, replace_result, "Successfully replaced lines in test_dummy.zig") != null);

    {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);
        try testing.expectEqualStrings("Line 1\nReplaced 2\nLine 3\n", content);
    }

    {
        const file = try std.fs.cwd().openFile(backup_path, .{});
        defer file.close();
        const backup_content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(backup_content);
        try testing.expectEqualStrings("Line 1\nLine 2\nLine 3\n", backup_content);
    }
}

test "searchCode finds matches" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const file_path = "search_test.txt";
    defer std.fs.cwd().deleteFile(file_path) catch {};

    {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("needle in haystack");
    }

    const result = try searchCode(allocator, ".", "needle");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "search_test.txt:1: needle in haystack") != null);
}
