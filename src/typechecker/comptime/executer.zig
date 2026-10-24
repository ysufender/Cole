const std = @import("std");
const common = @import("../../core/common.zig");
const defines = @import("../../core/defines.zig");
const collections = @import("../../util/collections.zig");
const types = @import("../type.zig");
const backend = @import("../../codegen/backend.zig");

const assert = std.debug.assert;

const Lexer = @import("../../lexer/lexer.zig");
const Parser = @import("../../parser/parser.zig");
const Typechecker = @import("../typechecker.zig");
const Resolver = @import("../resolver.zig");
const Comptime = @import("../comptime.zig");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = common.CompilerError;
const TypeID = types.TypeID;
const TypeInfo = types.TypeInfo;
const JIR = @import("../../codegen/c/jir.zig");

const Stack = collections.StaticStack(Scope, defines.comptimeStackLimit);

const Scope = struct {
    const Variables = collections.HashMap(defines.StringPtr, Comptime.Value.Ptr);

    pc: defines.Offset,
    bp: defines.Offset,
    variables: Variables,
    body: []const defines.StatementPtr,
};

const Executer = @This();

typechecker: *Typechecker,
arena: Arena,
stack: Stack,

pub fn init(typechecker: *Typechecker, allocator: Allocator) Error!Executer {
    return .{
        .arena = Arena.init(allocator),
        .typechecker = typechecker,
        .stack = .{},
    };
}

pub fn executeCall(self: *Executer, func: JIR.Function, args: []const Comptime.Value.Ptr) Error!Comptime.Value.Ptr {
    var zone = @import("tracy").ZoneN(
        @src(),
        std.fmt.allocPrintSentinel(self.arena.allocator(), "Execute {s}", .{self.typechecker.builder.getInternedString(func.name)}, 0)
            catch return Error.AllocatorFailure,
    );
    defer zone.End();

    const sign = self.typechecker.typeTable.get(func.signature).Function;

    const ast = self.typechecker.context.getAST(func.source);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const psrc = self.typechecker.currentFile;
    defer self.typechecker.currentFile = psrc;
    self.typechecker.currentFile = func.source;

    const bodyPtr = ast.statements.get(func.body).value;

    const bodyRange = defines.Range{
        .start = ast.extra[bodyPtr],
        .end = ast.extra[bodyPtr + 1],
    };

    const body  = ast.extra[bodyRange.start..bodyRange.end];

    const base = self.stack.index;
    try self.stack.push(.{
        .bp = @intCast(self.typechecker.folder.memory.items.len),
        .pc = 0,
        .variables = .empty,
        .body = body,
    });
    defer self.stack.revert(base);

    self.stack.peek().variables.ensureTotalCapacity(self.arena.allocator(), @intCast(args.len))
        catch return Error.AllocatorFailure;

    for (args, 0..) |arg, i| {
        self.stack.peek().variables.putAssumeCapacityNoClobber(func.args[i], arg);
    }

    const pc = self.typechecker.setFlag(.CoveredAllPaths, false);
    defer _ = self.typechecker.setFlag(.CoveredAllPaths, pc);

    const returnType = sign.returnType;

    try self.typechecker.typecheckStatement(func.body, returnType);
    if (!(
        self.typechecker.typeTable.get(returnType).isZeroBit()
        or self.typechecker.getFlag(.CoveredAllPaths)
    )) {
        self.report("Function with return type '{s}' does not return a value in all code paths.", .{
            try self.typechecker.typeName(self.arena.allocator(), returnType),
        });
        return Error.UncoveredCodePath;
    }

    while (self.stack.index > base) {
        const top = self.stack.peekm() orelse break;

        if (top.pc >= top.body.len) {
            // @Beware @TODO Causes out of bounds bugs
            // self.typechecker.folder.memory.shrinkRetainingCapacity(top.bp);
            _ = self.stack.pop();
            continue;
        }

        defer top.pc += 1;
        const statement = ast.statements.get(top.body[top.pc]);

        switch (statement.type) {
            .VariableDefinition => {
                const signature = ast.signatures.get(ast.extra[statement.value]);
                const varType = if (signature.type == Parser.AnyType) null else try self.typechecker.expectType(signature.type);
                const value = try self.typechecker.folder.eval(ast.extra[statement.value + 1], varType);

                const name = try self.typechecker.builder.internString(tokens.get(signature.name).lexeme(self.typechecker.context, tokens.items(.start)[0]));

                top.variables.put(self.arena.allocator(), name, value)
                    catch return Error.AllocatorFailure;
            },
            .Discard => _ = try self.typechecker.folder.eval(statement.value, null),
            .Return => {
                if (statement.value == Parser.AnyType) {
                    return @intFromEnum(Comptime.Value.Implicit.Void);
                }
                return self.typechecker.folder.eval(statement.value, returnType);
            },
            .Block => {
                try self.stack.push(.{
                    .pc = 0,
                    .bp = @intCast(self.typechecker.folder.memory.items.len),
                    .variables = .empty,
                    .body = ast.extra[
                        ast.extra[statement.value]
                        ..
                        ast.extra[statement.value + 1]
                    ],
                });
            },
            .Expression => _ = try self.typechecker.folder.eval(statement.value, null),
            .Conditional => {
                const conditionExpr = ast.extra[statement.value];
                const conditionRes = self.typechecker.folder.getValue(
                    try self.typechecker.folder.eval(conditionExpr, comptime Comptime.Folder.Builtin.Type("bool"))
                ).Bool;

                if (conditionRes) {
                    const bptr = ast.extra[statement.value + 1];
                    const bod = ast.statements.get(bptr);
                    try self.stack.push(.{
                        .pc = 0,
                        .bp = @intCast(self.typechecker.folder.memory.items.len),
                        .variables = .empty,
                        .body = ast.extra[
                            ast.extra[bod.value]
                            ..
                            ast.extra[bod.value + 1]
                        ],
                    });
                }
                else if (ast.extra[statement.value + 2] == 1) {
                    const bPtr = ast.extra[statement.value + 3];
                    const bod = ast.statements.get(bPtr);
                    try self.stack.push(.{
                        .pc = 0,
                        .bp = @intCast(self.typechecker.folder.memory.items.len),
                        .variables = .empty,
                        .body = ast.extra[
                            ast.extra[bod.value]
                            ..
                            ast.extra[bod.value + 1]
                        ],
                    });
                }
            },
            .InlineC, .Import => {
                self.report("'{s}' statements are not allowed in comptime scopes.", .{@tagName(statement.type)});
                return Error.ComptimeNotPossible;
            },
            else => {
                self.report("Unreachable '{s}'.", .{@tagName(statement.type)});
                return Error.ShouldBeImpossible;
            },
        }
    }

    return @intFromEnum(Comptime.Value.Implicit.Void);
}

pub fn executeAssignment(self: *Executer, exprPtr: defines.ExpressionPtr) Error!Comptime.Value.Ptr {
    _ = exprPtr;
    self.report("Comptime mutable variables are not (yet) supportede.", .{});
    return Error.ComptimeNotPossible;
}

pub fn getVar(self: *const Executer, name: defines.StringPtr) ?Comptime.Value.Ptr {
    var tmp = self.stack;

    while (tmp.pop()) |scope| {
        if (scope.variables.get(name)) |v| {
            return v;
        }
    }

    return null;
}

fn report(self: *Executer, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME EXECUTER: " ++ fmt, args);
}
