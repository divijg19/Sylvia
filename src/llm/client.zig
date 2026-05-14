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
        max_tokens: usize,
    };

    const payload = Payload{
        .model = config.model,
        .messages = &[_]Message{
            .{ .role = "user", .content = "Reply with exactly the word 'pong' and nothing else." },
        },
        .temperature = 0.0, // Force deterministic output
        .stream = false,
        .max_tokens = 4096,
    };

    // Zig 0.15.2: The new idiomatic JSON Stringify API
    var out: std.io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(payload, .{}, &out.writer);

    var arr = out.toArrayList();
    defer arr.deinit(allocator);
    const json_payload = arr.items;

    // 2. Format the URL strictly
    var base_url = config.url;
    if (std.mem.endsWith(u8, base_url, "/")) base_url = base_url[0 .. base_url.len - 1];
    const full_url = if (std.mem.endsWith(u8, base_url, "/chat/completions"))
        try allocator.dupe(u8, base_url)
    else
        try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
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
        max_tokens: usize,
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
        .max_tokens = 4096,
    };

    // 2. Serialize JSON
    var out: std.io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(payload, .{}, &out.writer);
    var arr = out.toArrayList();
    defer arr.deinit(allocator);
    const json_payload = arr.items;

    // 3. HTTP Setup
    var base_url = config.url;
    if (std.mem.endsWith(u8, base_url, "/")) base_url = base_url[0 .. base_url.len - 1];
    const full_url = if (std.mem.endsWith(u8, base_url, "/chat/completions"))
        try allocator.dupe(u8, base_url)
    else
        try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
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

    // 4. Perform low-level request and stream the response manually to avoid writer adapter issues
    const uri = try std.Uri.parse(full_url);

    var req = try client.request(.POST, uri, .{ .headers = headers });
    defer req.deinit();

    // Send the request body (use same pattern as fetch)
    if (json_payload.len != 0) {
        req.transfer_encoding = .{ .content_length = json_payload.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(json_payload);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    // Allocate redirect buffer and receive response head
    const redirect_buffer = try client.allocator.alloc(u8, 8 * 1024);
    defer client.allocator.free(redirect_buffer);
    var response = try req.receiveHead(redirect_buffer);

    // Prepare decompress buffer if needed (reuse logic from fetch)
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    var free_decompress: bool = true;
    if (decompress_buffer.len == 0) free_decompress = false;
    defer if (free_decompress) client.allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var full_response: std.ArrayList(u8) = .empty;
    defer full_response.deinit(allocator);
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        var chunk_writer = std.io.Writer.fixed(&buf);
        const bytes_read = try reader.stream(&chunk_writer, .limited(buf.len));
        if (bytes_read == 0) break;

        const chunk = chunk_writer.buffered()[0..bytes_read];

        var i: usize = 0;
        while (i < bytes_read) : (i += 1) {
            const b = chunk[i];
            if (b != '\n') {
                try line_buffer.append(allocator, b);
            } else {
                const line = line_buffer.items;
                if (line.len != 0 and std.mem.startsWith(u8, line, "data: ")) {
                    const json_str = std.mem.trim(u8, line[6..], " \r");
                    if (!std.mem.eql(u8, json_str, "[DONE]") and json_str.len != 0) {
                        const Delta = struct { content: ?[]const u8 = null };
                        const Choice = struct { delta: Delta = .{} };
                        const SsePayload = struct { choices: []Choice = &[_]Choice{} };

                        const parsed_res = std.json.parseFromSlice(SsePayload, allocator, json_str, .{ .ignore_unknown_fields = true });
                        if (parsed_res) |parsed| {
                            defer parsed.deinit();
                            if (parsed.value.choices.len > 0) {
                                if (parsed.value.choices[0].delta.content) |content| {
                                    // Print token-by-token to stdout (no newline)
                                    const tui = @import("../ui/tui.zig");
                                    var stdout_buf: [1024]u8 = undefined;
                                    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
                                    const stdout = &stdout_writer.interface;
                                    stdout.print("{s}{s}{s}", .{ tui.blue, content, tui.reset }) catch {};

                                    for (content) |c| {
                                        try full_response.append(allocator, c);
                                    }
                                }
                            }
                        } else |_| {
                            // ignore parse errors silently
                        }
                    }
                }
                line_buffer.clearRetainingCapacity();
            }
        }
    }

    return allocator.dupe(u8, full_response.items);
}
