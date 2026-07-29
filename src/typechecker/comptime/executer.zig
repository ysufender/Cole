// @Note Function calls do not get cached as for now, that means
// comptime execution goes on till the stack blows up. Stack, that
// is the host machine stack, not the Stack here.
//
// @Note executes JIR instead of raw AST unlike Comptime.Folder.

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

const FlagMap = std.bit_set.IntegerBitSet(8);
const Stack = collections.Stack(Comptime.Value);

/// Since strings are interned, each StringPtr is unique.
const VariableMap = collections.HashMap(defines.StringPtr, Comptime.Value);
const SymbolMap = collections.HashMap(defines.StringPtr, defines.Offset);

const Scope = struct {
    parent: ?*Scope,
    stackPointer: u32,
    symbols: SymbolMap,
    variables: VariableMap,

    pub const Result = union(enum) {
        Return,
        Jump: defines.StringPtr,
    };
};

const InLoop = 0;
const Return = 1;

const Executer = @This();

typechecker: *Typechecker,
stack: Stack,
flags: FlagMap,
arena: Arena,
scope: ?Scope = null,

pub fn init(folder: *Typechecker, allocator: Allocator) Error!Executer {
    var arena = Arena.init(allocator);

    var map = VariableMap.empty;
    map.ensureTotalCapacity(arena.allocator(), 512)
        catch return Error.AllocatorFailure;

    return .{
        .flags = FlagMap.initEmpty(),
        .typechecker = folder,
        .stack = try Stack.init(folder.arena.allocator(), 512),
        .arena = arena,
    };
}

pub fn executeCall(self: *Executer, func: *const JIR.Function, args: []JIR.Ptr) Error!Comptime.Value {
    for (args) |value| {
        try self.stack.push(try self.expression(value));
    }

    var vars = VariableMap.empty;
    vars.ensureTotalCapacity(self.arena.allocator(), @intCast(func.args.len))
        catch return Error.AllocatorFailure;

    var prevScope = self.scope;
    self.scope = .{
        .parent = if (prevScope) |*bod| bod else null,
        .stackPointer = self.stack.index,
        .symbols = .empty,
        .variables = vars,
    };
    defer self.scope = prevScope;

    for (func.args, 0..) |argn, idx| {
        self.scope.?.variables.putAssumeCapacityNoClobber(
            argn,
            try self.expression(args[idx]),
        );
    }

    return self.executeBlock(func.body);
}

fn executeBlock(self: *Executer, bodyPtr: JIR.Ptr) Error!Comptime.Value {
    const builder = self.typechecker.builder;

    const scopePtr = builder.nodes.get(bodyPtr).value;
    const body = builder.data.items[scopePtr + 2..scopePtr + 2 + builder.data.items[scopePtr + 1]];

    var syms = SymbolMap.empty;
    {
        var count: u32 = 0;
        for (body) |stmtPtr| {
            const stmt = builder.nodes.get(stmtPtr);
            if (stmt.type == .Label) {
                count += 1;
            }
        }

        syms.ensureTotalCapacity(self.arena.allocator(), count)
            catch return Error.AllocatorFailure;
        for (body, 0..) |stmtPtr, idx| {
            const stmt = builder.nodes.get(stmtPtr);
            if (stmt.type == .Label) {
                syms.putAssumeCapacityNoClobber(stmt.value, @intCast(idx));
            }
        }
    }

    var vars = VariableMap.empty;
    {
        var count: u32 = 0;
        for (body) |stmtPtr| {
            const stmt = builder.nodes.get(stmtPtr);
            if (stmt.type == .VariableDef) {
                count += 1;
            }
        }

        vars.ensureTotalCapacity(self.arena.allocator(), count)
            catch return Error.AllocatorFailure;
    } 

    var prevScope = self.scope;
    self.scope = .{
        .parent = if (prevScope) |*bod| bod else null,
        .stackPointer = self.stack.index,
        .symbols = syms,
        .variables = vars,
    };
    defer self.scope = prevScope;

    const scope = self.scope.?;

    var pc: u32 = 0;
    while (pc < body.len) : (pc += 1) {
        const stmt = builder.nodes.get(body[pc]);

        switch (stmt.type) {
            .Jump => pc = scope.symbols.get(stmt.value).?,
            .JumpIf => {
                const lbl = builder.nodes.get(builder.data.items[stmt.value]);
                const cndPtr = builder.data.items[stmt.value + 1];

                const cnd = (try self.expression(cndPtr)).Bool;
                if (cnd) {
                    pc = scope.symbols.get(lbl.value).?;
                }
            },
            .VariableDef => {
                const name = builder.data.items[stmt.value + 2];
                if (builder.data.items[stmt.value + 3] == 1) {
                    self.scope.?.variables.putAssumeCapacityNoClobber(name, .{
                        .Undefined = builder.data.items[stmt.value + 1],
                    });
                }
                else {
                    self.scope.?.variables.putAssumeCapacityNoClobber(
                        name,
                        try self.expression(builder.data.items[stmt.value + 4]),
                    );
                }
            },
            .Label, .TypeDef, .FunctionDef => { },
            .Code => {
                self.report("Foreign C code execution is not possible.", .{});
                return Error.ComptimeNotPossible;
            },
            .Call => {
                assert(builder.data.items[stmt.value] == 1);

                const func = (try self.expression(builder.data.items[stmt.value + 1])).Function;
                const args = builder.data.items[stmt.value + 3..stmt.value + 3 + builder.data.items[stmt.value + 2]];
                _ = try self.executeCall(&func, args);
            },
            .Return => return self.expression(stmt.value),
            .Assignment => {
                self.report("Comptime assignments are not implemented yet.", .{});
                return Error.NotImplemented;
            },
            else => unreachable,
        }
    }

    return .{ .Void = {} };
}

fn expression(self: *Executer, _node: JIR.Ptr) Error!Comptime.Value {
    const builder = self.typechecker.builder;

    const node = builder.nodes.get(_node);
    return switch (node.type) {
        .Literal => self.literal(node.value),
        else => {
            self.report("'{s}' is not implemented.", .{@tagName(node.type)});
            return common.debug.NotImplemented(self.typechecker.context.log, @src());
        },
    };
}

fn literal(self: *Executer, constPtr: JIR.Constant.Ptr) Error!Comptime.Value {
    const builder = self.typechecker.builder;
    return switch (builder.constants.get(constPtr)) {
        .Undefined => |typeID| .{ .Undefined = typeID },
        .Float => |fl| .{ .Float = fl },
        .Function => |func| .{ .Function = builder.functions.get(func) },
        .String => |str| .{ .String = builder.getInternedString(str) },
        .Type => |typeID| .{ .Type = typeID },
        .Integer => |int| .{ .Int = switch (int) {
            .u32 => |iu32| iu32,
            .i32 => |ii32| ii32,
            .i8 => |ii8| ii8,
            .u8 => |iu8| iu8,
        }},
        else => |tag| {
            self.report("Comptime executor can't handle complex value '{s}' yet.", .{
                @tagName(tag),
            });
            return Error.NotImplemented;
        },
    };
}

fn report(self: *Executer, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME: EXECUTER: " ++ fmt, args);
}
