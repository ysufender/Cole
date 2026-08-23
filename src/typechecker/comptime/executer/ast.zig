const std = @import("std");
const common = @import("../../../core/common.zig");
const defines = @import("../../../core/defines.zig");
const collections = @import("../../../util/collections.zig");
const types = @import("../../type.zig");
const backend = @import("../../../codegen/backend.zig");

const assert = std.debug.assert;

const Lexer = @import("../../../lexer/lexer.zig");
const Parser = @import("../../../parser/parser.zig");
const Typechecker = @import("../../typechecker.zig");
const Resolver = @import("../../resolver.zig");
const Comptime = @import("../../comptime.zig");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = common.CompilerError;
const TypeID = types.TypeID;
const TypeInfo = types.TypeInfo;
const JIR = backend.C.JIR;
const Executer = @import("../executer.zig");

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

const ASTExecuter = @This();

typechecker: *Typechecker,
cache: Cache.HashMap,
executer: *Executer,
allocator: Allocator,

pub fn init(typechecker: *Typechecker, allocator: Allocator) Error!ASTExecuter {
    return .{
        .typechecker = typechecker,
        .executer = undefined,
        .allocator = undefined,
        .cache = try Cache.HashMap.init(@ptrCast(&typechecker.folder), allocator, typechecker.context.counts.functions),
    };
}

pub fn executeCall(self: *ASTExecuter, func: *JIR.Function, args: []const Comptime.Value.Ptr) Error!Comptime.Value {
    _ = self;
    _ = func;
    _ = args;
    unreachable;
}
