const std = @import("std");
const defines = @import("../../core/defines.zig");
const common = @import("../../core/common.zig");

const Typechecker = @import("../../typechecker/typechecker.zig");
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
typeNames: Typechecker.TypeNameMap,
typeTable: Builder.TypeTable.Slice,
nodes: Node.List.Slice,
keyNodes: std.ArrayList(JAIR.Ptr).Slice,
data: std.ArrayList(u32).Slice,
indent: u32 = 0,
terminated: bool = false,

pub fn codegen(self: *JAIR, context: *Context, qbeOut: *std.Io.Dir) Error!void {
    var wbuf = std.mem.zeroes([512]u8);

    var outputFile = qbeOut.createFile(context.io, "source.ssa", .{ }) catch |err| {
        common.log.err("Failed to write output file 'source.ssa': {s}", .{@errorName(err)});
        return Error.IOError;
    };
    defer outputFile.close(context.io);

    var outputWriter = outputFile.writer(context.io, &wbuf);
    const out = &outputWriter.interface;
    defer outputWriter.flush() catch {};

    for (0..self.typeTable.len) |typeID| {
        const typeInfo = self.typeTable.get(typeID);

        switch (typeInfo) {
            .Custom => |custom| switch (custom) {
                .Opaque => |opaqueType| {
                    if (opaqueType.size == 0) continue;

                    try self.write(true, out, "type :{s} = align {d} {{ {d} }}\n", .{
                        self.strings[opaqueType.name],
                        opaqueType.alignment,
                        opaqueType.size,
                    });
                },
                .Aggregate => |aggregate| {
                    if (aggregate.size == 0 or aggregate.fields.len == 0) continue;

                    try self.write(true, out, "type :{s} = align {d} {{", .{
                        self.strings[aggregate.name],
                        aggregate.alignment,
                    });

                    for (aggregate.fields, 0..) |field, idx| {
                        try self.write(false, out, " ", .{});
                        try self.typeString(out, field);
                        try self.write(false, out, "{s}", .{
                            if (idx != aggregate.fields.len - 1) "," else ""
                        });
                    }

                    try self.write(false, out, " }}\n", .{});
                },
                else => { },
            },
            else => {},
        }
    }

    for (self.keyNodes) |nodePtr| {
        try self.write(false, out, "\n", .{});
        try self.generate(out, nodePtr);
    }
}

fn generate(self: *JAIR, out: *Writer, nodePtr: Ptr) Error!void {
    const node = self.nodes.get(nodePtr);

    switch (node.type) {
        .FunctionDef => {
            const isExported = self.data[node.value] == 1;
            const name = self.strings[self.data[node.value + 1]];
            const returnType = self.data[node.value + 2];
            const argLen = self.data[node.value + 3];
            const body = self.data[node.value + 4 + argLen * 2];

            try self.write(true, out, "{s}function ", .{if (isExported) "export " else ""});
            try self.typeString(out, returnType);
            try self.write(false, out, " ${s}(", .{name});
            for (0..argLen) |idx| {
                const offset = node.value + 4 + idx * 2;
                const argType = self.data[offset];
                const argName = self.data[offset + 1];

                try self.typeString(out, argType);
                try self.write(false, out, " %{s}{s}", .{
                    self.strings[argName],
                    if (idx != argLen - 1) ", "
                    else ""
                });
            }
            try self.write(false, out, ") {{\n@start\n", .{});
            self.indent += 1;
            self.terminated = false;

            try self.generateStatements(out, body);

            if (!self.terminated) {
                const isVoid = self.typeTable.get(returnType) == .Void;
                try self.write(true, out, "{s}\n", .{if (isVoid) "ret" else "hlt"});
            }
            self.indent -= 1;
            try self.write(true, out, "}}\n\n", .{});
        },
        .Scope => {
            const label = self.strings[self.data[node.value]];
            if (!self.terminated) {
                try self.write(true, out, "jmp @{s}\n", .{label});
            }
            try self.write(false, out, "@{s}\n", .{label});
            self.terminated = false;

            try self.generateStatements(out, nodePtr);
        },
        else => |t| try self.write(true, out, "# TODO {s}\n", .{@tagName(t)}),
    }
}

fn generateStatements(self: *JAIR, out: *Writer, scopePtr: Ptr) Error!void {
    const scope = self.nodes.get(scopePtr);
    std.debug.assert(scope.type == .Scope);

    const len = self.data[scope.value + 1];
    for (0..len) |idx| {
        try self.generate(out, self.data[scope.value + 2 + idx]);
    }
}

fn typeString(self: *const JAIR, out: *Writer, typeID: TypeID) Error!void {
    switch (self.typeTable.get(typeID)) {
        .Word => try self.write(false, out, "w", .{}),
        .Long => try self.write(false, out, "l", .{}),
        .Double => try self.write(false, out, "d", .{}),
        .Single => try self.write(false, out, "s", .{}),
        .Half => try self.write(false, out, "h", .{}),
        .Byte => try self.write(false, out, "b", .{}),
        .Void => { },
        else => try self.write(false, out, ":{s}", .{self.strings[self.typeNames.get(typeID).?]}),
    }
}

fn write(self: *const JAIR, indent: bool, out: *Writer, comptime fmt: []const u8, args: anytype) Error!void {
    if (indent) {
        for (0..self.indent) |_| {
            _ = out.write("    ") catch return Error.IOError;
        }
    }
    out.print(fmt, args) catch return Error.IOError;
}
