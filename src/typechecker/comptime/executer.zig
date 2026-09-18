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
const JIR = backend.C.JIR;

const Stack = collections.StaticStack(Scope, 512);

const VariableMap = collections.HashMap(defines.StringPtr, Comptime.Value.Ptr);

const Scope = struct {
    pc: defines.Offset,
    bp: defines.Offset,
    variables: VariableMap,
    body: []const defines.StatementPtr,
};

const Executer = @This();

typechecker: *Typechecker,
arena: Arena,
stack: Stack,

pub fn init(typechecker: *Typechecker, allocator: Allocator) Error!Executer {
    const arena = Arena.init(allocator);
    return Executer{
        .arena = arena,
        .typechecker = typechecker,
        .stack = .{ },
    };
}

pub fn executeCall(self: *Executer, func: *JIR.Function, args: []const Comptime.Value.Ptr) Error!Comptime.Value.Ptr {
    const psrc = self.typechecker.currentFile;
    defer self.typechecker.currentFile = psrc;
    self.typechecker.currentFile = func.source;

    const ast = self.typechecker.context.getAST(func.source);

    const body = defines.Range{
        .start = ast.extra[func.body],
        .end = ast.extra[func.body + 1],
    };

    var functionScope = Scope{
        .pc = 0,
        .bp = @intCast(self.typechecker.folder.memory.items.len),
        .variables = .empty,
        .body = ast.extra[body.start..body.end],
    };

    for (args, 0..) |arg, i| {
        functionScope.variables.putNoClobber(self.arena.allocator(), func.args[i], arg)
            catch return Error.AllocatorFailure;
    }

    self.stack.push(functionScope) catch {
        self.report("Comptime stack overflow.", .{});
        return Error.ComptimeNotPossible;
    };

    const sign = self.typechecker.typeTable.get(func.signature).Function;
    const rett = sign.returnType;

    if (sign.isComptime) {
        const pc = self.typechecker.setFlag(.CoveredAllPaths, false);
        defer _ = self.typechecker.setFlag(.CoveredAllPaths, pc);
        try self.typechecker.typecheckStatement(func.body, rett);

        if (!(
            self.typechecker.typeTable.get(rett).isZeroBit()
            or self.typechecker.getFlag(.CoveredAllPaths)
        )) {
            self.typechecker.report("Function with return type '{s}' does not return a value in all code paths.", .{
                try self.typechecker.typeName(self.arena.allocator(), rett),
            });
            return Error.UncoveredCodePath;
        }
    }

    return self.executeBlock(rett);
}

fn executeBlock(self: *Executer, returnType: TypeID) Error!Comptime.Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    while (self.stack.peekm()) |top| {
        defer top.pc += 1;

        if (top.pc >= top.body.len) {
            _ = self.stack.pop();
        }

        const stmtPtr = top.body[top.pc];
        const stmt = ast.statements.get(stmtPtr);

        switch (stmt.type) {
            .Return => return self.typechecker.folder.eval(stmt.value, returnType),
            .Block => {
                const body = defines.Range{
                    .start = ast.extra[stmt.value],
                    .end = ast.extra[stmt.value + 1],
                };

                const newBlock = Scope{
                    .pc = 0,
                    .bp = @intCast(self.typechecker.folder.memory.items.len),
                    .variables = .empty,
                    .body = ast.extra[body.start..body.end],
                };

                self.stack.push(newBlock) catch {
                    self.report("Comptime stack overflow.", .{});
                    return Error.ComptimeNotPossible;
                };
            },
            else => {
                self.report("'{s}' is not implemented.", .{@tagName(stmt.type)});
                return Error.NotImplemented;
            },
        }
    }

    return @intFromEnum(Comptime.Value.Implicit.Void);
}

pub fn getVar(self: *Executer, name: defines.StringPtr) Error!Comptime.Value.Ptr {
    var tmp = self.stack;
    while (tmp.pop()) |top| {
        if (top.variables.get(name)) |v| {
            return v;
        }
    }

    self.report("Failed to evaluate comptime parameter '{s}'.", .{
        self.typechecker.builder.getInternedString(name),
    });
    return Error.EarlyEval;
}

fn report(self: *Executer, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME EXECUTER: " ++ fmt, args);
}
