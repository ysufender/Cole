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
const JIRExecuter = @import("executer/jir.zig");
const ASTExecuter = @import("executer/ast.zig");


const Executer = @This();

typechecker: *Typechecker,
arena: Arena,

jir: JIRExecuter,
ast: ASTExecuter,

pub fn init(typechecker: *Typechecker, allocator: Allocator) Error!Executer {
    var arena = Arena.init(allocator);

    return Executer{
        .arena = arena,
        .typechecker = typechecker,
        .jir = try JIRExecuter.init(typechecker, arena.allocator()),
        .ast = try ASTExecuter.init(typechecker, arena.allocator()),
    };
}

pub fn executeCall(self: *Executer, func: *JIR.Function, args: []const Comptime.Value.Ptr) Error!Comptime.Value {
    self.jir.allocator = self.arena.allocator();
    self.jir.executer = self;

    self.ast.allocator = self.arena.allocator();
    self.ast.executer = self;

    const psrc = self.typechecker.currentFile;
    defer self.typechecker.currentFile = psrc;
    self.typechecker.currentFile = func.source;

    const signature = self.typechecker.typeTable.get(func.signature).Function;

    return
        if (signature.isComptime) try self.ast.executeCall(func, args)
        else try self.jir.executeCall(func, args);
}

fn report(self: *Executer, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME EXECUTER: " ++ fmt, args);
}
