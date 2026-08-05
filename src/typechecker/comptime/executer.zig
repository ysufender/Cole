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
    const VariableMap = collections.HashMap(defines.StringPtr, Comptime.Value.Ptr);
    const LabelMap = collections.HashMap(defines.StringPtr, defines.Offset);

    variables: VariableMap,
    labels: LabelMap,
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

pub fn executeCall()

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

fn report(self: *Executer, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME EXECUTER: " ++ fmt, args);
}
