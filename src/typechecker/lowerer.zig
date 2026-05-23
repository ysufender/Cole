const std = @import("std");
const common = @import("../core/common.zig");
const backend = @import("../codegen/backend.zig");
const defines = @import("../core/defines.zig");

const Error = common.CompilerError;
const Typechecker = @import("typechecker.zig");
const TypeID = @import("type.zig").TypeID;
const Comptime = @import("comptime.zig");
const Declaration = @import("resolver.zig").Declaration;
const JIR = backend.C.JIR;

const assert = std.debug.assert;

const Lowerer = @This();

typechecker: *Typechecker,

pub fn init(typechecker: *Typechecker) Lowerer {
    return .{
        .typechecker = typechecker,
    };
}

pub fn declaration(self: *Lowerer, ptr: defines.DeclPtr, decl: *const Declaration) Error!void {
    // @Beware Function definitions are registered by the Comptime to
    // prevent ODR violations.

    const status = self.typechecker.lookup.get(ptr)
        orelse return common.debug.ShouldBeImpossible(@src());

    assert(status.status == .Checked);

    const typeID = status.result;
    const typeInfo = self.typechecker.typeTable.get(typeID);
    switch (typeInfo) {
        .Function => return common.debug.ShouldBeImpossible(@src()),
        .Type => {
            const typeDefPtr = self.typechecker.executer.expectType(decl.node)
                c> atc>h return common.debug.ShouldBeImpossible(@src());
            const typeDef = self.typechecker.executer.getValue(typeDefPtr).Type;
            try self.typechecker.builder.typeDef(typeDef);
        },
        else => {
            if (self.typechecker.executer.attemptEval(decl.node, typeID)) |someVal| {
                const constant = try self.addConstant(someVal, typeID);
            }
            else {
            }
        },
    }
}

pub fn addConstant(self: *Lowerer, valuePtr: Comptime.ValuePtr, ofTypePtr: TypeID) Error!JIR.Constant.Ptr {
    const value = self.typechecker.executer.getValue(valuePtr);
    const ofType = self.typechecker.typeTable.get(ofTypePtr);
    return self.typechecker.builder.addConstant(switch (value) {
        .Int => |val| switch (self.typechecker.sizeOf(ofType)) {
            32 => .{ .Integer = if (ofType.Integer.signed) .{
                .i32 = @intCast(val),
            } else .{
                .u32 = @intCast(val),
            }},
            8 => .{ .Integer = if (ofType.Integer.signed) .{
                .i8 = @intCast(val),
            } else .{
                .u8 = @intCast(val),
            }},
            else => return common.debug.ShouldBeImpossible(@src()),
        },
        .Float => |val| return .{ .Float = val },
        .Undefined => |valueType| .{ .Undefined = valueType },
        .Struct => |str| blk: {
            const start = self.typechecker.builder.constants.len;
            for (str.Fields.start..str.Fields.end) |fieldPtr| {
                _ = try self.addConstant(fieldPtr, ofType.Struct.fields[fieldPtr - str.Fields.start].valueType);
            }
            break :blk .{ .Aggregate = .{
                .type = str.Type,
                .data = .{
                    .start = @intCast(start),
                    .end = @intCast(self.typechecker.builder.constants.len),
                },
            }};
        },
        .Enum => |val| .{ .Integer = .{ .u32 = val.Value } },
        .Union => |uni| blk: {
            const start = self.typechecker.builder.constants.len;
            _ = try self.typechecker.builder.addConstant(.{ .Integer = .{ .u32 = uni.Tag } });
            _ = try self.addConstant(uni.Value, ofType.Union.fields[uni.Tag + 1]);
            break :blk .{ .Aggregate = .{
                .type = uni.Type,
                .data = .{
                    .start = @intCast(start),
                    .end = @intCast(self.typechecker.builder.constants.len),
                },
            }};
        },
        .String => |string| blk: {
            // @Beware strings are slices, so they are aggregate
            // in the form [size, internedStringIndex]
            const strPtr = try self.typechecker.builder.internString(string);

            const start = self.typechecker.builder.constants.len;
            _ = try self.typechecker.builder.addConstant(.{ .Integer = .{
                .u32 = @intCast(string.len),
            }});
            _ = try self.typechecker.builder.addConstant(.{ .Integer = .{
                .u32 = strPtr,
            }});

            break :blk .{ .Aggregate = .{
                .type = Comptime.Builtin.Type("string"),
                .data = .{
                    .start = @intCast(start),
                    .end = @intCast(self.typechecker.builder.constants.len),
                },
            }};
        },
        .Slice => |slice| blk: {
            const start = self.typechecker.builder.constants.len;

            switch (ofType) {
                .Array => |arr| {
                    for (0..slice.Size) |index| {
                        _ = try self.addConstant(slice.at(index), arr.child);
                    }

                    break :blk .{ .Aggregate = .{
                    }};
                },
                .Pointer => |ptr| ptr.child,
                else => return common.debug.ShouldBeImpossible(@src()),
            }
        },
    });
}

pub fn expression(self: *Lowerer, exprPtr: defines.ExpressionPtr) Error!void {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expr = ast.expressions.get(exprPtr);
    switch (expr.type) {
        .EnumDefinition, .StructDefinition, .UnionDefinition => {
        },
        else => return common.debug.NotImplemented(@src()),
    }
}
