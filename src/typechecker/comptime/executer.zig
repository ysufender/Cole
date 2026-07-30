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
const SymbolMap = collections.HashMap(defines.StringPtr, defines.Offset);

const Scope = struct {
    parent: ?*Scope,
    variables: VariableMap,
    symbols: SymbolMap,

    pub fn getVar(self: *const Scope, varname: defines.StringPtr) Comptime.Value {
        return
            if (self.variables.get(varname)) |v| v
            else self.parent.?.getVar(varname);
    }

    pub fn setVar(self: *Scope, varname: defines.StringPtr, new: *const Comptime.Value) void {
        if (self.variables.getEntry(varname)) |entry| {
            entry.value_ptr.* = new.*;
        }
        else {
            self.parent.?.setVar(varname, new);
        }
    }

    pub fn getSym(self: *const Scope, sym: defines.StringPtr) defines.Offset {
        return
            if (self.symbols.get(sym)) |v| v
            else self.parent.?.getSym(sym);
    }
};

const Executer = @This();

typechecker: *Typechecker,
arena: Arena,
scope: Scope = .{
    .parent = null,
    .variables = .empty,
    .symbols = .empty,
},

pub fn init(allocator: Allocator, typechecker: *Typechecker) Executer {
    return .{
        .arena = Arena.init(allocator),
        .typechecker = typechecker,
    };
}

pub fn executeCall(
    self: *Executer,
    func: *const JIR.Function,
    args: []JIR.Ptr
) Error!Comptime.Value {
    var variables = VariableMap.empty;
    variables.ensureTotalCapacity(self.arena.allocator(), args.len)
        catch return Error.AllocatorFailure;

    for (args, 0..) |arg, i| {
        variables.putAssumeCapacityNoClobber(func.args[i], try self.expression(arg));
    }

    var parent = self.scope;
    self.scope = .{
        .parent = &parent,
        .symbols = .empty,
    };
    defer self.scope = parent;

    return self.executeBlock(func.body);
}

pub fn executeBlock(self: *Executer, nodePtr: JIR.Ptr) Error!Comptime.Value {
    const stmtsLen = self.typechecker.builder.data.items[nodePtr];
    const stmtsStart = nodePtr + 2;
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
            labels.putAssumeCapacityNoClobber(stmt.value, @intCast(i));
        }
    }

    var variables = VariableMap.empty;
    variables.ensureTotalCapacity(self.arena.allocator(), varCount)
        catch return Error.AllocatorFailure;

    var parent = self.scope;
    self.scope = .{
        .parent = &parent,
        .variables = variables,
        .symbols = labels,
    };

    var pc: u32 = 0;
    while (pc < stmts.len) : (pc += 1) {
        const stmtPtr = stmts[pc];
        const stmt = self.typechecker.builder.nodes.get(stmtPtr);

        switch (stmt.type) {
            .VariableDef => {
                const typeID = self.typechecker.builder.data.items[stmt.value + 1];
                const name = self.typechecker.builder.data.items[stmt.value + 2];
                const undef = self.typechecker.builder.data.items[stmt.value + 3];

                self.scope.setVar(name,
                    if (undef == 1) .{
                        .Undefined = typeID,
                    }
                    else try self.expression(
                        self.typechecker.builder.data.items[stmt.value + 3],
                    )
                );
            },
            .Scope => self.executeBlock(stmtPtr),
            .Assignment => {
                self.report("Assignments are not yet allowed at comptime.", .{});
                return Error.NotImplemented;
            },
        }
    }
    
    return self.typechecker.folder.memory.items[Comptime.Value.Implicit.Void];
}

fn report(self: *Executer, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME EXECUTER: " ++ fmt, args);
}
