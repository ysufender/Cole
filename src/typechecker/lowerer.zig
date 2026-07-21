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
const Stack = @import("../util/stack.zig").Stack;
const JIR = backend.C.JIR;
const Error = common.CompilerError;

const assert = std.debug.assert;

const Scope = u32; // defer count

const Lowerer = @This();

typechecker: *Typechecker,
lastLoop: []const u8 = "",
lastLoopDepth: u32 = 0,
scopes: Stack(Scope),
defers: Stack(defines.StatementPtr),

pub fn init(typechecker: *Typechecker) Error!Lowerer {
    return .{
        .typechecker = typechecker,
        .scopes = try Stack(Scope).init(typechecker.arena.allocator(), typechecker.symbols.scopes.len),
        .defers = try Stack(defines.StatementPtr).init(typechecker.arena.allocator(), typechecker.symbols.scopes.len * 8),
    };
}

pub fn topLevelDeclaration(self: *Lowerer, ptr: defines.DeclPtr, decl: *const Declaration) Error!void {
    // @Beware Function definitions are registered by the Comptime to
    // prevent ODR violations.

    const status = self.typechecker.lookup.get(ptr)
        orelse return common.debug.ShouldBeImpossible(@src());

    assert(status.status == .Checked);

    const typeID = status.result;
    const typeInfo = self.typechecker.typeTable.get(typeID);
    switch (typeInfo) {
        .Function => { },
        .Type => {
            const typeDefPtr = self.typechecker.executer.expectType(decl.node)
                catch return common.debug.ShouldBeImpossible(@src());
            const typeDef = self.typechecker.executer.getValue(typeDefPtr).Type;
            const info = self.typechecker.typeTable.get(typeDef);
            if (info == .Union and info.Union.isTagged) {
                _ = try self.typechecker.builder.typeDef(info.Union.tag);
            }
           _ = try self.typechecker.builder.typeDef(typeDef);
        },
        else => {
            // @Note Top-level comptimeness is checked in the typechecker.
            const node = try self.expression(decl.node, typeID);
            _ = try self.typechecker.builder.variableDef(decl.topLevel, typeID, decl, node, self.typechecker);
        },
    }
}

pub fn addConstant(self: *Lowerer, valuePtr: Comptime.Value.Ptr, ofTypePtr: TypeID) Error!JIR.Constant.Ptr {
    const value = self.typechecker.executer.getValue(valuePtr);
    const ofType = self.typechecker.typeTable.get(ofTypePtr);
    return self.typechecker.builder.addConstant(switch (value) {
        .Int => |val| switch (self.typechecker.sizeOf(ofTypePtr)) {
            64 => .{ .Integer = .{
                .i32 = @intCast(val),
            }},
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
            1 => .{ .Integer = .{
                .u8 = @intFromBool(ofType.Bool),
            } },
            else => |t| {
                common.log.err("Integer with size: {d}", .{t});
                return common.debug.ShouldBeImpossible(@src());
            },
        },
        .Float => |val| .{ .Float = val },
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
        .Enum => |valu| blk: {
            const cval = try self.typechecker.builder.addConstant(.{
                .Integer = .{ .u32 = valu.Value },
            });

            break :blk .{
                .Aggregate = .{
                    .type = valu.Type,
                    .data = .{
                        .start = cval,
                        .end = cval + 1,
                    },
                },
            };
        },
        .Union => |uni| uni: {
            const start = self.typechecker.builder.constants.len;
            _ = try self.typechecker.builder.addConstant(.{ .Integer = .{ .u32 = uni.Tag } });
            _ = try self.addConstant(uni.Value, ofType.Union.fields[uni.Tag + 1].valueType);
            break :uni .{ .Aggregate = .{
                .type = uni.Type,
                .data = .{
                    .start = @intCast(start),
                    .end = @intCast(self.typechecker.builder.constants.len),
                },
            }};
        },
        .String => |string| .{
            .String = try self.typechecker.builder.internString(string),
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
                .Pointer => |ptr|
                    if (true) {
                        self.report("Pointer types can't be comptime constants.", .{});
                        return Error.ComptimePointer;
                    }
                    else pointer: { 
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
        .Pointer => |ptr| blk: {
            const val = self.typechecker.executer.getValue(ptr.To);
            switch (val) {
                .Function => |func| break :blk JIR.Constant{
                    .Function = func.name,
                },
                else => {
                    self.report("Comptime pointers can't live outside the comptime scope.", .{});
                    return Error.ExistentialDilemma;
                }
            }
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
        .Function => |func| .{
            .Function = func.name,
        },
        .Type => return common.debug.ShouldBeImpossible(@src()),
    });
}

fn unwindDefers(self: *Lowerer, upTo: u32) Error!?defines.Range {
    var tmpDefers = self.defers;
    var tmpScopes = self.scopes;

    var range: ?defines.Range = null;

    for (0..upTo) |_| {
        const deferCount = tmpScopes.pop() orelse 0;
        for (0..deferCount) |_| {
            const stmtPtr = tmpDefers.pop() orelse return common.debug.ShouldBeImpossible(@src());
            const stmtRange = try self.statement(stmtPtr);

            range =
                if(range) |r| .{
                    .start = r.start,
                    .end = stmtRange.end + 1,
                }
                else .{
                    .start = stmtRange.start,
                    .end = stmtRange.end + 1,
                };
        }
    }

    return range;
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
            if (ast.expressions.items(.type)[stmt.value] == .Assignment) try self.assignment(ast.expressions.items(.value)[stmt.value])
            else {
                const res = try self.call(true, stmt.value, ast.expressions.get(stmt.value).value, try self.typechecker.typecheckExpression(stmt.value, null));
                return .{
                    .start = res,
                    .end = res + 1,
                };
            },
        .Conditional => try self.conditional(stmt.value, ast),
        .While => try self.loop(.While, stmt.value, ast),
        .Return => try self.@"return"(try self.expression(stmt.value, try self.typechecker.typecheckExpression(stmt.value, null))),
        .Break => try self.@"break"(),
        .Continue => try self.@"continue"(),
        .Discard => blk: {
            const start = try self.expression(stmt.value, try self.typechecker.typecheckExpression(stmt.value, null));

            break :blk .{
                .start = start,
                .end = start + 1,
            };
        },
        .VariableDefinition => try self.variableDef(stmt.value),
        .Import => return common.debug.ShouldBeImpossible(@src()),

        .Defer => try self.@"defer"(stmt.value),

        .For => return common.debug.ShouldBeImpossible(@src()),

        .InlineAssembly => try self.inlineAsm(stmt.value),

        .Switch => |t| {
            self.report("Statement '{s}' is not implemented.", .{
                @tagName(t),
            });
            return common.debug.NotImplemented(@src());
        },
    };

    return node;
}

fn inlineAsm(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!defines.Range {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const src = self.typechecker.context.getFile(ast.tokens);

    const cstart = ast.extra[extraPtr];
    const cend = ast.extra[extraPtr + 1];
    const code = try self.typechecker.builder.internString(src[cstart..cend]);

    const res = try self.typechecker.builder.inlineAsm(code);

    return .{
        .start = res,
        .end = res + 1,
    };
}

fn assignment(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!defines.Range {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const vexpr = ast.extra[extraPtr];
    const rexpr = ast.extra[extraPtr + 1];
    const vt = try self.typechecker.typecheckExpression(ast.extra[extraPtr], null);

    const prev = self.typechecker.executer.setFlag(.ComptimeBanned, true);
    const expr = try self.expression(vexpr, vt);
    _ = self.typechecker.executer.setFlag(.ComptimeBanned, prev);

    const rhs = try self.expression(rexpr, vt);

    const res = try self.typechecker.builder.assignment(expr, rhs);
    return .{
        .start = res,
        .end = res + 1,
    };
}

fn variableDef(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!defines.Range {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const declPtr = ast.extra[extraPtr + 2];

    // @Beware typecheckDecl must be before getDecl because names are
    // overwritten in typecheckDecl.
    const typeID = try self.typechecker.typecheckDecl(declPtr, null);
    const decl = self.typechecker.symbols.getDecl(declPtr);

    if (typeID == Comptime.Builtin.Type("type")) {
        const vdef = try self.typechecker.builder.typeDef(
            self.typechecker.executer.getValue(
                try self.typechecker.executer.eval(decl.node, null),
            ).Type,
        );
        return .{
            .start = vdef,
            .end = vdef + 1,
        };
    }

    const node =
        if (self.typechecker.executer.attemptEval(decl.node, typeID)) |someVal|
            try self.typechecker.builder.literal(try self.addConstant(someVal, typeID))
        else
            try self.expression(decl.node, typeID);

    const def = try self.typechecker.builder.variableDef(
        decl.topLevel,
        typeID,
        &decl,
        node,
        self.typechecker,
    );
    return .{
        .start = def,
        .end = def + 1,
    };
}

fn @"defer"(self: *Lowerer, stmtPtr: defines.StatementPtr) Error!defines.Range {
    const deferCount = self.scopes.pop() orelse {
        self.report("Defer statement outisde deferrable scope.", .{});
        return Error.DeferOutsideDeferrableScope;
    };
    try self.scopes.push(deferCount + 1);
    try self.defers.push(stmtPtr);
    return .{
        .start = 0,
        .end = 0,
    };
}

fn @"continue"(self: *Lowerer) Error!defines.Range {
    const startLabel = std.fmt.allocPrint(
        self.typechecker.arena.allocator(),
        "{s}_Start", .{
            self.lastLoop,
        },
    ) catch return Error.AllocatorFailure;

    const start = try self.unwindDefers(self.scopes.index - self.lastLoopDepth);

    const end = try self.typechecker.builder.jump(
        try self.typechecker.builder.internString(startLabel),
    );

    return
        if (start) |sr| .{
            .start = sr.start,
            .end = end,
        }
        else .{
            .start = end,
            .end = end + 1,
        };
}

fn @"break"(self: *Lowerer) Error!defines.Range {
    const endLabel = std.fmt.allocPrint(
        self.typechecker.arena.allocator(),
        "{s}_End", .{
            self.lastLoop,
        },
    ) catch return Error.AllocatorFailure;

    const start = try self.unwindDefers(self.scopes.index - self.lastLoopDepth);

    const end = try self.typechecker.builder.jump(
        try self.typechecker.builder.internString(endLabel),
    );

    return
        if (start) |sr| .{
            .start = sr.start,
            .end = end,
        }
        else .{
            .start = end,
            .end = end + 1,
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
    const cnd = try self.expression(conditionPtr, Comptime.Builtin.Type("bool"));

    _ = try self.typechecker.builder.cjump(endLabel, cnd);

    const bodyPtr = ast.extra[extraPtr + 1];
    self.lastLoopDepth = self.scopes.index;
    _ = try self.statement(bodyPtr);
    _ = try self.typechecker.builder.jump(startLabel);

    const end = try self.typechecker.builder.label(endLabel);

    return .{
        .start = start,
        .end = end + 1,
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

    const elseLabel = try self.typechecker.executer.generateRandomName(.Else);
    const finallyLabel = try self.typechecker.executer.generateRandomName(.Finally);

    const cnd = try self.expression(conditionExpr, Comptime.Builtin.Type("bool"));

    const maybeElse =
        if (ast.extra[extraPtr + 2] == 1) ast.extra[extraPtr + 3]
        else null;

    const start = try self.typechecker.builder.cjump(
        if (maybeElse) |_| elseLabel else finallyLabel,
        cnd
    );

    const end = blk: {
        const body = ast.extra[extraPtr + 1];
        _ = try self.statement(body);

        _ = try self.typechecker.builder.jump(finallyLabel);

        if (maybeElse) |elseBranch| {
            _ = try self.typechecker.builder.label(elseLabel);
            _ = try self.statement(elseBranch);
        }

        break :blk try self.typechecker.builder.label(finallyLabel);
    };

    return .{
        .start = start,
        .end = end + 1,
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

fn @"return"(self: *Lowerer, expr: JIR.Ptr) Error!defines.Range {
    const end = try self.unwindDefers(self.scopes.index);
    const start = try self.typechecker.builder.@"return"(expr);
    return .{
        .start = start,
        .end = if (end) |er| er.end else start + 1,
    };
}

fn block(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!defines.Range {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const statements = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    try self.scopes.push(0);

    const start = try self.typechecker.builder.scope(
        try self.typechecker.executer.generateRandomName(.Block),
    );

    for (statements.start..statements.end) |stmt| {
        _ = try self.statement(ast.extra[@intCast(stmt)]);
    }

    const deferCount = self.scopes.pop() orelse 0;
    for (0..deferCount) |_| {
        const stmtPtr = self.defers.pop()
            orelse return common.debug.ShouldBeImpossible(@src());

        if (!self.typechecker.getFlag(.CoveredAllPaths)) {
            _ = try self.statement(stmtPtr);
        }
    }

    const end = try self.typechecker.builder.exit();

    return .{
        .start = start,
        .end = end + 1,
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
        .Identifier => self.identifier(exprPtr),

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
        .ExpressionList => self.expressionList(expr.value),

        .Call => self.call(false, exprPtr, expr.value, ofType),

        .Switch, .Slicing => |t| {
            self.report("'{s}' lowering is not implemented.", .{@tagName(t)});
            return common.debug.NotImplemented(@src());
        },
    };
}

fn call(
    self: *Lowerer,
    stmt: bool,
    exprPtr: defines.ExpressionPtr,
    extraPtr: defines.OpaquePtr,
    ofType: TypeID,
) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const func = ast.extra[extraPtr];
    const argsListPtr = ast.extra[extraPtr + 1];
    const argsList = ast.expressions.get(argsListPtr);
    const argsRange = defines.Range{
        .start = ast.extra[argsList.value],
        .end = ast.extra[argsList.value + 1],
    };

    var res: ?defines.Range = null;

    for (argsRange.start..argsRange.end) |ptr| {
        const expr = try self.expression(ast.extra[@intCast(ptr)], try self.typechecker.typecheckExpression(ast.extra[@intCast(ptr)], null));

        res =
            if (res) |rr| .{
                .start = rr.start,
                .end = expr + 1,
            }
            else .{
                .start = expr,
                .end = expr + 1,
            };
    }

    const rres = res orelse defines.Range{ .start = 0, .end = 0 };

    const funcType = try self.typechecker.typecheckExpression(func, null);

    return switch (self.typechecker.typeTable.get(funcType)) {
        .Type => blk: {
            const typeID = self.typechecker.executer.getValue(
                try self.typechecker.executer.expectType(func),
            ).Type;
            break :blk self.typechecker.builder.construct(typeID, rres.start, rres.end);
        },
        .Function => |fnc|
            if (fnc.isComptime) self.literal(exprPtr, ofType)
            else self.typechecker.builder.call(
                stmt,
                try self.expression(func, funcType),
                rres
            ),
        else => common.debug.ShouldBeImpossible(@src()),
    };
}

fn expressionList(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const exprs = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    var res: ?defines.Range = null;

    for (exprs.start..exprs.end) |exprPtr| {
        const t = try self.typechecker.typecheckExpression(ast.extra[@intCast(exprPtr)], null);
        const expr = try self.expression(ast.extra[@intCast(exprPtr)], t);

        res =
            if (res) |rr| .{
                .start = rr.start,
                .end = expr + 1,
            }
            else .{
                .start = expr,
                .end = expr + 1,
            };
    }

    const rres = res orelse defines.Range{ .start = 0, .end = 0 };
    return self.typechecker.builder.grouping(rres.start, rres.end);
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
fn identifier(self: *Lowerer, id: defines.ExpressionPtr) Error!JIR.Ptr {
    const decl = self.typechecker.symbols.findGetDecl(.{
        .file = self.typechecker.currentFile,
        .expr = id,
    });
    return self.typechecker.builder.identifier(decl.name);
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
