// @Note Function calls do not get cached as for now, that means
// comptime execution goes on till the stack blows up. Stack, that
// is the host machine stack, not the Stack here.

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

const Stack = collections.StaticStack(Scope, defines.comptimeStackLimit);

const Cache = struct {
    pub const HashMap = collections.HashMapCustom(Key, Entry, Key.eql);

    pub const Status = enum {
        InProgress,
        Evaluated,
    };

    pub const Key = struct {
        func: JIR.Function.Ptr,
        args: []const Comptime.Value.Ptr,

        pub fn eql(_context: *anyopaque, key1: Key, key2: Key) bool {
            const context: *Comptime.Folder = @alignCast(@ptrCast(_context));
            if (key1.func != key2.func) {
                return false;
            }

            for (key1.args, key2.args) |_arg1, _arg2| {
                const arg1 = context.getValue(_arg1);
                const arg2 = context.getValue(_arg2);
                if (!context.comptimeEq(arg1, arg2)) {
                    return false;
                }
            }

            return true;
        }
    };

    pub const Entry = struct {
        status: Status,
        result: Comptime.Value.Ptr,
    };
};

const Scope = struct {
    pub const Symbol = struct {
        sp: defines.Offset,
        off: defines.Offset,
    };

    pub const VariableMap = collections.HashMap(defines.StringPtr, Comptime.Value);
    pub const LabelMap = collections.HashMap(defines.StringPtr, Symbol);

    variables: VariableMap,
    labels: LabelMap,
    bp: defines.Offset,
    len: u32,
};

const Executer = @This();

cache: Cache.HashMap,
stack: Stack,

typechecker: *Typechecker,

arena: Arena,

pub fn init(typechecker: *Typechecker, allocator: Allocator) Error!Executer {
    var arena = Arena.init(allocator);

    return Executer{
        .cache = try Cache.HashMap.init(@ptrCast(&typechecker.folder), arena.allocator(), typechecker.context.counts.functions),
        .stack = .{ },
        .arena = arena,
        .typechecker = typechecker,
    };
}

pub fn executeCall(self: *Executer, funcPtr: JIR.Function.Ptr, args: []const Comptime.Value.Ptr) Error!Comptime.Value.Ptr {
    const func = self.typechecker.builder.functions.get(funcPtr);

    if (self.cache.get(.{
        .func = funcPtr,
        .args = args,
    })) |res| {
        if (res.status == .InProgress) {
            self.report("Infinite recursion detected in function call. Call to '{s}' recurses on itself with the same parameters.", .{
                func.name,
            });
            return Error.DependencyCycle;
        }

        return res.result;
    }

    self.cache.put(.{
        .func = funcPtr,
        .args = args,
    }, .{
        .status = .InProgress,
        .result = 0,
    });

    var variables = Scope.VariableMap.empty;
    variables.ensureTotalCapacity(self.arena.allocator(), args.len)
        catch return Error.AllocatorFailure;

    for (args, 0..) |arg, idx| {
        variables.putAssumeCapacityNoClobber(func.args[idx], arg);
    }

    const scope = Scope{
        .variables = variables,
        .labels = Scope.LabelMap.empty,
        .bp = 0,
        .len = 0,
    };
    try self.stack.push(scope);

    const signature = self.typechecker.typeTable.get(func.signature).Function;

    const res =
        try if (signature.isComptime) res: {
            // @TODO
            //  Typecheck body
            //  Codepath check
            //  Execute

            // const prev = self.typechecker.currentScope;
            // self.typechecker.currentScope = self.typechecker.symbols.tryGetDecl(.{
            //    .file = self.typechecker.currentFile,
            //    .expr = func.name 
            // }) orelse return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
            // defer self.typechecker.currentScope = prev;

            const pc = self.typechecker.setFlag(.CoveredAllPaths, false);
            defer _ = self.typechecker.setFlag(.CoveredAllPaths, pc);

            try self.typechecker.typecheckStatement(func.body, signature.returnType);
            if (!(
                self.typechecker.typeTable.get(signature.returnType).isZeroBit()
                or self.typechecker.getFlag(.CoveredAllPaths)
            )) {
                self.typechecker.report("Function with return type '{s}' does not return a value in all code paths.", .{
                    try self.typechecker.typeName(self.arena.allocator(), signature.returnType),
                });
                return Error.UncoveredCodePath;
            }

            const stmt = try self.typechecker.lowerer.statement(func.body);
            break :res self.executeBlock(stmt);
        }
        else {
            return common.debug.NotImplemented(self.typechecker.context.log, @src());
        };

    try self.cache.put(.{
        .func = funcPtr,
        .args = args,
    }, .{
        .status = .Evaluated,
        .result = res,
    });
}

fn executeBlock(self: *Executer, blockPtr: JIR.Ptr) Error!Comptime.Value.Ptr {
    const blockValue = self.typechecker.builder.nodes.items(.value)[blockPtr];

    const stmtLen = self.typechecker.builder.data.items[blockValue + 1];
    const stmtStart = blockValue + 2;
    const stmts = self.typechecker.builder.data.items[stmtStart..stmtStart + stmtLen];

    var variableCount: u32 = 0;
    var labelCount: u32 = 0;
    for (stmts) |stmtPtr| {
        const stmtType = self.typechecker.builder.nodes.items(.type)[stmtPtr];

        if (stmtType == .Label) {
            labelCount += 1;
        }
        else if (stmtType == .VariableDef) {
            variableCount += 1;
        }
    }

    var variables = Scope.VariableMap.empty;
    variables.ensureTotalCapacity(self.arena.allocator(), variableCount)
        catch return Error.AllocatorFailure;

    var labels = Scope.LabelMap.empty;
    labels.ensureTotalCapacity(self.arena.allocator(), labelCount)
        catch return Error.AllocatorFailure;

    for (stmts) |stmtPtr| {
        const stmtType = self.typechecker.builder.nodes.items(.type)[stmtPtr];

        if (stmtType == .Label) {
            const labelName = self.typechecker.builder.nodes.items(.value)[stmtPtr];

            labels.putAssumeCapacityNoClobber(labelName, .{
                .sp = self.stack.items.len - 1,
                .off = stmtPtr - stmtStart,
            });
        }
        else if (stmtType == .VariableDef) {
            const stmtValue = self.typechecker.builder.nodes.items(.value)[stmtPtr];

            const typeID = self.typechecker.builder.data.items[stmtValue + 1];
            const name = self.typechecker.builder.data.items[stmtValue + 2];

            variables.putAssumeCapacityNoClobber(name, .{ .Undefined = typeID });
        }
    }

    const scope = Scope{
        .labels = labels,
        .variables = variables,
        .bp = stmtStart,
        .len = stmtLen,
    };

    try self.pushStack(scope);

    var pc: u32 = 0;
    while (pc < self.stack.peek().len) : (pc += 1) {
        const stmt = self.typechecker.builder.nodes.get(self.stack.peek().bp + pc);

        switch (stmt.type) {
            .Jump => {
                const label = try self.getLabel(stmt.value);
                self.stack.revert(label.sp);
            },
            else => {
                return common.debug.NotImplemented(self.typechecker.context.log, @src());
            }
        }
    }
}

fn pushStack(self: *Executer, scope: Scope) Error!void {
    return self.stack.push(scope) catch {
        self.report(std.fmt.comptimePrint("Reached max comptime stack depth of '{d}'", .{defines.comptimeStackLimit}), .{});
        return Error.StackOverflow;
    };
}

fn popStack(self: *Executer) Error!Scope {
    return self.stack.pop() orelse {
        self.report("Stack smash detected at comptime.", .{});
        return Error.StackUnderflow;
    };
}

fn getVar(self: *const Executer, name: defines.StringPtr) Error!Comptime.Value.Ptr {
    var stack = self.stack;
    while (stack.pop()) |scope| {
        if (scope.variables.get(name)) |variable| {
            return variable;
        }
    }

    self.report("Given variable '{s}' is not in the comptime scope.", .{
        self.typechecker.builder.getInternedString(name),
    });
    return Error.EarlyTypecheck;
}

fn setVar(self: *Executer, name: defines.StringPtr, newValue: Comptime.Value.Ptr) Error!void {
    var stack = self.stack;
    while (stack.pop()) |scope| {
        if (scope.variables.get(name)) |_| {
            self.stack.items[stack.index].variables.putAssumeCapacity(name, newValue)
                catch return common.debug.ShouldBeImpossible(undefined, @src());
            return;
        }
    }

    self.report("Given variable '{s}' is not in the comptime scope.", .{
        self.typechecker.builder.getInternedString(name),
    });
    return Error.EarlyTypecheck;
}

fn getLabel(self: *const Executer, name: defines.StringPtr) Error!Scope.Symbol {
    var stack = self.stack;
    while (stack.pop()) |scope| {
        if (scope.labels.get(name)) |lbl| {
            return lbl;
        }
    }

    return common.debug.ShouldBeImpossible(undefined, @src());
}

fn report(self: *Executer, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME EXECUTER: " ++ fmt, args);
}
