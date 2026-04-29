const std = @import("std");
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
    // strictly tracks memory and reports leaks on shutdown
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

    // Set Default configuration
    var config = Config{
        .url = "http://localhost:11434/v1",
        .model = "qwen2.5-coder:7b",
        .api_key = null,
    };

    // Override with Environment Variables if they exist
    if (env_map.get("SYLVIA_URL")) |url| config.url = url;
    if (env_map.get("SYLVIA_MODEL")) |model| config.model = model;
    if (env_map.get("SYLVIA_API_KEY")) |key| config.api_key = key;

    // 3. Parse Command Line Arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // Skip the first argument (the executable path itself)

    var command: ?[]const u8 = null;

    // Iterate through provided arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--url")) {
            config.url = args.next() orelse {
                std.log.err("Missing value for --url", .{});
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, arg, "--model")) {
            config.model = args.next() orelse {
                std.log.err("Missing value for --model", .{});
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, arg, "--key")) {
            config.api_key = args.next() orelse {
                std.log.err("Missing value for --key", .{});
                return error.MissingArgument;
            };
        } else if (command == null and arg.len > 0 and arg[0] != '-') {
            // First non-flag argument becomes the command
            command = arg;
        } else {
            std.log.err("Unknown argument or extra command: {s}", .{arg});
            printHelp();
            return error.InvalidArgument;
        }
    }

    // 4. Route the Command
    if (command) |cmd| {
        if (std.mem.eql(u8, cmd, "ping")) {
            std.log.info("Executing PING command...", .{});
            std.log.info("Target URL: {s}", .{config.url});
            std.log.info("Model: {s}", .{config.model});
            if (config.api_key) |key| {
                std.log.info("API Key: [Set, length: {d}]", .{key.len});
            } else {
                std.log.info("API Key: [Not Set]", .{});
            }

            // v0.0.3 Network Ping Execution
            client.pingProvider(allocator, config) catch |err| {
                std.log.err("Ping failed with error: {any}", .{err});
            };
        } else if (std.mem.eql(u8, cmd, "run")) {
            std.log.info("Run command not yet implemented. Wait for v0.1.0+", .{});
        } else {
            std.log.err("Unknown command: {s}", .{cmd});
            printHelp();
            return error.UnknownCommand;
        }
    } else {
        // If no command is provided, show help
        printHelp();
    }
}
