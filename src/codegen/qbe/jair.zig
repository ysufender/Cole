const std = @import("std");
const defines = @import("../../core/defines.zig");
const common = @import("../../core/common.zig");
const collections = @import("../../util/collections.zig");

const Typechecker = @import("../../typechecker/typechecker.zig");
const Context = common.CompilerContext;
const Error = common.CompilerError;
const TypeID = @import("../../typechecker/type.zig").TypeID;
const Writer = std.Io.Writer;

pub const Builder = @import("jair/builder.zig");
const JIR = @import("../c/jir.zig");

const MultiArrayList = @import("../../util/collections.zig").MultiArrayList;

const DataEmitter = struct { offset: u32 = 0, first: bool = true };

pub const Ptr = defines.Offset;

pub const Type = union(enum) {
    Void,
    Word: bool,
    Long: bool,
    Single,
    Double,
    Byte: bool,
    Half: bool,
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

    Word: struct { u32, bool },
    Long: struct { u64, bool },
    Single: f32,
    Double: f64,
    Byte: struct { u8, bool },
    Half: struct { u16, bool },
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
        Load,
        Store,
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
        Jump,
        JumpIf,
        Lesser,
        LesserEqual,
        Greater,
        GreaterEqual,
        Equal,
        NotEqual,
        Phi,
        Not,
        Xor,
        Negation,
        Code,
        Mod,
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

                        _ = std.mem.replace(u8, self.strings[opaqueType.name], "::", "__", @constCast(self.strings[opaqueType.name]));

                    try self.write(true, out, "type :{s} = align {d} {{ {d} }}\n", .{
                        self.strings[opaqueType.name],
                        opaqueType.alignment,
                        opaqueType.size,
                    });
                },
                .Union => |uni| {
                    if (uni.size == 0 or uni.fields.len == 0) continue;

                    _ = std.mem.replace(u8, self.strings[uni.name], "::", "__", @constCast(self.strings[uni.name]));

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

                    _ = std.mem.replace(u8, self.strings[aggregate.name], "::", "__", @constCast(self.strings[aggregate.name]));

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
                    try self.write(true, out, "data $str{d} = {{ ", .{cptr});
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
                if (self.sizeOf(agg.Type) == 0) {
                    continue;
                }

                const al: u32 = switch (self.typeTable.get(agg.Type)) {
                    .Custom => |cu| @max(1, switch (cu) {
                        .Opaque => |o| o.alignment,
                        .Union => |o| o.alignment,
                        .Aggregate => |o| o.alignment,
                    }),
                    else => @max(1, self.sizeOf(agg.Type)),
                };

                try self.write(true, out, "data $const{d} = align {d} {{ ", .{ cptr, al });
                var em: DataEmitter = .{};
                try self.dataItems(out, &em, @intCast(cptr));
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
        .Byte => |b| try self.write(false, out, "{s} {s}{d}", .{if (bare) "b" else "w", if (bare) "" else "copy ", b.@"0"}),
        .Double => |d|
            if (bare) try self.write(false, out, "l {d}", .{@as(u64, @bitCast(d))})
            else try self.write(false, out, "d copy d_{d}", .{d}),
        .Single => |s|
            if (bare) try self.write(false, out, "w {d}", .{@as(u32, @bitCast(s))})
            else try self.write(false, out, "s copy s_{d}", .{s}),
        .Half => |h| try self.write(false, out, "{s} {s}{d}", .{if (bare) "h" else "w", if (bare) "" else "copy ", h.@"0"}),
        .Long => |l| try self.write(false, out, "l {s}{d}", .{if (bare) "" else "copy ", l.@"0"}),
        .Word => |w| try self.write(false, out, "w {s}{d}", .{if (bare) "" else "copy ", w.@"0"}),
        .Function => |f| try self.write(false, out, "l ${s}", .{self.strings[f]}),
        .String, .Aggregate => try self.write(false, out, "l {s}$const{d}", .{if (bare) "" else "copy ", constPtr}),
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
        .Jump => try self.write(true, out, "jmp @{s}\n", .{self.strings[node.value]}),
        .JumpIf => {
            const operand = try self.generateExpr(out, self.data[node.value + 1]);
            const lbl = self.strings[self.data[node.value]];
            const otherwise = self.allocTmp();
            try self.write(true, out, "jnz %__tmp{d}, @__lbl{d}, @{s}\n", .{operand, otherwise, lbl});
            try self.write(true, out, "@__lbl{d}\n", .{otherwise});
        },
        .Code => try self.write(true, out, "{s}\n", .{self.strings[node.value]}),
        .Store => try self.store(out, &node),
        .Return => {
            self.terminated = true;

            const withRet = self.data[node.value] == 1;

            if (withRet) {
                const __tmp = try self.generateExpr(out, self.data[node.value + 1]);
                try self.write(true, out, "ret %__tmp{d}\n", .{__tmp});
            }
            else {
                try self.write(true, out, "ret\n", .{});
            }
        },

        .Exit => { },

        else => _ = try self.generateExpr(out, nodePtr),
    }
}

fn generateExpr(self: *JAIR, out: *Writer, ptr: Ptr) Error!u32 {
    const node = self.nodes.get(ptr);
    switch (node.kind) {
        .Literal => {
            switch (self.constants.get(node.value)) {
                .Double => |d| if (!std.math.isFinite(d)) {
                    const bits = self.allocTmp();
                    const res = self.allocTmp();
                    try self.write(true, out, "%__tmp{d} =l copy {d}\n", .{bits, @as(u64, @bitCast(d))});
                    try self.write(true, out, "%__tmp{d} =d cast %__tmp{d}\n", .{res, bits});
                    return res;
                },
                .Single => |s| if (!std.math.isFinite(s)) {
                    const bits = self.allocTmp();
                    const res = self.allocTmp();
                    try self.write(true, out, "%__tmp{d} =w copy {d}\n", .{bits, @as(u32, @bitCast(s))});
                    try self.write(true, out, "%__tmp{d} =s cast %__tmp{d}\n", .{res, bits});
                    return res;
                },
                else => {},
            }

            const res = self.allocTmp();
            try self.write(true, out, "%__tmp{d} =", .{res});
            try self.constant(out, false, node.value);
            try self.write(false, out, "\n", .{});

            return res;
        },
        .Negation => {
            const operand = try self.generateExpr(out, node.value);
            const res = self.allocTmp();

            try self.write(true, out, "%__tmp{d} =", .{res});
            try self.typeString(out, node.type);
            try self.write(false, out, " neg %__tmp{d}\n", .{operand});

            return res;
        },
        .Not => return self.not(out, &node),
        .And => return self.commonBinary(out, "and", &node),
        .Or => return self.commonBinary(out, "or", &node),
        .Add => return self.commonBinary(out, "add", &node),
        .Equal => return self.commonComparison(out, "eq", &node),
        .NotEqual => return self.commonComparison(out, "ne", &node),
        .Lesser => return self.commonComparison(out, "lt", &node),
        .LesserEqual => return self.commonComparison(out, "le", &node),
        .Greater => return self.commonComparison(out, "gt", &node),
        .GreaterEqual => return self.commonComparison(out, "ge", &node),
        .Div => return self.commonBinary(out, "div", &node),
        .Mod => return self.commonBinary(out, "rem", &node),
        .LeftShift => return self.commonBinary(out, "shl", &node),
        .RightShift => return self.commonBinary(out, "shr", &node),
        .Mul => return self.commonBinary(out, "mul", &node),
        .Sub => return self.commonBinary(out, "sub", &node),
        .Xor => return self.commonBinary(out, "xor", &node),
        .Phi => return self.phi(out, &node),
        .Identifier => return self.identifier(out, &node),
        .Call => return self.call(out, &node),

        .Code, .FunctionDef, .VariableDef, .Exit, .JumpIf, .Jump, .Label, .Return, .Scope => return Error.ShouldBeImpossible,

        else => |unr| {
            common.log.debug("Unreachable {s}", .{@tagName(unr)});
            return common.debug.ShouldBeImpossible(undefined, @src());
        },
    }
}

fn call(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    // @Beware allow 512 parameters for now, hardcoded.
    const Param = struct {
        id: u32,
        type: TypeID,
    };
    var params = collections.StaticStack(Param, 512){};
    params.revert(0);

    const func = try self.generateExpr(out, self.data[node.value]);
    const len = self.data[node.value + 1];

    for (0..len) |idx| {
        try params.push(.{
            .id = try self.generateExpr(out, self.data[node.value + 1 + len - idx]),
            .type = self.nodes.items(.type)[self.data[node.value + 1 + len - idx]],
        });
    }

    const res = self.allocTmp();
    try self.write(true, out, "%__tmp{d} =", .{res});
    try self.typeString(out, node.type);
    try self.write(false, out, " call %__tmp{d}(", .{func});
    while (params.pop()) |param| {
        try self.typeString(out, param.type);
        try self.write(false, out, " %__tmp{d}{s}", .{
            param.id,
            if (params.empty()) "" else ", ",
        });
    }
    try self.write(false, out, ")\n", .{});

    return res;
}

fn store(self: *JAIR, out: *Writer, node: *const Node) Error!void {
    const lhs = self.data[node.value];
    const rhs = self.data[node.value + 1];

    // @Beware lhs has LValue flag active, result must be an address.
    const lhsTmp = try self.generateExpr(out, lhs);
    const rhsTmp = try self.generateExpr(out, rhs);

    try self.write(true, out, "store", .{});
    try self.typeString(out, node.type);
    try self.write(false, out, " %__tmp{d}, %__tmp{d}\n", .{rhsTmp, lhsTmp});
}

fn identifier(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const name = self.strings[self.data[node.value]];
    const topLevel = self.data[node.value + 1] == 1;
    const valueType = node.type;
    const lvalue = self.data[node.value + 2] == 1;

    // @TODO This doesn't distinguish between locals and parameters.

    const res = self.allocTmp();

    try self.write(true, out, "%__tmp{d} =", .{res});
    if (lvalue) {
        try self.write(false, out, "l copy",. {});
    }
    else {
        try self.typeString(out, valueType);
        try self.write(false, out, " load",. {});
        try self.typeString(out, valueType);
    }
    try self.write(false, out, " {s}{s}\n",. {if (topLevel) "$" else "%", name});

    return res;
}

fn phi(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const cnd = try self.generateExpr(out, self.data[node.value]);
    const thenLabel = self.allocTmp();
    const otherwiseLabel = self.allocTmp();
    const finalLabel = self.allocTmp();
    try self.write(true, out, "jnz %__tmp{d}, @__ternary_then{d}, @__ternary_otherwise{d}\n", .{cnd, thenLabel, otherwiseLabel});

    try self.write(true, out, "@__ternary_then{d}\n", .{thenLabel});
    const then = try self.generateExpr(out, self.data[node.value + 1]);
    try self.write(true, out, "jmp @__ternary_final{d}\n", .{finalLabel});

    try self.write(true, out, "@__ternary_otherwise{d}\n", .{otherwiseLabel});
    const otherwise = try self.generateExpr(out, self.data[node.value + 2]);
    try self.write(true, out, "jmp @__ternary_final{d}\n", .{finalLabel});

    try self.write(true, out, "@__ternary_final{d}\n", .{finalLabel});
    const res = self.allocTmp();
    try self.write(true, out, "%__tmp{d} =", .{res});
    try self.typeString(out, node.type);
    try self.write(false, out, " phi @__ternary_then{d} %__tmp{d}, @__ternary_otherwise{d} %__tmp{d}\n", .{
        thenLabel, then,
        otherwiseLabel, otherwise,
    });

    return res;
}

fn commonComparison(self: *JAIR, out: *Writer, comptime op: []const u8, node: *const Node) Error!u32 {
    const lhs = try self.generateExpr(out, self.data[node.value]);
    const rhs = try self.generateExpr(out, self.data[node.value + 1]);
    const res = self.allocTmp();

    try self.write(true, out, "%__tmp{d} =", .{res});
    try self.typeString(out, node.type);
    try self.write(false, out, " c{s}{s}", .{
        if (self.signed(node.type)) |s|
            if (node.kind == .Equal or node.kind == .NotEqual) ""
            else if (s) "s"
            else "u"
        else "",
        op,
    });
    try self.typeString(out, node.type);
    try self.write(false, out, " %__tmp{d}, %__tmp{d}\n", .{lhs, rhs});

    return res;
}

fn commonBinary(self: *JAIR, out: *Writer, comptime op: []const u8, node: *const Node) Error!u32 {
    const lhs = try self.generateExpr(out, self.data[node.value]);
    const rhs = try self.generateExpr(out, self.data[node.value + 1]);
    const res = self.allocTmp();

    try self.write(true, out, "%__tmp{d} =", .{res});
    try self.typeString(out, node.type);
    try self.write(false, out, " {s}{s} %__tmp{d}, %__tmp{d}\n", .{
        if (node.kind == .Div or node.kind == .Mod)
            if (self.signed(node.type)) |s|
                if (s) ""
                else "u"
            else ""
        else "",
        op,
        lhs,
        rhs
    });

    return res;
}

fn not(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    switch (self.typeTable.get(node.type)) {
        .Word, .Long, .Double, .Single => {
            const operand = try self.generateExpr(out, node.value);
            const res = self.allocTmp();

            try self.write(true, out, "%__tmp{d} =", .{res});
            try self.typeString(out, node.type);
            try self.write(false, out, " xor %__tmp{d}, -1\n", .{operand});

            return res;
        },
        .Byte => {
            const operand = try self.generateExpr(out, node.value);
            const res = self.allocTmp();

            try self.write(true, out, "%__tmp{d} =", .{res});
            try self.typeString(out, node.type);
            try self.write(false, out, " xor %__tmp{d}, 255\n", .{operand});

            return res;
        },
        .Half => {
            const operand = try self.generateExpr(out, node.value);
            const res = self.allocTmp();

            try self.write(true, out, "%__tmp{d} =", .{res});
            try self.typeString(out, node.type);
            try self.write(false, out, " xor %__tmp{d}, 65535\n", .{operand});

            return res;
        },
        else => return common.debug.ShouldBeImpossible(undefined, @src()),
    }
}

fn signed(self: *const JAIR, id: TypeID) ?bool {
    return switch (self.typeTable.get(id)) {
        .Byte => |b| b,
        .Half => |b| b,
        .Word => |b| b,
        .Long => |b| b,
        else => null
    };
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
        .Half => try self.write(false, out, "w", .{}),
        .Byte => try self.write(false, out, "w", .{}),
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

fn dataItems(self: *JAIR, out: *Writer, em: *DataEmitter, ptr: Constant.Ptr) Error!void {
    const c = self.constants.get(ptr);

    const al: u32 = switch (c) {
        .Byte => 1,
        .Half => 2,
        .Word, .Single => 4,
        .Long, .Double, .Function, .String => 8,
        .Aggregate => |a| switch (self.typeTable.get(a.Type)) {
            .Custom => |cu| @max(1, switch (cu) {
                .Opaque => |o| o.alignment,
                .Union => |o| o.alignment,
                .Aggregate => |o| o.alignment,
            }),
            else => @max(1, self.sizeOf(a.Type)),
        },
        .Nop => 1,
    };

    // pad up to this item's alignment
    const aligned = std.mem.alignForward(u32, em.offset, al);
    if (aligned > em.offset) {
        try self.write(false, out, "{s}z {d}", .{ if (em.first) "" else ", ", aligned - em.offset });
        em.first = false;
        em.offset = aligned;
    }

    switch (c) {
        .Nop => return,
        .Aggregate => |agg| {
            const end = em.offset + self.sizeOf(agg.Type);
            for (agg.Init) |elem| try self.dataItems(out, em, elem);

            // trailing padding up to the aggregate's full size
            if (end > em.offset) {
                try self.write(false, out, "{s}z {d}", .{ if (em.first) "" else ", ", end - em.offset });
                em.first = false;
                em.offset = end;
            }
            return;
        },
        else => {},
    }

    try self.write(false, out, "{s}", .{if (em.first) "" else ", "});
    em.first = false;

    em.offset += switch (c) {
        .Byte => |b| blk: {
            try self.write(false, out, "b {d}", .{b.@"0"});
            break :blk 1;
        },
        .Half => |h| blk: {
            try self.write(false, out, "h {d}", .{h.@"0"});
            break :blk 2;
        },
        .Word => |w| blk: {
            try self.write(false, out, "w {d}", .{w.@"0"});
            break :blk 4;
        },
        .Long => |l| blk: {
            try self.write(false, out, "l {d}", .{l.@"0"});
            break :blk 8;
        },
        .Single => |s| blk: {
            try self.write(false, out, "w {d}", .{@as(u32, @bitCast(s))});
            break :blk 4;
        },
        .Double => |d| blk: {
            try self.write(false, out, "l {d}", .{@as(u64, @bitCast(d))});
            break :blk 8;
        },
        .Function => |f| blk: {
            try self.write(false, out, "l ${s}", .{self.strings[f]});
            break :blk 8;
        },
        .String => |s| switch (s) {
            .C => blk: {
                try self.write(false, out, "l $const{d}", .{ptr});
                break :blk 8;
            },
            .Cole => |str| blk: {
                // {ptr, len} plus 4 bytes of tail padding to the 8-byte alignment
                try self.write(false, out, "l $str{d}, w {d}, z 4", .{ ptr, self.strings[str].len });
                break :blk 16;
            },
        },
        .Nop, .Aggregate => unreachable,
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
