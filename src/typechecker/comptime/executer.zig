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

const FlagMap = std.bit_set.IntegerBitSet(8);
const Stack = collections.Stack(Comptime.Value);
const Memory = collections.Stack(Comptime.Value);
const VariableMap = collections.HashMap(defines.DeclPtr, Comptime.Value);

const Scope = struct {
    parent: ?*Scope,
    variables: Memory,
    stackPointer: u32,
};

const Executer = @This();
