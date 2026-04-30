const std = @import("std");
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
    };

    const payload = Payload{
        .model = config.model,
        .messages = &[_]Message{
            .{ .role = "user", .content = "Reply with exactly the word 'pong' and nothing else." },
        },
        .temperature = 0.0, // Force deterministic output
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
