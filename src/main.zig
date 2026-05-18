const std = @import("std");
const loop = @import("agent/loop.zig");
const client = @import("llm/client.zig");
const truncator = @import("memory/truncator.zig");

// The single source of truth for our runtime configuration
pub const Config = struct {
    url: []const u8,
    model: []const u8,
    api_key: ?[]const u8,
    max_context: usize,
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
        \\  --engine <name>  Engine profile (e.g., groq, llama-server)
        \\  --key <key>      API Key (Optional, default: null)
        \\  -y, --yes        Auto-approve all actions. Dangerous!
        \\  --plan           Exit after Phase 1 planning
        \\  --help, -h       Print this help message
        \\
        \\Environment Variables:
        \\  SYLVIA_URL, SYLVIA_MODEL, SYLVIA_API_KEY, SYLVIA_ENGINE
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
        .max_context = 4000,
    };

    if (env_map.get("SYLVIA_URL")) |url| config.url = url;
    if (env_map.get("SYLVIA_MODEL")) |model| config.model = model;
    if (env_map.get("SYLVIA_API_KEY")) |key| config.api_key = key;
    var engine_str: []const u8 = env_map.get("SYLVIA_ENGINE") orelse "";
    if (env_map.get("SYLVIA_MAX_CONTEXT")) |ctx_str| {
        config.max_context = std.fmt.parseInt(usize, ctx_str, 10) catch |err| {
            std.log.err("Invalid SYLVIA_MAX_CONTEXT value '{s}': {any}", .{ ctx_str, err });
            return error.InvalidEnvironment;
        };
    }

    // 3. Parse Command Line Arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // Skip the executable path

    var management_cmd: ?[]const u8 = null;
    var task_buffer: std.ArrayList(u8) = .empty;
    defer task_buffer.deinit(allocator);
    var explicit_url = false;
    var explicit_model = false;
    var plan_only: bool = false;
    var auto_yes: bool = false;

    const is_piped = !std.fs.File.stdin().isTty();
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
            explicit_url = true;
        } else if (std.mem.eql(u8, arg, "--model")) {
            config.model = args.next() orelse return error.MissingArgument;
            explicit_model = true;
        } else if (std.mem.eql(u8, arg, "--engine")) {
            engine_str = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--key")) {
            config.api_key = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--plan")) {
            plan_only = true;
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            auto_yes = true;
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
        } else if (std.mem.eql(u8, arg, "@")) {
            std.log.err("Lone '@' provided. If you meant to inject a file, specify a path (e.g., @src/main.zig).", .{});
            return error.InvalidArgument;
        } else if (arg.len > 0 and arg[0] != '-') {
            try task_buffer.writer(allocator).print("{s} ", .{arg});
        } else {
            std.log.err("Unknown argument or extra command: {s}", .{arg});
            printHelp();
            return error.InvalidArgument;
        }
    }

    if (std.mem.eql(u8, engine_str, "groq")) {
        if (!explicit_url) config.url = "https://api.groq.com/openai/v1";
        if (!explicit_model) config.model = "llama3-70b-8192";
    } else if (std.mem.eql(u8, engine_str, "llama-server")) {
        if (!explicit_url) config.url = "http://127.0.0.1:8080/v1";
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
            std.log.info("  Max Context: {d}", .{config.max_context});
            if (engine_str.len > 0) {
                std.log.info("  Engine: {s}", .{engine_str});
            }

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
        var final_task_str: []const u8 = std.mem.trimRight(u8, task_buffer.items, " ");
        var free_final_task = false;

        var rules_content: ?[]const u8 = std.fs.cwd().readFileAlloc(allocator, ".sylviarules", 1024 * 1024) catch null;
        if (rules_content == null) rules_content = std.fs.cwd().readFileAlloc(allocator, ".cursorrules", 1024 * 1024) catch null;

        if (rules_content) |rc| {
            const safe_rules = try truncator.truncate(allocator, rc, config.max_context);
            final_task_str = try std.fmt.allocPrint(allocator, "REPOSITORY RULES:\n{s}\n\nTASK:\n{s}", .{ safe_rules, final_task_str });
            free_final_task = true;
            allocator.free(safe_rules);
            allocator.free(rc);
        }

        loop.runLoop(allocator, config, final_task_str, plan_only, auto_yes) catch |err| {
            std.log.err("Agent loop crashed: {any}", .{err});
        };

        if (free_final_task) allocator.free(final_task_str);
    } else {
        printHelp();
    }
}

comptime {
    std.testing.refAllDecls(@This());
    _ = @import("agent/loop.zig");
    _ = @import("llm/client.zig");
    _ = @import("llm/parser.zig");
    _ = @import("memory/context.zig");
    _ = @import("memory/truncator.zig");
    _ = @import("tools/fs.zig");
    _ = @import("tools/shell.zig");
    _ = @import("ui/prompt.zig");
    _ = @import("ui/tui.zig");
}
