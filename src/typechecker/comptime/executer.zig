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
    return Executer{
        .arena = Arena.init(allocator),
        .typechecker = typechecker,
        .stack = .{},
    };
}

pub fn executeCall(self: *Executer, func: *JIR.Function, args: []const Comptime.Value.Ptr) Error!Comptime.Value.Ptr {
    const psrc = self.typechecker.currentFile;
    defer self.typechecker.currentFile = psrc;
    self.typechecker.currentFile = func.source;

    const ast = self.typechecker.context.getAST(func.source);
    const bodyPtr = ast.statements.get(func.body).value;

    const bodyRange = defines.Range{
        .start = ast.extra[bodyPtr],
        .end = ast.extra[bodyPtr + 1],
    };

    const body  = ast.extra[bodyRange.start..bodyRange.end];

    try self.stack.push(.{
        .bp = @intCast(self.typechecker.folder.memory.items.len),
        .pc = 0,
        .variables = .empty,
        .body = body,
    });

    self.stack.peek().variables.ensureTotalCapacity(self.arena.allocator(), @intCast(args.len))
        catch return Error.AllocatorFailure;

    for (args, 0..) |arg, i| {
        self.stack.peek().variables.putAssumeCapacityNoClobber(func.args[i], arg);
    }

    const pc = self.typechecker.setFlag(.CoveredAllPaths, false);
    defer _ = self.typechecker.setFlag(.CoveredAllPaths, pc);

    const returnType = self.typechecker.typeTable.get(func.signature).Function.returnType;

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

    while (self.stack.peekm()) |top| {
        if (top.pc >= top.body.len) {
            self.typechecker.folder.memory.shrinkRetainingCapacity(top.bp);
            _ = self.stack.pop();
            continue;
        }

        defer top.pc += 1;
        const statement = ast.statements.get(top.body[top.pc]);

        switch (statement.type) {
            .Return => return self.typechecker.folder.eval(statement.value, returnType),
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
            else => {
                self.report("Unreachable '{s}'.", .{@tagName(statement.type)});
                return Error.ShouldBeImpossible;
            },
        }
    }

    return @intFromEnum(Comptime.Value.Implicit.Void);
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
