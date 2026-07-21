// TODO: remove all temp arraylists, use scratch

const std = @import("std");
const common = @import("../core/common.zig");
const Lexer = @import("../lexer/lexer.zig");
const collections = @import("../util/collections.zig");
const defines = @import("../core/defines.zig");

const Error = common.CompilerError;
const Allocator = std.mem.Allocator;
const ExpressionResult = Error!defines.ExpressionPtr;

pub const StatementResult = Error!defines.StatementPtr;

pub const VariableSignatureMap = collections.MultiArrayList(VariableSignature);
pub const ExpressionMap = collections.MultiArrayList(Expression);
pub const StatementMap = collections.MultiArrayList(Statement);

const assert = std.debug.assert;

pub const AnyType = 0;

// Because manually tagged unions are more
// performant with collections.MultiArrayList(T)
pub const Expression = struct {
    pub const Type = enum {
        Assignment,
        Binary,
        Literal,
        Indexing,
        Slicing,
        Identifier,
        Unary,
        StructDefinition,
        EnumDefinition,
        UnionDefinition,
        FunctionDefinition,
        Mark,
        Lambda,
        Call,
        Conditional,
        Switch,
        MutableType,
        CPointerType,
        PointerType,
        SliceType,
        ArrayType,
        FunctionType,
        Scoping,
        ExpressionList,
        Dot,
    };

    type: Type,
    value: defines.OpaquePtr,
};

// Because manually tagged unions are more
// performant with collections.MultiArrayList(T)
pub const Statement = struct {
    pub const Type = enum {
        Block,
        InlineAssembly,
        Return,
        Conditional,
        Switch,
        While,
        For,
        Break,
        Continue,
        VariableDefinition,
        Discard,
        Import,
        Expression,
        Defer,
    };

    type: Type,
    value: defines.OpaquePtr,
};

pub const VariableSignature = struct {
    public: bool,
    name: defines.TokenPtr,
    type: defines.ExpressionPtr,
};

pub const AST = struct {
    tokens: defines.TokenPtr,
    expressions: ExpressionMap.Slice,
    statements: StatementMap.Slice,
    signatures: VariableSignatureMap.Slice,
    statementMask: std.ArrayList(defines.StatementPtr).Slice,
    extra: std.ArrayList(defines.OpaquePtr).Slice,
    stats: Stats,

    pub fn eql(self: *const AST, other: *const AST) bool {
        return
            self.tokens == other.tokens
            and self.expressions.eql(&other.expressions)
            and self.statements.eql(&other.statements)
            and self.signatures.eql(&other.signatures)
            and std.mem.eql(defines.StatementPtr, self.statementMask, other.statementMask)
            and std.mem.eql(defines.OpaquePtr, self.extra, other.extra);
    }

    pub fn print(self: *const AST, context: *common.CompilerContext) void {
        const tokens = context.getTokens(self.tokens);
        const file = tokens.items(.start)[0];
        common.log.debug("\nTokens ({d}):    ", .{tokens.len});
        var titerator = tokens.iterator();
        var i: u32 = 0;
        while (titerator.next()) |token| {
            defer i += 1;
            if (i >= 16) {
                break;
            }
            common.log.debug("({d} {s}) ", .{titerator.idx - 1, @tagName(token.type)});
        }
        common.log.debug("\nExpressions ({d}):", .{self.expressions.len});
        var eiterator = self.expressions.iterator();
        i = 0;
        while (eiterator.next()) |expr| {
            defer i += 1;
            if (i >= 16) {
                break;
            }
            common.log.debug("({s} {d}) ", .{@tagName(expr.type), expr.value});
        }
        common.log.debug("\nStatements ({d}):", .{self.statements.len});
        var siterator = self.statements.iterator();
        i = 0;
        while (siterator.next()) |stmt| {
            defer i += 1;
            if (i >= 16) {
                break;
            }
            common.log.debug("({s} {d}) ", .{@tagName(stmt.type), stmt.value});
        }
        common.log.debug("\nSignatures ({d}):", .{self.signatures.len});
        var viterator = self.signatures.iterator();
        i = 0;
        while (viterator.next()) |sign| {
            defer i += 1;
            if (i >= 16) {
                break;
            }
            common.log.debug("({s}{s} {d}) ", .{if (sign.public) "pub " else "", tokens.get(sign.name).lexeme(context, file), sign.type});
        }
        common.log.debug("\nMask ({d}):      ", .{self.statementMask.len});
        for (self.statementMask[0..@min(16, self.statementMask.len)]) |stmt| {
            common.log.debug("{d} ", .{stmt});
        }
        common.log.debug("\nExtra ({d}):     ", .{self.extra.len});
        for (self.extra[0..@min(16, self.extra.len)]) |extra| {
            common.log.debug("{d} ", .{extra});
        }
        common.log.debug("\n\n", .{});
    }
};

pub const Stats = struct {
    integer: u32 = 0,
    float: u32 = 0,
    string: u32 = 0,
    bool: u32 = 0,
    types: u32 = 0,
    meta: u32 = 0,
    functions: u32 = 0,
};

const Parser = @This();

tokens: *const Lexer.TokenList.Slice,
current: defines.TokenPtr,

arena: std.heap.ArenaAllocator,

expressionMap: ExpressionMap,
statementMap: StatementMap,
signaturePool: VariableSignatureMap,

statementMask: std.ArrayList(defines.StatementPtr),

extra: std.ArrayList(defines.OpaquePtr),
scratch: std.ArrayList(defines.OpaquePtr),

file: defines.FilePtr,
context: *common.CompilerContext,

// expression/statement counts are already stored in the Context.
/// In debug mode, stores counts for each expression/statement type.
/// In release mode, only stores literal counts per type.
stats: Stats,

pub fn init(base: Allocator, context: *common.CompilerContext, tokensPtr: defines.TokenListPtr) common.CompilerError!Parser {
    var arena = std.heap.ArenaAllocator.init(base);
    errdefer arena.deinit();
    const tokens = context.getTokens(tokensPtr);

    return .{
        .signaturePool = try VariableSignatureMap.init(arena.allocator(), tokens.len / 2),
        .expressionMap = try ExpressionMap.init(arena.allocator(), tokens.len / 2),
        .statementMap = try StatementMap.init(arena.allocator(), tokens.len / 4),
        .statementMask = std.ArrayList(defines.StatementPtr).initCapacity(arena.allocator(), tokens.len / 4) catch return error.AllocatorFailure,
        .extra = std.ArrayList(defines.OpaquePtr).initCapacity(arena.allocator(), tokens.len) catch return error.AllocatorFailure,
        .scratch = std.ArrayList(defines.OpaquePtr).initCapacity(arena.allocator(), 128) catch return error.AllocatorFailure,
        .file = tokens.items(.start)[0],
        .context = context,
        .tokens = tokens,
        .current = 1,
        .arena = arena,
        .stats = .{ }
    };
}

/// Returns a final table containing all info about the parsing.
/// Parser is undefined and should be reinitialized after the call.
pub fn parse(self: *Parser) common.CompilerError!defines.ASTPtr {
    defer self.arena.deinit();

    var errCount: u32 = 0;
    var lastErr: common.CompilerError = undefined;

    // any type expression
    self.expressionMap.appendAssumeCapacity(.{
        .type = .Identifier,
        .value = 0,
    });

    while (!self.isAtEnd()) {
        if (self.statement()) |index| {
            self.statementMask.append(self.allocator(), index) catch return error.AllocatorFailure;
        }
        else |err| {
            errCount += 1;
            lastErr = err;
            common.log.err("Error: {d} <{s}>\n", .{ @intFromError(err), @errorName(err) });
            self.synchronize();
            if (errCount == self.context.settings.maxErr) {
                common.log.err("Too many errors, aborting compilation.\n", .{});
                return err;
            }
        }
    }

    if (errCount > 1) {
        lastErr = error.MultipleErrors;
    }

    if (errCount > 0) {
        return lastErr;
    }

    const ast = AST{
        .tokens = self.file,
        .expressions = self.expressionMap.slice(),
        .statements = self.statementMap.slice(),
        .signatures = self.signaturePool.slice(),
        .statementMask = self.statementMask.items,
        .extra = self.extra.items,
        .stats = self.stats,
    };

    const result = try self.context.registerAST(ast);
    return result;
}

//
// Statements
//

fn statement(self: *Parser) StatementResult {
    return switch (self.tokens.items(.type)[self.advance()]) {
        .LBrace => self.block(),
        .Asm => self.inlineAssembly(),
        .Switch => self.commonSwitch(.Statement),
        .If => self.conditional(),
        .While, .For => |loop| self.loopStatement(loop),
        .Return => self.returnStatement(),
        .Break => self.breakStatement(),
        .Continue => self.continueStatement(),
        .Pub => switch (self.tokens.items(.type)[self.advance()]) {
            .Let => self.variable(true),
            else => {
                self.report("Expected a variable definition after 'pub' specifier.", .{});
                return error.InvalidToken;
            },
        },
        .Let => self.variable(false),
        .Discard => self.discard(),
        .Import => self.import(),
        .Semicolon => {
            self.report("Trailing semicolons are not permitted.", .{});
            return error.InvalidToken;
        },
        // .Defer => self.deferStatement(),
        .Defer => return common.debug.NotImplemented(@src()),
        else => self.expressionStmt(),
    };
}

/// Defer only allows function calls and assignments, for now.
fn deferStatement(self: *Parser) StatementResult {
    const deferred = try self.statement();
    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .Defer,
        .value = deferred,
    });

    return result;
}

fn expressionStmt(self: *Parser) StatementResult {
    assert(self.current > 0);
    self.current -= 1;

    const exprPtr = try self.expression();
    const expr = self.expressionMap.get(exprPtr);

    switch (expr.type) {
        .Assignment, .Call => { },
        .Mark =>
            switch (self.expressionMap.get(self.extra.items[expr.value + 2]).type) {
                .Assignment, .Call => { },
                else => |t| {
                    self.report("Only assignment and function calls are allowed as expression statements. Received '{s}'", .{@tagName(t)});
                    return error.IllegalSyntax;
                },
            },
        else => |t| {
            self.report("Only assignment and function calls are allowed as expression statements. Received '{s}'", .{@tagName(t)});
            return error.IllegalSyntax;
        },
    }

    _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .Expression,
        .value = exprPtr,
    });

    return result;
}

fn block(self: *Parser) StatementResult {
    const scratchStart = self.scratch.items.len;
    while (!self.check(.RBrace)) {
        self.scratch.append(self.allocator(), try self.statement()) catch return error.AllocatorFailure;
    }

    _ = try self.consume(.RBrace, error.MissingBrace, "Missing enclosing brace '}' after block.");
    const stmts = try self.commitScratch(scratchStart);

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), stmts.start) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), stmts.end) catch return error.AllocatorFailure;

    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .Block,
        .value = start,
    });

    return result;
}

fn inlineAssembly(self: *Parser) StatementResult {
    const cstart = self.tokens.get(try self.consume(.LBrace, error.MissingBrace, "Expected a block after 'asm' statement.")).end;
    while (!self.check(.RBrace)) {
        _ = self.advance();
    }
    const cend = self.tokens.get(try self.consume(.RBrace, error.MissingBrace, "Missing enclosing brace '}' after block.")).start;

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), cstart) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), cend) catch return error.AllocatorFailure;

    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .InlineAssembly,
        .value = start,
    });

    return result;
}

fn returnStatement(self: *Parser) StatementResult {
    const expr = try self.ifExpression();
    _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .Return,
        .value = expr
    });
    
    return result;
}

fn conditional(self: *Parser) StatementResult {
    const condition = try self.ifExpression();

    if (!self.check(.LBrace)) {
        self.report("Expected a block after if statement.", .{});
        return error.MissingBrace;
    }

    const body = try self.statement();

    var otherwise: ?defines.StatementPtr = null;
    if (self.match(&.{.Else})) {
        switch (self.tokens.items(.type)[self.peek()]) {
            .LBrace, .If => { },
            else => {
                self.report("Expected a block or conditional after else statement.", .{});
                return error.MissingBrace;
            },
        }

        otherwise = try self.statement();
    }

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), condition) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), body) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), if (otherwise) |_| 1 else 0) catch return error.AllocatorFailure;
    if (otherwise) |val| {
        self.extra.append(self.allocator(), val) catch return error.AllocatorFailure;
    }

    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .Conditional,
        .value = start,
    });

    return result;
}

fn loopStatement(self: *Parser, loopToken: Lexer.TokenType) StatementResult {
    const condition = try self.ifExpression();

    if (!self.check(.LBrace)) {
        self.report("Expected loop body.", .{});
        return error.MissingBrace;
    }

    const body = try self.statement();

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), condition) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), body) catch return error.AllocatorFailure;
    
    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = switch (loopToken) {
            .For => {
                self.report("For loop is not implemented.", .{});
                return common.debug.NotImplemented(@src());
            },
            .While => .While,
            else => unreachable,
        },
        .value = start,
    });
    
    return result;
}

fn breakStatement(self: *Parser) StatementResult {
    _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");
    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .Break,
        .value = 0 // maybe future label
    });
    return result;
}

fn continueStatement(self: *Parser) StatementResult {
    _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");
    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .Continue,
        .value = 0 // maybe future label
    });
    return result;
}

fn variable(self: *Parser, public: bool) StatementResult {
    const signature = try self.variableSignature(public, false);

    _ = try self.consume(.Equal, error.MissingAssignment, "Expected assignment in variable definition.");
    const expr = try self.ifExpression();
    _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), signature) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), 0) catch return error.AllocatorFailure;

    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .VariableDefinition,
        .value = start,
    });

    return result;
}

fn discard(self: *Parser) StatementResult {
    _ = try self.consume(.Equal, error.MissingAssignment, "Expected an assignment after discard.");
    const expr = try self.ifExpression();
    _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .Discard,
        .value = expr
    });
    
    return result;
}

fn import(self: *Parser) StatementResult {
    const module = try self.postfix();

    var lhs = module;
    loop: while (true) {
        switch (self.expressionMap.items(.type)[lhs]) {
            .Identifier => break :loop,
            .Scoping => lhs = self.extra.items[self.expressionMap.items(.value)[lhs]],
            else => |t| {
                self.report("Expected a module name, received '{s}'", .{@tagName(t)});
                return error.MissingModuleName;
            },
        }
    }

    const maybeAlias =
        if (
            self.match(&.{.Identifier})
            and std.mem.eql(u8, self.tokens.get(self.previous()).lexeme(self.context, self.file), "as")
        ) self.advance()
        else null;
    _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

    const start: u32 = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), module) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), if (maybeAlias) |_| 1 else 0) catch return error.AllocatorFailure;
    if (maybeAlias) |alias| {
        self.extra.append(self.allocator(), alias) catch return error.AllocatorFailure;
    }

    const result = try self.alloc(Statement);
    self.statementMap.set(result, .{
        .type = .Import,
        .value = start,
    });

    return result;
}

//
// Expressions
//

fn expression(self: *Parser) ExpressionResult {
    return self.assignment();
}

fn assignment(self: *Parser) ExpressionResult {
    var expr = try self.ifExpression();

    // @Note Assignment is actually a statement, rather than an expression.
    // The reason it resides here is that it was easier to parse it like
    // an expression rather than having to do a lookahead/lookback.
    // The only place Parser.assignment is called is Parser.expression,
    // so it is guaranteed to be the lowest precedence expression and
    // therefore suitable to be a statement.

    if (self.match(&.{.Equal})) {
        const rhs = try self.ifExpression();

        const start: defines.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), rhs) catch return error.AllocatorFailure;

        const newExpr = try self.alloc(Expression);
        self.expressionMap.set(newExpr, .{
            .type = .Assignment,
            .value = start,
        });

        expr = newExpr;
    }

    return expr;
}

fn ifExpression(self: *Parser) ExpressionResult {
    if (!self.match(&.{.If})) {
        return self.switchExpression();
    }

    _ = try self.consume(.LParen, error.MissingBrace, "Expected a left parenthesis to denote if expression condition.");
    const condition = try self.ifExpression();
    _ = try self.consume(.RParen, error.MissingBrace, "Expected an enclosing parenthesis.");
    const then = try self.ifExpression();

    _ = try self.consume(.Else, error.MissingBranch, "Expected an 'else' branch in conditional expression.");
    const otherwise = try self.ifExpression();

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), condition) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), then) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), otherwise) catch return error.AllocatorFailure;

    const expr = try self.alloc(Expression);
    self.expressionMap.set(expr, .{
        .type = .Conditional,
        .value = start,
    });

    return expr;
}

fn switchExpression(self: *Parser) ExpressionResult {
    if (!self.match(&.{.Switch})) {
        return self.logicalOr();
    }

    return self.commonSwitch(.Expression);
}

fn logicalOr(self: *Parser) ExpressionResult {
    var expr = try self.logicalAnd();

    while (self.match(&.{.Or})) {
        expr = try self.commonBinary(expr, Parser.logicalAnd);
    }

    return expr;
}

fn logicalAnd(self: *Parser) ExpressionResult {
    var expr = try self.equality();

    while (self.match(&.{.And})) {
        expr = try self.commonBinary(expr, Parser.equality);
    }

    return expr;
}

fn equality(self: *Parser) ExpressionResult {
    var expr = try self.bitwiseOr();

    while (self.match(&.{.EqualEqual, .BangEqual})) {
        expr = try self.commonBinary(expr, Parser.bitwiseOr);
    }

    return expr;
}

fn bitwiseOr(self: *Parser) ExpressionResult {
    var expr = try self.bitwiseXor();

    while (self.match(&.{.Pipe})) {
        expr = try self.commonBinary(expr, Parser.bitwiseXor);
    }

    return expr;
}

fn bitwiseXor(self: *Parser) ExpressionResult {
    var expr = try self.bitwiseAnd();

    while (self.match(&.{.Xor})) {
        expr = try self.commonBinary(expr, Parser.bitwiseAnd);
    }

    return expr;
}

fn bitwiseAnd(self: *Parser) ExpressionResult {
    var expr = try self.comparison();

    while (self.match(&.{.Ampersand})) {
        expr = try self.commonBinary(expr, Parser.comparison);
    }

    return expr;
}

fn comparison(self: *Parser) ExpressionResult {
    var expr = try self.shift();

    while (self.match(&.{.Lesser, .LesserEqual, .Greater, .GreaterEqual})) {
        expr = try self.commonBinary(expr, Parser.shift);
    }

    return expr;
}

fn shift(self: *Parser) ExpressionResult {
    var expr = try self.term();

    while (self.match(&.{.RightShift, .LeftShift})) {
        expr = try self.commonBinary(expr, Parser.term);
    }

    return expr;
}

fn term(self: *Parser) ExpressionResult {
    var expr = try self.factor();

    while (self.match(&.{.Plus, .Minus})) {
        expr = try self.commonBinary(expr, Parser.factor);
    }

    return expr;
}

fn factor(self: *Parser) ExpressionResult {
    var expr = try self.unary();

    while (self.match(&.{.Slash, .Star})) {
        expr = try self.commonBinary(expr, Parser.unary);
    }

    return expr;
}

fn unary(self: *Parser) ExpressionResult {
    if (self.match(&.{.Bang, .Minus, .Tilde})) {
        const operator = self.tokens.items(.type)[self.previous()];

        const rhs = try self.unary();

        const start: defines.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), @intFromEnum(operator)) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), rhs) catch return error.AllocatorFailure;

        const expr = try self.alloc(Expression);
        self.expressionMap.set(expr, .{
            .type = .Unary,
            .value = start,
        });

        return expr;
    }

    return self.postfix();
}

fn postfix(self: *Parser) ExpressionResult {
    var expr = try self.primary();

    while (true) {
        if (self.match(&.{.DoubleColon})) {
            const member = try self.consume(.Identifier, error.MissingIdentifier, "Expected member name in scope resolution.");
            
            const start: defines.OpaquePtr = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), member) catch return error.AllocatorFailure;

            const newExpr = try self.alloc(Expression);
            self.expressionMap.set(newExpr, .{
                .type = .Scoping,
                .value = start,
            });
            expr = newExpr;
        }
        else if (self.match(&.{.LParen})) {
            assert(self.current > 0);
            self.current -= 1;
            const args = try self.primary();

            const start: defines.OpaquePtr = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), args) catch return error.AllocatorFailure;

            const newExpr = try self.alloc(Expression);
            self.expressionMap.set(newExpr, .{
                .type = .Call,
                .value = start,
            });
            expr = newExpr;
        } else if (self.match(&.{.Dot})) {
            if (!self.match(&.{.Identifier, .Ampersand, .Star})) {
                _ = self.advance();
                self.report("Expected a member name in dot expression.", .{});
                return error.MissingIdentifier;
            }

            const member = self.previous();

            const start: defines.OpaquePtr = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), member) catch return error.AllocatorFailure;

            const newExpr = try self.alloc(Expression);
            self.expressionMap.set(newExpr, .{
                .type = .Dot,
                .value = start,
            });
            expr = newExpr;
        } else if (self.match(&.{.LBracket})) {
            const index = try self.ifExpression();

            if (self.match(&.{.Range})) {
                const rangeEnd = try self.ifExpression();

                _ = try self.consume(.RBracket, error.MissingBracket, "Expected closing bracket ']'.");

                const start: defines.OpaquePtr = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), index) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), rangeEnd) catch return error.AllocatorFailure;

                const newExpr = try self.alloc(Expression);
                self.expressionMap.set(newExpr, .{
                    .type = .Slicing,
                    .value = start,
                });
                expr = newExpr;
            }
            else {
                _ = try self.consume(.RBracket, error.MissingBracket, "Expected closing bracket ']'.");

                const start: defines.OpaquePtr = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), index) catch return error.AllocatorFailure;

                const newExpr = try self.alloc(Expression);
                self.expressionMap.set(newExpr, .{
                    .type = .Indexing,
                    .value = start,
                });
                expr = newExpr;
            }
        } else {
            break;
        }
    }

    return expr;
}

fn primary(self: *Parser) ExpressionResult {
    switch (self.tokens.items(.type)[self.peek()]) {
        .False, .True, .Integer, .Float, .String, .EnumLiteral => |t| {
            switch (t) {
                .False, .True => self.stats.bool += 1,
                .Integer => self.stats.integer += 1,
                .Float => self.stats.float += 1,
                .String => self.stats.string += 1,
                else => { },
            }

            const expr = try self.alloc(Expression);
            self.expressionMap.set(expr, .{
                .type = .Literal,
                .value = self.advance(),
            });
            return expr;
        },
        .Mut, .Star, .LBracket,
        .Enum, .Struct, .Union => {
            self.stats.types += 1;
            return self.typeExpression();
        },
        .Fn => return self.function(),
        .LParen => {
            _ = self.advance();

            const exprsStart = self.scratch.items.len;
            while (!self.check(.RParen)) {
                self.scratch.append(self.allocator(), try self.ifExpression()) catch return error.AllocatorFailure;
                if (!self.match(&.{.Comma})) {
                    break;
                }
            }

            _ = try self.consume(.RParen, error.MissingBrace, "Expected enclosing parenthesis ')' in expression list.");
            const expressions = try self.commitScratch(exprsStart);

            const start: defines.OpaquePtr = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), expressions.start) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), expressions.end) catch return error.AllocatorFailure;

            const expr = try self.alloc(Expression);
            self.expressionMap.set(expr, .{
                .type = .ExpressionList,
                .value = start,
            });
            return expr;
        },
        .Identifier => {
            const expr = try self.alloc(Expression);
            self.expressionMap.set(expr, .{
                .type = .Identifier,
                .value = try self.consume(.Identifier, error.MissingIdentifier, "Expected an identifier."),
            });
            return expr;
        },
        .Mark => return self.mark(),
        else => {
            self.report("Expected a primary expression, got '{s}' instead.", .{self.tokens.get(self.current).lexeme(self.context, self.file)});
            return error.InvalidToken;
        },
    }
}

fn mark(self: *Parser) ExpressionResult {
    const marks = try self.compilerHint();
    const marked = try self.ifExpression();

    if (marks.len() == 0) {
        return marked;
    }

    self.stats.meta += marks.len();

    const start: u32 = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), marks.start) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), marks.end) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), marked) catch return error.AllocatorFailure;

    const ptr = try self.alloc(Expression);
    self.expressionMap.set(ptr, .{
        .type = .Mark,
        .value = start,
    });
    return ptr;
}

fn function(self: *Parser) ExpressionResult {
    _ = self.advance();

    switch (self.tokens.items(.type)[self.advance()]) {
        .LParen => {
            const paramsStart = self.scratch.items.len;
            while (!self.check(.RParen)) {
                self.scratch.append(self.allocator(), try self.variableSignature(false, true)) catch return error.AllocatorFailure;
                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis ')' after parameter list.");
            const params = try self.commitScratch(paramsStart);

            _ = try self.consume(.Arrow, error.MissingArrow, "Expected arrow '->' to denote return type.");
            const returnType = try self.ifExpression();

            _ = try self.consume(.LBrace, error.MissingBrace, "Expected function body.");
            self.current -= 1;
            const body = try self.statement();

            const start: defines.OpaquePtr = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), params.start) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), params.end) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), returnType) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), body) catch return error.AllocatorFailure;

            const expr = try self.alloc(Expression);
            self.expressionMap.set(expr, .{
                .type = .FunctionDefinition,
                .value = start,
            });

            self.stats.functions += 1;

            return expr;
        },
        .Pipe => {
            const paramsStart = self.scratch.items.len;
            while (!self.check(.Pipe)) {
                self.scratch.append(self.allocator(), self.advance()) catch return error.AllocatorFailure;
                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.consume(.Pipe, error.MissingParenthesis, "Expected closing pipe '|' after capture list.");
            const params = try self.commitScratch(paramsStart);

            const body = try self.ifExpression();

            const start: defines.OpaquePtr = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), params.start) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), params.end) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), body) catch return error.AllocatorFailure;

            self.stats.functions += 1;

            const expr = try self.alloc(Expression);
            self.expressionMap.set(expr, .{
                .type = .Lambda,
                .value = start,
            });

            return expr;
        },
        else => {
            self.report("Expected a parameter list or lambda capture.", .{});
            return error.MissingParenthesis;
        }
    }
}

fn structDefinition(self: *Parser) ExpressionResult {
    _ = try self.consume(.LBrace, error.MissingBrace, "Expected struct body.");

    // Check unionDefinition for details.
    // TODO: Fix this. Maybe two loops using scratch would be better...
    var fieldList = collections.StaticStack(defines.OpaquePtr, defines.subscopeMax){};
    var definitions = collections.ReverseStackArray(defines.OpaquePtr, defines.subscopeMax).init();

    while (!self.check(.RBrace)) {
        switch (self.tokens.items(.type)[self.peek()]) {
            .Pub => {
                _ = self.advance();
                switch (self.tokens.items(.type)[self.peek()]) {
                    .Let => {
                        _ = self.advance();
                        try definitions.append(try self.variable(true));
                    },
                    .Identifier => {
                        try fieldList.push(try self.variableSignature(true, true));
                        if (!self.match(&.{.Comma})) break;
                    },
                    else => {
                        _ = self.advance();
                        self.report("Expected a field after 'pub' specifier.", .{});
                        return error.InvalidToken;
                    },
                }
            },
            .Let => {
                _ = self.advance();
                try definitions.append(try self.variable(false));
            },
            .Identifier => {
                try fieldList.push(try self.variableSignature(false, true));
                if (!self.match(&.{.Comma})) break;
            },
            else => {
                _ = self.advance();
                self.report("Expected a field in struct definition.", .{});
                return error.InvalidToken;
            },
        }
    }

    _ = try self.consume(.RBrace, error.MissingBrace, "Expected enclosing brace after struct definition.");

    const fields = try self.commitFromSlice(fieldList.items);
    const defs = try self.commitFromSlice(definitions.items);

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), fields.start) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), fields.end) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), defs.start) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), defs.end) catch return error.AllocatorFailure;

    const expr = try self.alloc(Expression);
    self.expressionMap.set(expr, .{
        .type = .StructDefinition,
        .value = start,
    });

    return expr;
}

fn enumDefinition(self: *Parser) ExpressionResult {
    _ = try self.consume(.LBrace, error.MissingBrace, "Expected enum body.");

    // Check unionDefinition for details.
    // TODO: Fix this.
    var variablesTmp = collections.StaticStack(defines.OpaquePtr, defines.subscopeMax){};
    var definitions = collections.ReverseStackArray(defines.OpaquePtr, defines.subscopeMax).init();

    while (!self.check(.RBrace)) {
        switch (self.tokens.items(.type)[self.peek()]) {
            .Pub => {
                _ = self.advance();
                switch (self.tokens.items(.type)[self.peek()]) {
                    .Let => {
                        _ = self.advance();
                        try definitions.append(try self.variable(true));
                    },
                    else => {
                        _ = self.advance();
                        self.report("Expected a definition after 'pub' specifier.", .{});
                        return error.InvalidToken;
                    },
                }
            },
            .Let => {
                _ = self.advance();
                try definitions.append(try self.variable(false));
            },
            .Identifier => {
                try variablesTmp.push(self.advance());
                if (!self.match(&.{.Comma})) break;
            },
            else => {
                _ = self.advance();
                self.report("Expected a field in enum definition.", .{});
                return error.InvalidToken;
            },
        }
    }

    _ = try self.consume(.RBrace, error.MissingBrace, "Expected enclosing brace after enum definition.");

    const variables = try self.commitFromSlice(variablesTmp.items);
    const defs = try self.commitFromSlice(definitions.items);

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), variables.start) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), variables.end) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), defs.start) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), defs.end) catch return error.AllocatorFailure;

    const expr = try self.alloc(Expression);
    self.expressionMap.set(expr, .{
        .type = .EnumDefinition,
        .value = start,
    });

    return expr;
}

fn unionDefinition(self: *Parser) ExpressionResult {
    var tagged: u32 = 0;
    var tag: ?defines.ExpressionPtr = null;

    if (self.match(&.{.LParen})) {
        tagged = 1;
        if (!self.match(&.{.Enum})) {
            // TODO: Add custom tag support
            self.report("Manually tagged unions are not (yet) supported.", .{});
            _ = &tag;
            return error.NotImplemented;
        }
        _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis.");
    }

    _ = try self.consume(.LBrace, error.MissingBrace, "Expected union body.");

    // For some reason, variablesTmp overwrites the extra buffer.
    // Fixed buffer for temporary fix.
    // TODO: fix this
    var variablesTmp = collections.StaticStack(defines.OpaquePtr, defines.subscopeMax){};
    var definitions = collections.ReverseStackArray(defines.OpaquePtr, defines.subscopeMax).init();

    while (!self.check(.RBrace)) {
        switch (self.tokens.items(.type)[self.peek()]) {
            .Pub => {
                _ = self.advance();
                switch (self.tokens.items(.type)[self.peek()]) {
                    .Let => {
                        _ = self.advance();
                        try definitions.append(try self.variable(true));
                    },
                    else => {
                        self.report("Expected a definition after 'pub' specifier.", .{});
                        return error.InvalidToken;
                    },
                }
            },
            .Let => {
                _ = self.advance();
                try definitions.append(try self.variable(false));
            },
            .Identifier => {
                try variablesTmp.push(try self.variableSignature(true, true));
                if (!self.match(&.{.Comma})) break;
            },
            else => {
                _ = self.advance();
                self.report("Expected a field in union definition.", .{});
                return error.InvalidToken;
            },
        }
    }

    _ = try self.consume(.RBrace, error.MissingBrace, "Expected enclosing brace after union definition.");

    const variables = try self.commitFromSlice(variablesTmp.items);
    const defs = try self.commitFromSlice(definitions.items);

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), tagged) catch return error.AllocatorFailure;
    if (tagged == 1) {
        self.extra.append(self.allocator(), if (tag) |_| 1 else 0) catch return error.AllocatorFailure;
        if (tag) |t| {
            self.extra.append(self.allocator(), t) catch return error.AllocatorFailure;
            unreachable;
        }
    }
    self.extra.append(self.allocator(), variables.start) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), variables.end) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), defs.start) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), defs.end) catch return error.AllocatorFailure;

    // Layout tagged-manual:
    // 0 isTagged
    // 1 isManual
    // 2 tag
    // 3.. default
    //
    // Layout tagged-auto.
    // 0 isTagged
    // 1 isManual
    // 2.. default
    //
    // Layout plain:
    // 0 isTagged
    // 1.. default
    //
    // Layout default:
    // 0 fieldsStart
    // 1 fieldsEnd
    // 2 declsStart
    // 3 declsEnd

    const expr = try self.alloc(Expression);
    self.expressionMap.set(expr, .{
        .type = .UnionDefinition,
        .value = start,
    });

    return expr;
}

fn typeExpression(self: *Parser) ExpressionResult {
    switch (self.tokens.items(.type)[self.advance()]) {
        .Star =>
            if (self.match(&.{.Fn})) {
                const args = try self.ifExpression();

                _ = try self.consume(.Arrow, error.MissingArrow, "Expected arrow '->' to denote return type.");
                const returnType = try self.ifExpression();

                const start: defines.OpaquePtr = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), args) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), returnType) catch return error.AllocatorFailure;

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .FunctionType,
                    .value = start,
                });
                return expr;
            }
            else {
                const res = try self.typeExpression();

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .PointerType,
                    .value = res,
                });
                return expr;
            },
        .LBracket => {
            return if (self.match(&.{.RBracket})) result: {
                const rest = try self.typeExpression();

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .SliceType,
                    .value = rest,
                });

                break :result expr;
            }
            else if (self.match(&.{.EnumLiteral})) result: {
                const literal = self.tokens.get(self.previous()).lexeme(self.context, self.file);
                _ = try self.consume(.RBracket, error.MissingBracket, "Expected enclosing bracket in array type.");
                const child = try self.typeExpression();
                const expr = try self.alloc(Expression);

                self.expressionMap.set(expr,
                    if (std.mem.eql(u8, literal, "@c")) .{
                        .type = .CPointerType,
                        .value = child,
                    }
                    else {
                        self.report("Unexpected slice descriptor '{s}'.", .{literal});
                        return error.InvalidToken;
                    }
                );

                break :result expr;
            }
            else result: {
                const size = try self.ifExpression();
                _ = try self.consume(.RBracket, error.MissingBracket, "Expected enclosing bracket in array type.");
                const rest = try self.typeExpression();

                const start: u32 = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), size) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), rest) catch return error.AllocatorFailure;

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .ArrayType,
                    .value = start,
                });

                break :result expr;
            };
        },
        .Mut => {
            const res = try self.typeExpression();

            const expr = try self.alloc(Expression);
            self.expressionMap.set(expr, .{
                .type = .MutableType,
                .value = res,
            });
            return expr;
        },
        .Struct => return self.structDefinition(),
        .Enum => return self.enumDefinition(),
        .Union => return self.unionDefinition(),
        .Identifier => {
            const typename = self.previous();

            const expr = try self.alloc(Expression);
            self.expressionMap.set(expr, .{
                .type = .Identifier,
                .value = typename,
            });
            return expr;
        },

        else => {
            assert(self.current > 0);
            self.current -= 1;
            _ = try self.consume(.Identifier, error.MissingTypeSpecifier, "Expected type name.");
        }
    }

    unreachable;
}

//
// Helpers
//

fn allocator(self: *Parser) Allocator {
    return self.arena.allocator();
}

fn compilerHint(self: *Parser) common.CompilerError!defines.Range {
    return if (self.match(&.{.Mark})) blk: {
        _ = try self.consume(.LParen, error.MissingParenthesis, "Expected '(' in compiler hint.");

        const scratchStart = self.scratch.items.len;
        while (!self.check(.RParen)) loop: {
            self.scratch.append(self.allocator(), try self.ifExpression()) catch return error.AllocatorFailure;
            if (!self.match(&.{.Comma})) break :loop;
        }
        _ = try self.consume(.RParen, error.MissingParenthesis, "Expected ')' in compiler hint.");

        const range = try self.commitScratch(scratchStart);

        if (range.len() == 0) {
            self.report("Redundant empty mark.", .{});
            return common.CompilerError.RedundantMark;
        }

        break :blk range;
    }
    else .{
        .start = 0,
        .end = 0,
    };
}

fn commonSwitch(
    self: *Parser,
    comptime switchType: enum {
        Statement,
        Expression
    },
) common.CompilerError!defines.EitherPtr(defines.StatementPtr, defines.ExpressionPtr) {
    const item = try self.ifExpression();

    _ = try self.consume(.LBrace, error.MissingBrace, "Expected a block after switch statement.");

    const scratchStart = self.scratch.items.len;
    while (!self.check(.RBrace)) {
        if (self.match(&.{.Else})) {
            self.scratch.append(self.allocator(), AnyType) catch return error.AllocatorFailure;
        }
        else {
            self.scratch.append(self.allocator(), try self.ifExpression()) catch return error.AllocatorFailure;
        }

        _ = try self.consume(.Arrow, error.MissingArrow, "Expected '->' after switch case.");

        // @Note Multi-captures in case I add destruction
        if (self.match(&.{.Pipe})) {
            const firstCapture = try self.alloc(Expression);
            self.expressionMap.set(firstCapture, .{
                .type = .Identifier,
                .value = self.current,
            });

            var captureCount: u32 = 0;
            while (!self.check(.Pipe)) {
                if (!self.match(&.{.Identifier, .Discard})) {
                    self.report("Expected a capture name.", .{});
                    return error.MissingIdentifier;
                }

                captureCount += 1;
                if (!self.match(&.{.Comma})) break;
            }
            _ = try self.consume(.Pipe, error.MissingPipe, "Expected an enclosing pipe '|' at case capture.");

            if (captureCount == 0) {
                self.report("Redundant empty capture list.", .{});
                return error.RedundantEmptyCaptureList;
            }

            self.scratch.append(self.allocator(), captureCount) catch return error.AllocatorFailure;
            self.scratch.append(self.allocator(), firstCapture) catch return error.AllocatorFailure;
        }
        else {
            self.scratch.append(self.allocator(), 0) catch return error.AllocatorFailure;
            self.scratch.append(self.allocator(), 0) catch return error.AllocatorFailure;
        }

        self.scratch.append(self.allocator(), switch (switchType) {
            .Statement => blk: {
                const stmt = try self.statement();

                if (self.statementMap.get(stmt).type == .VariableDefinition) {
                    self.report("Variable definitions are not allowed here.", .{});
                    return Error.IllegalSyntax;
                }

                break :blk stmt;
            },
            .Expression => try self.expression(),
        }) catch return error.AllocatorFailure;

        switch (switchType) {
            .Expression => if (!self.match(&.{.Comma})) break,
            .Statement => { },
        }
    }

    _ = try self.consume(.RBrace, error.MissingBrace, "Missing enclosing brace '}' after switch statement.");

    const cases = try self.commitScratch(scratchStart);

    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), item) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), cases.start) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), cases.end) catch return error.AllocatorFailure;
    
    // Captured Case layout:
    // 0 case
    // 1 captureCount
    // 2 firstCapture
    // 3 body
    //
    // Case Layout:
    // 0 case
    // 1 captureCount
    // 2 dummy
    // 3 body 

    const result = try self.alloc(switch (switchType) {
        .Expression => Expression,
        .Statement => Statement,
    });
    (switch (switchType) {
        .Statement => self.statementMap,
        .Expression => self.expressionMap
    }).set(result, .{
        .type = .Switch,
        .value = start,
    });

    return result;
}

fn commonBinary(self: *Parser, expr: defines.ExpressionPtr, comptime next: anytype) ExpressionResult {
    const operator = self.tokens.items(.type)[self.previous()];
    const rhs = try next(self);

    const binaryStart: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), @intFromEnum(operator)) catch return error.AllocatorFailure;
    self.extra.append(self.allocator(), rhs) catch return error.AllocatorFailure;

    const newExpr = try self.alloc(Expression);
    self.expressionMap.set(newExpr, .{
        .type = .Binary,
        .value = binaryStart,
    });

    return newExpr;
}

fn synchronize(self: *Parser) void {
    assert(self.current > 0);
    self.current -= 1;

    while (!self.isAtEnd()) {
        switch (self.tokens.items(.type)[self.peek()]) {
            .Fn, .Let, .Pub,
            .While, .If, .Asm,
            .Continue, .Return, .Import,
            .Defer, .Discard, .Break => return,
            else => {},
        }

        _ = self.advance();
    }
}

fn commitFromSlice(self: *Parser, items: []const defines.OpaquePtr) common.CompilerError!defines.Range {
    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.appendSlice(self.allocator(), items) catch return error.AllocatorFailure;
    return .{
        .start = start,
        .end = @intCast(self.extra.items.len)
    };
}

fn commitScratch(self: *Parser, scratchStart: usize) common.CompilerError!defines.Range {
    const span = try self.commitFromSlice(self.scratch.items[scratchStart..]);
    self.scratch.shrinkRetainingCapacity(@intCast(scratchStart));
    return span;
}

fn alloc(self: *Parser, comptime T: type) common.CompilerError!defines.OpaquePtr {
    if (T == Expression) {
        return @intCast(self.expressionMap.addOne(self.allocator()) catch return error.AllocatorFailure);
    } else if (T == Statement) {
        return @intCast(self.statementMap.addOne(self.allocator()) catch return error.AllocatorFailure);
    } else if (T == VariableSignature) {
        return @intCast(try self.signaturePool.addOne(self.allocator()));
    } else {
        @compileError("Unsupported type.");
    }
}

fn variableSignature(self: *Parser, public: bool, enforceType: bool) common.CompilerError!defines.SignaturePtr {
    const name = 
        if (self.match(&.{.Identifier})) self.previous()
        else {
            self.report("Expected an identifier in variable signature.", .{});
            return error.MissingIdentifier;
        };

    const varType = 
        if (!enforceType and !self.check(.Colon)) AnyType
        else res: {
            _ = try self.consume(.Colon, error.MissingColon, "Expected a separator colon ':' after identifier.");
            break :res try self.ifExpression();
        };

    const signature = try self.alloc(VariableSignature);
    self.signaturePool.set(signature, .{
        .public = public,
        .name = name,
        .type = varType,
    });

    return signature;
}

fn consume(self: *Parser, tokenType: Lexer.TokenType, err: common.CompilerError, message: []const u8) common.CompilerError!defines.TokenPtr {
    if (self.check(tokenType)) return self.advance();

    self.report("{s}\n\tExpected {s}, Received {s}", .{ message, @tagName(tokenType), @tagName(self.tokens.items(.type)[self.peek()]) });
    return err;
}

fn previous(self: *Parser) defines.TokenPtr {
    assert(self.current != 0);
    return self.current - 1;
}

fn peek(self: *Parser) defines.TokenPtr {
    return self.current;
}

fn isAtEnd(self: *Parser) bool {
    if (self.current >= self.tokens.len) return true;
    return self.tokens.items(.type)[self.peek()] == .EOF;
}

fn advance(self: *Parser) defines.TokenPtr {
    assert(!self.isAtEnd());
    defer self.current += 1;
    return self.current;
}

fn check(self: *Parser, tokenType: Lexer.TokenType) bool {
    if (self.isAtEnd()) return false;
    return self.tokens.items(.type)[self.peek()] == tokenType;
}

fn match(self: *Parser, comptime args: []const Lexer.TokenType) bool {
    const t = self.tokens.items(.type)[self.peek()];
    inline for (args) |arg| {
        if (t == arg) {
            _ = self.advance();
            return true;
        }
    }
    return false;
}

fn report(self: *Parser, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = self.tokens.get(self.current);
    const position = token.position(self.context, self.file);
    common.log.err(("." ** 4) ++ " In {s} {d}:{d}", .{ self.context.getFileName(self.file), position.line, position.column});
    token.printLocation(self.arena.allocator(), self.context, self.file, position, true);
}

//
// Tests
//

pub const Tests = struct {
    var debugAllocator = std.heap.DebugAllocator(.{}){};
    const gpa = debugAllocator.allocator();

    test "All" {
    }
};
