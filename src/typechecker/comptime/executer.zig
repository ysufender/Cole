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
    pub const Stack = collections.StaticStack(Key, defines.comptimeStackLimit);

    pub const Status = enum {
        InProgress,
        Evaluated,
        NotEvaluated,
    };

    pub const Key = struct {
        func: defines.StringPtr,
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
        status: Status = .NotEvaluated,
        result: Comptime.Value,
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
    pc: defines.Offset,
    len: u32,
};

const Executer = @This();

cache: Cache.HashMap,
cacheStack: Cache.Stack,
stack: Stack,

typechecker: *Typechecker,

arena: Arena,

pub fn init(typechecker: *Typechecker, allocator: Allocator) Error!Executer {
    var arena = Arena.init(allocator);

    return Executer{
        .cache = try Cache.HashMap.init(@ptrCast(&typechecker.folder), arena.allocator(), typechecker.context.counts.functions),
        .stack = .{ },
        .cacheStack = .{ },
        .arena = arena,
        .typechecker = typechecker,
    };
}

pub fn executeCall(self: *Executer, func: JIR.Function, args: []const Comptime.Value.Ptr) Error!Comptime.Value {
    const prev = self.typechecker.folder.setFlag(.InComptimeCall, true);
    defer _ = self.typechecker.folder.setFlag(.InComptimeCall, prev);

    const instantiation = blk: {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&func.name));
        for (args) |a| hasher.update(std.mem.asBytes(&a));
        break :blk hasher.final();
    };
    const prevInstantiation = self.typechecker.folder.currentInstantiation;
    self.typechecker.folder.currentInstantiation = instantiation;
    defer self.typechecker.folder.currentInstantiation = prevInstantiation;

    if (self.cache.get(.{
        .func = func.name,
        .args = args,
    })) |res| {
        if (res.status == .InProgress) {
            self.report("Infinite recursion detected in function call. Call to '{s}' recurses on itself with the same parameters.", .{
                self.typechecker.builder.getInternedString(func.name),
            });
            return Error.DependencyCycle;
        }
        else if (res.status == .Evaluated) {
            return res.result;
        }
    }

    const signature = self.typechecker.typeTable.get(func.signature).Function;

    try self.cache.put(.{
        .func = func.name,
        .args = args,
    }, .{
        .status = .InProgress,
        .result = .{ .Undefined = signature.returnType },
    });
    errdefer _ = self.cache.remove(.{ .func = func.name, .args = args });

    try self.cacheStack.push(.{
        .func = func.name,
        .args = args,
    });
    errdefer _ = self.cacheStack.pop();

    var variables = Scope.VariableMap.empty;
    variables.ensureTotalCapacity(self.arena.allocator(), @intCast(args.len))
        catch return Error.AllocatorFailure;

    for (args, 0..) |arg, idx| {
        variables.putAssumeCapacityNoClobber(func.args[idx], self.typechecker.folder.memory.items[arg]);
    }

    const scope = Scope{
        .variables = variables,
        .labels = Scope.LabelMap.empty,
        .bp = 0,
        .pc = 0,
        .len = 0,
    };
    const current = self.stack.index;
    try self.stack.push(scope);
    defer self.stack.revert(current);

    const res =
        try if (signature.isComptime) res: {
            const prevfile = self.typechecker.currentFile;
            self.typechecker.currentFile = func.source;
            defer self.typechecker.currentFile = prevfile;

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
        else self.executeBlock(func.body);

    try self.cache.put(.{
        .func = func.name,
        .args = args,
    }, .{
        .status = .Evaluated,
        .result = res,
    });

    return res;
}

fn executeBlock(self: *Executer, blockPtr: JIR.Ptr) Error!Comptime.Value {
    try self.decodePushScope(blockPtr);

    while (true) {
        const topScope = self.stack.peek();
        defer topScope.pc += 1;

        if (topScope.pc >= topScope.len) {
            _ = self.stack.pop() orelse break;
            continue;
        }

        const stmt = self.typechecker.builder.nodes.get(self.typechecker.builder.data.items[topScope.bp + topScope.pc]);

        switch (stmt.type) {
            .Jump => {
                const label = try self.getLabel(stmt.value);
                self.stack.revert(label.sp);
            },
            .VariableDef => {
                const typeID = self.typechecker.builder.data.items[stmt.value + 1];
                const name = self.typechecker.builder.data.items[stmt.value + 2];

                const initializer =
                    if (self.typechecker.builder.data.items[stmt.value + 3] == 1) Comptime.Value{
                        .Undefined = typeID,
                    }
                    else try self.expression(self.typechecker.builder.data.items[stmt.value + 4]);

                topScope.variables.putAssumeCapacityNoClobber(name, initializer);
            },
            .Exit => _ = self.stack.pop() orelse {
                self.report("Unterminated scope, but how?", .{});
                return Error.MissingBrace;
            },
            .Scope => {
                try self.decodePushScope(self.typechecker.builder.data.items[topScope.bp + topScope.pc]);
            },
            .Code => {
                self.report("Foreign code blocks are not suitable in comptime contexts.", .{});
                return Error.ComptimeNotPossible;
            },
            .Return => return self.expression(stmt.value),
            else => {
                return common.debug.NotImplemented(self.typechecker.context.log, @src());
            }
        }
    }

    return self.typechecker.folder.memory.items[@intFromEnum(Comptime.Value.Implicit.Void)];
}

fn expression(self: *Executer, exprPtr: JIR.Ptr) Error!Comptime.Value {
    const expr = self.typechecker.builder.nodes.get(exprPtr);

    return switch (expr.type) {
        .Jump, .JumpIf, .Exit, .Scope, .Code, .VariableDef, .Assignment,
        .FunctionDef, .Label, .TypeDef, .Return => common.debug.ShouldBeImpossible(undefined, @src()),
        .Identifier => self.getVar(expr.value),
        .Literal => self.literal(expr.value),
        .Call => self.call(expr.value),
        else => common.debug.NotImplemented(self.typechecker.context.log, @src()),
    };
}

fn call(self: *Executer, dataPtr: defines.OpaquePtr) Error!Comptime.Value {
    const funcPtr = self.typechecker.builder.data.items[dataPtr + 1];
    const argsLen = self.typechecker.builder.data.items[dataPtr + 2];
    const argsStart = dataPtr + 3;

    const function = (try self.expression(funcPtr)).Function;

    const args = self.arena.allocator().alloc(JIR.Ptr, argsLen)
        catch return Error.AllocatorFailure;

    for (0..argsLen) |idx| {
        args[idx] = try self.typechecker.folder.appendValue(
            try self.expression(@intCast(argsStart + idx))
        );
    }

    return self.executeCall(function, args);
}

fn literal(self: *Executer, constPtr: JIR.Ptr) Error!Comptime.Value {
    const constant = self.typechecker.builder.constants.get(constPtr);

    return switch (constant) {
        .Undefined => |typeID| .{ .Undefined = typeID },
        .Float => |fl| .{ .Float = fl },
        .Function => |func| .{ .Function = self.typechecker.builder.functions.get(func) },
        .String => |str| .{ .String = self.typechecker.builder.getInternedString(str) },
        .Void => .{ .Void = { } },
        .Type => |typeID| .{ .Type = typeID },
        .Integer => |integer| .{
            .Int = switch (integer) {
                .i32 => |i| @intCast(i),
                .u32 => |i| @intCast(i),
                .i8 => |i| @intCast(i),
                .u8 => |i| @intCast(i),
            },
        },
        else => |t| {
            self.report("'{s}' literals are not supported in comptime sopces.", .{
                @tagName(t),
            });
            return Error.ComptimeNotPossible;
        },
    };
}

fn decodePushScope(self: *Executer, blockPtr: JIR.Ptr) Error!void {
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
                .sp = @intCast(self.stack.items.len - 1),
                .off = stmtPtr - stmtStart,
            });
        }
    }

    const scope = Scope{
        .labels = labels,
        .variables = variables,
        .bp = stmtStart,
        .pc = 0,
        .len = stmtLen,
    };

    try self.pushStack(scope);
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

pub fn getVar(self: *Executer, name: defines.StringPtr) Error!Comptime.Value {
    var stack = self.stack;
    while (stack.pop()) |scope| {
        if (scope.variables.get(name)) |variable| {
            return variable;
        }
    }

    self.report("Given variable '{s}' is not in the comptime scope.", .{
        self.typechecker.builder.getInternedString(name),
    });
    return Error.EarlyEval;
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
    return Error.EarlyEval;
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
