const std = @import("std");
const loop = @import("agent/loop.zig");
const client = @import("llm/client.zig");

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
        \\Usage: sylvia [command] [options]
        \\
        \\Commands:
        \\  ping       Test the connection to the LLM endpoint (v0.0.3)
        \\  run        Run the agentic loop (v0.1.0+)
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

    var command: ?[]const u8 = null;
    var task_string: ?[]const u8 = null;
    var injected_files: std.ArrayList(u8) = .empty;
    defer injected_files.deinit(allocator);

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
        } else if (command == null and arg.len > 0 and arg[0] != '-') {
            command = arg;

            // If the command is 'run', the very next argument must be our task string.
            if (std.mem.eql(u8, arg, "run")) {
                task_string = args.next();
            }
        } else if (command != null and std.mem.eql(u8, command.?, "run") and task_string != null) {
            if (std.mem.startsWith(u8, arg, "@")) {
                const file_path = arg[1..];
                if (std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024 * 5)) |content| {
                    try injected_files.writer(allocator).print("\n\n--- File: {s} ---\n{s}\n", .{ file_path, content });
                    allocator.free(content);
                } else |err| {
                    std.log.warn("Could not read injected file {s}: {any}", .{ file_path, err });
                }
            } else {
                std.log.err("Unknown argument or extra command: {s}", .{arg});
                printHelp();
                return error.InvalidArgument;
            }
        } else {
            std.log.err("Unknown argument or extra command: {s}", .{arg});
            printHelp();
            return error.InvalidArgument;
        }
    }

    // 4. Route the Command
    if (command) |parsed_cmd| {
        if (std.mem.eql(u8, parsed_cmd, "ping")) {
            std.log.info("Executing PING command...", .{});
            std.log.info("Target URL: {s}", .{config.url});
            std.log.info("Model: {s}", .{config.model});

            client.pingProvider(allocator, config) catch |err| {
                std.log.err("Ping failed with error: {any}", .{err});
            };
        } else if (std.mem.eql(u8, parsed_cmd, "run")) {
            // Check if the task string was successfully captured
            if (task_string) |task| {
                if (injected_files.items.len > 0) {
                    const final_task = try std.fmt.allocPrint(allocator, "{s}{s}", .{ task, injected_files.items });
                    defer allocator.free(final_task);

                    loop.runLoop(allocator, config, final_task) catch |err| {
                        std.log.err("Agent loop crashed: {any}", .{err});
                    };
                } else {
                    loop.runLoop(allocator, config, task) catch |err| {
                        std.log.err("Agent loop crashed: {any}", .{err});
                    };
                }
            } else {
                std.log.err("Missing task. Example: sylvia run \"list files in src\"", .{});
                return error.MissingArgument;
            }
        } else {
            std.log.err("Unknown command: {s}", .{parsed_cmd});
            printHelp();
            return error.UnknownCommand;
        }
    } else {
        printHelp();
    }
}
