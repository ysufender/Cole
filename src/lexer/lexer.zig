const std = @import("std");
const common = @import("../core/common.zig");
const collections = @import("../util/collections.zig");
const defines = @import("../core/defines.zig");

const assert = std.debug.assert;

pub const TokenList = collections.MultiArrayList(Token);
const Error = common.CompilerError;
const testing = std.testing;

pub const TokenType = enum(u8) {
    LParen, RParen,
    LBrace, RBrace,
    LBracket, RBracket,
    Comma, Dot, Colon, DoubleColon, Semicolon,
    Xor, Tilde, Minus, Plus, Slash, Star,
    Bang, BangEqual,
    Equal, EqualEqual,
    Greater, GreaterEqual,
    Lesser, LesserEqual,
    LeftShift, RightShift,
    Arrow,
    Pipe, Ampersand,
    Import,
    If, Else, While, For,
    Switch,
    Return, Defer,
    Break, Continue,
    Fn, Struct, Let, Enum, Union,
    Code,
    Pub, Mut,
    And, Or, Mark,
    Identifier,
    Modulo,
    String, Integer, Float, False, True, LiteralPrefix,
    Discard,
    Range,
    EOF,
};

pub const Position = struct {
    line: defines.Offset,
    column: defines.Offset,
};

pub const Token = struct {
    type: TokenType,
    start: defines.Offset,
    end: defines.Offset,

    pub const eof = Token{
        .type = .EOF,
        .start = 0,
        .end = 0,
    };

    pub fn toString(token: *const Token, gpa: std.mem.Allocator, context: *const common.CompilerContext, file: defines.FilePtr) []const u8 {
        const string = token.lexeme(context, file);
        const length =  @tagName(token.type).len + string.len + 16;
        const pos = token.position(context, file);
        const buffer = gpa.alloc(u8, length) catch return @errorName(Error.AllocatorFailure);
        return std.fmt.bufPrint(buffer, "<{s}: {s} at ({d}:{d})>", .{
            @tagName(token.type),
            string,
            pos.line,
            pos.column,
        }) catch unreachable;
    }

    pub fn lexeme(token: *const Token, context: *const common.CompilerContext, file: defines.FilePtr) []const u8 {
        assert(token.start <= token.end);

        return context.getFile(file)[token.start..token.end];
    }

    pub fn position(token: *const Token, context: *const common.CompilerContext, file: defines.FilePtr) Position {
        var source = context.getFile(file)[0..token.start];

        var line: defines.Offset = 1;
        while (std.mem.findScalar(u8, source, '\n')) |newline| {
            source = source[(newline + 1)..];
            line += 1;
        }

        const col: defines.Offset = @intCast(source.len + 1);

        return .{
            .line = line,
            .column = col,
        };
    }

    pub fn errIdentifier(token: *const Token, context: *const common.CompilerContext, file: defines.FilePtr) []const u8 {
        const pos = token.position(context, file);

        var source = context.getFile(file);
        var line: defines.Offset = 1;
        const end = while (std.mem.findScalar(u8, source, '\n')) |newLine| {
            if (line == pos.line) {
                break newLine;
            }

            source = source[(newLine + 1)..];
            line += 1;
        } else 0;

        return source[0..end];
    }


    pub fn printLocation(
        token: Token,
        gpa: std.mem.Allocator,
        context: *const common.CompilerContext,
        file: defines.FilePtr,
        pos: Position,
        last: bool
    ) void {
        // TODO: Optimize
        const len = token.end - token.start;

        const errLine = token.errIdentifier(context, file);
        common.log.err("{s}", .{errLine});
        var locationIdentifier: []const u8 = "";
        for (0..pos.column - 1) |_| {
            locationIdentifier = std.fmt.allocPrint(
                gpa,
                "{s} ",
                .{locationIdentifier}
            ) catch "AllocatorFailure";
        }

        var underscore: []const u8 = "";
        for (0..len) |_| {
            underscore = std.fmt.allocPrint(
                gpa,
                "{s}^",
                .{underscore}
            ) catch "^^^^^^^^^^^^^";
        }

        locationIdentifier = std.fmt.allocPrint(
            gpa,
            "{s}{s}",
            .{locationIdentifier, underscore}
        ) catch "AllocatorFailure";
        common.log.err("{s}{s}", .{locationIdentifier, if (last) "\n" else ""});
    }

    pub fn printLocationInfo(
        token: Token,
        gpa: std.mem.Allocator,
        context: *const common.CompilerContext,
        file: defines.FilePtr,
        pos: Position,
        last: bool
    ) void {
        // TODO: Optimize
        const errLine = token.errIdentifier(context, file);
        common.log.info("{s}", .{errLine});
        var locationIdentifier: []const u8 = "";
        for (0..pos.column - 1) |_| {
            locationIdentifier = std.fmt.allocPrint(
                gpa,
                "{s} ",
                .{locationIdentifier}
            ) catch "AllocatorFailure";
        }
        locationIdentifier = std.fmt.allocPrint(
            gpa,
            "{s}^ Here.",
            .{locationIdentifier}
        ) catch "AllocatorFailure";
        common.log.info("{s}{s}", .{locationIdentifier, if (last) "\n" else ""});
    }
};

const Lexer = @This();

const keywords = std.StaticStringMap(TokenType).initComptime(&.{
    .{ "and", .And },
    .{ "or", .Or },
    .{ "if", .If },
    .{ "else", .Else },
    .{ "while", .While },
    .{ "for", .For },
    .{ "fn", .Fn },
    .{ "return", .Return },
    .{ "defer", .Defer },
    .{ "let", .Let },
    .{ "import", .Import },
    .{ "false", .False },
    .{ "true", .True },
    .{ "struct", .Struct },
    .{ "enum", .Enum },
    .{ "union", .Union},
    .{ "pub", .Pub },
    .{ "mut", .Mut },
    .{ "code", .Code },
    .{ "break", .Break },
    .{ "continue", .Continue },
    .{ "switch", .Switch },
    .{ "#", .Mark },
    .{ "_", .Discard },
});

tokens: TokenList,
file: defines.FilePtr,
source: []const u8,

start: defines.Offset,
current: defines.Offset,
end: defines.Offset,

arena: std.heap.ArenaAllocator,
context: *common.CompilerContext,

//
// Public API
//

pub fn init(base: std.mem.Allocator, context: *common.CompilerContext, file: []const u8) common.CompilerError!Lexer {
    const fileHandle = try context.openRead(file);

    const src = context.getFile(fileHandle);
    var arena = std.heap.ArenaAllocator.init(base);
    errdefer arena.deinit();
    var tokens = try TokenList.init(arena.allocator(), src.len + 2);

    tokens.appendAssumeCapacity(.{
        .type = .Identifier,
        .start = fileHandle,
        .end = fileHandle,
    });
    
    var self = Lexer{
        .start = 0,
        .current = 0,
        .end = @intCast(src.len),
        .file = fileHandle,
        .source = src,
        .arena = arena,
        .tokens = tokens,
        .context = context,
    };

    self.skipWhitespace();
    return self;
}

pub fn initFromSource(base: std.mem.Allocator, context: *common.CompilerContext, source: []const u8, name: []const u8) common.CompilerError!Lexer {
    const fileHandle = try context.openSource(source, name);

    var arena = std.heap.ArenaAllocator.init(base);
    errdefer arena.deinit();
    var tokens = try TokenList.init(arena.allocator(), source.len + 2);

    tokens.appendAssumeCapacity(.{
        .type = .Identifier,
        .start = fileHandle,
        .end = fileHandle,
    });
    
    var self = Lexer{
        .start = 0,
        .current = 0,
        .end = @intCast(source.len),
        .file = fileHandle,
        .source = source,
        .arena = arena,
        .tokens = tokens,
        .context = context,
    };

    self.skipWhitespace();
    return self;
}

pub fn lex(self: *Lexer) common.CompilerError!defines.TokenListPtr {
    defer self.arena.deinit();

    while (!self.isAtEnd()) {
        try self.scanToken();
        self.skipWhitespace();
    }

    self.tokens.append(
        self.allocator(),
        .{
            .type = .EOF,
            .start = self.start,
            .end = self.current,
        }
    ) catch return Error.ShouldBeImpossible;

    self.start = 0;
    self.current = 0;

    return self.context.registerTokens(self.tokens.slice());
}

pub fn lexToken(self: *Lexer) common.CompilerError!Token {
    if (self.isAtEnd()) {
        return .{
            .type = .EOF,
            .start = self.end,
            .end = self.end,
        };
    }
    else {
        try self.scanToken();
        assert(self.tokens.len > 0);
        return self.tokens[self.tokens.len - 1];
    }
}

//
// Private Implementation
//

fn scanToken(self: *Lexer) common.CompilerError!void {
    self.start = self.current;

    return blk: switch (self.advance()) {
        '%' => self.addToken(.Modulo),
        '(' => self.addToken(.LParen),
        ')' => self.addToken(.RParen),
        '{' => self.addToken(.LBrace),
        '}' => self.addToken(.RBrace),
        '[' => self.addToken(.LBracket),
        ']' => self.addToken(.RBracket),
        ',' => self.addToken(.Comma),
        '~' => self.addToken(.Tilde),
        '^' => self.addToken(.Xor),
        '.' => 
            if (std.ascii.isDigit(self.peek())) {
                self.report("Dot (.) prefixed numeric literals are not allowed.", .{});
                break :blk Error.DotPrefixedNumericLiteral;
            }
            else if (self.match('.')) self.addToken(.Range) 
            else self.addToken(.Dot),
        ':' =>
            if (self.match(':')) self.addToken(.DoubleColon)
            else self.addToken(.Colon),
        ';' => self.addToken(.Semicolon),
        '-' => 
            if (self.match('>')) self.addToken(.Arrow)
            else self.addToken(.Minus),
        '+' => self.addToken(.Plus),
        '/' => 
            if (self.match('/')) {
                const index =
                    if (std.mem.findScalarPos(u8, self.source, self.current, '\n'))
                        |idx| idx
                    else
                        self.end;

                self.current = @intCast(index);
            }
            else if (self.match('*')) {
                var ident: u32 = 1;

                // Rewrite SIMD
                while (ident > 0 and !self.isAtEnd()) {
                    const ch = self.advance();

                    if (ch == '*' and self.match('/')) {
                        ident -= 1;
                    }
                    else if (ch == '/' and self.match('*')) {
                        ident += 1;
                   }
                }

                if (self.isAtEnd()) {
                    self.report("Unterminated multiline comment", .{});
                    break :blk Error.UnterminatedComment;
                }
            }
            else self.addToken(.Slash),
        '*' => self.addToken(.Star),
        '!' =>
            if (self.match('=')) self.addToken(.BangEqual)
            else self.addToken(.Bang),
        '=' =>
            if (self.match('=')) self.addToken(.EqualEqual)
            else self.addToken(.Equal),
        '>' =>
            if (self.match('=')) self.addToken(.GreaterEqual)
            else if (self.match('>')) self.addToken(.RightShift)
            else self.addToken(.Greater),
        '<' =>
            if (self.match('=')) self.addToken(.LesserEqual)
            else if (self.match('<')) self.addToken(.LeftShift)
            else self.addToken(.Lesser),
        '|' => self.addToken(.Pipe),
        '&' => self.addToken(.Ampersand),
        '\'' => {
            const value = try self.charLiteralValue();

            writeZeroPadded(@constCast(self.source[self.start..self.current]), value);

            try self.addToken(.Integer);
        },
        '"' => {
            const index = index: {
                while (true) {
                    const idx =
                        if (std.mem.findScalarPos(u8, self.source, self.current, '"'))
                            |idx| idx
                        else
                            self.end;

                    if (self.source[idx - 1] == '\\') {
                        self.current = @intCast(idx + 1);
                        continue;
                    }

                    break :index idx;
                }

                unreachable;
            };

            self.current = @intCast(index);

            if (self.isAtEnd()) {
                self.report("Unterminated string literal", .{});
                break :blk Error.UnterminatedStringLiteral;
            }

            self.start += 1;
            try self.addToken(.String);
        },
        '@' => break :blk self.addToken(.LiteralPrefix),
        else => |ch| {
            if (std.ascii.isDigit(ch)) {
                if (ch == '0' and self.peek() == 'x') {
                    _ = self.advance();
                    break :blk self.hexLiteral();
                }

                while (std.ascii.isDigit(self.peek())) {
                    _ = self.advance();
                }

                if (self.check('.') and std.ascii.isDigit(self.peekn(1))) {
                    _ = self.advance();

                    while (std.ascii.isDigit(self.peek())) {
                        _ = self.advance();
                    }

                    break :blk self.addToken(.Float);
                }

                break :blk self.addToken(.Integer);
            }
            else if (std.ascii.isAlphabetic(ch) or ch == '_' or ch == '#') {
                while (
                    std.ascii.isAlphanumeric(self.peek())
                    or self.peek() == '_' or self.peek() == '#'
                ) {
                    _ = self.advance();
                }

                const str = self.source[self.start..self.current];
                break :blk self.addToken(getType(str));
            }
            else {
                self.report("Unexpected character '{c}'", .{ch});
                return Error.UnexpectedCharacter;
            }
        }
    };
}

//
// Helpers
//

fn allocator(self: *Lexer) std.mem.Allocator {
    return self.arena.allocator();
}

fn hexLiteral(self: *Lexer) common.CompilerError!void {
    const digitStart = self.current;
    while (std.ascii.isHex(self.peek())) {
        _ = self.advance();
    }

    if (self.current == digitStart) {
        self.report("Expected hex digits after '0x'.", .{});
        return Error.UnexpectedCharacter;
    }

    if (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
        self.report("Invalid character '{c}' in hex literal.", .{self.peek()});
        return Error.UnexpectedCharacter;
    }

    return self.addToken(.Integer);
}

fn charLiteralValue(self: *Lexer) common.CompilerError!u8 {
    if (self.isAtEnd()) {
        self.report("Unterminated character literal", .{});
        return Error.UnexpectedCharacter;
    }

    const first = self.advance();
    const value: u8 = switch (first) {
        '\'' => {
            self.report("Empty character literals are not allowed.", .{});
            return Error.EmptyCharLiteral;
        },
        '\\' => try self.escapeValue(),
        else => first,
    };

    _ = try self.consume('\'', "Expected closing single quote (')");
    return value;
}

fn escapeValue(self: *Lexer) common.CompilerError!u8 {
    if (self.isAtEnd()) {
        self.report("Unterminated escape sequence", .{});
        return Error.UnexpectedCharacter;
    }

    return switch (self.advance()) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '0' => 0,
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        'x' => {
            const hi = try self.hexDigit();
            const lo = try self.hexDigit();
            return (hi << 4) | lo;
        },
        else => |c| {
            self.report("Unknown escape sequence '\\{c}'", .{c});
            return Error.UnexpectedCharacter;
        },
    };
}

fn hexDigit(self: *Lexer) common.CompilerError!u8 {
    const digit = std.fmt.charToDigit(self.peek(), 16) catch {
        self.report("Expected a hex digit in '\\x' escape", .{});
        return Error.UnexpectedCharacter;
    };
    _ = self.advance();
    return digit;
}

fn writeZeroPadded(dst: []u8, value: u8) void {
    assert(dst.len >= 3);
    @memset(dst, '0');

    var v = value;
    var i = dst.len;
    while (v != 0) : (v /= 10) {
        i -= 1;
        dst[i] = '0' + v % 10;
    }
}

fn skipWhitespace(self: *Lexer) void {
    const index =
        if(std.mem.indexOfNonePos(u8, self.source, self.current, " \n\t\r")) |idx|
            idx
        else
            self.end;

    self.current = @intCast(index);
}

fn check(self: *const Lexer, expected: u8) bool {
    return
        if (self.isAtEnd()) false
        else self.source[self.current] == expected;
}

fn match(self: *Lexer, expected: u8) bool {
    if (self.isAtEnd()) return false;
    if (self.source[self.current] != expected) return false;

    _ = self.advance();
    return true;
}

fn previous(self: *const Lexer) u8 {
    assert(self.current > 0);
    return self.source[self.current-1];
}

fn peek(self: *const Lexer) u8 {
    return
        if (self.isAtEnd()) 0
        else self.source[self.current];
}

fn peekn(self: *const Lexer, n: u32) u8 {
    assert(self.current + n < self.source.len);
    return self.source[self.current + n];
}

fn advance(self: *Lexer) u8 {
    defer self.current += 1;
    return self.source[self.current];
}

fn consume(self: *Lexer, expected: u8, message: []const u8) common.CompilerError!u8 {
    if (self.peek() == expected) return self.advance();

    self.report("{s}\n\tExpected '{c}' got '{c}'", .{message, expected, self.peek()});
    return Error.UnexpectedCharacter;
}

fn addToken(self: *Lexer, tokenType: TokenType) common.CompilerError!void {
    self.tokens.append(self.allocator(), .{
        .type = tokenType,
        .start = self.start,
        .end = self.current,
    }) catch return Error.InvalidToken;

    if (tokenType == .String)
        _ = self.advance();
}

fn isAtEnd(self: *const Lexer) bool {
    return self.current >= self.end;
}

fn getType(str: []const u8) TokenType {
    return
        if (keywords.get(str)) |keyword| keyword 
        else .Identifier;
}

fn report(self: *Lexer, comptime fmt: []const u8, args: anytype) void {
    const errToken = Token {
        .type = .EOF,
        .start = self.start,
        .end = self.start + 1,
    };
    const pos = errToken.position(self.context, self.file);

    common.log.err(fmt, args);
    common.log.err("...." ++ " In {s} {d}:{d}", .{self.context.getFileName(self.file), pos.line, pos.column});
    errToken.printLocation(self.allocator(), self.context, self.file, pos, true);
}

//============================
// Test
//============================

fn create_test_context(testing_allocator: std.mem.Allocator, testing_io: std.Io, args: []const [*:0]const u8, arena: *std.heap.ArenaAllocator, env_map: *std.process.Environ.Map) !common.CompilerContext {
    const _mock_init: std.process.Init = .{
        .minimal = .{
            .args = .{ .vector = args },
            .environ = undefined,
        },
        .gpa = testing_allocator,
        .arena = arena,
        .io = testing_io,
        .environ_map = env_map,
        .preopens = undefined,
    };
    return common.CompilerContext.init(testing.allocator, _mock_init);
}

const TestEnv = struct {
    arena: std.heap.ArenaAllocator,
    env_map: std.process.Environ.Map,
    context: common.CompilerContext,

    const fake_args: []const [*:0]const u8 = &.{ "cole", "test.cole" };

    fn init(self: *TestEnv) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena.deinit();
        self.env_map = std.process.Environ.Map.init(testing.allocator);
        errdefer self.env_map.deinit();
        self.context = try create_test_context(testing.allocator, testing.io, fake_args, &self.arena, &self.env_map);
    }

    fn deinit(self: *TestEnv) void {
        self.arena.deinit();
        self.env_map.deinit();
        self.context.deinit();
    }
};


test "TC_01: [Lexeme]" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const ptrr = try env.context.openSource("let a = 43;", "test.cole");
    const let_token = Token{ .type = .Let, .start = 0, .end = 3 };
    const a_token = Token{ .type = .Identifier, .start = 4, .end = 5 };
    const eq_token = Token{ .type = .Identifier, .start = 6, .end = 7 };
    const int_token = Token{ .type = .Integer, .start = 8, .end = 10 };
    const semicolon_token = Token{ .type = .Semicolon, .start = 10, .end = 11 };
    try testing.expectEqualStrings("let", let_token.lexeme(&env.context, ptrr));
    try testing.expectEqualStrings("a", a_token.lexeme(&env.context, ptrr));
    try testing.expectEqualStrings("=", eq_token.lexeme(&env.context, ptrr));
    try testing.expectEqualStrings("43", int_token.lexeme(&env.context, ptrr));
    try testing.expectEqualStrings(";", semicolon_token.lexeme(&env.context, ptrr));
}


test "TC_02: [Lexeme]" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const ptrr = try env.context.openSource("let a = 32;", "test.cole");
    // env.context.tokenMap
    const let_token = Token{ .type = .Let, .start = 0, .end = 3 };
    const a_token = Token{ .type = .Identifier, .start = 4, .end = 5 };
    const eq_token = Token{ .type = .Identifier, .start = 6, .end = 7 };
    const int_token = Token{ .type = .Integer, .start = 8, .end = 10 };
    const semicolon_token = Token{ .type = .Semicolon, .start = 10, .end = 11 };
    try testing.expectEqualStrings("let", let_token.lexeme(&env.context, ptrr));
    try testing.expectEqualStrings("a", a_token.lexeme(&env.context, ptrr));
    try testing.expectEqualStrings("=", eq_token.lexeme(&env.context, ptrr));
    try testing.expectEqualStrings("32", int_token.lexeme(&env.context, ptrr));
    try testing.expectEqualStrings(";", semicolon_token.lexeme(&env.context, ptrr));
}


test "TC_03: [Position]" {
    // Source with just one line
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const filePtr = try env.context.openSource("let a = 32;", "test.cole");
    const let_token = Token{ .type = .Let, .start = 0, .end = 3 };
    const let_pos = let_token.position(&env.context, filePtr);

    try testing.expectEqualStrings("let", let_token.lexeme(&env.context, filePtr));
    try testing.expectEqual(1, let_pos.line);
    try testing.expectEqual(1, let_pos.column);
}


test "TC_04: [Position]" {
    // 2 source line with line break and a space
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const filePtr = try env.context.openSource("let a = 32;\n let b = 33", "test.cole");
    // expected for first let
    const let_token = Token{ .type = .Let, .start = 0, .end = 3 };
    const let_2_token = Token{ .type = .Let, .start = 13, .end = 16 };
    const let_pos = let_token.position(&env.context, filePtr);
    const let_2_pos = let_2_token.position(&env.context, filePtr);

    // first let
    try testing.expectEqualStrings("let", let_token.lexeme(&env.context, filePtr));
    try testing.expectEqual(1, let_pos.line);
    try testing.expectEqual(1, let_pos.column);

    // second let
    try testing.expectEqualStrings("let", let_2_token.lexeme(&env.context, filePtr));
    try testing.expectEqual(2, let_2_pos.line);
    try testing.expectEqual(2, let_2_pos.column);
}


test "TC_05: [Position]" {
    // 2 source line with line break and a space and a tab
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const filePtr = try env.context.openSource("let a = 32;\n \tlet b = 33", "test.cole");
    // expected for first let
    const let_token = Token{ .type = .Let, .start = 0, .end = 3 };
    const let_2_token = Token{ .type = .Let, .start = 14, .end = 17 };
    const let_pos = let_token.position(&env.context, filePtr);
    const let_2_pos = let_2_token.position(&env.context, filePtr);
    // first let
    try testing.expectEqualStrings("let", let_token.lexeme(&env.context, filePtr));
    try testing.expectEqual(1, let_pos.line);
    try testing.expectEqual(1, let_pos.column);
    // second let
    try testing.expectEqualStrings("let", let_2_token.lexeme(&env.context, filePtr));
    try testing.expectEqual(2, let_2_pos.line);
    try testing.expectEqual(3, let_2_pos.column);
}


test "TC_06: [Position]" {
    // line with multiple breaks
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const filePtr = try env.context.openSource("\n;\t\n \twhile", "test.cole");
    const while_token = Token{ .type = .While, .start = 6, .end = 11 };
    const while_pos = while_token.position(&env.context, filePtr);

    try testing.expectEqualStrings("while", while_token.lexeme(&env.context, filePtr));
    try testing.expectEqual(3, while_pos.line);
    try testing.expectEqual(3, while_pos.column);
}


test "TC_07: [Position]" {
    // checking for UTF-8 byte comment
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // 😀 is 4 bytes each
    const filePtr = try env.context.openSource("/*(😀😀)*/ \nlet", "test.cole");
    const _token = Token{ .type = .Let, .start = 16, .end = 19 };
    const _pos = _token.position(&env.context, filePtr);

    try testing.expectEqualStrings("let", _token.lexeme(&env.context, filePtr));
    try testing.expectEqual(2, _pos.line);
    try testing.expectEqual(1, _pos.column);
}


test "TC_08: [errIdentifier]" {
    // Depends on the location of token
    // in this token from 0 to 6 on very first \n
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const filePtr = try env.context.openSource("hello\nworld", "test.cole");
    const _token = Token{ .type = .Mark, .start = 0, .end = 6 };
    try testing.expectEqualStrings("hello", _token.errIdentifier(&env.context, filePtr));
}


test "TC_09: [errIdentifier]" {
    // random  token from 25 to 27 on 2nd \n
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const filePtr = try env.context.openSource("let a: any = i32(999);\n let b:any = i32(992); \n", "test.cole");
    // just a random token
    const _token = Token{ .type = .Let, .start = 24, .end = 27 };
    try testing.expectEqualStrings(" let b:any = i32(992); ", _token.errIdentifier(&env.context, filePtr));
}


test "TC_10: [errIdentifier]" {
    // Last line of source with no newline (\n)
    // fixed a bug in errIdentifier for the last line
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const filePtr = try env.context.openSource("let a: any = i32(999);\n let b:any = i32(992); ", "test.cole");
    // just a random token
    const _token = Token{ .type = .Let, .start = 24, .end = 27 };
    try testing.expectEqualStrings(" let b:any = i32(992); ", _token.errIdentifier(&env.context, filePtr));
}


test "TC_11: [toString]" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    

    const filePtr = try env.context.openSource("let a = i32(999);\nlet b = i32(992);", "test.cole");
    const tok1 = Token{ .type = .Let, .start = 0, .end = 3 };
    const ret1 = tok1.toString(env.arena.allocator(), &env.context, filePtr);
    try std.testing.expectEqualStrings("<Let: let at (1:1)>", ret1);

    const tok2 = Token{ .type = .Identifier, .start = 22, .end = 23 };
    const ret2 = tok2.toString(env.arena.allocator(), &env.context, filePtr);
    try std.testing.expectEqualStrings("<Identifier: b at (2:5)>", ret2);
}


test "TC_12: [toString]" {
    // what if char is at 10000th line
    // trying to overflow the buffer as it has a fixed length
    // BUFFER no space left 
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // Build a string with 1000 lines
    var source = try std.ArrayList(u8).initCapacity(testing.allocator, 10000);
    try source.appendNTimes(testing.allocator, '\n', 9999);
    try source.appendSlice(testing.allocator,"let x = 42;");
    defer source.deinit(testing.allocator);
    
    const filePtr = try env.context.openSource(source.items, "test.cole");
    const tok1 = Token{ .type = .Let, .start = 9999, .end = 10003 };
    const ret1 = tok1.toString(env.arena.allocator(), &env.context, filePtr);
    try std.testing.expectEqualStrings("<Let: let at (10000:1)>", ret1);
}