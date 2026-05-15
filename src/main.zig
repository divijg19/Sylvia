const std = @import("std");
const posix = std.posix;
const loop = @import("agent/loop.zig");
const client = @import("llm/client.zig");
const truncator = @import("memory/truncator.zig");

// The single source of truth for our runtime configuration
pub const Config = struct {
    url: []const u8,
    model: []const u8,
    api_key: ?[]const u8,
};

fn printHelp() void {
    const help_text =
        \\Sylvia - Lightweight Local Coding Agent
        \\
        \\Usage: sylvia [task] [@file...] [options]
        \\   or: sylvia [command] [options]
        \\
        \\Commands:
        \\  ping       Test the connection to the LLM endpoint (v0.0.3)
        \\  doctor     Test LLM connection and active config
        \\  version    Print version
        \\  help       Print this help message
        \\
        \\Options:
        \\  --url <url>      API Base URL (Default: http://localhost:11434/v1)
        \\  --model <name>   LLM Model Name (Default: qwen2.5-coder:7b)
        \\  --key <key>      API Key (Optional, default: null)
        \\  --help, -h       Print this help message
        \\
        \\Environment Variables:
        \\  SYLVIA_URL, SYLVIA_MODEL, SYLVIA_API_KEY
        \\
    ;

    // Zig 0.15+ Explicit Buffered I/O
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    stdout.print("{s}\n", .{help_text}) catch return;
    stdout.flush() catch return; // Must flush to actually print to the terminal!
}

pub fn main() !void {
    // 1. Initialize the General Purpose Allocator (GPA)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("Memory leak detected during shutdown!", .{});
        }
    }
    const allocator = gpa.allocator();

    // 2. Fetch Environment Variables
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var config = Config{
        .url = "http://localhost:11434/v1",
        .model = "qwen2.5-coder:7b",
        .api_key = null,
    };

    if (env_map.get("SYLVIA_URL")) |url| config.url = url;
    if (env_map.get("SYLVIA_MODEL")) |model| config.model = model;
    if (env_map.get("SYLVIA_API_KEY")) |key| config.api_key = key;

    // 3. Parse Command Line Arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // Skip the executable path

    var management_cmd: ?[]const u8 = null;
    var task_buffer: std.ArrayList(u8) = .empty;
    defer task_buffer.deinit(allocator);

    const is_piped = !posix.isatty(posix.STDIN_FILENO);
    if (is_piped) {
        const stdin_content = try std.fs.File.stdin().readToEndAlloc(allocator, 1024 * 1024 * 5);
        defer allocator.free(stdin_content);

        if (stdin_content.len > 0) {
            try task_buffer.writer(allocator).print("\n--- Piped Input ---\n{s}\n\n", .{stdin_content});
        }
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--url")) {
            config.url = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--model")) {
            config.model = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--key")) {
            config.api_key = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "ping") or std.mem.eql(u8, arg, "doctor") or std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "help")) {
            management_cmd = arg;
        } else if (arg.len > 1 and std.mem.startsWith(u8, arg, "@")) {
            const file_path = arg[1..];
            if (std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024 * 5)) |content| {
                const safe_content = try truncator.truncate(allocator, content, 3000);
                defer allocator.free(safe_content);
                try task_buffer.writer(allocator).print("\n\n--- File: {s} ---\n{s}\n", .{ file_path, safe_content });
                allocator.free(content);
            } else |err| {
                std.log.warn("Could not read injected file {s}: {any}", .{ file_path, err });
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            try task_buffer.writer(allocator).print("{s} ", .{arg});
        } else {
            std.log.err("Unknown argument or extra command: {s}", .{arg});
            printHelp();
            return error.InvalidArgument;
        }
    }

    // 4. Route the Command
    if (management_cmd) |parsed_cmd| {
        if (std.mem.eql(u8, parsed_cmd, "version")) {
            var stdout_buf: [64]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_writer.interface;
            stdout.print("Sylvia v0.7.0\n", .{}) catch return;
            stdout.flush() catch return;
            return;
        } else if (std.mem.eql(u8, parsed_cmd, "doctor") or std.mem.eql(u8, parsed_cmd, "ping")) {
            std.log.info("Active config:", .{});
            std.log.info("  URL: {s}", .{config.url});
            std.log.info("  Model: {s}", .{config.model});
            std.log.info("  Key: {s}", .{config.api_key orelse "(null)"});

            client.pingProvider(allocator, config) catch |err| {
                std.log.err("Ping failed with error: {any}", .{err});
            };
        } else if (std.mem.eql(u8, parsed_cmd, "help")) {
            printHelp();
        } else {
            std.log.err("Unknown command: {s}", .{parsed_cmd});
            printHelp();
            return error.UnknownCommand;
        }
    } else if (task_buffer.items.len > 0) {
        const task = std.mem.trimRight(u8, task_buffer.items, " ");
        loop.runLoop(allocator, config, task) catch |err| {
            std.log.err("Agent loop crashed: {any}", .{err});
        };
    } else {
        printHelp();
    }
}
