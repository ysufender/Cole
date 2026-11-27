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

const collections = @import("../../util/collections.zig");
const MultiArrayList = collections.MultiArrayList;

const DataEmitter = struct {
    offset: u32 = 0,
    first: bool = true,
};

const Local = struct {
    name: []const u8,
    unique: []const u8,
};

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
            fields: []const TypeID,
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
};

pub const Node = struct {
    pub const List = MultiArrayList(Node);

    pub const Type = enum {
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
        Invert,
        Xor,
        Negation,
        Code,
        Mod,
        StatementExpr,
        Construct,
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
currentBlock: []const u8 = "start",
allocator: std.mem.Allocator = undefined,
localStack: std.ArrayList(Local) = .empty,
localCount: u32 = 0,
locals: *Writer = undefined,

pub fn codegen(self: *JAIR, context: *Context, qbeOut: *std.Io.Dir, allocator: std.mem.Allocator) Error!void {
    var wbuf = std.mem.zeroes([512]u8);

    var outputFile = qbeOut.createFile(context.io, "source.ssa", .{}) catch |err| {
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

                    _ = std.mem.replace(
                        u8,
                        self.strings[opaqueType.name],
                        "::",
                        "__",
                        @constCast(self.strings[opaqueType.name]),
                    );

                    try self.write(true, out, "type :{s} = align {d} {{ {d} }}\n", .{
                        self.strings[opaqueType.name],
                        opaqueType.alignment,
                        opaqueType.size,
                    });
                },
                .Union => |uni| {
                    if (uni.size == 0 or uni.fields.len == 0) continue;

                    _ = std.mem.replace(
                        u8,
                        self.strings[uni.name],
                        "::",
                        "__",
                        @constCast(self.strings[uni.name]),
                    );

                    try self.write(true, out, "type :{s} = align {d} {{", .{
                        self.strings[uni.name],
                        uni.alignment,
                    });

                    for (uni.fields) |field| {
                        try self.write(false, out, " {{", .{});
                        try self.aggregateTypeString(out, field);
                        try self.write(false, out, " }}", .{});
                    }

                    try self.write(false, out, " }}\n", .{});
                },
                .Aggregate => |aggregate| {
                    if (aggregate.size == 0 or aggregate.fields.len == 0) continue;

                    _ = std.mem.replace(
                        u8,
                        self.strings[aggregate.name],
                        "::",
                        "__",
                        @constCast(self.strings[aggregate.name]),
                    );

                    try self.write(true, out, "type :{s} = align {d} {{", .{
                        self.strings[aggregate.name],
                        aggregate.alignment,
                    });

                    for (aggregate.fields, 0..) |field, idx| {
                        try self.write(false, out, " ", .{});
                        try self.aggregateTypeString(out, field);
                        try self.write(false, out, "{s}", .{
                            if (idx != aggregate.fields.len - 1) "," else "",
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
                    try self.write(true, out, "data $__const{d} = {{ ", .{cptr});

                    for (self.strings[c], 0..) |ch, i| {
                        try self.write(false, out, "b {d}{s}", .{
                            ch,
                            if (i != self.strings[c].len - 1) ", " else "",
                        });
                    }

                    try self.write(false, out, ", b 0 }}\n", .{});
                },
                .Cole => |c| {
                    try self.write(true, out, "data $__str{d} = {{ ", .{cptr});

                    for (self.strings[c], 0..) |ch, i| {
                        try self.write(false, out, "b {d}{s}", .{
                            ch,
                            if (i != self.strings[c].len - 1) ", " else "",
                        });
                    }

                    try self.write(true, out, "{s}b 0 }}\n", .{if (self.strings[c].len == 0) " " else ", "});
                    try self.write(true, out, "data $__const{d} = {{ l $__str{d}, w {d}, z 4 }}\n", .{
                        cptr,
                        cptr,
                        self.strings[c].len,
                    });
                },
            },
            .Aggregate => |agg| {
                if (self.sizeOf(agg.Type) == 0) continue;

                const al = self.alignOf(agg.Type);

                try self.write(true, out, "data $__const{d} = align {d} {{ ", .{ cptr, al });

                var em: DataEmitter = .{};
                try self.dataItems(out, &em, @intCast(cptr));

                try self.write(false, out, " }}\n", .{});
            },
            else => {},
        }
    }

    const hiddenMain = @embedFile("../../res/hidden_main.ssa");
    try self.write(false, out, hiddenMain, .{});

    self.allocator = allocator;

    self.localStack = std.ArrayList(Local).initCapacity(self.allocator, self.keyNodes.len)
        catch return Error.AllocatorFailure;

    for (self.keyNodes) |nodePtr| {
        self.terminated = false;
        try self.write(false, out, "\n", .{});
        try self.generateStatement(out, nodePtr);
    }
}

fn constant(self: *JAIR, out: *Writer, bare: bool, constPtr: Constant.Ptr) Error!void {
    switch (self.constants.get(constPtr)) {
        .Byte => |b| {
            try self.write(false, out, "{s} {s}{d}", .{
                if (bare) "b" else "w",
                if (bare) "" else "copy ",
                b.@"0",
            });
        },
        .Double => |d| {
            if (bare) {
                try self.write(false, out, "l {d}", .{@as(u64, @bitCast(d))});
            }
            else {
                try self.write(false, out, "d copy d_{d}", .{d});
            }
        },
        .Single => |s| {
            if (bare) {
                try self.write(false, out, "w {d}", .{@as(u32, @bitCast(s))});
            }
            else {
                try self.write(false, out, "s copy s_{d}", .{s});
            }
        },
        .Half => |h| {
            try self.write(false, out, "{s} {s}{d}", .{
                if (bare) "h" else "w",
                if (bare) "" else "copy ",
                h.@"0",
            });
        },
        .Long => |l| {
            try self.write(false, out, "l {s}{d}", .{
                if (bare) "" else "copy ",
                l.@"0",
            });
        },
        .Word => |w| {
            try self.write(false, out, "w {s}{d}", .{
                if (bare) "" else "copy ",
                w.@"0",
            });
        },
        .Function => |f| {
            try self.write(false, out, "l {s}${s}", .{
                if (bare) "" else "copy ",
                self.strings[f],
            });
        },
        .String, .Aggregate => {
            try self.write(false, out, "l {s}$__const{d}", .{
                if (bare) "" else "copy ",
                constPtr,
            });
        },
    }
}

fn generateStatement(self: *JAIR, out: *Writer, nodePtr: Ptr) Error!void {
    const node = self.nodes.get(nodePtr);

    if (self.terminated) switch (node.kind) {
        .Label, .Scope, .FunctionDef, .VariableDef => {},
        else => return,
    };

    switch (node.kind) {
        .FunctionDef => {
            self.terminated = false;

            const tmp = self.temp;
            defer self.temp = tmp;

            const isExtern = self.data[node.value] == 1;
            if (isExtern) return;

            const isExported = self.data[node.value + 1] == 1;
            const name = self.strings[self.data[node.value + 2]];
            const returnType = self.data[node.value + 3];
            const argLen = self.data[node.value + 4];
            const body = self.data[node.value + 5 + argLen * 2];

            try self.write(true, out, "{s}function ", .{
                if (isExported) "export " else "",
            });

            try self.typeString(out, false, returnType);
            try self.write(false, out, " ${s}(", .{name});

            for (0..argLen) |idx| {
                const offset = node.value + 5 + idx * 2;
                const argType = self.data[offset];
                const argName = self.data[offset + 1];

                try self.typeString(out, false, argType);
                try self.write(false, out, " %{s}{s}", .{
                    self.strings[argName],
                    if (idx != argLen - 1) ", " else "",
                });
            }

            try self.write(false, out, ") {{\n@start\n", .{});
            self.currentBlock = "start";

            for (0..argLen) |idx| {
                const offset = node.value + 5 + idx * 2;
                const argType = self.data[offset];
                const argName = self.data[offset + 1];

                if (self.sizeOf(argType) == 0) continue;

                if (self.isScalar(argType)) {
                    try self.write(true, out, "%__param_{s} =l alloc{d} {d}\n", .{
                        self.strings[argName],
                        self.allocAlignment(argType),
                        self.sizeOf(argType),
                    });

                    try self.write(true, out, "store", .{});
                    try self.storeTypeString(out, argType);
                    try self.write(false, out, " %{s}, %__param_{s}\n", .{
                        self.strings[argName],
                        self.strings[argName],
                    });
                }
                else {
                    try self.write(true, out, "%__param_{s} =l copy %{s}\n", .{self.strings[argName], self.strings[argName]});
                }
            }

            try self.write(false, out, "\n", .{});

            var bodyBuf: Writer.Allocating = .init(self.allocator);
            defer bodyBuf.deinit();
            var allocBuf: Writer.Allocating = .init(self.allocator);
            defer allocBuf.deinit();
            self.locals = &allocBuf.writer;

            self.localStack.clearRetainingCapacity();
            self.terminated = false;
            try self.generateStatement(&bodyBuf.writer, body);
            if (!self.terminated) {
                try self.write(true, &bodyBuf.writer, "{s}\n", .{
                    if (self.sizeOf(returnType) == 0) "ret" else "hlt",
                });
            }

            out.writeAll(allocBuf.written()) catch return Error.IOError;
            out.writeAll(bodyBuf.written()) catch return Error.IOError;
            try self.write(true, out, "}}\n\n", .{});
        },
        .Scope => {
            const label = self.strings[self.data[node.value]];

            const localStackLen = self.localStack.items.len;
            defer self.localStack.items = self.localStack.items[0..localStackLen];

            try self.write(false, out, "@{s}\n", .{label});
            self.currentBlock = label;

            self.terminated = false;
            self.indent += 1;
            defer self.indent -= 1;

            const len = self.data[node.value + 1];

            for (0..len) |idx| {
                try self.generateStatement(out, self.data[node.value + 2 + idx]);
            }
        },        .Label => {
            self.terminated = false;
            const label = self.strings[node.value];
            try self.write(true, out, "@{s}\n", .{label});
            self.currentBlock = label;
        },
        .Jump => {
            self.terminated = true;
            try self.write(true, out, "jmp @{s}\n", .{self.strings[node.value]});
        },
        .JumpIf => {
            const operand = try self.generateExpr(out, self.data[node.value + 1]);
            const lbl = self.strings[self.data[node.value]];
            const otherwise = self.allocTmp();

            try self.write(true, out, "jnz %__tmp{d},  @{s}, @__lbl{d}\n", .{
                operand,
                lbl,
                otherwise,
            });

            try self.write(true, out, "@__lbl{d}\n", .{otherwise});
            self.terminated = false;
            self.currentBlock = std.fmt.allocPrint(
                self.allocator,
                "__lbl{d}",
                .{otherwise},
            ) catch return Error.AllocatorFailure;
        },
        .Code => try self.write(true, out, "\n{s}\n", .{self.strings[node.value]}),
        .Store => try self.store(out, &node),
        .VariableDef => try self.variableDef(out, &node),
        .Return => {
            const withRet = self.data[node.value] == 1;

            if (withRet) {
                const expr = self.data[node.value + 1];
                const retType = self.nodes.items(.type)[expr];

                if (self.sizeOf(retType) == 0) {
                    _ = try self.generateExpr(out, expr);
                    try self.write(true, out, "ret\n", .{});
                }
                else {
                    const tmp = try self.generateExpr(out, expr);
                    try self.write(true, out, "ret %__tmp{d}\n", .{tmp});
                }
            }
            else {
                try self.write(true, out, "ret\n", .{});
            }

            self.terminated = true;
        },
        .Exit => {},
        else => {
            _ = try self.generateExpr(out, nodePtr);
        },
    }
}

fn allocSlot(self: *JAIR, typeID: TypeID) Error!u32 {
    const t = self.allocTmp();
    self.locals.print("    %__tmp{d} =l alloc{d} {d}\n", .{
        t, self.allocAlignment(typeID), @max(1, self.sizeOf(typeID)),
    }) catch return Error.IOError;
    return t;
}

fn variableDef(self: *JAIR, out: *Writer, node: *const Node) Error!void {
    const top = self.data[node.value] == 1;
    const ty = self.data[node.value + 1];
    const name = self.strings[self.data[node.value + 2]];
    const hasInit = self.data[node.value + 3] == 1;
    const isExtern = self.data[node.value + 4] == 1;
    const init = self.data[node.value + 5];
    const size = self.sizeOf(ty);

    _ = std.mem.replace(u8, name, "::", "__", @constCast(name));

    if (top) {
        if (isExtern) return;
        try self.write(true, out, "export data ${s} = align {d} {{ ", .{ name, self.allocAlignment(ty) });
        var em: DataEmitter = .{};
        if (hasInit and self.nodes.items(.kind)[init] == .Literal) {
            try self.dataItems(out, &em, self.nodes.items(.value)[init]);
        }
        if (em.offset < size) {
            try self.write(false, out, "{s}z {d}", .{ if (em.first) "" else ", ", size - em.offset });
        }
        try self.write(false, out, " }}\n", .{});
        return;
    }

    if (size == 0) {
        if (hasInit) _ = try self.generateExpr(out, init);
        return;
    }

    const unique = std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ name, self.localCount })
        catch return Error.AllocatorFailure;
    self.localCount += 1;
    self.localStack.append(self.allocator, .{ .name = name, .unique = unique })
        catch return Error.AllocatorFailure;

    self.locals.print("    %{s} =l alloc{d} {d}\n", .{ unique, self.allocAlignment(ty), size })
        catch return Error.IOError;
    const slot = self.allocTmp();
    try self.write(true, out, "%__tmp{d} =l copy %{s}\n", .{ slot, unique });

    if (hasInit) try self.storeTo(out, slot, init, ty) else try self.zeroFill(out, slot, size);
}

fn generateExpr(self: *JAIR, out: *Writer, ptr: Ptr) Error!u32 {
    const node = self.nodes.get(ptr);

    switch (node.kind) {
        .Literal => {
            switch (self.constants.get(node.value)) {
                .Double => |d| {
                    if (!std.math.isFinite(d)) {
                        const bits = self.allocTmp();
                        const res = self.allocTmp();

                        try self.write(true, out, "%__tmp{d} =l copy {d}\n", .{
                            bits,
                            @as(u64, @bitCast(d)),
                        });

                        try self.write(true, out, "%__tmp{d} =d cast %__tmp{d}\n", .{
                            res,
                            bits,
                        });

                        return res;
                    }
                },
                .Single => |s| {
                    if (!std.math.isFinite(s)) {
                        const bits = self.allocTmp();
                        const res = self.allocTmp();

                        try self.write(true, out, "%__tmp{d} =w copy {d}\n", .{
                            bits,
                            @as(u32, @bitCast(s)),
                        });

                        try self.write(true, out, "%__tmp{d} =s cast %__tmp{d}\n", .{
                            res,
                            bits,
                        });

                        return res;
                    }
                },
                .Aggregate => |agg| if (self.isScalar(node.type) and agg.Init.len == 1) {
                    const res = self.allocTmp();
                    try self.write(true, out, "%__tmp{d} =", .{res});
                    try self.constant(out, false, agg.Init[0]);
                    try self.write(false, out, "\n", .{});
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
            try self.typeString(out, true, node.type);
            try self.write(false, out, " neg %__tmp{d}\n", .{operand});

            return res;
        },
        .Not => return self.not(out, &node),
        .Invert => return self.invert(out, &node),
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
        .Load => return self.load(out, &node),
        .Reference => return self.reference(out, &node),
        .StatementExpr => return self.stmtExpr(out, &node),
        .Construct => return self.construct(out, &node),

        .Store, .Code, .FunctionDef,
        .VariableDef, .Exit, .JumpIf,
        .Jump, .Label, .Return, .Scope, => return Error.ShouldBeImpossible,
    }
}

fn construct(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const len = self.data[node.value];
    const args = self.data[node.value + 1 ..][0..len];

    const custom = switch (self.typeTable.get(node.type)) {
        .Custom => |c| c,
        else => return self.constructScalar(out, node, args),
    };

    const size = self.sizeOf(node.type);
    if (size == 0) {
        for (args) |arg| _ = try self.generateExpr(out, arg);
        const res = self.allocTmp();
        try self.write(true, out, "%__tmp{d} =l copy 0\n", .{res});
        return res;
    }

    const base = try self.allocSlot(node.type);
    try self.zeroFill(out, base, size);

    switch (custom) {
        .Aggregate => |agg| {
            var fieldIdx: usize = 0;
            var offset: u32 = 0;
            for (args) |arg| {
                if (self.sizeOf(self.nodes.items(.type)[arg]) == 0) {
                    _ = try self.generateExpr(out, arg);
                    continue;
                }
                if (fieldIdx >= agg.fields.len) {
                    common.log.debug("Field '{d}' is out of bounds on type '{s}'", .{
                        fieldIdx,
                        self.strings[self.typeNames.get(node.type).?],
                    });
                    return Error.ShouldBeImpossible;
                }
                const ft = agg.fields[fieldIdx];
                fieldIdx += 1;
                offset = std.mem.alignForward(u32, offset, @max(1, self.alignOf(ft)));
                try self.storeTo(out, try self.offsetPtr(out, base, offset), arg, ft);
                offset += self.sizeOf(ft);
            }
        },
        .Union => {
            if (len == 0) return base;
            for (args[0 .. len - 1]) |arg| _ = try self.generateExpr(out, arg);
            try self.storeTo(out, base, args[len - 1], null);
        },
        .Opaque => {
            if (len == 0) return base;
            const stride = if (size % len == 0) size / len
                else self.sizeOf(self.nodes.items(.type)[args[0]]);
            for (args, 0..) |arg, i| {
                const dst = try self.offsetPtr(out, base, @intCast(i * stride));
                try self.storeTo(out, dst, arg, null);
            }
        },
    }
    return base;
}

fn constructScalar(self: *JAIR, out: *Writer, node: *const Node, args: []const u32) Error!u32 {
    if (args.len == 0) {
        const res = self.allocTmp();
        try self.write(true, out, "%__tmp{d} =", .{res});
        try self.typeString(out, true, node.type);
        try self.write(false, out, " copy {s}\n", .{
            switch (self.typeTable.get(node.type)) {
                .Single => "s_0",
                .Double => "d_0",
                else => "0",
            },
        });
        return res;
    }

    const arg = args[0];
    const from = self.nodes.items(.type)[arg];
    const src = try self.generateExpr(out, arg);

    if (from == node.type) return src;

    if (!self.isScalar(from)) {
        const res = self.allocTmp();
        try self.write(true, out, "%__tmp{d} =", .{res});
        try self.typeString(out, true, node.type);
        try self.write(false, out, " load", .{});
        try self.loadTypeString(out, node.type);
        try self.write(false, out, " %__tmp{d}\n", .{src});
        return res;
    }

    return self.convert(out, src, from, node.type);
}

fn stmtExpr(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const final = self.data[node.value];
    const len = self.data[node.value + 1];

    for (0..len) |idx| {
        try self.generateStatement(out, self.data[node.value + 2 + idx]);
    }

    return try self.generateExpr(out, final);
}

fn reference(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    return self.generateExpr(out, node.value);
}

fn load(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const lvalue = self.data[node.value] == 1;
    const expr = self.data[node.value + 1];

    const ptr = try self.generateExpr(out, expr);

    if (lvalue or !self.isScalar(node.type)) return ptr;

    const res = self.allocTmp();

    try self.write(true, out, "%__tmp{d} =", .{res});
    try self.typeString(out, true, node.type);
    try self.write(false, out, " load", .{});
    try self.loadTypeString(out, node.type);
    try self.write(false, out, " %__tmp{d}\n", .{ptr});

    return res;
}

fn call(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const Param = struct {
        id: u32,
        type: TypeID,
    };

    var params = collections.StaticStack(Param, 512){};
    params.revert(0);

    const returnType = self.data[node.value];
    const func = try self.generateExpr(out, self.data[node.value + 1]);
    const len = self.data[node.value + 2];

    const argStart = node.value + 3;

    for (0..len) |idx| {
        const arg = self.data[argStart + len - 1 - idx];

        try params.push(.{
            .id = try self.generateExpr(out, arg),
            .type = self.nodes.items(.type)[arg],
        });
    }

    const hasReturn = self.sizeOf(returnType) != 0;
    const res = if (hasReturn) self.allocTmp() else 0;

    if (hasReturn) {
        try self.write(true, out, "%__tmp{d} =", .{res});
        try self.typeString(out, false, returnType);
        try self.write(false, out, " ", .{});
    }

    try self.write(true, out, "call %__tmp{d}(", .{func});

    var first = true;

    while (params.pop()) |param| {
        if (!first) try self.write(false, out, ", ", .{});
        first = false;

        try self.typeString(out, false, param.type);
        try self.write(false, out, " %__tmp{d}", .{param.id});
    }

    try self.write(false, out, ")\n", .{});

    if (!hasReturn) return 0;

    return self.normalize(out, res, returnType);
}

fn store(self: *JAIR, out: *Writer, node: *const Node) Error!void {
    const lhs = self.data[node.value];
    const rhs = self.data[node.value + 1];

    const lhsTmp = try self.generateExpr(out, lhs);
    const rhsType = self.nodes.items(.type)[rhs];

    if (self.sizeOf(rhsType) == 0) {
        _ = try self.generateExpr(out, rhs);
        return;
    }

    const rhsTmp = try self.generateExpr(out, rhs);

    if (self.isScalar(rhsType)) {
        const generatedType = self.expressionType(rhs);

        const value = if (generatedType != rhsType)
            try self.convert(out, rhsTmp, generatedType, rhsType)
        else
            rhsTmp;

        try self.write(true, out, "store", .{});
        try self.storeTypeString(out, rhsType);
        try self.write(false, out, " %__tmp{d}, %__tmp{d}\n", .{
            value,
            lhsTmp,
        });
    }
    else {
        try self.write(true, out, "blit %__tmp{d}, %__tmp{d}, {d}\n", .{
            rhsTmp,
            lhsTmp,
            self.sizeOf(rhsType),
        });
    }
}

fn identifier(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const name = self.strings[self.data[node.value]];
    const topLevel = (self.data[node.value + 1] & 2) != 0;
    const isParam = (self.data[node.value + 1] & 1) != 0;
    const valueType = node.type;
    const lvalue = self.data[node.value + 2] == 1;

    const res = self.allocTmp();

    if (topLevel) {
        try self.write(true, out, "%__tmp{d} =l copy ${s}\n", .{
            res,
            name,
        });

        if (!lvalue and self.isScalar(valueType)) {
            const loaded = self.allocTmp();

            try self.write(true, out, "%__tmp{d} =", .{loaded});
            try self.typeString(out, true, valueType);
            try self.write(false, out, " load", .{});
            try self.loadTypeString(out, valueType);
            try self.write(false, out, " %__tmp{d}\n", .{res});

            return loaded;
        }

        return res;
    }

    const symbol =
        if (isParam) try std.fmt.allocPrint(self.allocator, "__param_{s}", .{name})
        else self.lookupLocal(name);

    if (lvalue or !self.isScalar(valueType)) {
        try self.write(true, out, "%__tmp{d} =l copy %{s}\n", .{
            res,
            symbol,
        });

        return res;
    }

    const loaded = self.allocTmp();

    try self.write(true, out, "%__tmp{d} =l copy %{s}\n", .{
        res,
        symbol,
    });

    try self.write(true, out, "%__tmp{d} =", .{loaded});
    try self.typeString(out, true, valueType);
    try self.write(false, out, " load", .{});
    try self.loadTypeString(out, valueType);
    try self.write(false, out, " %__tmp{d}\n", .{res});

    return loaded;
}

fn phi(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const cnd = try self.generateExpr(out, self.data[node.value]);

    const thenLabel = self.allocTmp();
    const otherwiseLabel = self.allocTmp();
    const finalLabel = self.allocTmp();

    const thenBlock = std.fmt.allocPrint(
        self.allocator,
        "__ternary_then{d}",
        .{thenLabel},
    ) catch return Error.AllocatorFailure;
    const otherwiseBlock = std.fmt.allocPrint(
        self.allocator,
        "__ternary_otherwise{d}",
        .{otherwiseLabel},
    ) catch return Error.AllocatorFailure;
    const finalBlock = std.fmt.allocPrint(
        self.allocator,
        "__ternary_final{d}",
        .{finalLabel},
    ) catch return Error.AllocatorFailure;

    try self.write(true, out, "jnz %__tmp{d}, @{s}, @{s}\n", .{
        cnd,
        thenBlock,
        otherwiseBlock,
    });

    try self.write(true, out, "@{s}\n", .{thenBlock});
    self.currentBlock = thenBlock;
    const thenType = self.expressionType(self.data[node.value + 1]);
    var then = try self.generateExpr(out, self.data[node.value + 1]);
    if (self.isScalar(thenType) and self.isScalar(node.type) and thenType != node.type) {
        then = try self.convert(out, then, thenType, node.type);
    }
    const thenPredecessor = self.currentBlock;
    try self.write(true, out, "jmp @{s}\n", .{finalBlock});

    try self.write(true, out, "@{s}\n", .{otherwiseBlock});
    self.currentBlock = otherwiseBlock;
    const otherwiseType = self.expressionType(self.data[node.value + 2]);
    var otherwise = try self.generateExpr(out, self.data[node.value + 2]);
    if (self.isScalar(otherwiseType) and self.isScalar(node.type) and otherwiseType != node.type) {
        otherwise = try self.convert(out, otherwise, otherwiseType, node.type);
    }
    const otherwisePredecessor = self.currentBlock;
    try self.write(true, out, "jmp @{s}\n", .{finalBlock});

    try self.write(true, out, "@{s}\n", .{finalBlock});
    self.currentBlock = finalBlock;
    self.terminated = false;

    const res = self.allocTmp();

    try self.write(true, out, "%__tmp{d} =", .{res});
    try self.typeString(out, true, node.type);

    try self.write(false, out, " phi @{s} %__tmp{d}, @{s} %__tmp{d}\n", .{
        thenPredecessor,
        then,
        otherwisePredecessor,
        otherwise,
    });

    return res;
}

fn commonComparison(self: *JAIR, out: *Writer, comptime op: []const u8, node: *const Node) Error!u32 {
    const lhsNode = self.data[node.value];
    const rhsNode = self.data[node.value + 1];

    var lhs = try self.generateExpr(out, lhsNode);
    var rhs = try self.generateExpr(out, rhsNode);

    const lt = self.nodes.items(.type)[lhsNode];
    const rt = self.nodes.items(.type)[rhsNode];
    const operandType = self.wider(lt, rt);

    lhs = try self.widenTo(out, lhs, lt, operandType);
    rhs = try self.widenTo(out, rhs, rt, operandType);

    const res = self.allocTmp();

    try self.write(true, out, "%__tmp{d} =w c{s}{s}", .{
        res,
        if (self.signed(operandType)) |s|
            if (op[0] == 'e' or op[0] == 'n') "" else if (s) "s" else "u"
        else
            "",
        op,
    });
    try self.typeString(out, false, operandType);
    try self.write(false, out, " %__tmp{d}, %__tmp{d}\n", .{ lhs, rhs });

    return res;
}

fn commonBinary(self: *JAIR, out: *Writer, comptime op: []const u8, node: *const Node) Error!u32 {
    const lhsNode = self.data[node.value];
    const rhsNode = self.data[node.value + 1];

    var lhs = try self.generateExpr(out, lhsNode);
    var rhs = try self.generateExpr(out, rhsNode);

    const lt = self.nodes.items(.type)[lhsNode];
    const rt = self.nodes.items(.type)[rhsNode];
    const isShift = node.kind == .LeftShift or node.kind == .RightShift;
    const opType = if (isShift) lt else self.wider(lt, rt);

    if (!isShift) {
        lhs = try self.widenTo(out, lhs, lt, opType);
        rhs = try self.widenTo(out, rhs, rt, opType);
    }

    const res = self.allocTmp();
    try self.write(true, out, "%__tmp{d} =", .{res});
    try self.typeString(out, true, opType);

    const unsignedPrefix = if (node.kind == .Div or node.kind == .Mod)
        (if (self.signed(opType) orelse true) "" else "u")
    else
        "";

    const actualOp = if (node.kind == .RightShift)
        (if (self.signed(opType) orelse false) "sar" else "shr")
    else
        op;

    try self.write(false, out, " {s}{s} %__tmp{d}, %__tmp{d}\n", .{
        unsignedPrefix, actualOp, lhs, rhs,
    });

    return res;
}

fn not(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const operand = try self.generateExpr(out, node.value);
    const res = self.allocTmp();

    try self.write(true, out, "%__tmp{d} =w ceqw %__tmp{d}, 0\n", .{ res, operand });
    return res;
}

fn invert(self: *JAIR, out: *Writer, node: *const Node) Error!u32 {
    const operand = try self.generateExpr(out, node.value);
    const res = self.allocTmp();

    switch (self.typeTable.get(node.type)) {
        .Word, .Long => {
            try self.write(true, out, "%__tmp{d} =", .{res});
            try self.typeString(out, true, node.type);
            try self.write(false, out, " xor %__tmp{d}, -1\n", .{operand});
        },
        .Double, .Single => {
            return Error.ShouldBeImpossible;
        },
        .Byte => {
            try self.write(true, out, "%__tmp{d} =", .{res});
            try self.typeString(out, true, node.type);
            try self.write(false, out, " xor %__tmp{d}, 255\n", .{operand});
        },
        .Half => {
            try self.write(true, out, "%__tmp{d} =", .{res});
            try self.typeString(out, true, node.type);
            try self.write(false, out, " xor %__tmp{d}, 65535\n", .{operand});
        },
        else => return common.debug.ShouldBeImpossible(undefined, @src()),
    }

    return res;
}

fn signed(self: *const JAIR, id: TypeID) ?bool {
    return switch (self.typeTable.get(id)) {
        .Byte => |b| b,
        .Half => |b| b,
        .Word => |b| b,
        .Long => |b| b,
        else => null,
    };
}

fn allocTmp(self: *JAIR) u32 {
    defer self.temp += 1;
    return self.temp;
}

fn typeString(self: *const JAIR, out: *Writer, isTmp: bool, typeID: TypeID) Error!void {
    switch (self.typeTable.get(typeID)) {
        .Word => try self.write(false, out, "w", .{}),
        .Long => try self.write(false, out, "l", .{}),
        .Double => try self.write(false, out, "d", .{}),
        .Single => try self.write(false, out, "s", .{}),
        .Half, .Byte => try self.write(false, out, "w", .{}),
        .Void => {},
        else =>
            if (isTmp) try self.write(false, out, "l", .{})
            else try self.write(false, out, ":{s}", .{
                self.strings[self.typeNames.get(typeID).?],
            }),
    }
}

fn aggregateTypeString(self: *const JAIR, out: *Writer, typeID: TypeID) Error!void {
    switch (self.typeTable.get(typeID)) {
        .Byte => try self.write(false, out, "b", .{}),
        .Half => try self.write(false, out, "h", .{}),
        else => try self.typeString(out, false, typeID),
    }
}

fn loadTypeString(self: *const JAIR, out: *Writer, typeID: TypeID) Error!void {
    switch (self.typeTable.get(typeID)) {
        .Byte => |is_signed| try self.write(false, out, "{s}", .{
            if (is_signed) "sb" else "ub",
        }),
        .Half => |is_signed| try self.write(false, out, "{s}", .{
            if (is_signed) "sh" else "uh",
        }),
        .Word => try self.write(false, out, "w", .{}),
        .Long => try self.write(false, out, "l", .{}),
        .Single => try self.write(false, out, "s", .{}),
        .Double => try self.write(false, out, "d", .{}),
        .Void => {},
        .Custom => try self.write(false, out, "l", .{}),
    }
}

fn storeTypeString(self: *const JAIR, out: *Writer, typeID: TypeID) Error!void {
    switch (self.typeTable.get(typeID)) {
        .Byte => try self.write(false, out, "b", .{}),
        .Half => try self.write(false, out, "h", .{}),
        .Word => try self.write(false, out, "w", .{}),
        .Long => try self.write(false, out, "l", .{}),
        .Single => try self.write(false, out, "s", .{}),
        .Double => try self.write(false, out, "d", .{}),
        .Void => {},
        .Custom => try self.write(false, out, "l", .{}),
    }
}

fn isScalar(self: *const JAIR, typeID: TypeID) bool {
    return switch (self.typeTable.get(typeID)) {
        .Double, .Single, .Byte, .Half, .Long, .Word, .Void => true,
        .Custom => false,
    };
}

fn allocAlignment(self: *const JAIR, typeID: TypeID) u32 {
    return switch (self.alignOf(typeID)) {
        0, 1, 2, 4, 8, 16 => |alignment| @max(4, alignment),
        else => 8,
    };
}

fn alignOf(self: *const JAIR, typeID: TypeID) u32 {
    return switch (self.typeTable.get(typeID)) {
        .Double => 8,
        .Single => 4,
        .Byte => 1,
        .Half => 2,
        .Long => 8,
        .Word => 4,
        .Void => 1,
        .Custom => |c| switch (c) {
            .Opaque => |o| o.alignment,
            .Union => |o| o.alignment,
            .Aggregate => |o| o.alignment,
        },
    };
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
        .Aggregate => |a| self.alignOf(a.Type),
    };

    const aligned = std.mem.alignForward(u32, em.offset, al);

    if (aligned > em.offset) {
        try self.write(false, out, "{s}z {d}", .{
            if (em.first) "" else ", ",
            aligned - em.offset,
        });

        em.first = false;
        em.offset = aligned;
    }

    switch (c) {
        .Aggregate => |agg| {
            const end = em.offset + self.sizeOf(agg.Type);

            for (agg.Init) |elem| {
                try self.dataItems(out, em, elem);
            }

            if (end > em.offset) {
                try self.write(false, out, "{s}z {d}", .{
                    if (em.first) "" else ", ",
                    end - em.offset,
                });

                em.first = false;
                em.offset = end;
            }

            return;
        },
        else => {},
    }

    try self.write(false, out, "{s}", .{
        if (em.first) "" else ", ",
    });

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
                try self.write(false, out, "l $__const{d}", .{ptr});
                break :blk 8;
            },
            .Cole => |str| blk: {
                try self.write(false, out, "l $__str{d}, w {d}, z 4", .{
                    ptr,
                    self.strings[str].len,
                });
                break :blk 16;
            },
        },
        .Aggregate => unreachable,
    };
}

fn storeTo(self: *JAIR, out: *Writer, dst: u32, srcNode: Ptr, dstType: ?TypeID) Error!void {
    const srcType = self.nodes.items(.type)[srcNode];
    var src = try self.generateExpr(out, srcNode);
    if (self.sizeOf(srcType) == 0) return;

    const ty = dstType orelse srcType;

    const isUnionStorage = switch (self.typeTable.get(ty)) {
        .Custom => |custom| switch (custom) {
            .Union => true,
            .Opaque, .Aggregate => false,
        },
        else => false,
    };

    if (self.isScalar(srcType) and (self.isScalar(ty) or isUnionStorage)) {
        const storeType = if (self.isScalar(ty)) ty else srcType;
        const same = self.sizeOf(srcType) == self.sizeOf(storeType) and
            self.signed(srcType) == self.signed(storeType);
        if (!same) src = try self.convert(out, src, srcType, storeType);
        try self.write(true, out, "store", .{});
        try self.storeTypeString(out, storeType);
        try self.write(false, out, " %__tmp{d}, %__tmp{d}\n", .{ src, dst });
    } else {
        try self.write(true, out, "blit %__tmp{d}, %__tmp{d}, {d}\n", .{
            src, dst, @min(self.sizeOf(srcType), self.sizeOf(ty)),
        });
    }
}

fn offsetPtr(self: *JAIR, out: *Writer, base: u32, offset: u32) Error!u32 {
    if (offset == 0) return base;

    const res = self.allocTmp();
    try self.write(true, out, "%__tmp{d} =l add %__tmp{d}, {d}\n", .{ res, base, offset });
    return res;
}

fn zeroFill(self: *JAIR, out: *Writer, base: u32, size: u32) Error!void {
    var off: u32 = 0;
    while (off < size) {
        const rem = size - off;
        const chunk: u32 = if (rem >= 8) 8 else if (rem >= 4) 4 else if (rem >= 2) 2 else 1;
        const suffix: []const u8 = switch (chunk) {
            8 => "l",
            4 => "w",
            2 => "h",
            else => "b",
        };

        const ptr = try self.offsetPtr(out, base, off);
        try self.write(true, out, "store{s} 0, %__tmp{d}\n", .{ suffix, ptr });
        off += chunk;
    }
}

fn normalize(self: *JAIR, out: *Writer, tmp: u32, typeID: TypeID) Error!u32 {
    const op: []const u8 = switch (self.typeTable.get(typeID)) {
        .Byte => |s| if (s) "extsb" else "extub",
        .Half => |s| if (s) "extsh" else "extuh",
        else => return tmp,
    };
    const res = self.allocTmp();
    try self.write(true, out, "%__tmp{d} =w {s} %__tmp{d}\n", .{ res, op, tmp });
    return res;
}

fn convert(self: *JAIR, out: *Writer, src: u32, from: TypeID, to: TypeID) Error!u32 {
    const f = self.typeTable.get(from);
    const t = self.typeTable.get(to);
    const fromFloat = f == .Single or f == .Double;
    const toFloat = t == .Single or t == .Double;

    if (fromFloat and toFloat) {
        if (std.meta.activeTag(f) == std.meta.activeTag(t)) return src;
        const res = self.allocTmp();
        try self.write(true, out, "%__tmp{d} ={s} {s} %__tmp{d}\n", .{
            res,
            if (t == .Double) "d" else "s",
            if (t == .Double) "exts" else "truncd",
            src,
        });
        return res;
    }

    if (fromFloat) {
        const res = self.allocTmp();
        try self.write(true, out, "%__tmp{d} =", .{res});
        try self.typeString(out, true, to);
        try self.write(false, out, " {s}to{s}i %__tmp{d}\n", .{
            if (f == .Single) "s" else "d",
            if (self.signed(to) orelse false) "s" else "u",
            src,
        });
        return self.normalize(out, res, to);
    }

    const cur = try self.normalize(out, src, from);
    const fromSigned = self.signed(from) orelse false;

    if (toFloat) {
        const res = self.allocTmp();
        try self.write(true, out, "%__tmp{d} ={s} {s}{s}tof %__tmp{d}\n", .{
            res,
            if (t == .Double) "d" else "s",
            if (fromSigned) "s" else "u",
            if (f == .Long) "l" else "w",
            cur,
        });
        return res;
    }

    if (t == .Long and f != .Long) {
        const res = self.allocTmp();
        try self.write(true, out, "%__tmp{d} =l ext{s}w %__tmp{d}\n", .{
            res, if (fromSigned) "s" else "u", cur,
        });
        return res;
    }
    if (t != .Long and f == .Long) {
        const res = self.allocTmp();
        try self.write(true, out, "%__tmp{d} =w copy %__tmp{d}\n", .{ res, cur });
        return self.normalize(out, res, to);
    }
    return self.normalize(out, cur, to);
}

fn isFloat(self: *const JAIR, id: TypeID) bool {
    return switch (self.typeTable.get(id)) {
        .Single, .Double => true,
        else => false,
    };
}

fn wider(self: *const JAIR, a: TypeID, b: TypeID) TypeID {
    const aType = self.typeTable.get(a);
    const bType = self.typeTable.get(b);

    if (aType == .Double) return a;
    if (bType == .Double) return b;
    if (aType == .Single) return a;
    if (bType == .Single) return b;

    if (bType == .Long and aType != .Long) return b;
    return a;
}

fn widenTo(self: *JAIR, out: *Writer, tmp: u32, from: TypeID, to: TypeID) Error!u32 {
    if (self.isFloat(to)) {
        if (!self.isScalar(from) or self.sizeOf(from) == 0) return tmp;
        return self.convert(out, tmp, from, to);
    }

    if (self.typeTable.get(to) != .Long) return tmp;
    if (self.typeTable.get(from) == .Long) return tmp;
    if (self.isFloat(from) or !self.isScalar(from)) return tmp;

    const cur = try self.normalize(out, tmp, from);
    const res = self.allocTmp();
    try self.write(true, out, "%__tmp{d} =l ext{s}w %__tmp{d}\n", .{
        res,
        if (self.signed(from) orelse false) "s" else "u",
        cur,
    });
    return res;
}

fn expressionType(self: *const JAIR, ptr: Ptr) TypeID {
    const node = self.nodes.get(ptr);

    return switch (node.kind) {
        .Add, .Sub, .Div, .Mod, .Mul, .And, .Or, .Xor => self.wider(
            self.nodes.items(.type)[self.data[node.value]],
            self.nodes.items(.type)[self.data[node.value + 1]],
        ),

        .LeftShift, .RightShift =>
            self.nodes.items(.type)[self.data[node.value]],

        .StatementExpr => self.expressionType(self.data[node.value]),

        else => node.type,
    };
}

fn lookupLocal(self: *const JAIR, name: []const u8) []const u8 {
    var i = self.localStack.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, self.localStack.items[i].name, name))
            return self.localStack.items[i].unique;
    }
    return name;
}

fn write(
    self: *const JAIR,
    indent: bool,
    out: *Writer,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    if (indent) {
        for (0..self.indent) |_| {
            _ = out.write("    ") catch return Error.IOError;
        }
    }

    out.print(fmt, args) catch return Error.IOError;
}

