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

cstrings: std.AutoHashMapUnmanaged(TypeID, []const u8) = undefined,
strings: [][]const u8,
types: Typechecker.TypeTable.Slice,
typeNames: TypeNameMap,
constants: Constant.List,
functions: Function.List,
nodes: Node.List.Slice,
keyNodes: []const Ptr,
data: []const u32,
allocator: Allocator = undefined,
context: *const Context,

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

    self.cstrings = .empty;

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
    \\typedef uint8_t jasl_bool;
    \\
    \\
    , .{}) catch return Error.IOError;
    defer { 
        out.print("\n#endif /* JASL_CODEGEN_C_FORWARD_DECLS_H */\n" , .{}) catch common.log.err("Failed to end header.", .{});
        out.flush() catch common.log.err("Failed to flush forward declarations.", .{});
    }

    for (self.keyNodes) |node| {
        try self.discoverFunctionsAndTypes(out, node);
    }
}

fn discoverFunctionsAndTypes(self: *JIR, out: *std.Io.Writer, nodePtr: Ptr) Error!void {
    const node = self.nodes.get(nodePtr);
    switch (node.type) {
        .VariableDef => if (self.data[node.value] == 1) {
            const typeID = self.data[node.value + 1];
            _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "::", "__", @constCast(self.strings[self.data[node.value + 2]]));
            _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "$", "_", @constCast(self.strings[self.data[node.value + 2]]));
            out.print("extern {s} {s};\n\n", .{
                try self.getCName(typeID),
                self.strings[self.data[node.value + 2]],
            }) catch return Error.IOError;
        },
        .FunctionDef => {
            const typeID = self.functions.get(self.data[node.value + 1]).signature;
            const typeInfo = self.types.get(typeID).Function;

            var args: []const u8 = "";
            for (0.., typeInfo.argTypes) |i, typePtr| {
                args = std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{
                    args,
                    try self.getCName(typePtr),
                    if (i == typeInfo.argTypes.len - 1) "" else ",",
                    if (i == typeInfo.argTypes.len - 1) "" else " ",
                }) catch return Error.AllocatorFailure;
            }

            _ = std.mem.replace(u8, self.strings[self.data[node.value]], "::", "__", @constCast(self.strings[self.data[node.value]]));
            _ = std.mem.replace(u8, self.strings[self.data[node.value]], "$", "_", @constCast(self.strings[self.data[node.value]]));
            out.print("{s} {s}({s});\n\n", .{
                try self.getCName(typeInfo.returnType),
                self.strings[self.data[node.value]],
                args
            }) catch return Error.IOError;
        },
        .TypeDef => {
            const typeID = node.value;
            const typeInfo = self.types.get(typeID);

            switch (typeInfo) {
                .Struct => |str| {
                    out.print("typedef struct {{\n", .{}) catch return Error.IOError;
                    for (str.fields) |field| {
                        out.print("\t{s} {s}_{s};\n", .{
                            try self.getCName(field.valueType),
                            if (field.public) "pub" else "priv",
                            self.strings[field.name],
                        }) catch return Error.IOError;
                    }
                    const name = self.strings[str.name];
                    _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
                    _ = std.mem.replace(u8, name, "$", "_", @constCast(name));
                    out.print("}} {s};\n\n", .{name}) catch return Error.IOError;
                },

                .Union => |uni|{
                    if (uni.isTagged) {
                        out.print("typedef struct {{\n", .{}) catch return Error.IOError;
                        out.print("\t{s} {s}_{s};\n", .{
                            try self.getCName(uni.fields[0].valueType),
                            if (uni.fields[0].public) "pub" else "priv",
                            self.strings[uni.fields[0].name],
                        }) catch return Error.IOError;
                        out.print("\tunion {{\n", .{}) catch return Error.IOError;
                        for (uni.fields[1..]) |field| {
                            out.print("\t\t{s} {s};\n", .{
                                try self.getCName(field.valueType),
                                self.strings[field.name],
                            }) catch return Error.IOError;
                        }
                        out.print("\t}};\n", .{}) catch return Error.IOError;
                        const name = self.strings[uni.name];
                        _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
                        _ = std.mem.replace(u8, name, "$", "_", @constCast(name));
                        out.print("}} {s};\n\n", .{name}) catch return Error.IOError;
                    }
                    else {
                        out.print("typedef union {{\n", .{}) catch return Error.IOError;
                        for (uni.fields) |field| {
                            out.print("\t{s} {s};\n", .{
                                try self.getCName(field.valueType),
                                self.strings[field.name],
                            }) catch return Error.IOError;
                        }
                        const name = self.strings[uni.name];
                        _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
                        _ = std.mem.replace(u8, name, "$", "_", @constCast(name));
                        out.print("}} {s};\n\n", .{name}) catch return Error.IOError;
                    }
                },

                .Enum => |enm| {
                    const name = self.strings[enm.name];
                    _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
                    _ = std.mem.replace(u8, name, "$", "_", @constCast(name));
                    out.print("typedef enum {{\n", .{}) catch return Error.IOError;
                    for (enm.fields) |field| {
                        out.print("\t{s}_{s},\n", .{
                            name,
                            field,
                        }) catch return Error.IOError;
                    }
                    out.print("}} {s};\n\n", .{name}) catch return Error.IOError;
                },

                else => return common.debug.ShouldBeImpossible(@src()),
            }
        },
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

fn getCName(self: *JIR, typeID: TypeID) Error![]const u8 {
    if (self.cstrings.get(typeID)) |name| {
        return name;
    }

    const typeInfo = self.types.get(typeID);
    var name: []const u8 = "";
    switch (typeInfo) {
        .Type, .Any, .EnumLiteral,
        .Noreturn, .Void => return common.debug.ShouldBeImpossible(@src()),

        .Bool => |v| name = std.fmt.allocPrint(self.allocator, "jasl_bool{s}", .{
            if (v) "" else " const"
        }) catch return Error.AllocatorFailure,
        .Float => |v| name = std.fmt.allocPrint(self.allocator, "float{s}", .{
            if (v) "" else " const"
        }) catch return Error.AllocatorFailure,
        .ComptimeFloat => name = "float const" ,
        .ComptimeInt => name = "int32_t const" ,
        .Integer => |i| name = std.fmt.allocPrint(self.allocator, "{s}int{d}_t const", .{
            if (i.signed) "" else "u",
            i.size,
        }) catch return Error.AllocatorFailure,

        .Union, .Struct, .Enum => {
            name = self.strings[
                if (typeInfo == .Struct) typeInfo.Struct.name
                else if (typeInfo == .Union) typeInfo.Union.name
                else typeInfo.Enum.name
            ];

            _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
            _ = std.mem.replace(u8, name, "$", "_", @constCast(name));

            const mut =
                if (typeInfo == .Struct) typeInfo.Struct.mutable
                else if (typeInfo == .Union) typeInfo.Union.mutable
                else typeInfo.Enum.mutable;

            name = std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                name,
                if (mut) "" else " const",
            }) catch return Error.AllocatorFailure;
        },

        .Function => |func| {
            var args: []const u8 = "";
            for (0.., func.argTypes) |i, typePtr| {
                args = std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{
                    args,
                    try self.getCName(typePtr),
                    if (i == func.argTypes.len - 1) "" else ",",
                    if (i == func.argTypes.len - 1) "" else " ",
                }) catch return Error.AllocatorFailure;
            }

            name = std.fmt.allocPrint(self.allocator, "{s}(*)({s})", .{
                try self.getCName(func.returnType),
                args
            }) catch return Error.IOError;
        },

        .Array => |arr| {
            name = std.fmt.allocPrint(self.allocator, "Array_{s}_{d}{s}", .{
                try self.getCName(arr.child),
                arr.len,
                if (arr.mutable) "" else " const",
            }) catch return Error.AllocatorFailure;
        },

        .Pointer => |ptr| switch (ptr.size) {
            .Slice => {
                name = std.fmt.allocPrint(self.allocator, "Slice_{s}{s}", .{
                    try self.getCName(ptr.child),
                    if (ptr.mutable) "" else " const",
                }) catch return Error.AllocatorFailure;
            },
            .Single, .C => {
                name = std.fmt.allocPrint(self.allocator, "{s}*{s}", .{
                    try self.getCName(ptr.child),
                    if (ptr.mutable) "" else " const",
                }) catch return Error.AllocatorFailure;
            },
        },
    }

    self.cstrings.putNoClobber(self.allocator, typeID, name)
        catch return Error.AllocatorFailure;
    return name;
}
