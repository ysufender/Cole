// @Beware expects all passed parameters to be already typechecked.

const std = @import("std");
const common = @import("../core/common.zig");
const backend = @import("../codegen/backend.zig");
const defines = @import("../core/defines.zig");

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("../parser/parser.zig");
const Typechecker = @import("typechecker.zig");
const TypeID = @import("type.zig").TypeID;
const Comptime = @import("comptime.zig");
const Declaration = @import("resolver.zig").Declaration;
const JIR = backend.C.JIR;
const Error = common.CompilerError;

const assert = std.debug.assert;

const Lowerer = @This();

typechecker: *Typechecker,
lastLoop: []const u8 = "",

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
        .Function => {},
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
                    try self.expression(decl.node, typeID);

            try self.typechecker.builder.variableDef(typeID, initializer);
        },
    }
}

pub fn addConstant(self: *Lowerer, valuePtr: Comptime.Value.Ptr, ofTypePtr: TypeID) Error!JIR.Constant.Ptr {
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

//
// Statement
//

pub fn statement(self: *Lowerer, statementPtr: defines.StatementPtr) Error!defines.Range {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const stmt = ast.statements.get(statementPtr);
    const node: defines.Range = switch (stmt.type) {
        .Block => try self.block(stmt.value),
        .Expression =>
            if (ast.expressions.items(.type)[stmt.value] == .Assignment) return common.debug.NotImplemented(@src())
            else try self.expressionStmt(stmt.value),
        .Return => try self.@"return"(stmt.value),
        .Conditional => try self.conditional(stmt.value, ast),
        .While => try self.loop(.While, stmt.value, ast),
        .Break => try self.@"break"(),
        .Continue => try self.@"continue"(),
        .Discard => blk: {
            const start = try self.expression(stmt.value, try self.typechecker.typecheckExpression(stmt.value, null));

            break :blk .{
                .start = start,
                .end = start + 1,
            };
        },
        .VariableDefinition => .{
            .start = 0,
            .end = 0,
        },
        .Import, .Mark => return common.debug.ShouldBeImpossible(@src()),

        .Defer, .For,
        .InlineAssembly, .Switch => |t| {
            self.report("Statement '{s}' is not implemented.", .{
                @tagName(t),
            });
            return common.debug.NotImplemented(@src());
        },
    };

    try self.typechecker.builder.addKeyNode(node.start);
    return node;
}

fn @"continue"(self: *Lowerer) Error!defines.Range {
    const startLabel = std.fmt.allocPrint(
        self.typechecker.arena.allocator(),
        "{s}_Start", .{
            self.lastLoop,
        },
    ) catch return Error.AllocatorFailure;

    const start = try self.typechecker.builder.jump(
        try self.typechecker.builder.internString(startLabel),
    );

    return .{
        .start = start,
        .end = start + 1,
    };
}

fn @"break"(self: *Lowerer) Error!defines.Range {
    const endLabel = std.fmt.allocPrint(
        self.typechecker.arena.allocator(),
        "{s}_End", .{
            self.lastLoop,
        },
    ) catch return Error.AllocatorFailure;

    const start = try self.typechecker.builder.jump(
        try self.typechecker.builder.internString(endLabel),
    );

    return .{
        .start = start,
        .end = start + 1,
    };
}

fn loop(
    self: *Lowerer,
    loopType: enum {
        While,
        For,
    },
    extraPtr: defines.OpaquePtr,
    ast: *const Parser.AST,
) Error!defines.Range {
    if (loopType == .For) return common.debug.ShouldBeImpossible(@src());

    const loopLabel = try self.typechecker.executer.generateRandomNameString(.Loop);
    self.lastLoop = loopLabel;

    const startLabel = try self.typechecker.builder.internString(
        std.fmt.allocPrint(
            self.typechecker.arena.allocator(),
            "{s}_Start", .{
                loopLabel,
            }
        ) catch return Error.AllocatorFailure
    );

    const endLabel = try self.typechecker.builder.internString(
        std.fmt.allocPrint(
            self.typechecker.arena.allocator(),
            "{s}_End", .{
                loopLabel,
            }
        ) catch return Error.AllocatorFailure
    );

    const start = try self.typechecker.builder.label(startLabel);

    const conditionPtr = ast.extra[extraPtr];
    _  = try self.expression(conditionPtr, Comptime.Builtin.Type("bool"));

    _ = try self.typechecker.builder.cjump(endLabel);

    const bodyPtr = ast.extra[extraPtr + 1];
    _ = try self.statement(bodyPtr);
    _ = try self.typechecker.builder.jump(startLabel);

    const end = try self.typechecker.builder.label(endLabel);

    return .{
        .start = start,
        .end = end,
    };
}

fn conditional(self: *Lowerer, extraPtr: defines.OpaquePtr, ast: *const Parser.AST) Error!defines.Range {
    const conditionExpr = ast.extra[extraPtr];

    if (self.typechecker.executer.attemptEval(conditionExpr, null)) |comptimeConditionPtr| {
        const comptimeCondition = self.typechecker.executer.getValue(comptimeConditionPtr).Bool;

        if (comptimeCondition) {
            return self.statement(ast.extra[extraPtr + 1]);
        }

        if (ast.extra[extraPtr + 2] == 1) {
            return self.statement(ast.extra[extraPtr + 3]);
        }

        const start = self.typechecker.builder.nodes.len;
        return .{
            .start = start,
            .end = start + 1,
        };
    }

    // @Note the compiler sets up a virtual logic register which holds the
    // intermediary logic results. Conditional jumps read from the said
    // register directly.
    //
    // @Important @Beware Conditional jump is made only when register
    // stores false.

    const start = try self.expression(conditionExpr, Comptime.Builtin.Type("bool"));
    const end = blk: {
        const elseLabel = try self.typechecker.executer.generateRandomName(.Else);
        const finallyLabel = try self.typechecker.executer.generateRandomName(.Finally);

        _ = try self.typechecker.builder.cjump(elseLabel);

        const body = ast.extra[extraPtr + 1];
        _ = try self.statement(body);

        _ = try self.typechecker.builder.jump(finallyLabel);

        const maybeElse =
            if (ast.extra[extraPtr + 2] == 1) ast.extra[extraPtr + 3]
            else null;

        if (maybeElse) |elseBranch| {
            _ = try self.typechecker.builder.label(elseLabel);
            _ = try self.statement(elseBranch);
        }

        break :blk try self.typechecker.builder.label(finallyLabel);
    };

    return .{
        .start = start,
        .end = end,
    };
}

fn expressionStmt(self: *Lowerer, expr: defines.ExpressionPtr) Error!defines.Range {
    const exprType = self.typechecker.typecheckExpression(expr, null)
        catch return common.debug.ShouldBeImpossible(@src());
    const res = try self.expression(expr, exprType);
    return .{
        .start = res,
        .end = res + 1,
    };
}

fn @"return"(self: *Lowerer, expr: defines.ExpressionPtr) Error!defines.Range {
    const start = try self.typechecker.builder.@"return"(expr);
    return .{
        .start = start,
        .end = start + 1,
    };
}

fn block(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!defines.Range {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const statements = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    if (statements.len() <= 0) {
        return statements;
    }

    const start = try self.typechecker.builder.scope(
        try self.typechecker.executer.generateRandomName(.Block)
    );
    for (statements.start..statements.end) |stmt| {
        _ = try self.statement(ast.extra[@intCast(stmt)]);
    }
    const end = try self.typechecker.builder.exit();

    return .{
        .start = start,
        .end = end,
    };
}


//
// Expression
//

pub fn expression(self: *Lowerer, exprPtr: defines.ExpressionPtr, ofType: TypeID) Error!JIR.Ptr {
    if (self.typechecker.executer.attemptEval(exprPtr, ofType)) |_| {
        return self.literal(exprPtr, ofType);
    }

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expr = ast.expressions.get(exprPtr);
    return switch (expr.type) {
        .Literal => self.literal(exprPtr, ofType),
        .Mark => self.mark(expr.value, ofType),
        .Identifier => self.identifier(expr.value),

        .EnumDefinition, .StructDefinition, .UnionDefinition,
        .FunctionType, .ArrayType,
        .CPointerType, .MutableType, .PointerType,
        .Lambda, .FunctionDefinition,
        .SliceType, .Scoping => common.debug.ShouldBeImpossible(@src()),

        .Assignment => {
            self.report(
                "Hello, whomever changed the codebase to such a state that "
                ++ "the typechecker is now all screwed up. Due to your ingenius, "
                ++ "the lowerer now treats assignments as expressions, rather than "
                ++ "statements. I won't give you any further information about the "
                ++ "matter. I won't even give a stacktrace for you to debug.",
                .{}
            );
            return common.debug.ShouldBeImpossible(@src());
        },

        .Binary => self.binary(expr.value, ofType),
        .Unary => self.unary(expr.value, ofType),

        .Conditional => self.conditionalExpr(expr.value, ofType),

        .Dot => self.dot(expr.value),

        .Indexing => self.indexing(expr.value),

        .Switch, .ExpressionList, .Call, .Slicing => |t| {
            self.report("'{s}' lowering is not implemented.", .{@tagName(t)});
            return common.debug.NotImplemented(@src());
        },
    };
}

fn indexing(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const exprPtr = ast.extra[extraPtr];
    const typeID = try self.typechecker.typecheckExpression(exprPtr, null);

    const indexable = switch (self.typechecker.typeTable.get(typeID)) {
        .Array => try self.expression(exprPtr, typeID),
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => blk: {
                const slice = try self.expression(exprPtr, typeID);
                break :blk try self.typechecker.builder.dot(slice, try self.typechecker.builder.internString("ptr"));
            },
            else => try self.expression(exprPtr, typeID),
        },
        else => return common.debug.ShouldBeImpossible(@src()),
    };

    const indexPtr = ast.extra[extraPtr + 1];
    const indexType = try self.typechecker.typecheckExpression(indexPtr, null);

    const index = try self.expression(indexPtr, indexType);

    return self.typechecker.builder.dereference(
        try self.typechecker.builder.add(indexable, index)
    );
}

fn dot(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const exprPtr = ast.extra[extraPtr];
    const exprType = try self.typechecker.typecheckExpression(exprPtr, null);

    const obj = try self.expression(exprPtr, exprType);
    const member = tokens
                    .get(ast.extra[extraPtr + 1])
                    .lexeme(self.typechecker.context, self.typechecker.currentFile);

    return self.typechecker.builder.dot(obj, try self.typechecker.builder.internString(member));
}

fn conditionalExpr(self: *Lowerer, extraPtr: defines.OpaquePtr, ofType: TypeID) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const cndPtr = ast.extra[extraPtr];
    const thenPtr = ast.extra[extraPtr + 1];
    const otherPtr = ast.extra[extraPtr + 2];

    const cnd = try self.expression(cndPtr, Comptime.Builtin.Type("bool"));
    const then = try self.expression(thenPtr, ofType);
    const otherwise = try self.expression(otherPtr, ofType);

    return self.typechecker.builder.ternary(cnd, then, otherwise);
}

fn unary(self: *Lowerer, extraPtr: defines.OpaquePtr, ofType: TypeID) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const rhs = try self.expression(ast.extra[extraPtr + 1], ofType);

    return switch (@as(Lexer.TokenType, @enumFromInt(ast.extra[extraPtr]))) {
        .Bang => self.typechecker.builder.not(rhs),
        .Minus => self.typechecker.builder.negate(rhs),
        .Tilde => self.typechecker.builder.invert(rhs),
        else => common.debug.ShouldBeImpossible(@src()),
    };
}

fn binary(self: *Lowerer, extraPtr: defines.OpaquePtr, ofType: TypeID) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const lhs = try self.expression(ast.extra[extraPtr], ofType);
    const rhs = try self.expression(ast.extra[extraPtr + 2], ofType);

    return switch (@as(Lexer.TokenType, @enumFromInt(ast.extra[extraPtr + 1]))) {
        .Xor => self.typechecker.builder.xor(lhs, rhs),
        .Minus => self.typechecker.builder.sub(lhs, rhs),
        .Plus => self.typechecker.builder.add(lhs, rhs),
        .Slash => self.typechecker.builder.div(lhs, rhs),
        .Star => self.typechecker.builder.mul(lhs, rhs),
        .BangEqual => self.typechecker.builder.notEqual(lhs, rhs),
        .EqualEqual => self.typechecker.builder.equal(lhs, rhs),
        .GreaterEqual => self.typechecker.builder.greaterEqual(lhs, rhs),
        .LesserEqual => self.typechecker.builder.lesserEqual(lhs, rhs),
        .Lesser => self.typechecker.builder.lesser(lhs, rhs),
        .Greater => self.typechecker.builder.greater(lhs, rhs),
        .LeftShift => self.typechecker.builder.lshift(lhs, rhs),
        .RightShift => self.typechecker.builder.rshift(lhs, rhs),
        .And => self.typechecker.builder.@"and"(lhs, rhs),
        .Or => self.typechecker.builder.@"or"(lhs, rhs),
        .Pipe => self.typechecker.builder.bitwiseOr(lhs, rhs),
        .Ampersand => self.typechecker.builder.bitwiseAnd(lhs, rhs),
        else => common.debug.ShouldBeImpossible(@src()),
    };
}

// @Note type names are also plain identifiers.
fn identifier(self: *Lowerer, identifierTokenPtr: defines.TokenPtr) Error!JIR.Ptr {
    const tokens = self.typechecker.context.getTokens(self.typechecker.currentFile);

    const lexeme = tokens.get(identifierTokenPtr).lexeme(self.typechecker.context, self.typechecker.currentFile);
    const strPtr = try self.typechecker.builder.internString(lexeme);
    return self.typechecker.builder.identifier(strPtr);
}

fn mark(self: *Lowerer, extraPtr: defines.OpaquePtr, ofType: TypeID) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    return self.expression(ast.extra[extraPtr + 2], ofType);
}

fn literal(self: *Lowerer, exprPtr: defines.ExpressionPtr, ofType: TypeID) Error!JIR.Ptr {
    // @Note should already been evaluated before.
    const valuePtr = try self.typechecker.executer.eval(exprPtr, null);
    const constant = try self.addConstant(valuePtr, ofType);
    return self.typechecker.builder.literal(constant);
}

fn report(self: *Lowerer, comptime fmt: []const u8, args: anytype) void {
    _ = self.typechecker.setFlag(.AttemptingEval, false);
    return self.typechecker.report("LOWERER: " ++ fmt, args);
}
