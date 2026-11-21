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

    type: TypeID,
    kind: Node.Type,
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
                .C => |c| {
                    try self.write(true, out, "data $const{d} = {{ ", .{cptr});
                    for (self.strings[c], 0..) |ch, i| {
                        try self.write(false, out, "b {d}{s}", .{
                            ch,
                            if (i != self.strings[c].len - 1) ", " else "",
                        });
                    }
                    try self.write(true, out, ", b 0 }}\n", .{});
                },
                .Cole => |c| {
                    try self.write(true, out, "data $const{d} = {{ ", .{cptr});
                    for (self.strings[c], 0..) |ch, i| {
                        try self.write(false, out, "b {d}{s}", .{
                            ch,
                            if (i != self.strings[c].len - 1) ", " else "",
                        });
                    }
                    try self.write(true, out, " }}\n", .{});
                    try self.write(true, out, "data $const{d} = {{ l $str{d}, w {d} }}\n", .{cptr, cptr, self.strings[c].len});
                },
            },
            .Aggregate => |agg| {
                try self.write(true, out, "data $const{d} = {{ ", .{cptr});
                try self.typeString(out, agg.Type);
                try self.write(false, out, " {{", .{});
                for (agg.Init, 0..) |constptr, i| {
                    try self.write(false, out, " ", .{});
                    try self.constant(out, true, constptr);
                    if (i != agg.Init.len - 1) {
                        try self.write(false, out, ",", .{});
                    }
                }
                try self.write(false, out, " }}", .{});
                try self.write(false, out, " }}\n", .{});
            },
            else => { },
        }
    }

    const hiddenMain = @embedFile("../../res/hidden_main.ssa");
    try self.write(false, out, hiddenMain, .{});

    for (self.keyNodes) |nodePtr| {
        try self.write(false, out, "\n", .{});
        try self.generateStatement(out, nodePtr);
    }
}

fn constant(self: *JAIR, out: *Writer, bare: bool, constPtr: Constant.Ptr) Error!void {
    switch (self.constants.get(constPtr)) {
        .Byte => |b| try self.write(false, out, "b {s}{d}", .{if (bare) "" else "copy ", b}),
        .Double => |d| try self.write(false, out, "d {s}{d}", .{if (bare) "" else "copy ", @as(u64, @bitCast(d))}),
        .Half => |h| try self.write(false, out, "h {s}{d}", .{if (bare) "" else "copy ", h}),
        .Long => |l| try self.write(false, out, "l {s}{d}", .{if (bare) "" else "copy ", l}),
        .Single => |s| try self.write(false, out, "s {s}{d}", .{if (bare) "" else "copy ", @as(u32, @bitCast(s))}),
        .Word => |w| try self.write(false, out, "w {s}{d}", .{if (bare) "" else "copy ", w}),
        .Function => |f| try self.write(false, out, "l ${s}", .{self.strings[f]}),
        .String, .Aggregate => try self.write(false, out, "l $const{d}", .{constPtr}),
        .Nop => { },
    }
}

fn generateStatement(self: *JAIR, out: *Writer, nodePtr: Ptr) Error!void {
    const node = self.nodes.get(nodePtr);

    switch (node.kind) {
        .FunctionDef => {
            const tmp = self.temp;
            defer self.temp = tmp;

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

            try self.generateStatement(out, body);

            if (!self.terminated) {
                const isVoid = self.typeTable.get(returnType) == .Void;
                try self.write(true, out, "{s}\n", .{if (isVoid) "ret" else "hlt"});
            }
            try self.write(true, out, "}}\n\n", .{});
        },
        .Scope => {
            const label = self.strings[self.data[node.value]];
            try self.write(false, out, "@{s}\n", .{label});
            self.terminated = false;

            self.indent += 1;
            defer self.indent -= 1;

            const len = self.data[node.value + 1];
            for (0..len) |idx| {
                try self.generateStatement(out, self.data[node.value + 2 + idx]);
            }
        },
        .Label => try self.write(true, out, "@{s}\n", .{self.strings[node.value]}),
        .Return => {
            self.terminated = true;

            const withRet = self.data[node.value] == 1;

            if (withRet) {
                const tmp = try self.generateExpr(out, self.data[node.value + 1]);
                try self.write(true, out, "ret %tmp{d}\n", .{tmp});
            }
            else {
                try self.write(true, out, "ret\n", .{});
            }
        },
        else => |t| try self.write(true, out, "# SHOULDN'T' BE REACHABLE {s}\n", .{@tagName(t)}),
    }
}

fn generateExpr(self: *JAIR, out: *Writer, ptr: Ptr) Error!u32 {
    const node = self.nodes.get(ptr);
    switch (node.kind) {
        .Literal => {
            const res = self.allocTmp();
            try self.write(true, out, "%tmp{d} =", .{res});
            try self.constant(out, false, node.value);
            try self.write(false, out, "\n", .{});

            return res;
        },
        .Negation => {
            const operand = try self.generateExpr(out, node.value);
            const res = self.allocTmp();

            try self.write(true, out, "%tmp{d} =", .{res});
            try self.typeString(out, node.type);
            try self.write(false, out, " neg %tmp{d}\n", .{operand});

            return res;
        },
        .Not => switch (self.typeTable.get(node.type)) {
            .Word, .Long, .Double, .Single => {
                const operand = try self.generateExpr(out, node.value);
                const res = self.allocTmp();

                try self.write(true, out, "%tmp{d} =", .{res});
                try self.typeString(out, node.type);
                try self.write(false, out, " xor %tmp{d}, -1\n", .{operand});

                return res;
            },
            .Byte => {
                const operand = try self.generateExpr(out, node.value);
                const res = self.allocTmp();

                try self.write(true, out, "%tmp{d} =", .{res});
                try self.typeString(out, node.type);
                try self.write(false, out, " xor %tmp{d}, 255\n", .{operand});

                return res;
            },
            .Half => {
                const operand = try self.generateExpr(out, node.value);
                const res = self.allocTmp();

                try self.write(true, out, "%tmp{d} =", .{res});
                try self.typeString(out, node.type);
                try self.write(false, out, " xor %tmp{d}, 65535\n", .{operand});

                return res;
            },
            else => return 0,
        },
        .Nop => return 0,
        else => return 0,
    }
}

fn allocTmp(self: *JAIR) u32 {
    defer self.temp += 1;
    return self.temp;
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
