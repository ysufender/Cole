const std = @import("std");
const common = @import("../../../core/common.zig");
const collections = @import("../../../util/collections.zig");
const defines = @import("../../../core/defines.zig");

const Comptime = @import("../../../typechecker/comptime.zig");
const Allocator = std.mem.Allocator;
const Error = common.CompilerError;
const TypeID = @import("../../../typechecker/type.zig").TypeID;
const TypeInfo = @import("../../../typechecker/type.zig").TypeInfo;
const Typechecker = @import("../../../typechecker/typechecker.zig");

const JIR = @import("../../backend.zig").C.JIR;
const JAIR = @import("../jair.zig");

pub const TypeTable = std.MultiArrayList(JAIR.Type);
pub const Constants = std.MultiArrayList(JAIR.Constant);

const FieldLayout = struct {
    offset: u32,
    type: TypeID
};

const FlagMap = std.bit_set.Static(8);

const Flags = enum(u8) {
    LValue = 0,

    pub fn flag(flagToGet: Flags) u8 {
        return @intFromEnum(flagToGet);
    }
};

const Builder = @This();

jir: JIR.Base,
typeNameMap: collections.HashMap(TypeID, defines.StringPtr),
nodes: JAIR.Node.List,
typeTable: TypeTable,
typeMap: collections.HashMap(TypeID, TypeID),
keyNodes: std.ArrayList(JAIR.Ptr),
strings: std.ArrayList([]const u8),
data: std.ArrayList(u32),
allocator: Allocator,
typechecker: *Typechecker,
constants: Constants,
constMap: collections.HashMap(JIR.Constant.Ptr, JAIR.Constant.Ptr),
flags: FlagMap,
symbolNameMap: collections.HashMap(defines.StringPtr, defines.StringPtr),

pub fn fromJIR(jir: JIR.Base, allocator: Allocator, typechecker: *Typechecker) Error!Builder {
    var typeMap = collections.HashMap(TypeID, TypeID).empty;
    typeMap.ensureTotalCapacity(allocator, @intCast(jir.types.len)) catch return Error.AllocatorFailure;

    var taggedUnionCount: usize = 0;
    for (0..jir.types.len) |id| {
        switch (jir.types.get(@intCast(id))) {
            .Union => |uni| if (uni.isTagged) {
                taggedUnionCount += 1;
            },
            else => {},
        }
    }

    var strings = std.ArrayList([]const u8).initCapacity(
        allocator,
        jir.strings.len + taggedUnionCount,
    ) catch return Error.AllocatorFailure;
    strings.appendSliceAssumeCapacity(jir.strings);

    var constMap = collections.HashMap(JIR.Constant.Ptr, JAIR.Constant.Ptr).empty;
    constMap.ensureTotalCapacity(allocator, @intCast(jir.constants.len)) catch return Error.AllocatorFailure;

    var typeNameMap = collections.HashMap(TypeID, defines.StringPtr).empty;
    typeNameMap.ensureTotalCapacity(allocator, @intCast(jir.types.len)) catch return Error.AllocatorFailure;

    var symbolMap = collections.HashMap(defines.StringPtr, defines.StringPtr).empty;
    symbolMap.ensureTotalCapacity(allocator, @intCast(jir.strings.len)) catch return Error.AllocatorFailure;

    return .{
        .jir = jir,
        .nodes = try JAIR.Node.List.init(allocator, jir.nodes.len),
        .keyNodes = std.ArrayList(JAIR.Ptr).initCapacity(allocator, jir.keyNodes.len) catch return Error.AllocatorFailure,
        .data = std.ArrayList(u32).initCapacity(allocator, jir.data.len) catch return Error.AllocatorFailure,
        .typeTable = TypeTable.initCapacity(
            allocator,
            jir.types.len + taggedUnionCount,
        ) catch return Error.AllocatorFailure,
        .constants = Constants.initCapacity(allocator, jir.constants.len) catch return Error.AllocatorFailure,
        .constMap = constMap,
        .flags = FlagMap.empty,
        .typeMap = typeMap,
        .typeNameMap = typeNameMap,
        .strings = strings,
        .allocator = allocator,
        .typechecker = typechecker,
        .symbolNameMap = symbolMap,
    };
}

pub fn build(self: *Builder) Error!JAIR {
    for (0..self.jir.types.len) |id| {
        _ = try self.convertType(@intCast(id));
    }

    for (0..self.jir.constants.len) |constPtr| {
        _ = try self.convertConstant(@intCast(constPtr));
    }

    for (self.jir.keyNodes) |nodePtr| {
        const n = self.jir.nodes.get(nodePtr);
        switch (n.type) {
            .FunctionDef => {},
            .VariableDef => if (self.jir.data[n.value] != 1) continue,
            else => continue,
        }
        self.keyNodes.append(self.allocator, try self.createJAIR(nodePtr))
            catch return Error.AllocatorFailure;
    }

    var typeNames = Typechecker.TypeNameMap.empty;
    typeNames.ensureTotalCapacity(
        self.allocator,
        @intCast(self.typeTable.len),
    ) catch return Error.AllocatorFailure;

    for (0..self.jir.types.len) |id| {
        const sourceType: TypeID = @intCast(id);
        const newType = self.typeMap.get(sourceType) orelse
            return Error.ShouldBeImpossible;

        switch (self.typeTable.get(newType)) {
            .Custom => {
                const res = typeNames.getOrPutAssumeCapacity(newType);

                if (!res.found_existing) {
                    res.value_ptr.* = try self.typeName(sourceType);
                }
            },
            else => {},
        }
    }

    for (0..self.typeTable.len) |id| {
        const name: defines.StringPtr = switch (self.typeTable.get(@intCast(id))) {
            .Custom => |custom| switch (custom) {
                .Opaque => |v| v.name,
                .Aggregate => |v| v.name,
                .Union => |v| v.name,
            },
            else => continue,
        };

        const res = typeNames.getOrPutAssumeCapacity(@intCast(id));
        if (!res.found_existing) {
            res.value_ptr.* = name;
        }
    }

    return .{
        .typeTable = self.typeTable.toOwnedSlice(),
        .data = self.data.toOwnedSlice(self.allocator) catch return Error.AllocatorFailure,
        .strings = self.strings.toOwnedSlice(self.allocator) catch return Error.AllocatorFailure,
        .nodes = self.nodes.toOwnedSlice(),
        .keyNodes = self.keyNodes.toOwnedSlice(self.allocator) catch return Error.AllocatorFailure,
        .constants = self.constants.toOwnedSlice(),
        .typeNames = typeNames,
    };
}

fn createJAIR(self: *Builder, nodePtr: JAIR.Ptr) Error!JAIR.Ptr {
    const node = self.jir.nodes.get(nodePtr);
    return switch (node.type) {
        .FunctionDef => self.functionDef(nodePtr),
        .Scope => self.scope(nodePtr),
        .Return => self.@"return"(node.value),
        .Literal => self.literal(node.value),
        .Label => self.label(node.value),
        .Negation => try self.negation(node.value),
        .Not => try self.not(node.value),
        .Invert => try self.invert(node.value),
        .Jump => try self.jump(node.value),
        .JumpIf => try self.cjump(node.value),
        .And, .BitwiseAnd => try self.commonBinary(.And, node.value),
        .Or, .BitwiseOr => try self.commonBinary(.Or, node.value),
        .Code => try self.code(node.value),
        .Add => try self.commonBinary(.Add, node.value),
        .Equal => try self.commonBinary(.Equal, node.value),
        .NotEqual => try self.commonBinary(.NotEqual, node.value),
        .Lesser => try self.commonBinary(.Lesser, node.value),
        .LesserEqual => try self.commonBinary(.LesserEqual, node.value),
        .Greater => try self.commonBinary(.Greater, node.value),
        .GreaterEqual => try self.commonBinary(.GreaterEqual, node.value),
        .Div => try self.commonBinary(.Div, node.value),
        .Mod => try self.commonBinary(.Mod, node.value),
        .LeftShift => try self.commonBinary(.LeftShift, node.value),
        .RightShift => try self.commonBinary(.RightShift, node.value),
        .Mul => try self.commonBinary(.Mul, node.value),
        .Sub => try self.commonBinary(.Sub, node.value),
        .Xor => try self.commonBinary(.Xor, node.value),
        .Discard => try self.createJAIR(node.value),
        .Ternary => try self.phi(node.value),
        .Identifier => try self.identifier(node.value),
        .Assignment => try self.assignment(node.value),
        .Call => try self.call(node.value),
        .Dereference => try self.dereference(node.value),
        .Reference => try self.reference(node.value),
        .Dot => try self.dot(node.value),
        .StatementExpr => try self.stmtExpr(node.value),
        .Construction => try self.construct(node.value),
        .VariableDef => try self.variableDef(nodePtr),

        .Exit, .TypeDef => res: {
            const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
            self.nodes.set(res, .{
                .type = 0,
                .kind = .Exit,
                .value = 0,
            });
            break :res res;
        },

        .Grouping =>
            if (self.jir.data[node.value] == 0) res: {
                const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
                self.nodes.set(res, .{
                    .type = 0,
                    .kind = .Exit,
                    .value = 0,
                });
                break :res res;
            } else self.createJAIR(self.jir.data[node.value + 1]),
    };
}

fn variableDef(self: *Builder, nodePtr: JIR.Ptr) Error!JAIR.Ptr {
    const value = self.jir.nodes.get(nodePtr).value;
    const typeID = try self.convertType(self.jir.data[value + 1]);
    const isUndef = self.jir.data[value + 3] == 1;
    const init = if (isUndef) 0 else try self.createJAIR(self.jir.data[value + 4]);

    const topLevel = self.jir.data[value] == 1;

    const name = if (topLevel)
        try self.mangleSymbol(self.jir.data[value + 2])
    else
        self.jir.data[value + 2];

    const start: u32 = @intCast(self.data.items.len);
    self.data.appendSlice(self.allocator, &.{
        self.jir.data[value],
        typeID,
        name,
        @intFromBool(!isUndef),
        @intFromBool(self.jir.hasMetadata(nodePtr, "@extern")),
        init,
    }) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{ .type = typeID, .kind = .VariableDef, .value = start });
    return res;
}

fn construct(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const typeID = try self.convertType(self.jir.data[value]);
    const argsLen = self.jir.data[value + 1];

    const start: u32 = @intCast(self.data.items.len);
    _ = self.data.addManyAsSlice(self.allocator, argsLen + 1) catch return Error.AllocatorFailure;
    self.data.items[start] = argsLen;
    for (0..argsLen) |idx| {
        const res = try self.createJAIR(self.jir.data[value + 2 + idx]);
        self.data.items[start + 1 + idx] = res;
    }

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = typeID,
        .kind = .Construct,
        .value = start,
    });
    return res;
}

fn stmtExpr(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const final = self.jir.data[value];
    const stmtsLen = self.jir.data[value + 1];

    const start: u32 = @intCast(self.data.items.len);
    _ = self.data.addManyAsSlice(self.allocator, stmtsLen + 2) catch return Error.AllocatorFailure;
    const finalExpr = try self.createJAIR(final);
    self.data.items[start] = finalExpr;
    self.data.items[start + 1] = stmtsLen;
    for (0..stmtsLen) |idx| {
        const res = try self.createJAIR(self.jir.data[value + 2 + idx]);
        self.data.items[start + 2 + idx] = res;
    }

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = self.nodes.items(.type)[self.data.items[start]],
        .kind = .StatementExpr,
        .value = start,
    });
    return res;
}

fn dot(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const objType = self.jir.data[value];
    const fieldName = self.jir.data[value + 2];
    const wantAddress = self.getFlag(.LValue);

    var recvType = objType;
    var derefReceiver = false;
    switch (self.jir.types.get(objType)) {
        .Pointer => |ptr| if (ptr.size != .Slice) {
            recvType = ptr.child;
            derefReceiver = true;
        },
        else => {},
    }

    const obj = blk: {
        const prev = self.setFlag(.LValue, !derefReceiver);
        defer _ = self.setFlag(.LValue, prev);
        break :blk try self.createJAIR(self.jir.data[value + 1]);
    };

    const field: FieldLayout = switch (self.jir.types.get(recvType)) {
        .Array => blk: {
            const isData = std.mem.eql(
                u8,
                self.jir.strings[fieldName],
                "data",
            );

            if (!isData) return Error.ShouldBeImpossible;

            break :blk .{
                .offset = 0,
                .type = comptime Comptime.Folder.Builtin.Type("usize"),
            };
        },
        .Pointer => |ptr| blk: {
            if (ptr.size != .Slice) {
                common.log.err("Field access on non-slice pointer child", .{});
                return Error.ShouldBeImpossible;
            }
            const isLen = std.mem.eql(u8, self.jir.strings[fieldName], "len");
            break :blk FieldLayout{
                .offset = if (isLen) 8 else 0,
                .type = if (isLen)
                    comptime Comptime.Folder.Builtin.Type("u32")
                else
                    comptime Comptime.Folder.Builtin.Type("usize"),
            };
        },
        .Struct => |str| try self.fieldLayout(str.fields, fieldName, true),
        .Union => |uni| blk: {
            if (!uni.isTagged) {
                break :blk try self.fieldLayout(uni.fields, fieldName, false);
            }

            if (uni.fields.len == 0) return Error.ShouldBeImpossible;

            const tag = uni.fields[0];
            if (std.mem.eql(
                u8,
                self.jir.strings[tag.name],
                self.jir.strings[fieldName],
            )) {
                break :blk .{
                    .offset = 0,
                    .type = tag.valueType,
                };
            }

            const payloadAlignment = try self.typechecker.alignOf(recvType);
            const payloadOffset = std.mem.alignForward(
                u32,
                try self.byteSize(tag.valueType),
                payloadAlignment,
            );
            const payload = try self.fieldLayout(uni.fields[1..], fieldName, false);

            break :blk .{
                .offset = payloadOffset,
                .type = payload.type,
            };
        },
        else => return common.debug.ShouldBeImpossible(undefined, @src()),
    };

    const addr = try self.offsetPtr(obj, field.offset);
    const fieldType = try self.convertType(field.type);

    const isArrayData = switch (self.jir.types.get(recvType)) {
        .Array => std.mem.eql(u8, self.jir.strings[fieldName], "data"),
        else => false,
    };

    const asAddress = isArrayData or
        wantAddress or
        self.typeTable.get(fieldType) == .Custom or
        (try self.byteSize(field.type)) == 0;

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, @intFromBool(asAddress)) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, addr) catch return Error.AllocatorFailure;

    const res: u32 = @intCast(self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure);
    self.nodes.set(res, .{ .type = fieldType, .kind = .Load, .value = start });
    return res;
}

fn reference(self: *Builder, ptr: JIR.Ptr) Error!JAIR.Ptr {
    const previous = self.setFlag(.LValue, true);
    defer _ = self.setFlag(.LValue, previous);

    const operand = try self.createJAIR(ptr);

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = try self.convertType(comptime Comptime.Folder.Builtin.Type("usize")),
        .kind = .Reference,
        .value = operand,
    });
    return res;
}

fn dereference(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const lvalue = @intFromBool(self.getFlag(.LValue));

    const expr = expr: {
        const prev = self.setFlag(.LValue, false);
        defer _ = self.setFlag(.LValue, prev);
        break :expr try self.createJAIR(self.jir.data[value]);
    };

    const typeID = try self.convertType(self.jir.types.get(self.jir.data[value + 1]).Pointer.child);

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, lvalue) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, expr) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = typeID,
        .kind = .Load,
        .value = start,
    });
    return res;
}

fn call(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const func = self.jir.data[value + 2];
    const len = self.jir.data[value + 3];

    const start: u32 = @intCast(self.data.items.len);
    _ = self.data.addManyAsSlice(self.allocator, len + 3) catch return Error.AllocatorFailure;
    self.data.items[start] = try self.convertType(self.jir.data[value]);
    const funcExpr = try self.createJAIR(func);
    self.data.items[start + 1] = funcExpr;
    self.data.items[start + 2] = len;

    for (0..len) |idx| {
        const arg = try self.createJAIR(self.jir.data[value + 4 + idx]);
        self.data.items[start + 3 + idx] = arg;
    }

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = try self.convertType(self.jir.data[value]),
        .kind = .Call,
        .value = start,
    });
    return res;
}

fn assignment(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const lhs = lhs: {
        const prev = self.setFlag(.LValue, true);
        defer _ = self.setFlag(.LValue, prev);
        break :lhs try self.createJAIR(self.jir.data[value]);
    };

    const rhs = try self.createJAIR(self.jir.data[value + 1]);

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, lhs) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, rhs) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = self.nodes.items(.type)[lhs],
        .kind = .Store,
        .value = start,
    });
    return res;
}

fn identifier(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const valueType = try self.convertType(self.jir.data[value + 2]);

    const rawName = self.jir.data[value];
    const topLevel = self.jir.data[value + 1];

    const name = if ((topLevel & 2) != 0)
        try self.mangleSymbol(rawName)
    else
        rawName;

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, name) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, topLevel) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intFromBool(self.getFlag(.LValue))) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = valueType,
        .kind = .Identifier,
        .value = start,
    });
    return res;
}

fn phi(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const cnd = try self.createJAIR(self.jir.data[value]);
    const then = try self.createJAIR(self.jir.data[value + 1]);
    const otherwise = try self.createJAIR(self.jir.data[value + 2]);

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, cnd) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, then) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, otherwise) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = self.nodes.get(then).type,
        .kind = .Phi,
        .value = start,
    });
    return res;
}

fn isComparison(comptime kind: anytype) bool {
    return switch (kind) {
        .Equal, .NotEqual, .Lesser, .LesserEqual, .Greater, .GreaterEqual => true,
        else => false,
    };
}

fn commonBinary(self: *Builder, comptime kind: @EnumLiteral(), value: defines.Offset) Error!JAIR.Ptr {
    const lhs = try self.createJAIR(self.jir.data[value]);
    const rhs = try self.createJAIR(self.jir.data[value + 1]);

    const resultType = if (isComparison(kind))
        try self.convertType(comptime Comptime.Folder.Builtin.Type("bool"))
    else
        self.nodes.get(lhs).type;

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, lhs) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, rhs) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = resultType,
        .kind = kind,
        .value = start,
    });
    return res;
}

fn code(self: *Builder, value: defines.StringPtr) Error!JAIR.Ptr {
    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = 0,
        .kind = .Code,
        .value = value,
    });
    return res;
}

fn cjump(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const lbl = self.jir.data[value];
    const cnd = try self.createJAIR(self.jir.data[value + 1]);

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, lbl) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, cnd) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = 0,
        .kind = .JumpIf,
        .value = start,
    });
    return res;
}

fn jump(self: *Builder, value: defines.StringPtr) Error!JAIR.Ptr {
    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = 0,
        .kind = .Jump,
        .value = value,
    });
    return res;
}

fn not(self: *Builder, value: JIR.Ptr) Error!JAIR.Ptr {
    const rhs = try self.createJAIR(value);

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = self.nodes.items(.type)[rhs],
        .kind = .Not,
        .value = rhs,
    });
    return res;
}

fn invert(self: *Builder, value: JIR.Ptr) Error!JAIR.Ptr {
    const rhs = try self.createJAIR(value);

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = self.nodes.items(.type)[rhs],
        .kind = .Invert,
        .value = rhs,
    });
    return res;
}

fn negation(self: *Builder, value: JIR.Ptr) Error!JAIR.Ptr {
    const rhs = try self.createJAIR(value);

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = self.nodes.items(.type)[rhs],
        .kind = .Negation,
        .value = rhs,
    });
    return res;
}

fn label(self: *Builder, value: defines.StringPtr) Error!JAIR.Ptr {
    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = 0,
        .kind = .Label,
        .value = value,
    });
    return res;
}

fn literal(self: *Builder, value: JIR.Constant.Ptr) Error!JAIR.Ptr {
    const constant = try self.convertConstant(value);

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = self.constantType(constant),
        .kind = .Literal,
        .value = constant,
    });
    return res;
}

fn @"return"(self: *Builder, value: defines.Offset) Error!JAIR.Ptr {
    const withRet = self.jir.data[value];
    const expr = if (withRet == 1) try self.createJAIR(self.jir.data[value + 1]) else 0;

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, withRet) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, expr) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = 0,
        .kind = .Return,
        .value = start,
    });
    return res;
}

fn scope(self: *Builder, nodePtr: defines.Offset) Error!JAIR.Ptr {
    const scopeVal = self.jir.nodes.get(nodePtr).value;
    const name = self.jir.data[scopeVal];
    const len = self.jir.data[scopeVal + 1];

    const start: u32 = @intCast(self.data.items.len);
    _ = self.data.addManyAsSlice(self.allocator, len + 2)
        catch return Error.AllocatorFailure;

    for (0..len) |idx| {
        const child = try self.createJAIR(self.jir.data[scopeVal + 2 + idx]);
        self.data.items[start + 2 + idx] = child;
    }

    self.data.items[start] = name;
    self.data.items[start + 1] = len;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = 0,
        .kind = .Scope,
        .value = start,
    });
    return res;
}

fn functionDef(self: *Builder, fptr: JIR.Ptr) Error!JAIR.Ptr {
    const function = self.jir.functions.get(self.jir.data[self.jir.nodes.get(fptr).value + 1]);
    const signature = self.jir.types.get(function.signature).Function;

    const functionName = try self.mangleSymbol(function.name);

    const body = try self.createJAIR(function.body);

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, if (self.jir.hasMetadata(fptr, "@extern")) 1 else 0) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, if (self.jir.hasMetadata(fptr, "@export")) 1 else 0) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, functionName) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, try self.convertType(signature.returnType)) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intCast(signature.argTypes.len)) catch return Error.AllocatorFailure;

    for (signature.argTypes, function.args) |argType, argName| {
        self.data.append(self.allocator, try self.convertType(argType)) catch return Error.AllocatorFailure;
        self.data.append(self.allocator, argName) catch return Error.AllocatorFailure;
    }

    self.data.append(self.allocator, body) catch return Error.AllocatorFailure;

    const nodePtr = try self.nodes.addOne(self.allocator);
    self.nodes.set(nodePtr, .{
        .type = self.typeMap.get(function.signature).?,
        .kind = .FunctionDef,
        .value = start,
    });
    return nodePtr;
}

fn typeName(self: *Builder, id: TypeID) Error!defines.StringPtr {
    if (self.typeNameMap.get(id)) |name| {
        return name;
    }

    const typeInfo = self.jir.types.get(id);
    const newName = switch (typeInfo) {
        .Noreturn, .Any, .Type, .EnumLiteral, .ComptimeInt, .ComptimeFloat => "",
        .Void => |mut| if (mut) "mut_void" else "void",
        .Bool => |mut| if (mut) "mut_bool" else "bool",
        .CChar => |mut| if (mut) "mut_c_char" else "c_char",
        .CUChar => |mut| if (mut) "mut_c_uchar" else "c_uchar",
        .CDouble => |mut| if (mut) "mut_c_double" else "c_double",
        .CInt => |mut| if (mut) "mut_c_int" else "c_int",
        .CLong => |mut| if (mut) "mut_c_long" else "c_long",
        .CShort => |mut| if (mut) "mut_c_short" else "c_short",
        .CSize => |mut| if (mut) "mut_c_size" else "c_size",
        .CUInt => |mut| if (mut) "mut_c_uint" else "c_uint",
        .CULong => |mut| if (mut) "mut_c_ulong" else "c_ulong",
        .CUShort => |mut| if (mut) "mut_c_ushort" else "c_ushort",
        .Float => |mut| if (mut) "mut_float" else "float",
        .Integer => |int| switch (int.size) {
            64 => if (int.signed and int.mutable) "mut_isize" else if (int.signed) "isize" else if (int.mutable) "mut_usize" else "usize",
            32 => if (int.signed and int.mutable) "mut_i32" else if (int.signed) "i32" else if (int.mutable) "mut_u32" else "u32",
            16 => if (int.signed and int.mutable) "mut_i16" else if (int.signed) "i16" else if (int.mutable) "mut_u16" else "u16",
            8 => if (int.signed and int.mutable) "mut_i8" else if (int.signed) "i8" else if (int.mutable) "mut_u8" else "u8",
            else => return common.debug.ShouldBeImpossible(undefined, @src()),
        },
        .Enum => |enm| if (enm.mutable)
            std.fmt.allocPrint(self.allocator, "mut_{s}", .{self.strings.items[enm.name]}) catch return Error.AllocatorFailure
        else
            self.strings.items[enm.name],
        .Union => |uni| if (uni.mutable)
            std.fmt.allocPrint(self.allocator, "mut_{s}", .{self.strings.items[uni.name]}) catch return Error.AllocatorFailure
        else
            self.strings.items[uni.name],
        .Struct => |str| if (str.mutable)
            std.fmt.allocPrint(self.allocator, "mut_{s}", .{self.strings.items[str.name]}) catch return Error.AllocatorFailure
        else
            self.strings.items[str.name],
        .Array => |arr| std.fmt.allocPrint(self.allocator, "{s}Array_{d}_{s}", .{
            if (arr.mutable) "mut_" else "",
            arr.len,
            self.strings.items[try self.typeName(arr.child)],
        }) catch return Error.AllocatorFailure,
        .Function => std.fmt.allocPrint(
            self.allocator,
            "__cole_fn_type_{d}",
            .{id},
        ) catch return Error.AllocatorFailure,
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => std.fmt.allocPrint(self.allocator, "{s}Slice_{s}", .{
                if (ptr.mutable) "mut_" else "",
                self.strings.items[try self.typeName(ptr.child)],
            }) catch return Error.AllocatorFailure,
            else => |size| std.fmt.allocPrint(self.allocator, "{s}{s}ptr_{s}", .{
                if (ptr.mutable) "mut_" else "",
                if (size == .C) "c_" else "",
                self.strings.items[try self.typeName(ptr.child)],
            }) catch return Error.AllocatorFailure,
        },
    };

    // self.strings.items[name] = newName;
    // self.renamedStringMap.set(name);
    const owned = std.fmt.allocPrint(self.allocator, "{s}", .{newName}) catch return Error.AllocatorFailure;
    _ = std.mem.replace(u8, owned, "::", "__", owned);

    const newString: u32 = @intCast(self.strings.items.len);
    self.strings.append(self.allocator, owned) catch return Error.AllocatorFailure;
    self.typeNameMap.putAssumeCapacityNoClobber(id, newString);
    return newString;
}

fn constantType(self: *Builder, constant: JAIR.Constant.Ptr) TypeID {
    return switch (self.constants.get(constant)) {
        .Byte => |v| if (v.@"1") self.typeMap.get(comptime Comptime.Folder.Builtin.Type("i8")).? else self.typeMap.get(comptime Comptime.Folder.Builtin.Type("u8")).?,
        .Double => self.typeMap.get(comptime Comptime.Folder.Builtin.Type("c_double")).?,
        .Single => self.typeMap.get(comptime Comptime.Folder.Builtin.Type("float")).?,
        .Function => self.typeMap.get(comptime Comptime.Folder.Builtin.Type("usize")).?,
        .Word => |v| if (v.@"1") self.typeMap.get(comptime Comptime.Folder.Builtin.Type("i32")).? else self.typeMap.get(comptime Comptime.Folder.Builtin.Type("u32")).?,
        .Half => |v| if (v.@"1") self.typeMap.get(comptime Comptime.Folder.Builtin.Type("c_short")).? else self.typeMap.get(comptime Comptime.Folder.Builtin.Type("c_ushort")).?,
        .Long => |v| if (v.@"1") self.typeMap.get(comptime Comptime.Folder.Builtin.Type("isize")).? else self.typeMap.get(comptime Comptime.Folder.Builtin.Type("usize")).?,
        .String => |s| switch (s) {
            .C => self.typeMap.get(comptime Comptime.Folder.Builtin.Type("usize")).?,
            .Cole => self.typeMap.get(comptime Comptime.Folder.Builtin.Type("[]u8")).?,
        },
        .Aggregate => |agg| agg.Type,
    };
}

fn convertConstant(self: *Builder, constant: JIR.Constant.Ptr) Error!JAIR.Constant.Ptr {
    if (self.constMap.get(constant)) |c| {
        return c;
    }

    const converted: JAIR.Constant = switch (self.jir.constants.get(constant)) {
        .Integer => |int| switch (int) {
            .i32 => |integer| .{ .Word = .{ @bitCast(integer), true } },
            .u32 => |integer| .{ .Word = .{ @bitCast(integer), false } },
            .c_int => |integer| .{ .Word = .{ @bitCast(integer), true } },
            .c_uint => |integer| .{ .Word = .{ @bitCast(integer), false } },
            .i8 => |integer| .{ .Byte = .{ @bitCast(integer), true } },
            .u8 => |integer| .{ .Byte = .{ @bitCast(integer), false } },
            .c_char => |integer| .{ .Byte = .{ @bitCast(integer), true } },
            .c_uchar => |integer| .{ .Byte = .{ @bitCast(integer), false } },
            .c_long => |integer|
                if (comptime self.typechecker.context.settings.buildInfo.platform == .Windows) .{ .Word = .{ @bitCast(integer), true } }
                else .{ .Long = .{ @bitCast(integer), true } },

            .c_ulong => |integer|
                if (comptime self.typechecker.context.settings.buildInfo.platform == .Windows) .{ .Word = .{ @bitCast(integer), false } }
                else .{ .Long = .{ @bitCast(integer), false } },
            .c_size => |integer| .{ .Long = .{ @bitCast(integer), true } },
            .c_short => |integer| .{ .Half = .{ @bitCast(integer), true } },
            .c_ushort => |integer| .{ .Half = .{ @bitCast(integer), false } },
        },
        .Float => |f| switch (f) {
            .f32 => |v| .{ .Single = v },
            .f64 => |v| .{ .Double = v },
        },
        .String => |str| switch (str.type) {
            .C => .{ .String = .{ .C = str.str } },
            .Cole => .{ .String = .{ .Cole = str.str } },
        },
        .Function => |func| .{
            .Function = try self.mangleSymbol(func),
        },
        .Array => |arr| arr: {
            const init = self.allocator.alloc(JAIR.Constant.Ptr, arr.data.len())
                catch return Error.AllocatorFailure;
            for (init, 0..) |*elem, i| {
                elem.* = try self.convertConstant(arr.data.at(@intCast(i)));
            }
            break :arr .{
                .Aggregate = .{
                    .Type = try self.convertType(arr.type),
                    .Init = init,
                },
            };
        },
        .Aggregate => |aggregate| aggregate_value: {
            const convertedType = try self.convertType(aggregate.type);

            switch (self.jir.types.get(aggregate.type)) {
                .Union => |unionInfo| {
                    if (unionInfo.isTagged) {
                        if (aggregate.data.len() != 2) {
                            return Error.ShouldBeImpossible;
                        }

                        const tag = try self.convertConstant(
                            aggregate.data.at(0),
                        );

                        const payload = try self.convertConstant(
                            aggregate.data.at(1),
                        );

                        const payloadStorageType: ?TypeID = switch (
                            self.typeTable.get(convertedType)
                        ) {
                            .Custom => |custom| switch (custom) {
                                .Aggregate => |layout|
                                    if (layout.fields.len >= 2)
                                        layout.fields[1]
                                    else
                                        null,
                                else => null,
                            },
                            else => null,
                        };

                        const init = self.allocator.alloc(
                            JAIR.Constant.Ptr,
                            2,
                        ) catch return Error.AllocatorFailure;

                        init[0] = tag;

                        if (payloadStorageType) |storageType| {
                            const payloadInit = self.allocator.alloc(
                                JAIR.Constant.Ptr,
                                1,
                            ) catch return Error.AllocatorFailure;

                            payloadInit[0] = payload;

                            const wrapper: u32 = @intCast(
                                self.constants.addOne(self.allocator)
                                    catch return Error.AllocatorFailure,
                            );

                            self.constants.set(wrapper, .{
                                .Aggregate = .{
                                    .Type = storageType,
                                    .Init = payloadInit,
                                },
                            });

                            init[1] = wrapper;
                        } else {
                            init[1] = payload;
                        }

                        break :aggregate_value .{
                            .Aggregate = .{
                                .Type = convertedType,
                                .Init = init,
                            },
                        };
                    }

                    const init = self.allocator.alloc(
                        JAIR.Constant.Ptr,
                        1,
                    ) catch return Error.AllocatorFailure;

                    init[0] = try self.convertConstant(
                        aggregate.data.at(
                            @intCast(aggregate.data.len() - 1),
                        ),
                    );

                    break :aggregate_value .{
                        .Aggregate = .{
                            .Type = convertedType,
                            .Init = init,
                        },
                    };
                },
                else => {
                    const init = self.allocator.alloc(
                        JAIR.Constant.Ptr,
                        aggregate.data.len(),
                    ) catch return Error.AllocatorFailure;

                    for (init, 0..) |*element, i| {
                        element.* = try self.convertConstant(
                            aggregate.data.at(@intCast(i)),
                        );
                    }

                    break :aggregate_value .{
                        .Aggregate = .{
                            .Type = convertedType,
                            .Init = init,
                        },
                    };
                },
            }
        },
        .Undefined => |t| switch (self.jir.types.get(t)) {
            .Pointer => |p| if (p.size == .Slice) .{ .Aggregate = .{
                .Type = try self.convertType(t),
                .Init = &.{},
            } } else .{ .Long = .{ 0, false } },
            else => .{ .Long = .{ 0, false } },
        },
        .Type, .Void => .{ .Long = .{ 0, false } },
    };

    const ptr: u32 = @intCast(
        self.constants.addOne(self.allocator)
            catch return Error.AllocatorFailure,
    );

    self.constants.set(ptr, converted);

    self.constMap.put(self.allocator, constant, ptr)
        catch return Error.AllocatorFailure;

    return ptr;
}

fn convertType(self: *Builder, id: TypeID) Error!TypeID {
    if (self.typeMap.get(id)) |res| {
        return res;
    }

    const converted: JAIR.Type = switch (self.jir.types.get(id)) {
        .Type, .Any, .EnumLiteral => .{ .Void = {} },
        .Void, .Noreturn => .{ .Void = {} },
        .Bool, .CUChar => .{ .Byte = false },
        .CChar => .{ .Byte = true },
        .CDouble, .ComptimeFloat => .{ .Double = {} },
        .Float => .{ .Single = {} },
        .CInt => .{ .Word = true },
        .Enum, .CUInt => .{ .Word = false },
        .Function, .CULong => .{ .Long = false },
        .CLong, .ComptimeInt, .CSize => .{ .Long = true },
        .CShort => .{ .Half = true },
        .CUShort => .{ .Half = false },
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => JAIR.Type{ .Custom = .{ .Aggregate = .{
                .name = try self.typeName(id),
                .size = try self.byteSize(id),
                .alignment = try self.typechecker.alignOf(id),
                .fields = fields: {
                    const fields = self.allocator.alloc(TypeID, 2) catch return Error.AllocatorFailure;
                    fields[0] = try self.convertType(comptime Comptime.Folder.Builtin.Type("usize"));
                    fields[1] = try self.convertType(comptime Comptime.Folder.Builtin.Type("u32"));
                    break :fields fields;
                },
            } } },
            else => .{ .Long = false },
        },
        .Integer => |int| switch (int.size) {
            64 => .{ .Long = int.signed },
            32 => .{ .Word = int.signed },
            16 => .{ .Half = int.signed },
            8 => .{ .Byte = int.signed },
            else => unreachable,
        },
        .Array => .{ .Custom = .{ .Opaque = .{
            .name = try self.typeName(id),
            .alignment = try self.typechecker.alignOf(id),
            .size = try self.byteSize(id),
        } } },
        .Union => |uni| if (uni.isTagged)
            JAIR.Type{ .Custom = .{ .Aggregate = .{
                .name = try self.typeName(id),
                .alignment = try self.typechecker.alignOf(id),
                .size = try self.byteSize(id),
                .fields = try self.convertTaggedUnionFields(id, uni.fields),
            } } }
        else
            .{ .Custom = .{ .Union = .{
                .name = try self.typeName(id),
                .alignment = try self.typechecker.alignOf(id),
                .size = try self.byteSize(id),
                .fields = try self.convertFields(uni.fields),
            } } },
        .Struct => |str| .{ .Custom = .{ .Aggregate = .{
            .name = try self.typeName(id),
            .alignment = try self.typechecker.alignOf(id),
            .size = try self.byteSize(id),
            .fields = try self.convertFields(str.fields),
        } } },
    };

    const res: u32 = @intCast(self.typeTable.addOneAssumeCapacity());
    self.typeTable.set(res, converted);
    self.typeMap.putAssumeCapacityNoClobber(id, res);
    return res;
}

fn byteSize(self: *Builder, id: TypeID) Error!u32 {
    return (try self.typechecker.sizeOf(id) + 7) / 8;
}

fn convertTaggedUnionFields(
    self: *Builder,
    parentType: TypeID,
    fields: anytype,
) Error![]const TypeID {
    if (fields.len == 0) return Error.ShouldBeImpossible;

    const tagType = try self.convertType(fields[0].valueType);
    const payloadFields = fields[1..];
    const payloadTypes = try self.convertFields(payloadFields);

    const out = self.allocator.alloc(
        TypeID,
        1 + @as(usize, @intFromBool(payloadTypes.len != 0)),
    ) catch return Error.AllocatorFailure;
    out[0] = tagType;

    if (payloadTypes.len != 0) {
        const layout = try self.unionPayloadLayout(payloadFields);
        const name = std.fmt.allocPrint(
            self.allocator,
            "__cole_internal_tagged_union_payload_{d}",
            .{parentType},
        ) catch return Error.AllocatorFailure;
        const namePtr: defines.StringPtr = @intCast(self.strings.items.len);
        self.strings.append(self.allocator, name) catch return Error.AllocatorFailure;

        const payloadType: TypeID = @intCast(self.typeTable.addOneAssumeCapacity());
        self.typeTable.set(payloadType, .{ .Custom = .{ .Union = .{
            .name = namePtr,
            .size = layout.size,
            .alignment = layout.alignment,
            .fields = payloadTypes,
        } } });

        out[1] = payloadType;
    }

    return out;
}

fn unionPayloadLayout(self: *Builder, fields: anytype) Error!struct {
    size: u32,
    alignment: u32,
} {
    var size: u32 = 0;
    var alignment: u32 = 1;

    for (fields) |field| {
        const fieldSize = try self.byteSize(field.valueType);
        if (fieldSize == 0) continue;

        const fieldAlignment = @max(
            1,
            try self.typechecker.alignOf(field.valueType),
        );
        size = @max(size, fieldSize);
        alignment = @max(alignment, fieldAlignment);
    }

    return .{
        .size = std.mem.alignForward(u32, size, alignment),
        .alignment = alignment,
    };
}

fn convertFields(self: *Builder, fields: anytype) Error![]const TypeID {
    var count: usize = 0;
    for (fields) |field| {
        if (try self.typechecker.sizeOf(field.valueType) != 0) count += 1;
    }

    const out = self.allocator.alloc(TypeID, count) catch return Error.AllocatorFailure;
    var idx: usize = 0;
    for (fields) |field| {
        if (try self.typechecker.sizeOf(field.valueType) == 0) continue;
        out[idx] = try self.convertType(field.valueType);
        idx += 1;
    }
    return out;
}

fn fieldLayout(self: *Builder, fields: anytype, fieldName: defines.StringPtr, sequential: bool) Error!FieldLayout {
    var offset: u32 = 0;
    for (fields) |field| {
        const size = try self.byteSize(field.valueType);
        const isTarget = std.mem.eql(u8, self.jir.strings[field.name], self.jir.strings[fieldName]);

        if (size == 0) {
            if (isTarget) return .{ .offset = offset, .type = field.valueType };
            continue;
        }

        const a: u32 = @max(1, @as(u32, @intCast(try self.typechecker.alignOf(field.valueType))));
        const at: u32 = if (sequential) std.mem.alignForward(u32, offset, a) else 0;

        if (isTarget) return .{ .offset = at, .type = field.valueType };
        if (sequential) offset = at + size;
    }

    common.log.err("No field '{s}' found while lowering field access", .{self.jir.strings[fieldName]});
    return Error.ShouldBeImpossible;
}

fn offsetPtr(self: *Builder, base: JAIR.Ptr, offset: u32) Error!JAIR.Ptr {
    if (offset == 0) return base;

    const usizeType = try self.convertType(comptime Comptime.Folder.Builtin.Type("usize"));

    const constant: u32 = @intCast(self.constants.addOne(self.allocator) catch return Error.AllocatorFailure);
    self.constants.set(constant, .{ .Long = .{ offset, false } });

    const offLit: u32 = @intCast(self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure);
    self.nodes.set(offLit, .{ .kind = .Literal, .type = usizeType, .value = constant });

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, base) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, offLit) catch return Error.AllocatorFailure;

    const res: u32 = @intCast(self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure);
    self.nodes.set(res, .{ .type = usizeType, .kind = .Add, .value = start });
    return res;
}

fn mangleSymbol(self: *Builder, source: defines.StringPtr) Error!defines.StringPtr {
    if (self.symbolNameMap.get(source)) |cached| {
        return cached;
    }

    const original = self.strings.items[source];

    if (std.mem.indexOf(u8, original, "::") == null) {
        try self.symbolNameMap.put(
            self.allocator,
            source,
            source,
        );
        return source;
    }

    const mangled = self.allocator.dupe(u8, original)
        catch return Error.AllocatorFailure;

    for (0..mangled.len - 1) |i| {
        if (mangled[i] == ':' and mangled[i + 1] == ':') {
            mangled[i] = '_';
            mangled[i + 1] = '_';
        }
    }

    const result: defines.StringPtr = @intCast(self.strings.items.len);

    self.strings.append(self.allocator, mangled)
        catch return Error.AllocatorFailure;

    try self.symbolNameMap.put(self.allocator, source, result);

    return result;
}

pub fn setFlag(self: *Builder, comptime flag: Flags, bit: bool) bool {
    defer self.flags.setValue(Flags.flag(flag), bit);
    return self.flags.isSet(Flags.flag(flag));
}

pub fn getFlag(self: *Builder, comptime flag: Flags) bool {
    return self.flags.isSet(Flags.flag(flag));
}

