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
const Comptime= @import("../../typechecker/comptime.zig");
const MultiArrayList = @import("../../util/collections.zig").MultiArrayList;
const TypeID = Types.TypeID;
const Allocator = std.mem.Allocator;
const Error = common.CompilerError;
const CompilerSettings = common.CompilerSettings;
const Arena = std.heap.ArenaAllocator;
const Context = common.CompilerContext;
const CreateDirError = std.Io.Dir.CreateDirError;
const TypeNameMap = @import("../../typechecker/typechecker.zig").TypeNameMap;

const Writer = std.Io.Writer;

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
        Assignment,
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
        Construction,
        Code,
        Mod,
        Discard,
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

        c_int: c_int,
        c_uint: c_uint,
        c_char: c_char,
        c_uchar: u8,
        c_long: c_long,
        c_ulong: c_ulong,
        c_short: c_short,
        c_ushort: c_ushort,
        c_size: usize,
    },
    String: struct {
        type: enum {
            C,
            Cole,
        },
        str: defines.StringPtr,
    },
    Float: union(enum) {
        f32: f32,
        f64: f64,
    },
    Aggregate: ConstantArray, 
    Array: ConstantArray,
    Undefined: TypeID,
    Function: defines.StringPtr,
    Type: TypeID,
    Void: void,
};

pub const Function = struct {
    pub const Ptr = defines.Offset;
    pub const List = MultiArrayList(Function).Slice;

    name: defines.StringPtr,
    signature: TypeID,
    args: []const defines.StringPtr,
    body: JIR.Ptr,
    source: defines.FilePtr,
    scope: defines.ScopePtr,
    expr: defines.ExpressionPtr,
};

const JIR = @This();

cstrings: std.AutoHashMapUnmanaged(TypeID, []const u8) = .empty,
strings: [][]const u8,
types: Typechecker.TypeTable.Slice,
typeNames: TypeNameMap,
constants: Constant.List,
functions: Function.List,
nodes: Node.List.Slice,
metadata: Builder.MetadataMap,
topLevelAsms: std.ArrayList(defines.StringPtr).Slice,
keyNodes: []const Ptr,
data: []const u32,
allocator: Allocator = undefined,
context: *const Context,
indent: u32 = 0,

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

pub fn codegen(self: *JIR, context: *Context) Error!std.Io.Dir {
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

    buildDir.createDir(context.io, "c/", .default_dir) catch |err| switch (err) {
        CreateDirError.PathAlreadyExists => { },
        else => {
            common.log.err("Failed to create output directory.", .{});
            return Error.IOError;
        },
    };

    const cOut = buildDir.openDir(context.io, "c", .{})
        catch return Error.IOError;

    self.cstrings = .empty;

    var wbuf = std.mem.zeroes([512]u8);
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

    return cOut;
}

fn forwardDecls(self: *JIR, out: *Writer) Error!void {
    try self.write(out, 
    \\/*
    \\ * This file has been automatically generated
    \\ * by the Cole compiler.
    \\ */
    \\
    \\#ifndef COLE_CODEGEN_C_FORWARD_DECL_H
    \\#define COLE_CODEGEN_C_FORWARD_DECL_H
    \\
    \\#include <stdint.h>
    \\#include <stdbool.h>
    \\#include <stddef.h>
    \\
    \\typedef bool cole_bool;
    \\
    \\
    , .{});
    defer { 
        self.write(out, "\n#endif /* COLE_CODEGEN_C_FORWARD_DECL_H */\n" , .{}) catch common.log.err("Failed to end header.", .{});
        out.flush() catch common.log.err("Failed to flush forward declarations.", .{});
    }

    try self.write(out, "/* Top-level inserted code */\n", .{});
    for (self.topLevelAsms) |asmn| {
        const asmc = std.mem.trim(u8, self.strings[asmn], " \t\n\r");

        if (std.mem.startsWith(u8, asmc, "#include")) {
            try self.write(out, "{s}\n", .{asmc});
        }
        try self.write(out, "\n", .{});
    }
    try self.write(out, "\n\n", .{});

    var visited = std.StringHashMapUnmanaged(void).empty;

    for (0..self.types.len) |typeID| {
        if (Comptime.Folder.Builtin.isBuiltinType(@intCast(typeID))) {
            continue;
        }

        const typeInfo = self.types.get(@intCast(typeID));

        // @Beware I don't like this.
        if (typeInfo.isZeroBit()) {
            continue;
        }

        switch (typeInfo) {
            .Struct => |str| {
                if (str.external) {
                    continue;
                }

                const name = try self.getCName(@intCast(typeID), null, true, false);
                const res = visited.getOrPut(self.allocator, name)
                    catch return Error.AllocatorFailure;
                if (res.found_existing) {
                    continue;
                }
                res.key_ptr.* = name;
                try self.write(out, "struct {s};\n", .{name});
                try self.write(out, "typedef struct {s} {s};\n\n", .{name, name});
            },

            .Union => |uni| {
                if (uni.external) {
                    continue;
                }

                const name = try self.getCName(@intCast(typeID), null, true, false);
                const res = visited.getOrPut(self.allocator, name)
                    catch return Error.AllocatorFailure;
                if (res.found_existing) {
                    continue;
                }
                res.key_ptr.* = name;
                try self.write(out, "struct {s};\n", .{name});
                try self.write(out, "typedef struct {s} {s};\n\n", .{name, name});
            },
            else => {},
        }
    }

    visited.clearRetainingCapacity();

    for (0..self.types.len) |typeID| {
        if (Comptime.Folder.Builtin.isBuiltinType(@intCast(typeID))) {
            continue;
        }

        const typeInfo = self.types.get(@intCast(typeID));

        // @Beware I don't like this.
        if (typeInfo.isZeroBit()) {
            continue;
        }

        switch (typeInfo) {
            .Array => |arr| {
                const childName = switch (self.types.get(arr.child)) {
                    .Type, .Any, .EnumLiteral => continue,
                    else => try self.getCName(arr.child, null, true, true),
                };

                const name = std.fmt.allocPrint(self.allocator, "{s}Array_{s}_{d}", .{
                    "",
                    childName,
                    arr.len,
                }) catch return Error.AllocatorFailure;

                const res = visited.getOrPut(self.allocator, name)
                    catch return Error.AllocatorFailure;
                if (res.found_existing) {
                    continue;
                }
                res.key_ptr.* = name;

                try self.write(out, "typedef struct {s} {{ {s} data[{d}]; }} {s};\n\n", .{
                    name,
                    try self.getCName(arr.child, null, false, false),
                    arr.len,
                    name
                });
            },
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => {
                    const childName = switch (self.types.get(ptr.child)) {
                        .Type, .Any, .EnumLiteral => continue,
                        else => try self.getCName(ptr.child, null, true, true),
                    };

                    const name = std.fmt.allocPrint(self.allocator, "{s}Slice_{s}", .{
                        "",
                        childName,
                    }) catch return Error.AllocatorFailure;

                    const res = visited.getOrPut(self.allocator, name)
                        catch return Error.AllocatorFailure;
                    if (res.found_existing) {
                        continue;
                    }
                    res.key_ptr.* = name;

                    try self.write(out, "typedef struct {s} {{ {s}* ptr; uint32_t len; }} {s};\n\n", .{
                        name,
                        try self.getCName(ptr.child, null, true, false),
                        name,
                    });
                },
                else => { },
            },

            .Struct => |str| {
                if (str.external) {
                    continue;
                }

                const name = try self.getCName(@intCast(typeID), null, true, false);
                const res = visited.getOrPut(self.allocator, name)
                    catch return Error.AllocatorFailure;
                if (res.found_existing) {
                    continue;
                }
                res.key_ptr.* = name;
                try self.write(out, "typedef struct {s} {{\n", .{name});
                for (str.fields) |field| {
                    const info = self.types.get(field.valueType);

                    if (info.isZeroBit()) {
                        continue;
                    }

                    try self.write(out, "\t{s}{s}{s};\n", .{
                        try self.getCName(field.valueType, field.name, info == .Function, false),
                        if (info == .Function) ""
                        else " ",
                        if (info == .Function) ""
                        else self.strings[field.name],
                    });
                }
                try self.write(out, "}} {s};\n\n", .{
                    name
                });
            },

            .Union => |uni| {
                if (uni.external) {
                    continue;
                }

                const name = try self.getCName(@intCast(typeID), null, true, false);
                const res = visited.getOrPut(self.allocator, name)
                    catch return Error.AllocatorFailure;
                if (res.found_existing) {
                    continue;
                }
                res.key_ptr.* = name;


                if (uni.isTagged) {
                    try self.write(out, "typedef struct {s} {{\n", .{name});
                    try self.write(out, "\t{s} {s};\n", .{
                        try self.getCName(uni.fields[0].valueType, null, false, false),
                        self.strings[uni.fields[0].name],
                    });
                    try self.write(out, "\tunion {{\n", .{});
                    for (uni.fields[1..]) |field| {
                        const info = self.types.get(field.valueType);

                        if (info.isZeroBit()) {
                            continue;
                        }

                        try self.write(out, "\t\t{s} {s};\n", .{
                            try self.getCName(field.valueType, field.name, false, false),
                            if (info == .Function)
                                ""
                            else
                                self.strings[field.name],
                        });
                    }
                    try self.write(out, "\t}};\n", .{});
                    try self.write(out, "}} {s};\n\n", .{
                        name
                    });
                }
                else {
                    try self.write(out, "typedef union {s} {{\n", .{name});
                    for (uni.fields) |field| {
                        const info = self.types.get(field.valueType);

                        if (info.isZeroBit()) {
                            continue;
                        }

                        try self.write(out, "\t{s} {s};\n", .{
                            try self.getCName(field.valueType, field.name, false, false),
                            if (info == .Function)
                                ""
                            else
                                self.strings[field.name],
                        });
                    }
                    try self.write(out, "}} {s};\n\n", .{
                        name
                    });
                }
            },

            .Enum => |enm| {
                if (enm.external) {
                    continue;
                }

                const name = try self.getCName(@intCast(typeID), null, true, false);
                const res = visited.getOrPut(self.allocator, name)
                    catch return Error.AllocatorFailure;
                if (res.found_existing) {
                    continue;
                }
                res.key_ptr.* = name;


                _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
                try self.write(out, "typedef enum __attribute__((aligned (sizeof(uint32_t)))) {s} {{\n", .{name});
                for (enm.fields) |field| {
                    try self.write(out, "\t{s}_{s} = {d},\n", .{
                        name,
                        field.name,
                        field.value,
                    });
                }
                try self.write(out, "}} {s};\n\n", .{
                    name
                });
            },


            else => {},
        }
    }

    for (0..self.nodes.len) |node| {
        try self.discoverFunctionsAndTypes(out, @intCast(node));
    }
}

fn discoverFunctionsAndTypes(self: *JIR, out: *Writer, nodePtr: Ptr) Error!void {
    const node = self.nodes.get(nodePtr);

    switch (node.type) {
        .VariableDef => if (self.data[node.value] == 1) {
            const typeID = self.data[node.value + 1];
            const info = self.types.get(typeID);

            if (info == .Void) {
                return;
            }
 
            if (info == .Function) {
                _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "::", "__", @constCast(self.strings[self.data[node.value + 2]]));
                try self.write(out, "extern {s};\n\n", .{
                    try self.getCName(info.Pointer.child, self.data[node.value + 2], false, false),
                });
            }
            else {
                _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "::", "__", @constCast(self.strings[self.data[node.value + 2]]));
                try self.write(out, "extern {s} {s};\n\n", .{
                    try self.getCName(typeID, null, false, false),
                    self.strings[self.data[node.value + 2]],
                });
            }
        },
        .FunctionDef => {
            const func = self.functions.get(self.data[node.value + 1]);
            const typeInfo = self.types.get(func.signature).Function;

            if (typeInfo.isComptime) {
                return;
            }

            var args: []const u8 = "";
            for (0.., typeInfo.argTypes) |i, typePtr| {
                args = std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{
                    args,
                    try self.getCName(typePtr, null, false, false),
                    if (i == typeInfo.argTypes.len - 1) "" else ",",
                    if (i == typeInfo.argTypes.len - 1) "" else " ",
                }) catch return Error.AllocatorFailure;
            }

            _ = std.mem.replace(u8, self.strings[self.data[node.value]], "::", "__", @constCast(self.strings[self.data[node.value]]));
            _ = std.mem.replace(u8, self.strings[func.name], "::", "__", @constCast(self.strings[func.name]));
            try self.write(out, "{s}{s} {s}({s}{s});\n\n", .{
                if (self.hasMetadata(nodePtr, "@extern")) "extern " else "",
                try self.getCName(typeInfo.returnType, null, false, false),
                self.strings[func.name],
                args,
                if (typeInfo.variadic) ", ..."
                else "",
            });
        },

        else => { },
    }
}

fn sourceGen(self: *JIR, out: *Writer) Error!void {
    try self.write(out, @embedFile("../../res/hidden_main.c"), .{});
    defer out.flush() catch {
        common.log.err("Failed to flush source file.", .{});
    };
    try self.write(out, "\n\n", .{});

    try self.write(out, "/* Top-level inserted code */\n", .{});
    for (self.topLevelAsms) |asmn| {
        const asmc = std.mem.trim(u8, self.strings[asmn], " \t\n\r");

        if (!std.mem.startsWith(u8, asmc, "#include")) {
            try self.write(out, "{s}", .{asmc});
        }
        try self.write(out, "\n", .{});
    }
    try self.write(out, "\n\n", .{});

    for (self.keyNodes) |keyNode| {
        const node = self.nodes.get(@intCast(keyNode));
        switch (node.type) {
            .VariableDef => if (self.data[node.value] == 1) {
                try self.operation(out, keyNode);
            },
            .FunctionDef => try self.operation(out, keyNode),
            else => { },
        }
    }
}

fn operation(self: *JIR, out: *Writer, nodePtr: Ptr) Error!void {
    const node = self.nodes.get(nodePtr);

    try switch (node.type) {
        .TypeDef => { },
        .FunctionDef => {
            const func = self.functions.get(self.data[node.value + 1]);
            const name = self.strings[func.name];
            const typeInfo = self.types.get(func.signature).Function;

            if (typeInfo.isComptime or self.hasMetadata(nodePtr, "@extern")) {
                return;
            }

            var args: []const u8 = "";
            for (0.., typeInfo.argTypes) |i, typePtr| {
                args = std.fmt.allocPrint(self.allocator, "{s}{s} {s}{s}{s}", .{
                    args,
                    try self.getCName(typePtr, null, false, false),
                    self.strings[func.args[i]],
                    if (i == typeInfo.argTypes.len - 1) "" else ",",
                    if (i == typeInfo.argTypes.len - 1) "" else " ",
                }) catch return Error.AllocatorFailure;
            }

            try self.writeln(out, "{s} {s}({s})\n", .{
                try self.getCName(typeInfo.returnType, null, false, false),
                name,
                args
            });
            
            try self.operation(out, func.body);
        },
        .VariableDef => {
            const typeID = self.data[node.value + 1];
            const info = self.types.get(typeID);

            if (info == .Void) {
                return;
            }

            // @Beware @Note Remove the false if you want constants to not be declared.
            if (false and info.isComptime(undefined)) {
                return;
            }

            if (self.hasMetadata(nodePtr, "@extern")) {
                return;
            }

            if (info == .Function) {
                _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "::", "__", @constCast(self.strings[self.data[node.value + 2]]));
                try self.writeln(out, "{s}{s}", .{
                    try self.getCName(typeID, self.data[node.value + 2], false, false),
                    if (self.data[node.value + 3] == 1) ";\n" else " = ",
                });
            }
            else {
                try self.writeln(out, "{s} {s}{s}", .{
                    try self.getCName(typeID, null, false, false),
                    self.strings[self.data[node.value + 2]],
                    if (self.data[node.value + 3] == 1) ";\n" else " = ",
                });
            }

            if (self.data[node.value + 3] == 0) {
                try self.operation(out, self.data[node.value + 4]);
                try self.write(out, ";\n", .{ });
            }
        },
        .Identifier => {
            const str = @constCast(self.strings[node.value]);
            _ = std.mem.replace(u8, str, "::", "__", str);
            try self.write(out, "{s}", .{str});
        },
        .Literal => self.literal(out, node.value),
        .Scope => {
            try self.writeln(out, "{{\n{s}: (void)(0);\n", .{
                self.strings[self.data[node.value]],
            });
            self.indent += 1;
            const len = self.data[node.value + 1];

            for (0..len) |idx| {
                try self.operation(out, self.data[node.value + 2 + idx]);
            }

            self.indent -= 1;
            try self.writeln(out, "}}\n\n", .{ });
        },

        .Exit => common.debug.ShouldBeImpossible(self.context.log, @src()),

        .Add => try self.commonBinary(out, node.value, "+"),
        .Sub => try self.commonBinary(out, node.value, "-"),
        .And => try self.commonBinary(out, node.value, "&&"),
        .Div => try self.commonBinary(out, node.value, "/"),
        .Mod => try self.commonBinary(out, node.value, "%"),
        .Mul => try self.commonBinary(out, node.value, "*"),
        .Or => try self.commonBinary(out, node.value, "||"),
        .Xor => try self.commonBinary(out, node.value, "^"),
        .LeftShift => try self.commonBinary(out, node.value, "<<"),
        .RightShift => try self.commonBinary(out, node.value, ">>"),
        .Lesser => try self.commonBinary(out, node.value, "<"),
        .LesserEqual => try self.commonBinary(out, node.value, "<="),
        .Greater => try self.commonBinary(out, node.value, ">"),
        .GreaterEqual => try self.commonBinary(out, node.value, ">="),
        .Equal => try self.commonBinary(out, node.value, "=="),
        .NotEqual => try self.commonBinary(out, node.value, "!="),
        .BitwiseAnd => try self.commonBinary(out, node.value, "&"),
        .BitwiseOr => try self.commonBinary(out, node.value, "|"),

        .Label => try self.writeln(out, "{s}: (void)(0);\n", .{self.strings[node.value]}),
        .Jump => try self.writeln(out, "goto {s};\n", .{self.strings[node.value]}),
        .JumpIf => {
            try self.writeln(out, "if (", .{});
            try self.operation(out, self.data[node.value + 1]);
            try self.write(out, ") goto {s};\n", .{self.strings[self.data[node.value]]});
        },
        .Return => {
            try self.writeln(out, "return ", .{});
            if (node.value != 0) {
                try self.operation(out, node.value);
            }
            try self.write(out, ";\n", .{});
        },
        .Ternary => {
            try self.operation(out, self.data[node.value]);
            try self.write(out, " ? ", .{});
            try self.operation(out, self.data[node.value + 1]);
            try self.write(out, " : ", .{});
            try self.operation(out, self.data[node.value + 2]);
        },

        .Reference => try self.commonSingle(out, node.value, "&"),
        .Dereference => try self.commonSingle(out, node.value, "*"),
        .Invert => try self.commonSingle(out, node.value, "~"),
        .Not => try self.commonSingle(out, node.value, "!"),
        .Negation => try self.commonSingle(out, node.value, "-"),
        .Assignment => {
            try self.writeln(out, "", .{});
            try self.operation(out, self.data[node.value]);
            try self.write(out, " = ", .{});
            try self.operation(out, self.data[node.value + 1]);
            try self.write(out, ";\n", .{});
        },
        .Dot => {
            try self.operation(out, self.data[node.value]);
            try self.write(out, ".{s}", .{
                self.strings[self.data[node.value + 1]],
            });
        },
        .Grouping => {
            try self.write(out, "(", .{});
            const len = self.data[node.value];
            for (0..self.data[node.value]) |idx| {
                try self.operation(out, self.data[@intCast(node.value + 1 + idx)]);
                if (idx == len - 1) {
                    continue;
                }
                try self.write(out, ", ", .{});
            }
            try self.write(out, ")", .{});
        },
        .Call => {
            const func = self.data[node.value + 1];
            const len = self.data[node.value + 2];

            if (self.data[node.value] == 1) {
                try self.indentf(out);
            }

            try self.operation(out, func);
            try self.write(out, "(", .{});
            for (0..len) |idx| {
                try self.operation(out, self.data[@intCast(node.value + 3 + idx)]);
                if (idx == len - 1) {
                    continue;
                }
                try self.write(out, ", ", .{});
            }
            try self.write(out, "){s}", .{
                if (self.data[node.value] == 1) ";\n"
                else ""
            });
        },

        .Construction => {
            const typeToCtor = self.data[node.value];
            const len = self.data[node.value + 1];
            const typeInfo = self.types.get(typeToCtor);

            try self.write(out, "({s}){{", .{
                try self.getCName(typeToCtor, null, true, false),
            });

            switch (typeInfo) {
                .Union => |uni| {
                    if (uni.isTagged and len > 0) {
                        // Emit tag field
                        const tagNodePtr = self.data[@intCast(node.value + 2)];
                        try self.write(out, ".{s} = ", .{self.strings[uni.fields[0].name]});
                        try self.operation(out, tagNodePtr);

                        // Resolve tag value to find the active payload field
                        if (len > 1) {
                            const tagNode = self.nodes.get(tagNodePtr);
                            const tagConst = self.constants.get(tagNode.value);
                            const tagValue: u32 = switch (tagConst) {
                                .Integer => |i| switch (i) {
                                    .u32    => |v| v,
                                    .i32    => |v| @intCast(v),
                                    .u8     => |v| v,
                                    .i8     => |v| @intCast(v),
                                    .c_int  => |v| @intCast(v),
                                    .c_uint => |v| @intCast(v),
                                    .c_long => |v| @intCast(v),
                                    else    => 0,
                                },
                                .Aggregate => |agg| self.constants.get(agg.data.start).Integer.u32,
                                else => 0,
                            };
                            const payloadField = uni.fields[1 + tagValue];
                            if (!self.types.get(payloadField.valueType).isZeroBit()) {
                                try self.write(out, ", .{s} = ", .{self.strings[payloadField.name]});
                                try self.operation(out, self.data[@intCast(node.value + 3)]);
                            }
                        }
                    } else {
                        // Untagged union: emit first non-zero-bit field only
                        var dataIdx: usize = 0;
                        for (uni.fields) |field| {
                            if (self.types.get(field.valueType).isZeroBit()) continue;
                            if (dataIdx >= len) break;
                            try self.write(out, ".{s} = ", .{self.strings[field.name]});
                            try self.operation(out, self.data[@intCast(node.value + 2 + dataIdx)]);
                            dataIdx += 1;
                        }
                    }
                },
                .Struct => |str| {
                    var fieldIdx: usize = 0;
                    var dataIdx: usize = 0;
                    while (dataIdx < len) : (dataIdx += 1) {
                        // Skip zero-bit fields
                        while (fieldIdx < str.fields.len and
                               self.types.get(str.fields[fieldIdx].valueType).isZeroBit())
                        {
                            fieldIdx += 1;
                        }
                        if (fieldIdx >= str.fields.len) break;
                        if (dataIdx != 0) try self.write(out, ", ", .{});
                        try self.write(out, ".{s} = ", .{self.strings[str.fields[fieldIdx].name]});
                        try self.operation(out, self.data[@intCast(node.value + 2 + dataIdx)]);
                        fieldIdx += 1;
                    }
                },
                else => {
                    // Primitive or pointer reinterpret: emit positionally
                    for (0..len) |idx| {
                        if (idx != 0) try self.write(out, ", ", .{});
                        try self.operation(out, self.data[@intCast(node.value + 2 + idx)]);
                    }
                },
            }

            try self.write(out, "}}", .{});
        },

        .Code => {
            const str = self.strings[node.value];
            try self.write(out, "/* Inserted Code */\n{s}\n", .{
                str,
            });
        },

        .Discard => {
            try self.indentf(out);
            try self.write(out, "(void)(", .{});
            try self.operation(out, node.value);
            try self.write(out, ");\n", .{});
        },
    };
}

fn commonSingle(self: *JIR, out: *Writer, ptr: Ptr, comptime op: []const u8) Error!void {
    try self.write(out, "("++op++"(", .{});
    try self.operation(out, ptr);
    try self.write(out, "))", .{});
}

fn commonBinary(self: *JIR, out: *Writer, ptr: Ptr, comptime op: []const u8) Error!void {
    try self.write(out, "(", .{});
    try self.operation(out, self.data[ptr]);
    try self.write(out, " "++op++" ", .{});
    try self.operation(out, self.data[ptr + 1]);
    try self.write(out, ")", .{});
}

fn literal(self: *JIR, out: *Writer, ptr: Constant.Ptr) Error!void {
    const cst = self.constants.get(ptr);

    try switch (cst) {
        .Void => try self.write(out, "{{0}}", .{}),
        .Type => |id| try self.write(out, "{s}", .{try self.getCName(id, null, false, false)}),
        .Undefined => |typeID| switch (self.types.get(typeID)) {
            .Pointer => |pointer| switch (pointer.size) {
                .Single, .C => self.write(out, "(({s})NULL)", .{ try self.getCName(typeID, null, false, false)}),
                .Slice => self.write(out, "({s}){{NULL, 0}}", .{ try self.getCName(typeID, null, false, false)}),
            },
            .Struct, .Union, .Enum => self.write(out, "({s}){{}}", .{ try self.getCName(typeID, null, false, false)}),
            else => self.write(out, "{{0}}", .{ }),
        },
        .Integer => |int| switch (int) {
            .i32 => |t| self.write(out, "{d}", .{t}),
            .u32 => |t| self.write(out, "{d}", .{t}),
            .i8 => |t| self.write(out, "{d}", .{t}),
            .u8 => |t| self.write(out, "{d}", .{t}),
            .c_int => |t| self.write(out, "{d}", .{t}),
            .c_uint => |t| self.write(out, "{d}", .{t}),
            .c_char => |t| self.write(out, "{d}", .{t}),
            .c_uchar => |t| self.write(out, "{d}", .{t}),
            .c_long => |t| self.write(out, "{d}", .{t}),
            .c_ulong => |t| self.write(out, "{d}", .{t}),
            .c_short => |t| self.write(out, "{d}", .{t}),
            .c_ushort => |t| self.write(out, "{d}", .{t}),
            .c_size => |t| self.write(out, "{d}", .{t}),
        },
        .Float => |fl| switch (fl) {
            .f32 => |f| self.write(out, "{d}", .{f}),
            .f64 => |f| self.write(out, "{d}", .{f}),
        },
        .Function => |name| {
            const str = @constCast(self.strings[name]);
            _ = std.mem.replace(u8, str, "::", "__", str);
            try self.write(out, "{s}", .{str});
        },
        .Aggregate => |agg| {
            const aggTypeInfo = self.types.get(agg.type);
            const dataLen = agg.data.end - agg.data.start;

            try self.write(out, "({s}){{", .{
                try self.getCName(agg.type, null, true, false),
            });

            switch (aggTypeInfo) {
                .Union => |uni| {
                    if (uni.isTagged and dataLen > 0) {
                        // Emit tag field
                        try self.write(out, ".{s} = ", .{self.strings[uni.fields[0].name]});
                        try self.literal(out, @intCast(agg.data.start));

                        // Resolve tag value to find the active payload field
                        if (dataLen > 1) {
                            const tagConst = self.constants.get(@intCast(agg.data.start));
                            const tagValue: u32 = switch (tagConst) {
                                .Integer => |i| switch (i) {
                                    .u32    => |v| v,
                                    .i32    => |v| @intCast(v),
                                    .u8     => |v| v,
                                    .i8     => |v| @intCast(v),
                                    .c_int  => |v| @intCast(v),
                                    .c_uint => |v| @intCast(v),
                                    .c_long => |v| @intCast(v),
                                    else    => 0,
                                },
                                .Aggregate => |inner| self.constants.get(inner.data.start).Integer.u32,
                                else => 0,
                            };
                            const payloadField = uni.fields[1 + tagValue];
                            if (!self.types.get(payloadField.valueType).isZeroBit()) {
                                try self.write(out, ", .{s} = ", .{self.strings[payloadField.name]});
                                try self.literal(out, @intCast(agg.data.start + 1));
                            }
                        }
                    } else {
                        var dataIdx: usize = 0;
                        for (uni.fields) |field| {
                            if (self.types.get(field.valueType).isZeroBit()) continue;
                            if (dataIdx >= dataLen) break;
                            if (dataIdx != 0) try self.write(out, ", ", .{});
                            try self.write(out, ".{s} = ", .{self.strings[field.name]});
                            try self.literal(out, @intCast(agg.data.start + dataIdx));
                            dataIdx += 1;
                        }
                    }
                },
                .Struct => |str| {
                    var fieldIdx: usize = 0;
                    var dataIdx: usize = 0;
                    while (dataIdx < dataLen) : (dataIdx += 1) {
                        while (fieldIdx < str.fields.len and
                               self.types.get(str.fields[fieldIdx].valueType).isZeroBit())
                        {
                            fieldIdx += 1;
                        }
                        if (fieldIdx >= str.fields.len) break;
                        if (dataIdx != 0) try self.write(out, ", ", .{});
                        try self.write(out, ".{s} = ", .{self.strings[str.fields[fieldIdx].name]});
                        try self.literal(out, @intCast(agg.data.start + dataIdx));
                        fieldIdx += 1;
                    }
                },
                else => {
                    for (agg.data.start..agg.data.end) |idx| {
                        if (idx != agg.data.start) try self.write(out, ", ", .{});
                        try self.literal(out, @intCast(idx));
                    }
                },
            }

            try self.write(out, "}}", .{});
        },
        .Array => |arr| {
            try self.write(out, "({s}){{", .{
                try self.getCName(arr.type, null, true, false),
            });
            for (arr.data.start..arr.data.end) |idx| {
                try self.literal(out, @intCast(idx));
                if (idx != arr.data.end - 1) {
                    try self.write(out, ", ", .{});
                }
            }
            try self.write(out, "}}", .{ });
        },
        .String => |str| switch (str.type) {
            .C => {
                const rstr = self.strings[str.str];
                try self.write(out, "((char const*)\"{s}\")", .{
                    rstr,
                });
            },
            .Cole => {
                const rstr = self.strings[str.str];
                try self.write(out, "({s}){{(uint8_t*)\"{s}\", {d}}}", .{
                    try self.getCName(Comptime.Folder.Builtin.Type("[]u8"), null, true, false),
                    rstr,
                    rstr.len,
                });
            }
        },
    };
}

fn getCName(self: *JIR, typeID: TypeID, _name: ?defines.StringPtr, mutable: bool, noSymbol: bool) Error![]const u8 {
    const typeInfo = self.types.get(typeID);

    if (!noSymbol and !(typeInfo == .Function and _name != null)) {
        if (self.cstrings.get(typeID)) |name| {
            return
                if (mutable and std.mem.endsWith(u8, name, "const")) name[0..name.len - 6]
                else name;
        }
    }

    var name: []const u8 = "";
    switch (typeInfo) {
        .Type, .Any, .EnumLiteral => {
            common.log.err("Unsupported {s}", .{@tagName(typeInfo)});
            return common.debug.ShouldBeImpossible(self.context.log, @src());
        },

        .CInt => |m| return
            if (m) "int"
            else if (noSymbol) "int_const"
            else "int const",

        .CUInt => |m| return
            if (m and !noSymbol) "unsigned int"
            else if (m and noSymbol) "unsigned_int"
            else if (noSymbol) "unsigned_int_const"
            else "unsigned int const",

        .CChar => |m| return
            if (m) "char"
            else if (noSymbol) "char_const"
            else "char const",

        .CUChar => |m| return
            if (m and !noSymbol) "unsigned char"
            else if (m and noSymbol) "unsigned_char"
            else if (noSymbol) "unsigned_char_const"
            else "unsigned char const",

        .CDouble => |m| return
            if (m) "double"
            else if (noSymbol) "double_const"
            else "double const",

        .CLong => |m| return
            if (m) "long"
            else if (noSymbol) "long_const"
            else "long const",

        .CULong => |m| return
            if (m and !noSymbol) "unsigned long"
            else if (m and noSymbol) "unsigned_long"
            else if (noSymbol) "unsigned_long_const"
            else "unsigned long const",

        .CShort => |m| return
            if (m) "short"
            else if (noSymbol) "short_const"
            else "short const",

        .CUShort => |m| return
            if (m and !noSymbol) "unsigned short"
            else if (m and noSymbol) "unsigned_short"
            else if (noSymbol) "unsigned_short_const"
            else "unsigned short const",

        .CSize => |m| return
            if (m and !noSymbol) "size_t"
            else if (noSymbol) "size_t_const"
            else "size_t const",

        .Void => return "void",

        .Noreturn => return
            if (noSymbol) "noreturn"
            else "void __attribute__((noreturn))",

        .Bool => |v| name = std.fmt.allocPrint(self.allocator, "cole_bool{s}", .{
            if (v) ""
            else if (noSymbol) "_const"
            else " const"
        }) catch return Error.AllocatorFailure,
        .Float => |v| name = std.fmt.allocPrint(self.allocator, "float{s}", .{
            if (v) ""
            else if (noSymbol) "_const"
            else" const"
        }) catch return Error.AllocatorFailure,
        .ComptimeFloat => name = std.fmt.allocPrint(self.allocator,
            "float{s}", .{
            if (mutable) ""
            else if (noSymbol) "_const"
            else " const"
        }) catch return Error.AllocatorFailure,
        .ComptimeInt => name = std.fmt.allocPrint(self.allocator,
            "int32_t{s}", .{
            if (mutable) ""
            else if (noSymbol) "_const"
            else " const"
        }) catch return Error.AllocatorFailure,
        .Integer => |i| name = std.fmt.allocPrint(self.allocator, "{s}int{d}_t{s}", .{
            if (i.signed) "" else "u",
            i.size,
            if (mutable or i.mutable) ""
            else if (noSymbol) "_const"
            else " const",
        }) catch return Error.AllocatorFailure,

        .Union, .Struct, .Enum => {
            const namePtr =
                if (typeInfo == .Struct) typeInfo.Struct.name
                else if (typeInfo == .Union) typeInfo.Union.name
                else typeInfo.Enum.name;

            name = self.strings[namePtr];

            _ = std.mem.replace(u8, name, "::", "__", @constCast(name));

            const mut =
                if (typeInfo == .Struct) typeInfo.Struct.mutable
                else if (typeInfo == .Union) typeInfo.Union.mutable
                else typeInfo.Enum.mutable;

            name = std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                name,
                if (mut) ""
                else if (noSymbol) "_const"
                else " const",
            }) catch return Error.AllocatorFailure;
        },

        .Function => |func| {
            var args: []const u8 = "";
            for (0.., func.argTypes) |i, typePtr| {
                args = std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{
                    args,
                    try self.getCName(typePtr, _name, false, noSymbol),
                    if (i == func.argTypes.len - 1) ""
                    else if (noSymbol) "_"
                    else ",",
                    if (i == func.argTypes.len - 1) ""
                    else if (noSymbol) "_"
                    else " ",
                }) catch return Error.AllocatorFailure;
            }

            if (noSymbol) {
                name = std.fmt.allocPrint(self.allocator, "{s}__func_{s}____{s}__", .{
                    try self.getCName(func.returnType, _name, false, true),
                    if (_name) |n| self.strings[n] else "",
                    args,
                }) catch return Error.AllocatorFailure;
            }
            else {
                name = std.fmt.allocPrint(self.allocator, "{s} (*{s})({s})", .{
                    try self.getCName(func.returnType, _name, false, false),
                    if (_name) |n| self.strings[n] else "",
                    args
                }) catch return Error.AllocatorFailure;
            }
        },

        .Array => |arr| {
            name = std.fmt.allocPrint(self.allocator, "{s}Array_{s}_{d}{s}", .{
                "",
                // if (arr.mutable) "" else "const_",
                try self.getCName(arr.child, _name, true, true),
                arr.len,
                if (arr.mutable) "" else " const",
            }) catch return Error.AllocatorFailure;
        },

        .Pointer => |ptr| switch (ptr.size) {
            .Slice => {
                name = std.fmt.allocPrint(self.allocator, "{s}Slice_{s}{s}", .{
                    "",
                    // if (ptr.mutable) "" else "const_",
                    try self.getCName(ptr.child, _name, true, true),
                    if (ptr.mutable) "" else " const",
                }) catch return Error.AllocatorFailure;
            },
            .Single, .C => {
                const info = self.types.get(ptr.child);
                name = std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{
                    try self.getCName(ptr.child, _name, false, noSymbol),
                    if (info == .Void and noSymbol and !info.Void) "_const"
                    else if (info == .Void and !info.Void) " const"
                    else "",
                    if (noSymbol) "_ptr" else "*",
                    if (ptr.mutable) "" else " const",
                }) catch return Error.AllocatorFailure;
            },
        },
    }

    if (!noSymbol) {
        self.cstrings.put(self.allocator, typeID, name)
            catch return Error.AllocatorFailure;
    }

    return
        if (mutable and std.mem.endsWith(u8, name, "const")) name[0..name.len - 6]
        else name;
}

fn isStmt(self: *const JIR, nt: Node) bool {
    const res = switch (nt.type) {
        .FunctionDef, .Return, .JumpIf,
        .Jump, .Label, .Scope,
        .Assignment, .VariableDef, .Code, => true,

        else => false,
    };

    if (nt.type != .Call) {
        return res;
    }

    return self.data[nt.value] == 1;
}

fn indentf(self: *JIR, out: *Writer) Error!void {
    for (0..self.indent) |_| {
        out.print("    ", .{}) catch return Error.IOError;
    }
}

fn write(_: *JIR, out: *Writer, comptime msg: []const u8, args: anytype) Error!void {
    return out.print(msg, args) catch Error.IOError;
}

fn writeln(self: *JIR, out: *Writer, comptime msg: []const u8, args: anytype) Error!void {
    try self.indentf(out);
    return out.print(msg, args) catch Error.IOError;
}

pub fn hasMetadata(
    self: *const JIR,
    _value: JIR.Ptr,
    _meta: []const u8,
) bool {
    return
        if (self.getMetadata(_value)) |metadata| blk: {
            for (metadata) |meta| {
                const constant = self.constants.get(meta);
                switch (constant) {
                    .Aggregate => |agg|
                        if (agg.type == Comptime.Folder.Builtin.Type("builtin_metadata")) {
                            const enumValue = self.constants.get(agg.data.start).Integer.u32;
                            if (enumValue == Comptime.Folder.Builtin.Metadata(_meta)) break :blk true;
                        },
                    else => { },
                }
            }

            break :blk false;
        }
        else false;
}

pub fn getMetadata(
    self: *const JIR,
    value: defines.ExpressionPtr,
) ?[]const defines.ExpressionPtr {
    return self.metadata.get(value);
}
