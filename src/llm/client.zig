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

    // Zig 0.15: Bypass ArrayList entirely and directly allocate the JSON string
    const json_payload = try std.json.stringifyAlloc(allocator, payload, .{});
    defer allocator.free(json_payload);

    // 2. Format the URL strictly (ensure no trailing slash issues)
    const base_url = if (std.mem.endsWith(u8, config.url, "/")) config.url[0 .. config.url.len - 1] else config.url;
    const full_url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
    defer allocator.free(full_url);

    const uri = try std.Uri.parse(full_url);

    // 3. Setup HTTP Client & Headers
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Zero-allocation header array management
    var headers_buffer: [2]std.http.Header = undefined;
    var headers_count: usize = 0;

    headers_buffer[headers_count] = .{ .name = "Content-Type", .value = "application/json" };
    headers_count += 1;

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |ah| allocator.free(ah);

    if (config.api_key) |key| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        headers_buffer[headers_count] = .{ .name = "Authorization", .value = auth_header.? };
        headers_count += 1;
    }

    const headers_slice = headers_buffer[0..headers_count];

    std.log.info("Sending POST to {s}...", .{full_url});

    // 4. Open and Send Request
    var header_buf: [4096]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = headers_slice,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = json_payload.len };
    try req.send();
    try req.writeAll(json_payload);
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        std.log.err("HTTP Error: {d} {s}", .{ @intFromEnum(req.response.status), req.response.status.phrase() orelse "" });
        return error.HttpRequestFailed;
    }

    // 5. Read the Response
    // Zig 0.15: Reads stream directly into a newly allocated string slice
    const response_body = try req.reader().readAllAlloc(allocator, 1024 * 1024 * 10); // Cap at 10MB
    defer allocator.free(response_body);

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

    const parsed = try std.json.parseFromSlice(ChatResponse, allocator, response_body, .{
        .ignore_unknown_fields = true, // Safe guard for unexpected provider metadata
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
