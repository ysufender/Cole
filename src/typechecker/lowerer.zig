// @Beware expects all passed parameters to be already typechecked.

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
                catch return common.debug.ShouldBeImpossible(@src());
            const typeDef = self.typechecker.executer.getValue(typeDefPtr).Type;
            _ = try self.typechecker.builder.typeDef(typeDef);
        },
        else => {
            // @Note Top-level comptimeness is checked in the typechecker.
            const initializer =
                if (self.typechecker.executer.attemptEval(decl.node, typeID)) |someVal|
                    try self.typechecker.builder.literal(try self.addConstant(someVal, typeID))
                else
                    try self.expression(decl.node);

            try self.typechecker.builder.variableDef(typeID, initializer);
        },
    }
}

pub fn addConstant(self: *Lowerer, valuePtr: Comptime.ValuePtr, ofTypePtr: TypeID) Error!JIR.Constant.Ptr {
    const value = self.typechecker.executer.getValue(valuePtr);
    const ofType = self.typechecker.typeTable.get(ofTypePtr);
    return self.typechecker.builder.addConstant(switch (value) {
        .Int => |val| integer: {
            if (ofType == .ComptimeInt) {
                self.report(
                    "Value of type 'comptime_int' can't leak outside the comptime scope "
                    ++ "without a target integer type. Consider adding a type annotation "
                    ++ "or an explicit cast.",
                    .{}
                );
                return Error.ExistentialDilemma;
            }

            break :integer switch (self.typechecker.sizeOf(ofTypePtr)) {
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
            };
        },
        .Float => |val| float: {
            if (ofType == .ComptimeFloat) {
                self.report(
                    "Value of type 'comptime_float' can't leak outside the comptime scope "
                    ++ "without a target floating point type. Consider adding a type annotation "
                    ++ "or an explicit cast.",
                    .{}
                );
                return Error.ExistentialDilemma;
            }

            break :float .{ .Float = val };
        },
        .Undefined => |valueType| .{ .Undefined = valueType },
        .Struct => |str| @"struct": {
            const start = self.typechecker.builder.constants.len;
            for (str.Fields.start..str.Fields.end) |fieldPtr| {
                _ = try self.addConstant(@intCast(fieldPtr), ofType.Struct.fields[fieldPtr - str.Fields.start].valueType);
            }
            break :@"struct" .{ .Aggregate = .{
                .type = str.Type,
                .data = .{
                    .start = @intCast(start),
                    .end = @intCast(self.typechecker.builder.constants.len),
                },
            }};
        },
        .Enum => |val| .{ .Integer = .{ .u32 = val.Value } },
        .Union => |uni| @"union": {
            const start = self.typechecker.builder.constants.len;
            _ = try self.typechecker.builder.addConstant(.{ .Integer = .{ .u32 = uni.Tag } });
            _ = try self.addConstant(uni.Value, ofType.Union.fields[uni.Tag + 1].valueType);
            break :@"union" .{ .Aggregate = .{
                .type = uni.Type,
                .data = .{
                    .start = @intCast(start),
                    .end = @intCast(self.typechecker.builder.constants.len),
                },
            }};
        },
        .String => |string| string: {
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

            break :string .{ .Aggregate = .{
                .type = Comptime.Builtin.Type("string"),
                .data = .{
                    .start = @intCast(start),
                    .end = @intCast(self.typechecker.builder.constants.len),
                },
            }};
        },
        .Slice => |slice| slice: {
            const start = self.typechecker.builder.constants.len;

            const child = switch (ofType) {
                .Array => |arr| arr.child,
                .Pointer => |ptr| ptr.child,
                else => return common.debug.ShouldBeImpossible(@src()),
            };

            for (0..slice.Size) |index| {
                _ = try self.addConstant(slice.at(@intCast(index)), child);
            }

            break :slice switch (ofType) {
                .Array => .{ .Aggregate = .{
                    .type = slice.Type,
                    .data = .{
                        .start = @intCast(start),
                        .end = @intCast(self.typechecker.builder.constants.len),
                    },
                }},
                .Pointer => |ptr| pointer: { 
                    const implicitArray = JIR.Constant{ .Aggregate = .{
                        .type = try self.typechecker.registerType(.{
                            .Array = .{
                                .mutable = true,
                                .child = ptr.child,
                                .len = slice.Size,
                            },
                        }),
                        .data = .{
                            .start = @intCast(start),
                            .end = @intCast(self.typechecker.builder.constants.len),
                        },
                    }};

                    break :pointer .{ .Pointer = try self.typechecker.builder.addConstant(implicitArray) };
                },
                else => return common.debug.ShouldBeImpossible(@src()),
            };
        },
        .Pointer => {
            self.report("Comptime pointers can't live outside the comptime scope.", .{});
            return Error.ExistentialDilemma;
        },
        .Bool => |boolValue| .{ .Integer = .{ .u8 = @intFromBool(boolValue), }, },
        .Void => {
            self.report(
                "I don't even know what happened, but somehow you tried to "
                ++ "create a constant value of type 'void'. I don't think that is "
                ++ "really useful, since it only means that the statement should "
                ++ "be comptime ran. Anyway, here is the place of this error message: "
                ++ common.debug.locationString(@src())
                ++ ". And here is also (hopefully) some stacktrace: ",
                .{},
            );

            const _stderr = std.Io.File.stderr().writer(self.typechecker.context.io, &common.log.wbuf);
            var stderr = _stderr.interface;
            common.debug.stackTrace(@frameAddress(), &stderr);

            return common.debug.ShouldBeImpossible(@src());
        },
        .Function, .Type => return common.debug.ShouldBeImpossible(@src()),
    });
}

fn expression(self: *Lowerer, exprPtr: defines.ExpressionPtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expr = ast.expressions.get(exprPtr);
    return switch (expr.type) {
        .Assignment => self.assignment(expr.value),
        .EnumDefinition, .StructDefinition, .UnionDefinition,
        .FunctionDefinition, .FunctionType, .ArrayType,
        .CPointerType, .MutableType, .PointerType,
        .SliceType, .Scoping, .Mark => common.debug.ShouldBeImpossible(@src()),
        else => common.debug.NotImplemented(@src()),
    };
}

fn assignment(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const lhs = ast.extra[extraPtr];
    const rhs = ast.extra[extraPtr + 1];

    const lhsType = try self.typechecker.typecheckExpression(lhs, null);

    // @Beware Must be kept in sync with ConcreteValue check in typechecker.
    // @Note lhs can be: Scoping, Identifier, Indexing, or a dereference.
    // Indexing and dereference should be redirected to Lowerer.store instead of
    // handling here.

    // TODO: After assignment typechecking.

    _ = lhsType;
    _ = rhs;
    unreachable;
}

fn report(self: *Lowerer, comptime fmt: []const u8, args: anytype) void {
    _ = self.typechecker.setFlag(.AttemptingEval, false);
    return self.typechecker.report("LOWERER: " ++ fmt, args);
}
