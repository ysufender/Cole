const std = @import("std");
const defines = @import("../../core/defines.zig");
const common = @import("../../core/common.zig");

const Typechecker = @import("../../typechecker/typechecker.zig");
const Context = common.CompilerContext;
const Error = common.CompilerError;
const TypeID = @import("../../typechecker/type.zig").TypeID;
const Writer = std.Io.Writer;

pub const Builder = @import("jair/builder.zig");
const JIR = @import("../c/jir.zig");

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

pub const Constant = union(enum) {
    pub const Ptr = defines.Offset;
    pub const List = Builder.Constants.Slice;

    Word: u32,
    Long: u64,
    Single: f32,
    Double: f64,
    Byte: u8,
    Half: u16,
    String: union(enum) {
        C: defines.StringPtr,
        Cole: defines.StringPtr,
    },
    Function: defines.StringPtr,
    Aggregate: struct {
        Type: TypeID,
        Init: []const Constant.Ptr,
    },
    Nop,
};

pub const Node = struct {
    pub const List = MultiArrayList(Node);

    pub const Type = enum {
        Nop,
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
constants: Constant.List,
nodes: Node.List.Slice,
keyNodes: std.ArrayList(JAIR.Ptr).Slice,
data: std.ArrayList(u32).Slice,
indent: u32 = 0,
temp: u32 = 0,
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
                .Union => |uni| {
                    if (uni.size == 0 or uni.fields.len == 0) continue;

                    try self.write(true, out, "type :{s} = align {d} {{", .{
                        self.strings[uni.name],
                        uni.alignment,
                    });

                    for (uni.fields, 0..) |field, idx| {
                        try self.write(false, out, " {{", .{});
                        try self.typeString(out, field);
                        try self.write(false, out, "}}{s}", .{
                            if (idx != uni.fields.len - 1) "," else ""
                        });
                    }

                    try self.write(false, out, " }}\n", .{});
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
            },
            else => {},
        }
    }

    try self.write(true, out, "\n", .{});
    for (0..self.constants.len) |cptr| {
        switch (self.constants.get(cptr)) {
            .String => |str| switch (str) {
                .C => |c| try self.write(true, out, "data $const{d} = {{ b \"{s}\", b 0 }}\n", .{cptr, self.strings[c]}),
                .Cole => |c| {
                    try self.write(true, out, "data $str{d} = {{ b \"{s}\" }}\n", .{cptr, self.strings[c]});
                    try self.write(true, out, "data $const{d} = {{ l $str{d}, w {d} }}\n", .{cptr, cptr, self.strings[c].len});
                },
            },
            .Aggregate => |agg| {
                try self.write(true, out, "data $const{d} = {{ ", .{cptr});
                try self.typeString(out, agg.Type);
                try self.write(false, out, "{{", .{});
                for (agg.Init) |constant| {
                    // @TODO Continue
                }
                try self.write(false, out, " }}", .{});
            },
            else => { },
        }
    }

    for (self.keyNodes) |nodePtr| {
        try self.write(false, out, "\n", .{});
        try self.generate(out, nodePtr);
    }
}

fn constant(self: *JAIR, out: *Writer, constPtr: Constant.Ptr) Error!void {
    // @TODO Continue
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
            self.terminated = false;

            try self.generate(out, body);

            if (!self.terminated) {
                const isVoid = self.typeTable.get(returnType) == .Void;
                try self.write(true, out, "{s}\n", .{if (isVoid) "ret" else "hlt"});
            }
            try self.write(true, out, "}}\n\n", .{});
        },
        .Scope => {
            const label = self.strings[self.data[node.value]];
            if (!self.terminated) {
                try self.write(true, out, "jmp @{s}\n", .{label});
            }
            try self.write(false, out, "@{s}\n", .{label});
            self.terminated = false;

            self.indent += 1;
            defer self.indent -= 1;

            const len = self.data[node.value + 1];
            for (0..len) |idx| {
                try self.generate(out, self.data[node.value + 2 + idx]);
            }
        },
        .Nop => { },
        else => |t| try self.write(true, out, "# TODO {s}\n", .{@tagName(t)}),
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

fn sizeOf(self: *const JAIR, typeID: TypeID) u32 {
    return switch (self.typeTable.get(typeID)) {
        .Double => 8,
        .Single => 4,
        .Byte => 1,
        .Half => 2,
        .Long => 8,
        .Word => 4,
        .Void => 0,
        .Custom => |c| switch (c) {
            .Opaque => |o| o.size,
            .Union => |o| o.size,
            .Aggregate => |o| o.size,
        },
    };
}

fn write(self: *const JAIR, indent: bool, out: *Writer, comptime fmt: []const u8, args: anytype) Error!void {
    if (indent) {
        for (0..self.indent) |_| {
            _ = out.write("    ") catch return Error.IOError;
        }
    }
    out.print(fmt, args) catch return Error.IOError;
}
