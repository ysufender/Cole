const std = @import("std");
const testing = std.testing;

const common = @import("../core/common.zig");
const Context = @import("../core/context.zig");
const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("../parser/parser.zig");

fn lexSource(io: std.Io, source: []const u8) !struct {
    context: Context,
    tokensPtr: u32,
    tokens: *const Lexer.TokenList.Slice,
} {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "test.jasl", .data = source });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "test.jasl");
    defer testing.allocator.free(path);

    var context = try Context.initForTest(testing.allocator, io, path);
    errdefer context.deinit();

    var lexer = try Lexer.init(testing.allocator, &context, path);
    const tokensPtr = try lexer.lex();

    return .{ .context = context, .tokensPtr = tokensPtr, .tokens = context.getTokens(tokensPtr) };
}

test "lexer: recognizes basic tokens" {
    const io: std.Io = std.testing.io;

    var result = try lexSource(io, "let x: i32 = 1;");
    defer result.context.deinit();

    const types = result.tokens.items(.type);
    try testing.expect(types.len > 0);
    try testing.expectEqual(Lexer.TokenType.Let, types[1]);
    try testing.expectEqual(Lexer.TokenType.Identifier, types[2]);
    try testing.expectEqual(Lexer.TokenType.Colon, types[3]);
}

test "lexer: unterminated string reports the right error, doesn't crash" {
    const io: std.Io = undefined;
    try testing.expectError(
        common.CompilerError.UnterminatedStringLiteral,
        lexSource(io, "let s = \"unterminated;"),
    );
}

test "lexer: unterminated block comment reports the right error" {
    const io: std.Io = undefined;
    try testing.expectError(
        common.CompilerError.UnterminatedComment,
        lexSource(io, "/* never closed"),
    );
}

test "lexer: empty file produces just EOF" {
    const io: std.Io = undefined;
    var result = try lexSource(io, "");
    defer result.context.deinit();

    const types = result.tokens.items(.type);
    try testing.expectEqual(@as(usize, 2), types.len);
    try testing.expectEqual(Lexer.TokenType.EOF, types[1]);
}

test "parser: rejects a program missing a closing brace cleanly" {
    const io: std.Io = undefined;
    var lexed = try lexSource(io, "let main = fn () -> i32 { return 0;");
    defer lexed.context.deinit();

    var parser = try Parser.init(testing.allocator, &lexed.context, lexed.tokensPtr);
    try testing.expectError(common.CompilerError.MissingBrace, parser.parse());
}
