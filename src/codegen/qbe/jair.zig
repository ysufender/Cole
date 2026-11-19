const std = @import("std");
const defines = @import("../../core/defines.zig");
const common = @import("../../core/common.zig");

const Context = common.CompilerContext;
const Error = common.CompilerError;
const TypeID = @import("../../typechecker/type.zig").TypeID;
const Writer = std.Io.Writer;

pub const Builder = @import("jair/builder.zig");

const MultiArrayList = @import("../../util/collections.zig").MultiArrayList;

pub const Ptr = defines.Offset;

pub const Type = union(enum) {
    Void,
    Word,
    Long,
    Single,
    Double,
    Byte,
    Half,
    Array: struct {
        size: u32,
        alignment: u32,
    },
    Custom: union(enum) {
        Opaque: struct {
            name: defines.StringPtr,
            size: u32,
            alignment: u32,
        },
        Aggregate: struct {
            name: defines.StringPtr,
            size: u32,
            alignment: u32,
            fields: []const TypeID
        },
        Union: struct {
            name: defines.StringPtr,
            size: u32,
            alignment: u32,
            fields: []const TypeID,
        },
    },
};

pub const Node = struct {
    pub const List = MultiArrayList(Node);

    pub const Type = enum {
        AggregateTypeDef,
        OpaqueTypeDef,
        UnionTypeDef,
        FunctionDef,
        VariableDef,
        Identifier,
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
        SignedRightShift,
        And,
        Or,
        Label,
        Jump,
        JumpIf,
        Lesser,
        SignedLesser,
        FloatLesser,
        LesserEqual,
        SignedLesserEqual,
        FloatLesserEqual,
        Greater,
        SignedGreater,
        FloatGreater,
        GreaterEqual,
        SignedGreaterEqual,
        FloatGreaterEqual,
        Equal,
        NotEqual,
        Phi,
        Not,
        Xor,
        Negation,
        Code,
        Mod,
        UnsignedMod,
    };

    type: Node.Type,
    value: defines.EitherPtr(Ptr, u32),
};

const JAIR = @This();

strings: [][]const u8,
typeTable: Builder.TypeTable.Slice,
nodes: Node.List.Slice,
keyNodes: std.ArrayList(JAIR.Ptr).Slice,
data: std.ArrayList(u32).Slice,

pub fn codegen(self: *const JAIR, context: *Context, qbeOut: *std.Io.Dir) Error!void {
    var wbuf = std.mem.zeroes([512]u8);

    var outputFile = qbeOut.createFile(context.io, "source.ssa", .{ }) catch |err| {
        common.log.err("Failed to write output file 'source.ssa': {s}", .{@errorName(err)});
        return Error.IOError;
    };
    defer outputFile.close(context.io);

    var outputWriter = outputFile.writer(context.io, &wbuf);
    defer outputWriter.flush() catch {};

    for (self.keyNodes) |nodePtr| {
        try self.generate(&outputWriter.interface, nodePtr);
    }
}

fn generate(self: *const JAIR, out: *Writer, nodePtr: Ptr) Error!void {
    const node = self.nodes.get(nodePtr);

    switch (node.type) {
        .FunctionDef => {
            const isExported = self.data[node.value] == 1;
            const name = self.strings[self.data[node.value + 1]];
            const returnType = self.data[node.value + 2];
            const argLen = self.data[node.value + 3];

            try write(out, "{s}function ", .{if (isExported) "export " else ""});
            try self.typeString(out, returnType);
            try write(out, " ${s}(", .{name});
            for (0..argLen) |idx| {
                const offset = 4 + idx * 2;
                const argType = self.data[offset];
                const argName = self.data[offset + 1];

                try self.typeString(out, argType);
                try write(out, " %{s}{s}", .{
                    self.strings[argName],
                    if (idx != argLen - 1) ", "
                    else ""
                });
            }
            try write(out, ") {{\n@start\n", .{});
            try write(out, "}}\n\n", .{});
        },
        else => { },
    }
}

fn typeString(self: *const JAIR, out: *Writer, typeID: TypeID) Error!void {
    switch (self.typeTable.get(typeID)) {
        .Word => try write(out, "w", .{}),
        .Long => try write(out, "l", .{}),
        .Double => try write(out, "d", .{}),
        .Single => try write(out, "s", .{}),
        .Half => try write(out, "h", .{}),
        .Byte => try write(out, "b", .{}),
        else => { },
    }
}

fn write(out: *Writer, comptime fmt: []const u8, args: anytype) Error!void {
    out.print(fmt, args) catch return Error.IOError;
}
