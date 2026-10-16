const std = @import("std");

pub fn parseToolArgsObject(alloc: std.mem.Allocator, args_json: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, args_json, .{});
    // The returned object map is backed by the parse allocation; callers should
    // use an arena or allocator lifetime that outlives all borrowed values.
    if (parsed.value != .object) return error.InvalidToolArguments;
    return parsed.value.object;
}

pub fn normalizeCompositeObjectValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
) !void {
    if (value.* != .string) return;
    const decoded = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        value.string,
        .{ .allocate = .alloc_always },
    );
    if (decoded != .object) return error.InvalidCompositeArgument;
    value.* = decoded;
}

/// Errors a caller reports when a string-encoded argument object cannot be
/// read. Every defect other than a raw control character lands here.
pub const EncodedObjectError = error{ OutOfMemory, InvalidEncodedObject };

/// Parses one JSON object that a model serialized into a string, such as a
/// shell call's `request`. A literal control character inside that text is
/// escaped and the parse retried once: models put multi-line commands there,
/// and a raw newline is the one defect that carries no ambiguity, so the text
/// is repaired instead of rejecting the whole call. Every other defect,
/// including a duplicate key, still fails.
pub fn parseEncodedJsonObject(
    alloc: std.mem.Allocator,
    text: []const u8,
) EncodedObjectError!std.json.ObjectMap {
    if (parseJsonObjectValue(alloc, text)) |object| return object else |_| {}
    const escaped = try escapeRawControlCharacters(alloc, text);
    defer alloc.free(escaped);
    return parseJsonObjectValue(alloc, escaped) catch error.InvalidEncodedObject;
}

fn parseJsonObjectValue(
    alloc: std.mem.Allocator,
    text: []const u8,
) EncodedObjectError!std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidEncodedObject,
    };
    if (value != .object) return error.InvalidEncodedObject;
    return value.object;
}

/// Copies JSON text with every raw control character inside a string literal
/// written as its escape. Text outside strings is copied unchanged, so text
/// that is already valid parses to the same value.
fn escapeRawControlCharacters(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const hex = "0123456789abcdef";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var in_string = false;
    var escaped = false;
    for (text) |byte| {
        if (!in_string) {
            if (byte == '"') in_string = true;
            try out.append(alloc, byte);
            continue;
        }
        if (escaped) {
            escaped = false;
        } else if (byte == '\\') {
            escaped = true;
        } else if (byte == '"') {
            in_string = false;
        } else if (byte < 0x20) {
            if (byte == '\n') {
                try out.appendSlice(alloc, "\\n");
                continue;
            }
            if (byte == '\r') {
                try out.appendSlice(alloc, "\\r");
                continue;
            }
            if (byte == '\t') {
                try out.appendSlice(alloc, "\\t");
                continue;
            }
            try out.appendSlice(alloc, "\\u00");
            try out.append(alloc, hex[byte >> 4]);
            try out.append(alloc, hex[byte & 0xf]);
            continue;
        }
        try out.append(alloc, byte);
    }
    return try out.toOwnedSlice(alloc);
}

pub fn requiredStringArg(args: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = args.get(key) orelse return error.InvalidToolArguments;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

pub fn optionalStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = args.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

/// Tool schemas that require every field tell the model to send null for the
/// fields its selected action does not use. Models routinely serialize that null
/// as the literal text "null", so readers treat it as the absence it expresses.
pub fn isNullPlaceholderText(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, &std.ascii.whitespace), "null");
}

/// Reads an optional string argument from a schema whose unused fields arrive as
/// nulls, so textual null placeholders read as absent instead of as a value.
pub fn nullablePlaceholderStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const text = optionalStringArg(args, key) orelse return null;
    if (isNullPlaceholderText(text)) return null;
    return text;
}

pub fn optionalBoolArg(args: std.json.ObjectMap, key: []const u8) ?bool {
    const value = args.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

pub fn optionalIntArg(args: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = args.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

test "parseToolArgsObject parses object roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"path\":\"src/main.zig\"}");

    try std.testing.expectEqualStrings("src/main.zig", args.get("path").?.string);
}

test "parseToolArgsObject rejects non-object roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.InvalidToolArguments, parseToolArgsObject(arena, "[]"));
}

test "requiredStringArg rejects missing and wrong-type values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"path\":\"src/main.zig\",\"count\":3}");

    try std.testing.expectEqualStrings("src/main.zig", try requiredStringArg(args, "path"));
    try std.testing.expectError(error.InvalidToolArguments, requiredStringArg(args, "missing"));
    try std.testing.expectError(error.InvalidToolArguments, requiredStringArg(args, "count"));
}

test "optional typed args return payloads only for matching tags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"name\":\"fx\",\"enabled\":true,\"count\":3,\"other\":1.25}");

    try std.testing.expectEqualStrings("fx", optionalStringArg(args, "name").?);
    try std.testing.expect(optionalStringArg(args, "missing") == null);
    try std.testing.expect(optionalStringArg(args, "enabled") == null);

    try std.testing.expectEqual(true, optionalBoolArg(args, "enabled").?);
    try std.testing.expect(optionalBoolArg(args, "missing") == null);
    try std.testing.expect(optionalBoolArg(args, "name") == null);

    try std.testing.expectEqual(@as(i64, 3), optionalIntArg(args, "count").?);
    try std.testing.expect(optionalIntArg(args, "missing") == null);
    try std.testing.expect(optionalIntArg(args, "other") == null);
}

test "encoded object parsing repairs raw control characters only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A multi-line command the model left as a literal newline inside the
    // string-encoded request.
    const multiline =
        "{\"action\":\"run\",\"command\":\"git commit -F - <<'EOF'\n" ++
        "fix(shell): keep the request envelope\n\n- decode the repair\nEOF\"}";
    const repaired = try parseEncodedJsonObject(arena, multiline);
    try std.testing.expectEqualStrings("run", repaired.get("action").?.string);
    try std.testing.expect(std.mem.indexOfScalar(u8, repaired.get("command").?.string, '\n') != null);

    // Already-valid text parses unchanged.
    const valid = try parseEncodedJsonObject(arena, "{\"action\":\"run\",\"command\":\"pwd\"}");
    try std.testing.expectEqualStrings("pwd", valid.get("command").?.string);

    // Defects that carry ambiguity still fail. A wrong value type is not one:
    // it parses as an object here and the tool's typed decode reports it.
    try std.testing.expectError(
        error.InvalidEncodedObject,
        parseEncodedJsonObject(arena, "{\"action\":\"run\",\"command\":\"pwd\",\"command\":\"true\"}"),
    );
    try std.testing.expectError(
        error.InvalidEncodedObject,
        parseEncodedJsonObject(arena, "[]"),
    );
    try std.testing.expectError(
        error.InvalidEncodedObject,
        parseEncodedJsonObject(arena, "{\"action\":\"run\",\"command\",\"command\":\"pwd\"}"),
    );
    // An escaped backslash before a quote stays one escape, so the string ends.
    const escaped = try parseEncodedJsonObject(arena, "{\"action\":\"run\",\"command\":\"echo \\\"hi\\\"\"}");
    try std.testing.expectEqualStrings("echo \"hi\"", escaped.get("command").?.string);
}

test "null placeholder reads treat textual nulls as absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(
        arena,
        "{\"cwd\":\"null\",\"profile\":\" NULL \",\"shell\":null,\"command\":\"echo null\",\"dir\":\"nullify\"}",
    );

    try std.testing.expect(nullablePlaceholderStringArg(args, "cwd") == null);
    try std.testing.expect(nullablePlaceholderStringArg(args, "profile") == null);
    try std.testing.expect(nullablePlaceholderStringArg(args, "shell") == null);
    try std.testing.expect(nullablePlaceholderStringArg(args, "missing") == null);
    try std.testing.expectEqualStrings("echo null", nullablePlaceholderStringArg(args, "command").?);
    try std.testing.expectEqualStrings("nullify", nullablePlaceholderStringArg(args, "dir").?);
    try std.testing.expectEqualStrings("null", optionalStringArg(args, "cwd").?);
}

test "composite object normalization preserves objects and decodes JSON strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var object = std.json.Value{ .object = try parseToolArgsObject(
        arena,
        "{\"kind\":\"executable\",\"path\":\"/bin/bash\"}",
    ) };
    try normalizeCompositeObjectValue(arena, &object);
    try std.testing.expectEqualStrings("/bin/bash", object.object.get("path").?.string);

    var encoded = std.json.Value{ .string = "{\"kind\":\"executable\",\"path\":\"/bin/zsh\"}" };
    try normalizeCompositeObjectValue(arena, &encoded);
    try std.testing.expectEqualStrings("/bin/zsh", encoded.object.get("path").?.string);

    var invalid = std.json.Value{ .string = "[]" };
    try std.testing.expectError(
        error.InvalidCompositeArgument,
        normalizeCompositeObjectValue(arena, &invalid),
    );
}
