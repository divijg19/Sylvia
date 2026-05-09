const std = @import("std");

pub const reset = "\x1b[0m";
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";

pub fn printColor(color: []const u8, text: []const u8) void {
    var empty: [0]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(empty[0..0]);
    const stdout = &stdout_writer.interface;

    stdout.print("{s}{s}{s}\n", .{ color, text, reset }) catch {};
}

pub fn printDiff(old_text: []const u8, new_text: []const u8) void {
    var empty: [0]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(empty[0..0]);
    const stdout = &stdout_writer.interface;

    var old_lines = std.mem.splitSequence(u8, old_text, "\n");
    while (old_lines.next()) |line| {
        stdout.print("\x1b[31m- {s}\x1b[0m\n", .{line}) catch {};
    }

    var new_lines = std.mem.splitSequence(u8, new_text, "\n");
    while (new_lines.next()) |line| {
        stdout.print("\x1b[32m+ {s}\x1b[0m\n", .{line}) catch {};
    }
}
