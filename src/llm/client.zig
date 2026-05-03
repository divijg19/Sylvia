const std = @import("std");
const Context = @import("../memory/context.zig").Context;
const Config = @import("../main.zig").Config;

pub fn pingProvider(allocator: std.mem.Allocator, config: Config) !void {
    std.log.info("Constructing ping request...", .{});

    // 1. Prepare the JSON Payload (OpenAI format)
    const Message = struct {
        role: []const u8,
        content: []const u8,
    };
    const Payload = struct {
        model: []const u8,
        messages: []const Message,
        temperature: f32,
        stream: bool,
    };

    const payload = Payload{
        .model = config.model,
        .messages = &[_]Message{
            .{ .role = "user", .content = "Reply with exactly the word 'pong' and nothing else." },
        },
        .temperature = 0.0, // Force deterministic output
        .stream = false,
    };

    // Zig 0.15.2: The new idiomatic JSON Stringify API
    var out: std.io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(payload, .{}, &out.writer);

    var arr = out.toArrayList();
    defer arr.deinit(allocator);
    const json_payload = arr.items;

    // 2. Format the URL strictly
    const base_url = if (std.mem.endsWith(u8, config.url, "/")) config.url[0 .. config.url.len - 1] else config.url;
    const full_url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
    defer allocator.free(full_url);

    // 3. Setup HTTP Client & Headers
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers = std.http.Client.Request.Headers{
        .content_type = .{ .override = "application/json" },
    };

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |ah| allocator.free(ah);

    if (config.api_key) |key| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        headers.authorization = .{ .override = auth_header.? };
    }

    std.log.info("Sending POST to {s}...", .{full_url});

    // 4. Send the Request using the high-level fetch() API
    var response_out: std.io.Writer.Allocating = .init(allocator);

    // fetch() does start, send, writeAll, finish, and wait in a single command.
    const fetch_result = client.fetch(.{
        .method = .POST,
        .location = .{ .url = full_url },
        .headers = headers,
        .payload = json_payload,
        .response_writer = &response_out.writer,
    }) catch |err| {
        // Guarantee memory cleanup if the network connection fails
        var arr_err = response_out.toArrayList();
        arr_err.deinit(allocator);
        return err;
    };

    // 5. Extract the downloaded response bytes safely
    var response_arr = response_out.toArrayList();
    defer response_arr.deinit(allocator);
    const response_bytes = response_arr.items;

    if (fetch_result.status != .ok) {
        std.log.err("HTTP Error: {d} {s}", .{ @intFromEnum(fetch_result.status), fetch_result.status.phrase() orelse "" });
        return error.HttpRequestFailed;
    }

    // 6. Parse the JSON Response
    const ResponseMessage = struct {
        content: []const u8,
    };
    const Choice = struct {
        message: ResponseMessage,
    };
    const ChatResponse = struct {
        choices: []Choice,
    };

    const parsed = try std.json.parseFromSlice(ChatResponse, allocator, response_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    // Verify & Complete
    if (parsed.value.choices.len > 0) {
        std.log.info("SUCCESS! LLM Replied: {s}", .{parsed.value.choices[0].message.content});
    } else {
        std.log.err("Received successful HTTP response, but no choices in JSON.", .{});
        return error.InvalidJsonResponse;
    }
}

// --- NEW: The Cognitive Loop Fetcher ---
pub fn getChatCompletion(allocator: std.mem.Allocator, config: Config, ctx: *const Context) ![]const u8 {
    const Message = struct {
        role: []const u8,
        content: []const u8,
    };
    const Payload = struct {
        model: []const u8,
        messages: []Message,
        temperature: f32,
        stream: bool,
    };

    // 1. Build the dynamic messages array from the Context Ring-Buffer
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(allocator);

    // System prompt goes first
    try messages.append(allocator, .{ .role = "system", .content = ctx.system_prompt });

    // Add all rolling history
    for (ctx.history.items) |turn| {
        try messages.append(allocator, .{ .role = turn.role, .content = turn.content });
    }

    const payload = Payload{
        .model = config.model,
        .messages = messages.items,
        .temperature = 0.0, // 0.0 prevents hallucinations
        .stream = true,
    };

    // 2. Serialize JSON
    var out: std.io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(payload, .{}, &out.writer);
    var arr = out.toArrayList();
    defer arr.deinit(allocator);
    const json_payload = arr.items;

    // 3. HTTP Setup
    const base_url = if (std.mem.endsWith(u8, config.url, "/")) config.url[0 .. config.url.len - 1] else config.url;
    const full_url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
    defer allocator.free(full_url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers = std.http.Client.Request.Headers{
        .content_type = .{ .override = "application/json" },
    };

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |ah| allocator.free(ah);
    if (config.api_key) |key| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        headers.authorization = .{ .override = auth_header.? };
    }

    // 4. Fetch (streaming) using a custom SseContext writer
    const SseContext = struct {
        allocator: std.mem.Allocator,
        full_response: std.ArrayList(u8),
        line_buffer: std.ArrayList(u8),

        pub const Error = error{OutOfMemory};
        pub const Writer = std.io.GenericWriter(*@This(), Error, writeFn);

        pub fn writer(self: *@This()) Writer {
            return Writer{ .context = self };
        }

        fn writeFn(sctx: *@This(), bytes: []const u8) Error!usize {
            for (bytes) |b| {
                if (b == '\n') {
                    const line = sctx.line_buffer.items;
                    if (line.len != 0 and std.mem.startsWith(u8, line, "data: ")) {
                        const json_str = std.mem.trim(u8, line[6..], " \r");
                        if (!std.mem.eql(u8, json_str, "[DONE]") and json_str.len != 0) {
                            const Delta = struct { content: ?[]const u8 = null };
                            const Choice = struct { delta: Delta = .{} };
                            const SsePayload = struct { choices: []Choice = &[_]Choice{} };

                            const parsed_res = std.json.parseFromSlice(SsePayload, sctx.allocator, json_str, .{ .ignore_unknown_fields = true });
                            if (parsed_res) |parsed| {
                                defer parsed.deinit();
                                if (parsed.value.choices.len > 0) {
                                    if (parsed.value.choices[0].delta.content) |content| {
                                        var stdout_buf: [1024]u8 = undefined;
                                        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
                                        const stdout = &stdout_writer.interface;
                                        const tui = @import("../ui/tui.zig");
                                        stdout.print("{s}{s}{s}", .{ tui.blue, content, tui.reset }) catch {};

                                        for (content) |c| {
                                            try sctx.full_response.append(sctx.allocator, c);
                                        }
                                    }
                                }
                            } else |_| {
                                // ignore parse errors
                            }
                        }
                    }
                    sctx.line_buffer.clearRetainingCapacity();
                } else {
                    sctx.line_buffer.append(sctx.allocator, b) catch return Error.OutOfMemory;
                }
            }
            return bytes.len;
        }
    };

    var sse_ctx = SseContext{
        .allocator = allocator,
        .full_response = .empty,
        .line_buffer = .empty,
    };
    defer sse_ctx.full_response.deinit(allocator);
    defer sse_ctx.line_buffer.deinit(allocator);

    var sse_writer = sse_ctx.writer();
    var sse_buf: [1024]u8 = undefined;
    var adapter = sse_writer.adaptToNewApi(&sse_buf);

    const fetch_result = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = full_url },
        .headers = headers,
        .payload = json_payload,
        .response_writer = &adapter.new_interface,
    });

    if (fetch_result.status != .ok) {
        std.log.err("HTTP Error: {d} {s}", .{ @intFromEnum(fetch_result.status), fetch_result.status.phrase() orelse "" });
        // clean up
        sse_ctx.full_response.deinit(allocator);
        sse_ctx.line_buffer.deinit(allocator);
        return error.HttpRequestFailed;
    }

    // Duplicate the accumulated response
    const result = try allocator.dupe(u8, sse_ctx.full_response.items);
    sse_ctx.full_response.deinit(allocator);
    sse_ctx.line_buffer.deinit(allocator);
    return result;
}
