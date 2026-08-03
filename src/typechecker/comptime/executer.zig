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

const VariableMap = collections.HashMap(defines.StringPtr, Comptime.Value);
const SymbolMap = collections.HashMap(defines.StringPtr, Symbol);
const Stack = collections.Stack(Scope);

const Symbol = struct {
    pc: defines.Offset,
    scope: defines.ScopePtr,
};

const Scope = struct {
    node: JIR.Ptr,
    variables: VariableMap,
    symbols: SymbolMap,

    pub const Result = union(enum) {
        Return: ?Comptime.Value,
        Void,
    };
};

const Executer = @This();

typechecker: *Typechecker,
arena: Arena,
stack: Stack,

pub fn init(typechecker: *Typechecker, allocator: Allocator) Error!Executer {
    var arena = Arena.init(allocator);

    return .{
        .arena = arena,
        .typechecker = typechecker,
        .stack = try Stack.init(arena.allocator(), 512),
    };
}

pub fn executeCall(
    self: *Executer,
    func: *const JIR.Function,
    args: []JIR.Ptr
) Error!?Comptime.Value {
    var variables = VariableMap.empty;
    variables.ensureTotalCapacity(self.arena.allocator(), @intCast(args.len))
        catch return Error.AllocatorFailure;

    for (args, 0..) |arg, i| {
        variables.putAssumeCapacityNoClobber(func.args[i], try self.expression(arg));
    }

    try self.stack.push(.{
        .node = 0,
        .symbols = .empty,
        .variables = variables,
    });
    defer _ = self.stack.pop();

    const sign = self.typechecker.typeTable.get(func.signature).Function;
    if (sign.isComptime) {
        const prev = self.typechecker.currentFile;
        defer self.typechecker.currentFile = prev;
        self.typechecker.currentFile = func.source;

        try self.typechecker.typecheckStatement(func.body, sign.returnType);

        const val = switch (try self.executeBlock(try self.typechecker.lowerer.statement(func.body))) {
            .Return => |r| r,
            else => null,
        };

        if (val == null or val.? != .Type) {
            return val;
        }

        const rv = self.typechecker.typeTable.get(val.?.Type);
        switch (rv) {
            .Struct, .Union, .Enum => {
                const scope = switch (rv) {
                    .Struct => |str| str.scope,
                    .Enum => |str| str.scope,
                    .Union => |str| str.scope,
                    else => unreachable,
                };

                const defs: []types.FieldInfo = @constCast(switch (rv) {
                    .Struct => |str| str.definitions,
                    .Enum => |str| str.definitions,
                    .Union => |str| str.definitions,
                    else => unreachable,
                });

                for (defs) |*member| {
                    const declPtr = self.typechecker.symbols.lookup.get(.{
                        .scope = scope,
                        .name = self.typechecker.builder.getInternedString(member.name),
                    }) orelse return common.debug.ShouldBeImpossible(undefined, @src());

                    const discoveredType = try self.typechecker.typecheckDecl(declPtr, null);
                    _ = try self.typechecker.folder.evalDecl(declPtr, discoveredType);
                    member.valueType = discoveredType;
                }

                self.typechecker.typeTable.set(val.?.Type, switch (rv) {
                    .Enum => |enm| .{
                        .Enum = .{
                            .name = enm.name,
                            .definitions = defs,
                            .scope = enm.scope,
                            .fields = enm.fields,
                            .mutable = enm.mutable,
                        },
                    },
                    .Struct => |str| .{
                        .Struct = .{
                            .name = str.name,
                            .definitions = defs,
                            .scope = str.scope,
                            .fields = str.fields,
                            .mutable = str.mutable,
                        },
                    },
                    .Union => |uni| .{
                        .Union = .{
                            .isTagged = uni.isTagged,
                            .tag = uni.tag,
                            .name = uni.name,
                            .definitions = defs,
                            .scope = uni.scope,
                            .fields = uni.fields,
                            .mutable = uni.mutable,
                        },
                    },
                    else => return common.debug.ShouldBeImpossible(undefined, @src()),
                });
            },
            else => { },
        }

        return val;
    }
    else {
        return switch (try self.executeBlock(func.body)) {
            .Return => |r| r,
            else => null,
        };
    }
}

pub fn executeBlock(self: *Executer, nodePtr: JIR.Ptr) Error!Scope.Result {
    const block = self.typechecker.builder.nodes.get(nodePtr);

    const stmtsLen = self.typechecker.builder.data.items[block.value + 1];
    const stmtsStart = block.value + 2;
    const stmts = self.typechecker.builder.data.items[stmtsStart..stmtsStart + stmtsLen];

    var varCount: u32 = 0;
    var lblCount: u32 = 0;
    for (stmts) |stmtPtr| {
        const stmt = self.typechecker.builder.nodes.get(stmtPtr);
        if (stmt.type == .VariableDef) {
            varCount += 1;
        }
        else if (stmt.type == .Label) {
            lblCount += 1;
        }
    }

    var labels = SymbolMap.empty;
    labels.ensureTotalCapacity(self.arena.allocator(), lblCount)
        catch return Error.AllocatorFailure;

    for (stmts, 0..) |stmtPtr, i| {
        const stmt = self.typechecker.builder.nodes.get(stmtPtr);
        if (stmt.type == .Label) {
            labels.putAssumeCapacityNoClobber(stmt.value, .{
                .pc = @intCast(i),
                .scope = self.stack.index,
            });
        }
    }

    var variables = VariableMap.empty;
    variables.ensureTotalCapacity(self.arena.allocator(), varCount)
        catch return Error.AllocatorFailure;

    try self.stack.push(.{
        .node = nodePtr,
        .symbols = labels,
        .variables = variables,
    });
    defer _ = self.stack.pop();

    return self.executeBlockLoop();
}

fn executeBlockLoop(self: *Executer) Error!Scope.Result {
    var pc: u32 = 0;
    while (true) : (pc += 1) {
        const nodePtr = self.typechecker.builder.nodes.get(self.stack.peek().?.node).value;
        const stmtsLen = self.typechecker.builder.data.items[nodePtr + 1];
        const stmtsStart = nodePtr + 2;
        const stmts = self.typechecker.builder.data.items[stmtsStart..stmtsStart + stmtsLen];
        
        if (pc >= stmts.len) {
            return .{ .Return = null, };
        }

        const stmtPtr = stmts[pc];
        const stmt = self.typechecker.builder.nodes.get(stmtPtr);

        switch (stmt.type) {
            .VariableDef => {
                const typeID = self.typechecker.builder.data.items[stmt.value + 1];
                const name = self.typechecker.builder.data.items[stmt.value + 2];
                const undef = self.typechecker.builder.data.items[stmt.value + 3];
                const value =
                    if (undef == 1) Comptime.Value{.Undefined = typeID}
                    else try self.expression(self.typechecker.builder.data.items[stmt.value + 4]);

                const frame = self.stack.peek().?;
                frame.variables.putAssumeCapacityNoClobber(name, value);
            },
            .Scope => switch (try self.executeBlock(stmtPtr)) {
                .Return => |r| return .{ .Return = r }, 
                else => { },
            },
            .Jump => {
                const label = self.getSym(stmt.value);
                pc = label.pc;
                self.stack.revert(label.scope);
            },
            .JumpIf => {
                const label = self.getSym(self.typechecker.builder.data.items[stmt.value]);
                const cnd = self.typechecker.builder.data.items[stmt.value + 1];

                if (!(try self.expression(cnd)).Bool) {
                    continue;
                }

                pc = label.pc;
                self.stack.revert(label.scope);
            },
            .Return => {
                return .{ .Return = try self.expression(stmt.value) };
            },
            .Code => {
                self.report("Comptime execution of embedded C code is not permitted.", .{});
                return Error.ComptimeNotPossible;
            },
            .Exit => return .{ .Void = { } },
            .TypeDef, .FunctionDef => { },
            .Assignment => {
                self.report("Assignments are not yet allowed at comptime.", .{});
                return Error.NotImplemented;
            },
            else => return common.debug.NotImplemented(self.typechecker.context.log, @src()),
        }
    }

    return .{ .Void = { } };
}

fn expression(self: *Executer, nodePtr: JIR.Ptr) Error!Comptime.Value {
    const node = self.typechecker.builder.nodes.get(nodePtr);
    return switch (node.type) {
        .Literal => self.literal(nodePtr),
        .Return, .FunctionDef, .TypeDef,
        .Code, .JumpIf, .Scope, .Jump,
        .Assignment, .VariableDef, .Exit => {
            return common.debug.ShouldBeImpossible(undefined, @src());
        },
        .Grouping => self.expression(self.typechecker.builder.data.items[node.value + 1]),
        .Identifier => self.getVar(node.value),
        .ComptimeDef => {
            const prev = self.typechecker.currentFile;
            self.typechecker.currentFile = self.typechecker.builder.data.items[node.value + 1];
            defer self.typechecker.currentFile = prev;

            const valID = try self.typechecker.folder.eval(
                    self.typechecker.builder.data.items[node.value],
                    Comptime.Folder.Builtin.Type("type"),
            );
            const val = self.typechecker.folder.getValue(valID);
            return val;
        },
        .Call => {
            const func = (try self.expression(self.typechecker.builder.data.items[node.value + 1])).Function;
            const argsLen = self.typechecker.builder.data.items[node.value + 2];
            const argsStart = node.value + 3;
            const args = self.typechecker.builder.data.items[argsStart..argsStart + argsLen];
            return (try self.executeCall(&func, args)) orelse .{ .Void = { } };
        },
        else => common.debug.NotImplemented(self.typechecker.context.log, @src()),
    };
}

fn literal(self: *Executer, nodePtr: JIR.Ptr) Error!Comptime.Value {
    return switch (self.typechecker.builder.constants.get(self.typechecker.builder.nodes.get(nodePtr).value)) {
        .Function => |f| .{ .Function = self.typechecker.builder.functions.get(f) },
        .Undefined => |t| .{ .Undefined = t },
        .Float => |f| .{ .Float = f },
        .Integer => |i| switch (i) {
            .i32 => |ii32| .{ .Int = ii32 },
            .u32 => |iu32| .{ .Int = iu32 },
            .i8 => |ii8| .{ .Int = ii8 },
            .u8 => |iu8| .{ .Int = iu8 },
        },
        .String => |s| .{ .String = self.typechecker.builder.getInternedString(s) },
        .Type => |t| .{ .Type = t },
        else => {
            self.report("Aggregates and arrays are not comptime executable.", .{});
            return Error.ComptimeNotPossible;
        },
    };
}

fn getVar(self: *const Executer, varname: defines.StringPtr) Comptime.Value {
    var stack = self.stack;
    while (stack.pop()) |st| {
        if (st.variables.get(varname)) |v| {
            return v;
        }
    }

    unreachable;
}

fn setVar(self: *Executer, varname: defines.StringPtr, new: Comptime.Value) void {
    var i = self.stack.index;
    while (i > 0) {
        i -= 1;
        const frame = &self.stack.items[i];
        if (frame.variables.getPtr(varname)) |ptr| {
            ptr.* = new;
            return;
        }
    }

    unreachable;
}

fn getSym(self: *const Executer, sym: defines.StringPtr) Symbol {
    var stack = self.stack;
    while (stack.pop()) |st| {
        if (st.symbols.get(sym)) |s| {
            return s;
        }
    }

    unreachable;
}

pub fn paramType(self: *Executer, name: defines.StringPtr) Error!Comptime.Value {
    var stack = self.stack;
    while (stack.pop()) |st| {
        if (st.variables.get(name)) |v| {
            return v;
        }
    }

    self.report("Failed to find '{s}' in the current scope.", .{self.typechecker.builder.getInternedString(name)});
    return Error.MissingDefinition;
}

fn report(self: *Executer, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME EXECUTER: " ++ fmt, args);
}
