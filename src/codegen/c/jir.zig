// @Note this JIR backend is fairly high level,
// it doesn't have low-level info about the stack
// indices etc since it passes all those problems
// to the C compiler. Keep in mind that such thing
// won't be the case for future backends.

const std = @import("std");
const common = @import("../../core/common.zig");
const defines = @import("../../core/defines.zig");
const collections = @import("../../util/collections.zig");
const Types = @import("../../typechecker/type.zig");

const Typechecker = @import("../../typechecker/typechecker.zig");
const Comptime = @import("../../typechecker/comptime.zig");
const MultiArrayList = @import("../../util/collections.zig").MultiArrayList;
const TypeID = Types.TypeID;
const Allocator = std.mem.Allocator;
const Error = common.CompilerError;
const CompilerSettings = common.CompilerSettings;
const Arena = std.heap.ArenaAllocator;
const Context = common.CompilerContext;
const CreateDirError = std.Io.Dir.CreateDirError;
const TypeNameMap = @import("../../typechecker/typechecker.zig").TypeNameMap;

pub const InternTable = std.array_hash_map.String(void);

pub const Ptr = defines.Offset;

pub const Builder = @import("jir/builder.zig");

pub const Node = struct {
    pub const List = MultiArrayList(Node);

    pub const Type = enum {
        TypeDef,
        FunctionDef,
        VariableDef,
        Identifier,
        Assignment, // Direct assignment to a variable.
        Store, // Assignment through pointer
        Return,
        Scope,
        Exit,
        Reference,
        Dereference,
        Call,
        Literal,
        Add,
        Sub,
        Div,
        Mul,
        LeftShift,
        RightShift,
        And,
        Or,
        Label,
        Dot,
        Grouping,
        Jump,
        JumpIf,
        Lesser,
        LesserEqual,
        Greater,
        GreaterEqual,
        Equal,
        NotEqual,
        Ternary,
        Invert,
        Xor,
        BitwiseOr,
        BitwiseAnd,
        Not,
        Negation,
    };

    type: Type,
    value: defines.EitherPtr(Ptr, u32),
};

pub const Constant = union(enum) {
    pub const Ptr = defines.Offset;
    pub const List = std.MultiArrayList(Constant).Slice;

    const ConstantArray = struct {
        type: TypeID,
        data: defines.Range,
    };

    Integer: union(enum) {
        i32: i32,
        u32: u32,
        i8: i8,
        u8: u8,
    },
    Float: f32,
    Aggregate: ConstantArray, 
    Array: ConstantArray,
    Pointer: Constant.Ptr,
    Undefined: TypeID,
    Function: Function.Ptr,
};

pub const Function = struct {
    pub const Ptr = defines.Offset;
    pub const List = MultiArrayList(Function).Slice;

    signature: TypeID,
    body: defines.Range,
};

const JIR = @This();

strings: [][]const u8,
types: Typechecker.TypeTable.Slice,
typeNames: TypeNameMap,
constants: Constant.List,
functions: Function.List,
nodes: Node.List.Slice,
keyNodes: []const Ptr,
data: []const u32,
allocator: Allocator = undefined,

pub fn dump(self: *const JIR) void {
    common.log.debug("Registered types:", .{});
    for (0..self.types.len) |index| {
        common.log.debug("    {d}", .{ index });
    }

    common.log.debug("Lowered IR:", .{});
    var iterator = self.nodes.iterator();
    while (iterator.next()) |node| {
        common.log.debug("{s}", .{@tagName(node.type)});
    }
}

pub fn codegen(self: *JIR, context: *Context) Error!void {
    self.allocator = context.arena.allocator();

    std.Io.Dir.cwd().createDir(context.io, "build", .default_dir) catch |err| switch (err) {
        CreateDirError.PathAlreadyExists => { },
        else => {
            common.log.err("Failed to create output directory.", .{});
            return Error.IOError;
        },
    };

    const buildDir = std.Io.Dir.cwd().openDir(context.io, "build", .{})
        catch return Error.IOError;

    while (true) {
        buildDir.createDir(context.io, "c/", .default_dir) catch |err| switch (err) {
            CreateDirError.PathAlreadyExists => {
                buildDir.deleteTree(context.io, "c")
                    catch return Error.IOError;
                continue;
            },
            else => {
                common.log.err("Failed to create output directory.", .{});
                return Error.IOError;
            },
        };
        break;
    }

    const cOut = buildDir.openDir(context.io, "c", .{})
        catch return Error.IOError;

    var wbuf: [256]u8 = undefined;

    var forwardDeclFile = cOut.createFile(context.io, "forward_decl.h", .{ })
        catch return Error.IOError;
    defer forwardDeclFile.close(context.io);
    var forwardDeclWriter = forwardDeclFile.writer(context.io, &wbuf);
    try self.forwardDecls(&forwardDeclWriter.interface);

    var sourceFile = cOut.createFile(context.io, "source.c", .{ })
        catch return Error.IOError;
    defer sourceFile.close(context.io);
    var sourceWriter = sourceFile.writer(context.io, &wbuf);
    try self.sourceGen(&sourceWriter.interface);
}

fn forwardDecls(self: *JIR, out: *std.Io.Writer) Error!void {
    out.print(
    \\/*
    \\ * This file has been automatically generated
    \\ * by the JASL compiler.
    \\ */
    \\
    \\#ifndef JASL_CODEGEN_C_FORWARD_DECLS_H
    \\#define JASL_CODEGEN_C_FORWARD_DECLS_H
    \\
    \\#include <stdint.h>
    \\
    \\typedef uint8_t bool;
    \\
    \\
    , .{}) catch return Error.IOError;
    defer { 
        out.print("\n#endif /* JASL_CODEGEN_C_FORWARD_DECLS_H */\n" , .{}) catch common.log.err("Failed to end header.", .{});
        out.flush() catch common.log.err("Failed to flush forward declarations.", .{});
    }

    for (0..self.keyNodes.len) |i| {
        try self.discoverFunctionsAndTypes(out, self.keyNodes[self.keyNodes.len - i - 1]);
    }
}

fn discoverFunctionsAndTypes(self: *JIR, out: *std.Io.Writer, nodePtr: Ptr) Error!void {
    const node = self.nodes.get(nodePtr);
    switch (node.type) {
        .FunctionDef => {
            const typeID = self.functions.get(self.data[node.value + 1]).signature;
            const typeInfo = self.types.get(typeID).Function;

            var args: []const u8 = "";
            for (0.., typeInfo.argTypes) |i, typePtr| {
                args = std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{
                    args,
                    self.getCName(typePtr),
                    if (i == typeInfo.argTypes.len - 1) "" else ",",
                    if (i == typeInfo.argTypes.len - 1) "" else " ",
                }) catch return Error.AllocatorFailure;
            }

            // @Beware terribly unsafe, but I can guarantee the strings
            // live in heap, so no worries.
            _ = std.mem.replace(u8, self.strings[self.data[node.value]], "::", "__", @constCast(self.strings[self.data[node.value]].ptr)[0..self.strings[self.data[node.value]].len]);
            out.print("{s} {s}({s});\n", .{
                self.getCName(typeInfo.returnType),
                self.strings[self.data[node.value]],
                args
            }) catch return Error.IOError;
        },
        .TypeDef => {
        },
        .Scope => { },
        else => { },
    }
}

fn sourceGen(_: *JIR, out: *std.Io.Writer) Error!void {
    out.print(
    \\/*
    \\ * This file has been automatically generated
    \\ * by the JASL compiler.
    \\ */
    \\
    \\#include "forward_decl.h"
    , .{}) catch return Error.IOError;
    defer out.flush() catch {
        common.log.err("Failed to flush source file.", .{});
    };
}

fn typeName(self: *JIR, typeID: TypeID) []const u8 {
    return self.strings[self.typeNames.get(typeID) orelse return "<UNKNOWN>"];
}

fn getCName(self: *JIR, typeID: TypeID) []const u8 {
    inline for (builtins) |builtin| {
        if (builtin.name == typeID) {
            return builtin.cname;
        }
    }

    _ = self;
    unreachable;
}

pub const builtins = [_]struct {
    name: TypeID,
    cname: []const u8,
}{
    .{ .name = Comptime.Builtin.Type("u32"), .cname = "uint32_t" },
    .{ .name = Comptime.Builtin.Type("i32"), .cname = "int32_t" },
    .{ .name = Comptime.Builtin.Type("u8"), .cname = "uint8_t" },
    .{ .name = Comptime.Builtin.Type("i8"), .cname = "int8_t" },
    .{ .name = Comptime.Builtin.Type("bool"), .cname = "bool" },
    .{ .name = Comptime.Builtin.Type("float"), .cname = "float" },
    .{ .name = Comptime.Builtin.Type("void"), .cname = "void" },
    .{ .name = Comptime.Builtin.Type("comptime_int"), .cname = "uint32_t" },
    .{ .name = Comptime.Builtin.Type("comptime_float"), .cname = "float" },
    .{ .name = Comptime.Builtin.Type("noreturn"), .cname = "void" },
};

