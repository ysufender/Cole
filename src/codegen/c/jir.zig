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
        Asm,
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
    String: defines.StringPtr,
    Float: f32,
    Aggregate: ConstantArray, 
    Array: ConstantArray,
    Undefined: TypeID,
    Function: defines.StringPtr,
};

pub const Function = struct {
    pub const Ptr = defines.Offset;
    pub const List = MultiArrayList(Function).Slice;

    name: defines.StringPtr,
    signature: TypeID,
    args: []const defines.StringPtr,
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

    return cOut;
}

fn forwardDecls(self: *JIR, out: *Writer) Error!void {
    try self.write(out, 
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
    , .{});
    defer { 
        self.write(out, "\n#endif /* JASL_CODEGEN_C_FORWARD_DECLS_H */\n" , .{}) catch common.log.err("Failed to end header.", .{});
        out.flush() catch common.log.err("Failed to flush forward declarations.", .{});
    }

    for (0..self.types.len) |typeID| {
        const typeInfo = self.types.get(@intCast(typeID));

        switch (typeInfo) {
            .Array => |arr| {
                const name = std.fmt.allocPrint(self.allocator, "Array_{s}_{d}_t[{d}]", .{
                    try self.getCName(arr.child, null, true),
                    arr.len,
                    arr.len,
                }) catch return Error.AllocatorFailure;

                try self.write(out, "typedef {s} {s};\n\n", .{
                    try self.getCName(arr.child, null, false), name
                });
            },
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => {
                    const name = std.fmt.allocPrint(self.allocator, "Slice_{s}", .{
                        try self.getCName(ptr.child, null, true),
                    }) catch return Error.AllocatorFailure;

                    try self.write(out, "typedef struct {{ {s}* ptr; uint32_t len; }} {s};\n\n", .{
                        try self.getCName(ptr.child, null, false), name
                    });
                },
                else => { },
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
            if (info == .Pointer and self.types.get(info.Pointer.child) == .Function) {
                _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "::", "__", @constCast(self.strings[self.data[node.value + 2]]));
                _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "$", "_", @constCast(self.strings[self.data[node.value + 2]]));
                try self.write(out, "extern {s};\n\n", .{
                    try self.getCName(info.Pointer.child, self.data[node.value + 2], false),
                });
            }
            else {
                _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "::", "__", @constCast(self.strings[self.data[node.value + 2]]));
                _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "$", "_", @constCast(self.strings[self.data[node.value + 2]]));
                try self.write(out, "extern {s} {s};\n\n", .{
                    try self.getCName(typeID, null, false),
                    self.strings[self.data[node.value + 2]],
                });
            }
        },
        .FunctionDef => {
            const func = self.functions.get(self.data[node.value + 1]);
            const typeInfo = self.types.get(func.signature).Function;

            var args: []const u8 = "";
            for (0.., typeInfo.argTypes) |i, typePtr| {
                args = std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{
                    args,
                    try self.getCName(typePtr, null, false),
                    if (i == typeInfo.argTypes.len - 1) "" else ",",
                    if (i == typeInfo.argTypes.len - 1) "" else " ",
                }) catch return Error.AllocatorFailure;
            }

            _ = std.mem.replace(u8, self.strings[self.data[node.value]], "::", "__", @constCast(self.strings[self.data[node.value]]));
            _ = std.mem.replace(u8, self.strings[self.data[node.value]], "$", "_", @constCast(self.strings[self.data[node.value]]));
            try self.write(out, "{s} {s}({s});\n\n", .{
                try self.getCName(typeInfo.returnType, null, false),
                self.strings[func.name],
                args
            });
        },
        .TypeDef => {
            const typeID = node.value;
            const typeInfo = self.types.get(typeID);

            switch (typeInfo) {
                .Struct => |str| {
                    try self.write(out, "typedef struct {{\n", .{});
                    for (str.fields) |field| {
                        try self.write(out, "\t{s} {s};\n", .{
                            try self.getCName(field.valueType, null, false),
                            self.strings[field.name],
                        });
                    }
                    const name = self.strings[str.name];
                    _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
                    _ = std.mem.replace(u8, name, "$", "_", @constCast(name));
                    try self.write(out, "}} {s};\n\n", .{name});
                },

                .Union => |uni|{
                    if (uni.isTagged) {
                        try self.write(out, "typedef struct {{\n", .{});
                        try self.write(out, "\t{s} {s};\n", .{
                            try self.getCName(uni.fields[0].valueType, null, false),
                            self.strings[uni.fields[0].name],
                        });
                        try self.write(out, "\tunion {{\n", .{});
                        for (uni.fields[1..]) |field| {
                            try self.write(out, "\t\t{s} {s};\n", .{
                                try self.getCName(field.valueType, null, false),
                                self.strings[field.name],
                            });
                        }
                        try self.write(out, "\t}};\n", .{});
                        const name = self.strings[uni.name];
                        _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
                        _ = std.mem.replace(u8, name, "$", "_", @constCast(name));
                        try self.write(out, "}} {s};\n\n", .{name});
                    }
                    else {
                        try self.write(out, "typedef union {{\n", .{});
                        for (uni.fields) |field| {
                            try self.write(out, "\t{s} {s};\n", .{
                                try self.getCName(field.valueType, null, false),
                                self.strings[field.name],
                            });
                        }
                        const name = self.strings[uni.name];
                        _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
                        _ = std.mem.replace(u8, name, "$", "_", @constCast(name));
                        try self.write(out, "}} {s};\n\n", .{name});
                    }
                },

                .Enum => |enm| {
                    const name = self.strings[enm.name];
                    _ = std.mem.replace(u8, name, ":", "_", @constCast(name));
                    _ = std.mem.replace(u8, name, "$", "_", @constCast(name));
                    try self.write(out, "typedef enum {{\n", .{});
                    for (enm.fields) |field| {
                        try self.write(out, "\t{s}_{s},\n", .{
                            name,
                            field,
                        });
                    }
                    try self.write(out, "}} {s};\n\n", .{name});
                },

                // @Note type constants are already folded
                else => { },
            }
        },

        else => { },
    }
}

fn sourceGen(self: *JIR, out: *Writer) Error!void {
    try self.write(out, 
    \\/*
    \\ * This file has been automatically generated
    \\ * by the JASL compiler.
    \\ */
    \\
    \\#include "forward_decl.h"
    \\
    \\int main() {{
    \\    return root__main();
    \\}}
    \\
    \\
    , .{});
    defer out.flush() catch {
        common.log.err("Failed to flush source file.", .{});
    };

    for (self.topLevelAsms) |asmn| {
        const asmc = self.strings[asmn];
        try self.write(out, "{s}", .{asmc});
    }
    try self.write(out, "\n", .{});

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
            const name = self.strings[self.data[node.value]];
            const func = self.functions.get(self.data[node.value + 1]);
            const typeInfo = self.types.get(func.signature).Function;

            var args: []const u8 = "";
            for (0.., typeInfo.argTypes) |i, typePtr| {
                // @Important TODO: Function parameter names WHY AREN'T THEY HERE???
                args = std.fmt.allocPrint(self.allocator, "{s}{s} {s}{s}{s}", .{
                    args,
                    try self.getCName(typePtr, null, false),
                    self.strings[func.args[i]],
                    if (i == typeInfo.argTypes.len - 1) "" else ",",
                    if (i == typeInfo.argTypes.len - 1) "" else " ",
                }) catch return Error.AllocatorFailure;
            }

            try self.writeln(out, "{s} {s}({s})\n", .{
                try self.getCName(typeInfo.returnType, null, false),
                name,
                args
            });
            
            for (func.body.start..func.body.end) |ptr| {
                if (self.isStmt(self.nodes.get(@intCast(ptr)))) {
                    try self.operation(out, @intCast(ptr));
                }
            }
        },
        .VariableDef => {
            const typeID = self.data[node.value + 1];
            const info = self.types.get(typeID);
            if (info == .Pointer and self.types.get(info.Pointer.child) == .Function) {
                _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "::", "__", @constCast(self.strings[self.data[node.value + 2]]));
                _ = std.mem.replace(u8, self.strings[self.data[node.value + 2]], "$", "_", @constCast(self.strings[self.data[node.value + 2]]));
                try self.write(out, "{s}{s}", .{
                    try self.getCName(info.Pointer.child, self.data[node.value + 2], false),
                    if (self.data[node.value + 3] == 1) ";\n" else " = ",
                });
            }
            else {
                try self.writeln(out, "{s} {s}{s}", .{
                    try self.getCName(typeID, null, false),
                    self.strings[self.data[node.value + 2]],
                    if (self.data[node.value + 3] == 1) ";\n" else " = ",
                });
            }

            if (self.data[node.value + 3] == 0) {
                try self.operation(out, self.data[node.value + 4]);
                try self.write(out, ";\n", .{ });
            }
        },
        .Identifier => try self.write(out, "{s}", .{self.strings[node.value]}),
        .Literal => self.literal(out, node.value),
        .Scope => {
            try self.writeln(out, "{{\n{s}: (void)(0);\n", .{
                self.strings[node.value],
            });
            self.indent += 1;
        },

        .Exit => {
            self.indent -= 1;
            try self.writeln(out, "}}\n\n", .{});
        },

        .Add => try self.commonBinary(out, node.value, "+"),
        .Sub => try self.commonBinary(out, node.value, "-"),
        .And => try self.commonBinary(out, node.value, "&&"),
        .Div => try self.commonBinary(out, node.value, "/"),
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
            try self.operation(out, node.value);
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
            for (self.data[node.value]..self.data[node.value + 1]) |idx| {
                try self.operation(out, @intCast(idx));
                if (idx == self.data[node.value + 1] - 1) {
                    continue;
                }
                try self.write(out, ", ", .{});
            }
            try self.write(out, ")", .{});
        },
        .Call => {
            const func = self.data[node.value + 1];
            const range = defines.Range{
                .start = self.data[node.value + 2],
                .end = self.data[node.value + 3],
            };

            if (self.data[node.value] == 1) {
                try self.indentf(out);
            }

            try self.operation(out, func);
            try self.write(out, "(", .{});
            for (range.start..range.end) |idx| {
                try self.operation(out, @intCast(idx));
                if (idx == self.data[node.value + 3] - 1) {
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
            const func = self.data[node.value];
            const range = defines.Range{
                .start = self.data[node.value + 1],
                .end = self.data[node.value + 2],
            };

            try self.write(out, "({s}){{", .{
                try self.getCName(func, null, true),
            });
            for (range.start..range.end) |idx| {
                try self.operation(out, @intCast(idx));
                if (idx != self.data[node.value + 1] - 1) {
                    continue;
                }
                try self.write(out, ", ", .{});
            }
            try self.write(out, "}}", .{});
        },

        .Asm => {
            const str = self.strings[node.value];
            try self.write(out, "/*Inserted Code*/\n{s}\n", .{
                str,
            });
        },
    };
}

fn commonSingle(self: *JIR, out: *Writer, ptr: Ptr, comptime op: []const u8) Error!void {
    try self.write(out, op++"(", .{});
    try self.operation(out, ptr);
    try self.write(out, ")", .{});
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
        .Undefined => self.write(out, "{{ }}", .{}),
        .Integer => |int| switch (int) {
            .i32 => |t| self.write(out, "{d}", .{t}),
            .u32 => |t| self.write(out, "{d}", .{t}),
            .i8 => |t| self.write(out, "{d}", .{t}),
            .u8 => |t| self.write(out, "{d}", .{t}),
        },
        .Float => |fl| self.write(out, "{}", .{fl}),
        .Function => |func| self.write(out, "{s}", .{self.strings[func]}),
        .Aggregate => |agg| {
            try self.write(out, "({s}){{", .{
                try self.getCName(agg.type, null, true),
            });
            for (agg.data.start..agg.data.end) |idx| {
                try self.literal(out, @intCast(idx));
                if (idx != agg.data.end - 1) {
                    try self.write(out, ", ", .{});
                }
            }
            try self.write(out, "}}", .{});
        },
        .Array => |arr| {
            try self.write(out, "{{ ", .{});
            for (arr.data.start..arr.data.end) |idx| {
                try self.literal(out, @intCast(idx));
                if (idx != arr.data.end - 1) {
                    try self.write(out, ", ", .{});
                }
            }
            try self.write(out, " }}", .{});
        },
        .String => |str| {
            const rstr = self.strings[str];
            try self.write(out, "({s}){{(uint8_t*)\"{s}\\0\", {d}}}", .{
                try self.getCName(Comptime.Builtin.Type("string"), null, true),
                rstr,
                rstr.len,
            });
        },
    };
}

fn getCName(self: *JIR, typeID: TypeID, _name: ?defines.StringPtr, mutable: bool) Error![]const u8 {
    if (self.cstrings.get(typeID)) |name| {
        return
            if (mutable and std.mem.endsWith(u8, name, "const")) name[0..name.len - 6]
            else name;
    }

    const typeInfo = self.types.get(typeID);
    var name: []const u8 = "";
    switch (typeInfo) {
        .Type, .Any, .EnumLiteral => {
            common.log.err("Unsupported {s}", .{@tagName(typeInfo)});
            return common.debug.ShouldBeImpossible(@src());
        },

        .Void => return "void",
        .Noreturn => return "void",

        .Bool => |v| name = std.fmt.allocPrint(self.allocator, "jasl_bool{s}", .{
            if (v) "" else " const"
        }) catch return Error.AllocatorFailure,
        .Float => |v| name = std.fmt.allocPrint(self.allocator, "float{s}", .{
            if (v) "" else " const"
        }) catch return Error.AllocatorFailure,
        .ComptimeFloat => name = std.fmt.allocPrint(self.allocator,
            "float{s}", .{
            if (mutable) "" else " const"
        }) catch return Error.AllocatorFailure,
        .ComptimeInt => name = std.fmt.allocPrint(self.allocator,
            "int32_t{s}", .{
            if (mutable) "" else " const"
        }) catch return Error.AllocatorFailure,
        .Integer => |i| name = std.fmt.allocPrint(self.allocator, "{s}int{d}_t{s}", .{
            if (i.signed) "" else "u",
            i.size,
            if (mutable or i.mutable) "" else " const",
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
                    try self.getCName(typePtr, _name, false),
                    if (i == func.argTypes.len - 1) "" else ",",
                    if (i == func.argTypes.len - 1) "" else " ",
                }) catch return Error.AllocatorFailure;
            }

            name = std.fmt.allocPrint(self.allocator, "{s} (*{s})({s})", .{
                try self.getCName(func.returnType, _name, true),
                if (_name) |n| self.strings[n] else "",
                args
            }) catch return Error.AllocatorFailure;
        },

        .Array => |arr| {
            name = std.fmt.allocPrint(self.allocator, "Array_{s}_{d}_t{s}", .{
                try self.getCName(arr.child, _name, true),
                arr.len,
                if (arr.mutable) "" else " const",
            }) catch return Error.AllocatorFailure;
        },

        .Pointer => |ptr| switch (ptr.size) {
            .Slice => {
                name = std.fmt.allocPrint(self.allocator, "Slice_{s}{s}", .{
                    try self.getCName(ptr.child, _name, true),
                    if (ptr.mutable) "" else " const",
                }) catch return Error.AllocatorFailure;
            },
            .Single, .C => {
                name = std.fmt.allocPrint(self.allocator, "{s}*{s}", .{
                    try self.getCName(ptr.child, _name, true),
                    if (ptr.mutable) "" else " const",
                }) catch return Error.AllocatorFailure;
            },
        },
    }

    self.cstrings.putNoClobber(self.allocator, typeID, name)
        catch return Error.AllocatorFailure;

    return
        if (mutable and std.mem.endsWith(u8, name, "const")) name[0..name.len - 6]
        else name;
}

fn isStmt(self: *const JIR, nt: Node) bool {
    const res = switch (nt.type) {
        .FunctionDef, .Return, .JumpIf,
        .Jump, .Label, .Exit, .Scope,
        .Assignment, .VariableDef, .Asm => true,

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
