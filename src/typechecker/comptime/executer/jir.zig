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

const JIRExecuter = @This();

typechecker: *Typechecker,
allocator: Allocator,
executer: *Executer,

pub fn init(typechecker: *Typechecker, allocator: Allocator) Error!JIRExecuter {
    return .{
        .typechecker = typechecker,
        .allocator = allocator,
        .executer = undefined,

    };
}

pub fn executeCall(self: *JIRExecuter, _: *JIR.Function, _: []const Comptime.Value.Ptr) Error!Comptime.Value {
    return common.debug.NotImplemented(self.typechecker.context.log, @src());
}
