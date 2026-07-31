// @Beware expects all passed parameters to be already typechecked.

const std = @import("std");
const common = @import("../core/common.zig");
const backend = @import("../codegen/backend.zig");
const defines = @import("../core/defines.zig");
const types = @import("../typechecker/type.zig");

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("../parser/parser.zig");
const Typechecker = @import("typechecker.zig");
const TypeID = @import("type.zig").TypeID;
const Comptime = @import("comptime.zig");
const Declaration = @import("resolver.zig").Declaration;
const Stack = @import("../util/stack.zig").Stack;
const JIR = backend.C.JIR;
const Error = common.CompilerError;
const Resolver = @import("../typechecker/resolver.zig");

const assert = std.debug.assert;

const Scope = u32; // defer count

const Lowerer = @This();

typechecker: *Typechecker,
lastLoop: []const u8 = "",
lastLoopDepth: u32 = 0,
lastReturnType: TypeID = Comptime.Folder.Builtin.Type("any"),
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
        orelse return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());

    assert(status.status == .Checked);

    const typeID = status.result;
    const typeInfo = self.typechecker.typeTable.get(typeID);
    switch (typeInfo) {
        .Function => { },
        .Type => {
            if (self.typechecker.hasMetadata(decl.node, "@extern")) {
                return;
            }

            const typeDefPtr = self.typechecker.folder.expectType(decl.node)
                catch return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
            const typeDef = self.typechecker.folder.getValue(typeDefPtr).Type;
            const info = self.typechecker.typeTable.get(typeDef);
            if (info == .Union and info.Union.isTagged) {
                _ = try self.typechecker.builder.typeDef(info.Union.tag);
            }
           _ = try self.typechecker.builder.typeDef(typeDef);
        },
        else => {
            // @Note Top-level comptimeness is checked in the typechecker.
            const node = try self.expression(decl.node, typeID);
            _ = try self.typechecker.builder.variableDef(
                decl.topLevel,
                typeID,
                decl.name,
                if (self.typechecker.context.settings.canFold())
                    if (self.typechecker.folder.attemptEval(decl.node, typeID)) |i| self.typechecker.folder.getValue(i) == .Undefined
                    else false
                else false,
                node
            );
        },
    }
}

pub fn addConstant(self: *Lowerer, valuePtr: Comptime.Value.Ptr, ofTypePtr: TypeID) Error!JIR.Constant.Ptr {
    const value = self.typechecker.folder.getValue(valuePtr);
    const ofType = self.typechecker.typeTable.get(ofTypePtr);
    return self.typechecker.builder.addConstant(switch (value) {
        .Int => |val| switch (ofType) {
            .Integer, .ComptimeInt => switch (self.typechecker.sizeOf(ofTypePtr)) {
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
                    return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
                },
            },
            
            .Float, .ComptimeFloat => .{
                .Float = @floatFromInt(value.Int),
            },

            .Bool => .{
                .Integer = .{ .u32 = @intCast(value.Int) },
            },

            else => |t| {
                common.log.err("addConstant: {s}", .{@tagName(t)});
                return common.debug.ShouldBeImpossible(undefined, @src());
            },
        },

        .Float => |val| .{ .Float = val },
        .Undefined => |valueType| .{ .Undefined = valueType },
        .Struct => |str| @"struct": {
            const fieldConsts = self.typechecker.builder.allocator.alloc(JIR.Constant.Ptr, str.Fields.len())
                catch return Error.AllocatorFailure;
            for (str.Fields.start..str.Fields.end, 0..) |fieldPtr, i| {
                fieldConsts[i] = try self.addConstant(@intCast(fieldPtr), ofType.Struct.fields[i].valueType);
            }
 
            const start = self.typechecker.builder.constants.len;
            for (fieldConsts) |c| {
                _ = try self.typechecker.builder.addConstant(self.typechecker.builder.constants.get(c));
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
            const tagConst = try self.typechecker.builder.addConstant(.{ .Integer = .{ .u32 = uni.Tag } });
            const valueConst = try self.addConstant(uni.Value, ofType.Union.fields[uni.Tag + 1].valueType);
 
            const start = self.typechecker.builder.constants.len;
            _ = try self.typechecker.builder.addConstant(self.typechecker.builder.constants.get(tagConst));
            _ = try self.typechecker.builder.addConstant(self.typechecker.builder.constants.get(valueConst));
 
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
            const child = switch (ofType) {
                .Array => |arr| arr.child,
                .Pointer => |ptr| ptr.child,
                else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
            };
 
            const elemConsts = self.typechecker.builder.allocator.alloc(JIR.Constant.Ptr, slice.Size)
                catch return Error.AllocatorFailure;
            for (0..slice.Size) |index| {
                elemConsts[index] = try self.addConstant(slice.at(@intCast(index)), child);
            }
 
            const start = self.typechecker.builder.constants.len;
            for (elemConsts) |c| {
                _ = try self.typechecker.builder.addConstant(self.typechecker.builder.constants.get(c));
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
                    else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
            };
        },

        .Pointer => |ptr| blk: {
            const val = self.typechecker.folder.getValue(ptr.To);
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

            return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
        },

        .Function => |func| .{
            .Function = func.name,
        },

        .Type => |id| .{ .Type = id },
    });
}

fn unwindDefers(self: *Lowerer, upTo: u32) Error!?defines.Range {
    var tmpDefers = self.defers;
    var tmpScopes = self.scopes;

    var range: ?defines.Range = null;

    for (0..upTo) |_| {
        const deferCount = tmpScopes.pop() orelse 0;
        for (0..deferCount) |_| {
            const stmtPtr = tmpDefers.pop() orelse return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
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

pub fn statement(self: *Lowerer, statementPtr: defines.StatementPtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const stmt = ast.statements.get(statementPtr);
    const node: JIR.Ptr = switch (stmt.type) {
        .Block => try self.block(stmt.value),
        .Expression =>
            if (ast.expressions.items(.type)[stmt.value] == .Assignment) try self.assignment(ast.expressions.items(.value)[stmt.value])
            else try self.call(true, stmt.value, ast.expressions.get(stmt.value).value, try self.typechecker.typecheckExpression(stmt.value, null)),
        .Conditional => try self.conditional(stmt.value, ast),
        .While => try self.loop(.While, stmt.value, ast),
        .Return => try self.@"return"(try self.expression(stmt.value, self.lastReturnType)),
        .Break => try self.@"break"(),
        .Continue => try self.@"continue"(),
        .Discard => try self.expression(stmt.value, try self.typechecker.typecheckExpression(stmt.value, null)),
        .VariableDefinition => try self.variableDef(stmt.value),
        .Import => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),

        .Defer => try self.@"defer"(stmt.value),

        .For => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),

        .InlineC => try self.inlineC(stmt.value),

        .Switch => try self.@"switch"(stmt.value),
    };

    return node;
}

fn @"switch"(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    var typechecker = self.typechecker;
    var exec = typechecker.folder;

    const ast = typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = typechecker.context.getTokens(ast.tokens);

    const enumOrUnionType = try typechecker.typecheckExpression(ast.extra[extraPtr], null);
    const enumOrUnion = try self.expression(ast.extra[extraPtr], enumOrUnionType);
    const maybeComptimeEnumOrUnion =
        if (self.typechecker.context.settings.canFold())
            if (typechecker.folder.attemptEval(ast.extra[extraPtr], enumOrUnionType))
                |ptr| typechecker.folder.getValue(ptr)
            else null
        else null;
    const typeInfo = typechecker.typeTable.get(enumOrUnionType);
    const tag: struct { type: TypeID, fields: []const []const u8 } = switch (typeInfo) {
        .Enum => |enm| .{ .type = enumOrUnionType, .fields = enm.fields },
        .Union => |uni| .{ .type = uni.tag, .fields = typechecker.typeTable.get(uni.tag).Enum.fields },
        else => return common.debug.ShouldBeImpossible(undefined, @src()),
    };

    const switchEnd = try exec.generateRandomName(.SwitchEnd);

    const caseRange = defines.Range{
        .start = ast.extra[extraPtr + 1],
        .end = ast.extra[extraPtr + 2],
    };

    var ptrs = typechecker.arena.allocator().alloc(JIR.Ptr, @divFloor(caseRange.len(), 4) + 1)
        catch return Error.AllocatorFailure;

    var idx: u32 = 0;
    while (idx < caseRange.len()) : (idx += 4) {
        const caseIndex = ast.extra[caseRange.at(idx)];

        if (caseIndex == Parser.AnyType) {
            const bodyPtr = ast.extra[caseRange.at(idx + 3)];
            const body = try self.statement(bodyPtr);

            if (maybeComptimeEnumOrUnion) |_| {
                return body;
            }
            else {
                ptrs[@divFloor(idx, 4)] = body;
                continue;
            }
        }

        const caseValue = exec.getValue(try exec.eval(caseIndex, tag.type)).Enum.Value;


        const case = try self.expression(caseIndex, tag.type);

        const caseEnd = try exec.generateRandomName(.CaseEnd);
        const cnd =
            if (typeInfo == .Union) res: {
                const tagFieldName = try typechecker.builder.internString("tag");
                const tagField = try typechecker.builder.dot(enumOrUnion, tagFieldName);
                break :res try typechecker.builder.notEqual(tagField, case);
            }
            else try typechecker.builder.notEqual(enumOrUnion, case);

        const caseJump = try typechecker.builder.cjump(caseEnd, cnd);

        const captureCount = ast.extra[caseRange.at(idx + 1)];
        const bodyPtr = ast.extra[caseRange.at(idx + 3)];

        const switchFull = res: {
            if (captureCount == 1) {
                const caseField = typeInfo.Union.fields[caseValue + 1];

                const nameStr = tokens
                                .get(ast.expressions.get(ast.extra[caseRange.at(idx + 2)]).value)
                                .lexeme(typechecker.context, ast.tokens);

                const name = try typechecker.builder.internString(nameStr);
                const capture = try typechecker.builder.variableDef(
                    false,
                    caseField.valueType,
                    name,
                    false,
                    try typechecker.builder.dot(enumOrUnion, caseField.name),
                );

                const body = try self.statement(bodyPtr);

                if (maybeComptimeEnumOrUnion) |val| {
                    switch (val) {
                        .Union => |uni|
                            if (uni.Tag == caseValue) {
                                return typechecker.builder.scope(
                                    try exec.generateRandomName(.Case), &.{
                                        capture,
                                        body,
                                    },
                                );
                            },

                        .Enum => |enm|
                            if (enm.Value == caseValue) {
                                return typechecker.builder.scope(
                                    try exec.generateRandomName(.Case), &.{
                                        capture,
                                        body,
                                    },
                                );
                            },

                        else => return common.debug.ShouldBeImpossible(undefined, @src()),
                    }
                }

                const caseEndLbl = try typechecker.builder.label(caseEnd);

                break :res try typechecker.builder.scope(
                    try exec.generateRandomName(.Case), &.{
                        caseJump,
                        capture,
                        body,
                        try typechecker.builder.jump(switchEnd),
                        caseEndLbl,
                    },
                );
            }
            else {
                const body = try self.statement(bodyPtr);

                if (maybeComptimeEnumOrUnion) |val| {
                    switch (val) {
                        .Union => |uni|
                            if (uni.Tag == caseValue) {
                                return body;
                            },

                        .Enum => |enm| {
                            if (enm.Value == caseValue)
                                return body;
                        },

                        else => return common.debug.ShouldBeImpossible(undefined, @src()),
                    }
                }

                const caseEndLbl = try typechecker.builder.label(caseEnd);

                break :res try typechecker.builder.scope(
                    try exec.generateRandomName(.Case), &.{
                        caseJump,
                        body,
                        try typechecker.builder.jump(switchEnd),
                        caseEndLbl,
                    },
                );
            }
        };

        ptrs[@divFloor(idx, 4)] = switchFull;
    }

    const switchEndLabel = try typechecker.builder.label(switchEnd); 
    ptrs[@divFloor(caseRange.len(), 4)] = switchEndLabel;

    return typechecker.builder.scope(
        try exec.generateRandomName(.Switch),
        ptrs,
    );
}

fn inlineC(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const src = self.typechecker.context.getFile(ast.tokens);

    const cstart = ast.extra[extraPtr];
    const cend = ast.extra[extraPtr + 1];
    const code = try self.typechecker.builder.internString(src[cstart..cend]);

    const res = try self.typechecker.builder.inlineC(code);

    return res; 
}

fn assignment(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const vexpr = ast.extra[extraPtr];
    const rexpr = ast.extra[extraPtr + 1];
    const vt = try self.typechecker.typecheckExpression(vexpr, null);

    const prev = self.typechecker.folder.setFlag(.ComptimeBanned, true);
    const expr = try self.expression(vexpr, vt);
    _ = self.typechecker.folder.setFlag(.ComptimeBanned, prev);

    const rhs = try self.expression(rexpr, vt);

    const res = try self.typechecker.builder.assignment(expr, rhs);
    return res; 
}

fn variableDef(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const declPtr = ast.extra[extraPtr + 2];

    // @Beware typecheckDecl must be before getDecl because names are
    // overwritten in typecheckDecl.
    const typeID = try self.typechecker.typecheckDecl(declPtr, null);
    const decl = self.typechecker.symbols.getDecl(declPtr);

    if (typeID == Comptime.Folder.Builtin.Type("type")) {
        const vdef = try self.typechecker.builder.typeDef(
            self.typechecker.folder.getValue(
                try self.typechecker.folder.eval(decl.node, null),
            ).Type,
        );
        return vdef;
    }

    const node =
        if (self.typechecker.context.settings.canFold())
            if (self.typechecker.folder.attemptEval(decl.node, typeID)) |someVal|
                try self.typechecker.builder.literal(try self.addConstant(someVal, typeID))
            else try self.expression(decl.node, typeID)
        else
            try self.expression(decl.node, typeID);

    const def = try self.typechecker.builder.variableDef(
        decl.topLevel,
        typeID,
        decl.name,
        if (self.typechecker.context.settings.canFold())
            if (self.typechecker.folder.attemptEval(decl.node, typeID)) |i| self.typechecker.folder.getValue(i) == .Undefined
            else false
        else false,
        node,
    );
    return def; 
}

fn @"defer"(self: *Lowerer, stmtPtr: defines.StatementPtr) Error!JIR.Ptr {
    const deferCount = self.scopes.pop() orelse {
        self.report("Defer statement outisde deferrable scope.", .{});
        return Error.DeferOutsideDeferrableScope;
    };
    try self.scopes.push(deferCount + 1);
    try self.defers.push(stmtPtr);
    return 0;
}

fn @"continue"(self: *Lowerer) Error!JIR.Ptr {
    const startLabel = std.fmt.allocPrint(
        self.typechecker.arena.allocator(),
        "{s}_Start", .{
            self.lastLoop,
        },
    ) catch return Error.AllocatorFailure;

    // _ = try self.unwindDefers(self.scopes.index - self.lastLoopDepth);

    const end = try self.typechecker.builder.jump(
        try self.typechecker.builder.internString(startLabel),
    );

    return end;
}

fn @"break"(self: *Lowerer) Error!JIR.Ptr {
    const endLabel = std.fmt.allocPrint(
        self.typechecker.arena.allocator(),
        "{s}_End", .{
            self.lastLoop,
        },
    ) catch return Error.AllocatorFailure;

    // const start = try self.unwindDefers(self.scopes.index - self.lastLoopDepth);

    const end = try self.typechecker.builder.jump(
        try self.typechecker.builder.internString(endLabel),
    );

    return end;
}

fn loop(
    self: *Lowerer,
    loopType: enum {
        While,
        For,
    },
    extraPtr: defines.OpaquePtr,
    ast: *const Parser.AST,
) Error!JIR.Ptr {
    if (loopType == .For) return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());

    const loopLabel = try self.typechecker.folder.generateRandomNameString(.Loop);
    self.lastLoop = loopLabel;

    const startLabel = try self.typechecker.builder.internString(
        std.fmt.allocPrint(
            self.typechecker.arena.allocator(),
            "{s}_Start", .{
                loopLabel,
            }
        ) catch return Error.AllocatorFailure
    );

    const cndLabel = try self.typechecker.builder.internString(
        std.fmt.allocPrint(
            self.typechecker.arena.allocator(),
            "{s}_Check", .{
                loopLabel,
            }
        ) catch return Error.AllocatorFailure
    );


    const conditionPtr = ast.extra[extraPtr];

    if (self.typechecker.context.settings.canFold()) {
        if (self.typechecker.folder.attemptEval(conditionPtr, Comptime.Folder.Builtin.Type("bool"))) |res| {
            if (self.typechecker.folder.getValue(res).Bool) {
                var loopData: [3]JIR.Ptr = undefined;

                const bodyPtr = ast.extra[extraPtr + 1];
                self.lastLoopDepth = self.scopes.index;
                const start = try self.typechecker.builder.label(startLabel);
                loopData[0] = start;
                loopData[1] = try self.statement(bodyPtr);
                loopData[2] = try self.typechecker.builder.jump(startLabel);

                return self.typechecker.builder.scope(
                    try self.typechecker.folder.generateRandomName(.Block),
                    &loopData,
                );
            }
            else {
                return self.typechecker.builder.label(try self.typechecker.folder.generateRandomName(.OptimizedLoop));
            }
        }
        else {
            return self.typechecker.builder.label(try self.typechecker.folder.generateRandomName(.OptimizedLoop));
        }
    }

    const cnd = try self.expression(conditionPtr, Comptime.Folder.Builtin.Type("bool"));

    var loopData: [5]JIR.Ptr = undefined;

    loopData[0] = try self.typechecker.builder.jump(cndLabel);
    const bodyPtr = ast.extra[extraPtr + 1];
    self.lastLoopDepth = self.scopes.index;
    const start = try self.typechecker.builder.label(startLabel);
    loopData[1] = start;
    loopData[2] = try self.statement(bodyPtr);
    loopData[3] = try self.typechecker.builder.label(cndLabel);
    loopData[4] = try self.typechecker.builder.cjump(startLabel, cnd);

    return self.typechecker.builder.scope(
        try self.typechecker.folder.generateRandomName(.Block),
        &loopData,
    );
}

fn conditional(self: *Lowerer, extraPtr: defines.OpaquePtr, ast: *const Parser.AST) Error!JIR.Ptr {
    const conditionExpr = ast.extra[extraPtr];

    if (self.typechecker.context.settings.canFold()) {
        if (self.typechecker.folder.attemptEval(conditionExpr, null)) |comptimeConditionPtr| {
            const comptimeCondition = self.typechecker.folder.getValue(comptimeConditionPtr).Bool;

            if (comptimeCondition) {
                return self.statement(ast.extra[extraPtr + 1]);
            }

            if (ast.extra[extraPtr + 2] == 1) {
                return self.statement(ast.extra[extraPtr + 3]);
            }

            return self.typechecker.builder.label(try self.typechecker.folder.generateRandomName(.OptimizedConditional));
        }
    }

    const elseLabel = try self.typechecker.folder.generateRandomName(.Else);
    const finallyLabel = try self.typechecker.folder.generateRandomName(.Finally);

    const cnd = try self.typechecker.builder.not(try self.expression(conditionExpr, Comptime.Folder.Builtin.Type("bool")));

    const maybeElse =
        if (ast.extra[extraPtr + 2] == 1) ast.extra[extraPtr + 3]
        else null;

    var data: [6]JIR.Ptr = undefined;

    const start = try self.typechecker.builder.cjump(
        if (maybeElse) |_| elseLabel else finallyLabel,
        cnd
    );
    data[0] = start;

    const body = ast.extra[extraPtr + 1];
    data[1] = try self.statement(body);

    data[2] = try self.typechecker.builder.jump(finallyLabel);

    if (maybeElse) |elseBranch| {
        data[3] = try self.typechecker.builder.label(elseLabel);
        data[4] = try self.statement(elseBranch);
        data[5] = try self.typechecker.builder.label(finallyLabel);
    }
    else {
        data[3] = try self.typechecker.builder.label(finallyLabel);
    }

    return self.typechecker.builder.scope(
        try self.typechecker.folder.generateRandomName(.Block),
        if (maybeElse) |_| data[0..6] else data[0..4]
    );
}

fn expressionStmt(self: *Lowerer, expr: defines.ExpressionPtr) Error!JIR.Ptr {
    const exprType = self.typechecker.typecheckExpression(expr, null)
        catch return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
    return self.expression(expr, exprType);
}

fn @"return"(self: *Lowerer, expr: JIR.Ptr) Error!JIR.Ptr {
    // const end = try self.unwindDefers(self.scopes.index);
    const start = try self.typechecker.builder.@"return"(expr);
    return start;
}

fn block(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const statements = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    try self.scopes.push(0);

    _ = self.typechecker.builder.data.addOne(self.typechecker.builder.allocator)
        catch return Error.AllocatorFailure;

    // const start = try self.typechecker.builder.scope(
    //    try self.typechecker.executer.generateRandomNameSanitized(.Block),
    // );

    const stmts = self.typechecker.builder.allocator.alloc(JIR.Ptr, statements.len())
        catch return Error.AllocatorFailure;

    for (statements.start..statements.end, 0..) |stmt, i| {
        stmts[i] = try self.statement(ast.extra[@intCast(stmt)]);
    }

    const deferCount = self.scopes.pop() orelse 0;
    for (0..deferCount) |_| {
        const stmtPtr = self.defers.pop()
            orelse return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());

        if (!self.typechecker.getFlag(.CoveredAllPaths)) {
            _ = try self.statement(stmtPtr);
        }
    }

    return self.typechecker.builder.scope(
        try self.typechecker.folder.generateRandomName(.Block),
        stmts,
    );
}


//
// Expression
//

pub fn expression(self: *Lowerer, exprPtr: defines.ExpressionPtr, ofType: TypeID) Error!JIR.Ptr {
    if (self.typechecker.folder.attemptEval(exprPtr, ofType)) |_| {
        return self.literal(exprPtr, ofType);
    }

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expr = ast.expressions.get(exprPtr);
    return switch (expr.type) {
        .Literal => self.literal(exprPtr, ofType),
        .Mark => self.mark(expr.value, ofType),
        .Identifier => self.identifier(exprPtr),

        .Scoping => self.scoping(expr.value),

        .EnumDefinition, .StructDefinition, .UnionDefinition,
        .FunctionType, .ArrayType,
        .CPointerType, .MutableType, .PointerType,
        .Lambda, .FunctionDefinition,
        .SliceType => self.typechecker.builder.comptimeDef(exprPtr),

        .Assignment => {
            self.report(
                "Hello, whomever changed the codebase to such a state that "
                ++ "the typechecker is now all screwed up. Due to your ingenius, "
                ++ "the lowerer now treats assignments as expressions, rather than "
                ++ "statements. I won't give you any further information about the "
                ++ "matter. I won't even give a stacktrace for you to debug.",
                .{}
            );
            return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
        },

        .Binary => self.binary(expr.value, ofType),
        .Unary => self.unary(expr.value, ofType),
        .Conditional => self.conditionalExpr(expr.value, ofType),
        .Dot => self.dot(expr.value),
        .Indexing => self.indexing(expr.value),
        .ExpressionList => self.expressionList(expr.value, ofType),

        .Call => self.call(false, exprPtr, expr.value, ofType),

        .Switch => self.switchExpr(expr.value, ofType),

        .Slicing => self.slicing(expr.value, ofType),
    };
}

fn scoping(self: *Lowerer, _extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    var extraPtr = _extraPtr;
    var rightMost: u32 = 0;
    var leftMost: u32 = 0;
    var namespace: []const u8 = "";

    while (true) {
        const lhs = ast.extra[extraPtr];
        const rhs = ast.extra[extraPtr + 1];
        
        const rtoken = tokens.get(rhs);
        rightMost = rtoken.end;
        leftMost = rtoken.start;

        if (self.typechecker.symbols.resolutionMap.get(.{
            .expr = lhs,
            .file = ast.tokens,
        })) |decl| {
            namespace = self.typechecker.context.moduleNameMap.items[self.typechecker.symbols.getDecl(decl).node];
            break;
        }

        extraPtr = ast.expressions.get(lhs).value;
    }

    const member = self.typechecker.context.getFile(ast.tokens)[leftMost..rightMost];
    const qualified = std.fmt.allocPrint(self.typechecker.builder.allocator, "{s}__{s}", .{
        namespace,
        member,
    }) catch return Error.AllocatorFailure;

    _ = std.mem.replace(u8, qualified, "::", "__", qualified);
    _ = std.mem.replace(u8, qualified, "$$", "__", qualified);

    const id = try self.typechecker.builder.internString(qualified);
    return self.typechecker.builder.identifier(id);
}

fn slicing(self: *Lowerer, extraPtr: defines.OpaquePtr, ofType: TypeID) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const sliceable = try self.expression(ast.extra[extraPtr], try self.typechecker.typecheckExpression(ast.extra[extraPtr], null));
    const sliceableInfo = self.typechecker.typeTable.get(try self.typechecker.typecheckExpression(ast.extra[extraPtr], null));

    const data = switch (sliceableInfo) {
        .Array => try self.typechecker.builder.dot(sliceable, try self.typechecker.builder.internString("data")),
        .Pointer => |ptr| switch (ptr.size) {
            .C => sliceable,
            .Slice => try self.typechecker.builder.dot(sliceable, try self.typechecker.builder.internString("ptr")),
            else => return common.debug.ShouldBeImpossible(undefined, @src()),
        },
        else => return common.debug.ShouldBeImpossible(undefined, @src()),
    };

    const start = try self.expression(ast.extra[extraPtr + 1], try self.typechecker.typecheckExpression(ast.extra[extraPtr + 1], null));
    const end = try self.expression(ast.extra[extraPtr + 2], try self.typechecker.typecheckExpression(ast.extra[extraPtr + 2], null));

    const length = try self.typechecker.builder.sub(
        end,
        start,
    );
    const index = try self.typechecker.builder.add(
        data,
        start,
    );

    const newType = try self.typechecker.registerType(.{ .Pointer =
        if (sliceableInfo == .Array) .{
            .size = .Slice,
            .child = sliceableInfo.Array.child,
            .mutable = self.typechecker.mutable(ofType),
        }
        else .{
            .size = .Slice,
            .child = sliceableInfo.Pointer.child,
            .mutable = self.typechecker.mutable(ofType),
        },
    });

    return self.typechecker.builder.construct(newType, &.{index, length});
}

fn switchExpr(self: *Lowerer, extraPtr: defines.OpaquePtr, ofType: TypeID) Error!JIR.Ptr {
    var typechecker = self.typechecker;

    const ast = typechecker.context.getAST(self.typechecker.currentFile);

    const enumOrUnionType = try typechecker.typecheckExpression(ast.extra[extraPtr], null);
    const enumOrUnion = try self.expression(ast.extra[extraPtr], enumOrUnionType);
    const typeInfo = typechecker.typeTable.get(enumOrUnionType);
    const tag: struct { type: TypeID, fields: []const []const u8 } = switch (typeInfo) {
        .Enum => |enm| .{ .type = enumOrUnionType, .fields = enm.fields },
        .Union => |uni| .{ .type = uni.tag, .fields = typechecker.typeTable.get(uni.tag).Enum.fields },
        else => return common.debug.ShouldBeImpossible(undefined, @src()),
    };

    const caseRange = defines.Range{
        .start = ast.extra[extraPtr + 1],
        .end = ast.extra[extraPtr + 2],
    };
    const numCases = @divFloor(caseRange.len(), 4);

    var conds = typechecker.arena.allocator().alloc(JIR.Ptr, numCases)
        catch return Error.AllocatorFailure;
    var vals = typechecker.arena.allocator().alloc(JIR.Ptr, numCases)
        catch return Error.AllocatorFailure;
    var defaultVal: ?JIR.Ptr = null;
    var written: u32 = 0;

    var idx: u32 = 0;
    while (idx < caseRange.len()) : (idx += 4) {
        const caseIndex = ast.extra[caseRange.at(idx)];
        const bodyPtr = ast.extra[caseRange.at(idx + 3)];
        const captureCount = ast.extra[caseRange.at(idx + 1)];

        if (captureCount != 0) {
            return common.debug.NotImplemented(self.typechecker.context.log, @src());
        }

        if (caseIndex == Parser.AnyType) {
            defaultVal = try self.expression(bodyPtr, ofType);
            continue;
        }

        const case = try self.expression(caseIndex, tag.type);

        const cnd = if (typeInfo == .Union) res: {
            const tagFieldName = try typechecker.builder.internString("tag");
            const tagField = try typechecker.builder.dot(enumOrUnion, tagFieldName);
            break :res try typechecker.builder.equal(tagField, case);
        } else try typechecker.builder.equal(enumOrUnion, case);

        conds[written] = cnd;
        vals[written] = try self.expression(bodyPtr, ofType);
        written += 1;
    }

    var result: JIR.Ptr = defaultVal orelse
        return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());

    var j: u32 = written;
    while (j > 0) {
        j -= 1;
        result = try typechecker.builder.ternary(conds[j], vals[j], result);
    }

    return result;
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

    if (ast.expressions.items(.type)[func] == .Identifier) blk: {
        if (self.typechecker.symbols.resolutionMap.get(.{
            .file = self.typechecker.currentFile,
            .expr = func,
        })) |builtinPtr| {
            const decl = self.typechecker.symbols.declarations.get(builtinPtr);

            if (decl.kind != .Builtin) {
                break :blk;
            }
            if (Comptime.Folder.Builtin.isBuiltinType(decl.type)) {
                break :blk;
            }

            return self.builtinCall(extraPtr, decl.type, ofType);
        }
    }

    const args = self.typechecker.builder.allocator.alloc(JIR.Ptr, argsRange.len())
        catch return Error.AllocatorFailure;

    const funcType = try self.typechecker.typecheckExpression(func, null);
    const fti = self.typechecker.typeTable.get(funcType);

    for (argsRange.start..argsRange.end, 0..) |ptr, i| {
        args[i] = try self.expression(ast.extra[@intCast(ptr)], try self.typechecker.typecheckExpression(ast.extra[@intCast(ptr)], switch (fti) {
            .Function => |function| function.argTypes[i],
            else => null,
        }));
    }

    return switch (self.typechecker.typeTable.get(funcType)) {
        .Type => blk: {
            const typeID = self.typechecker.folder.getValue(
                try self.typechecker.folder.expectType(func),
            ).Type;
            break :blk self.typechecker.builder.construct(typeID, args);
        },
        .Function => |fnc|
            // @TODO inline functions
            if (fnc.isComptime) self.literal(exprPtr, ofType)
            else self.typechecker.builder.call(
                stmt,
                try self.expression(func, funcType),
                args
            ),
        else => common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
    };
}

fn builtinCall(
    self: *Lowerer,
    extraPtr: defines.OpaquePtr,
    declPtr: defines.DeclPtr,
    ofType: TypeID,
) Error!JIR.Ptr {
    const BI = Resolver.BuiltinIndex;
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const exprlst = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[exprlst],
        .end = ast.extra[exprlst + 1],
    };

    return switch (declPtr) {
        BI("cast"), BI("unsafeCast") => self.cast(extraPtr, ofType),
        BI("as") =>
            self.expression(ast.extra[args.at(1)], try self.typechecker.expectType(ast.extra[args.at(0)])),
        BI("typeOf") =>
            self.literal(ast.extra[args.at(0)], ofType),
        BI("unreachable") => blk: {
            const builtinUnreach = try self.identifier(try self.typechecker.builder.internString("__builtin_unreachable"));
            break :blk self.typechecker.builder.call(true, builtinUnreach, &.{});
        },
        BI("compileLog"), BI("compileError") => 0,

        else => common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
    };
}

fn cast(self: *Lowerer, extraPtr: defines.OpaquePtr, ofType: TypeID) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const exprlst = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[exprlst],
        .end = ast.extra[exprlst + 1],
    };

    const rtype = try self.typechecker.typecheckExpression(ast.extra[args.at(0)], null);
    const rexpr = try self.expression(ast.extra[args.at(0)], rtype);

    const targetInfo = self.typechecker.typeTable.get(ofType);
    const rtypeInfo = self.typechecker.typeTable.get(rtype);

    return res: switch (targetInfo) {
        .Pointer => |tptr| switch (rtypeInfo) {
            .Pointer => |rptr|
                if (tptr.size == .Slice and rptr.size == .Slice) {
                    const ptr = try self.typechecker.builder.dot(
                        rexpr,
                        try self.typechecker.builder.internString("ptr"),
                    );

                    const len = try self.typechecker.builder.dot(
                        rexpr,
                        try self.typechecker.builder.internString("len"),
                    );

                    const itemSize = try self.typechecker.builder.literal(
                        try self.typechecker.builder.addConstant(.{
                            .Integer = .{ .u32 = blk: {
                                const newLen = self.typechecker.sizeOf(rptr.child) / 8;
                                break :blk if (newLen == 0) 1 else newLen;
                            } },
                        })
                    );

                    const newItemSize = try self.typechecker.builder.literal(
                        try self.typechecker.builder.addConstant(.{
                            .Integer = .{ .u32 = blk: {
                                const newItemSize = self.typechecker.sizeOf(tptr.child) / 8;
                                break :blk if (newItemSize == 0) 1 else newItemSize;
                            } },
                        })
                    );

                    const newSize = try self.typechecker.builder.div(
                        try self.typechecker.builder.mul(len, itemSize),
                        newItemSize,
                    );

                    break :res self.typechecker.builder.construct(ofType, &.{ptr, newSize});
                }
                else return common.debug.ShouldBeImpossible(undefined, @src()),

                else => return common.debug.ShouldBeImpossible(undefined, @src()),
        },
        else => self.typechecker.builder.construct(ofType, &.{rexpr}),
    };
}

fn expressionList(self: *Lowerer, extraPtr: defines.OpaquePtr, expected: TypeID) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const exprs = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    const exs = self.typechecker.builder.allocator.alloc(JIR.Ptr, exprs.len())
        catch return Error.AllocatorFailure;

    const eti = self.typechecker.typeTable.get(expected);

    if (exprs.len() == 1 and switch (eti) { .Struct, .Union, .Enum, .Array => true, else => false }) {
        const innerType = try self.typechecker.typecheckExpression(ast.extra[exprs.start], expected);
        if (self.typechecker.suitable(expected, innerType)) {
            return self.expression(ast.extra[exprs.start], expected);
        }
    }

    for (exprs.start..exprs.end, 0..) |exprPtr, i| {
        const t = try self.typechecker.typecheckExpression(ast.extra[@intCast(exprPtr)], switch (eti) {
            .Array => |arr| arr.child,
            .Struct => |str| str.fields[i].valueType,
            .Union => |uni| uni.fields[i].valueType,
            .Function => |func| func.argTypes[i],
            else => expected,
        });
        exs[i] = try self.expression(ast.extra[@intCast(exprPtr)], t);
    }

    return switch (eti) {
        .Array, .Struct, .Union => self.typechecker.builder.construct(expected, exs),
        else => self.typechecker.builder.grouping(exs)
    };
}

fn indexing(self: *Lowerer, extraPtr: defines.OpaquePtr) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const exprPtr = ast.extra[extraPtr];
    const typeID = try self.typechecker.typecheckExpression(exprPtr, null);

    const indexable = blk: switch (self.typechecker.typeTable.get(typeID)) {
        .Array => {
            const arr = try self.expression(exprPtr, typeID);
            break :blk try self.typechecker.builder.dot(arr, try self.typechecker.builder.internString("data"));
        },
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => {
                const slice = try self.expression(exprPtr, typeID);
                break :blk try self.typechecker.builder.dot(slice, try self.typechecker.builder.internString("ptr"));
            },
            else => try self.expression(exprPtr, typeID),
        },
        else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
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

    var obj = try self.expression(exprPtr, exprType);
    const member = tokens
                    .get(ast.extra[extraPtr + 1])
                    .lexeme(self.typechecker.context, self.typechecker.currentFile);

    const ref = std.mem.eql(u8, member, "&");
    const deref = std.mem.eql(u8, member, "*");

    switch (self.typechecker.typeTable.get(exprType)) {
        .Array => |arr|
            if (std.mem.eql(u8, member, "ptr")) {
                const data = try self.typechecker.builder.internString("data");
                return try self.typechecker.builder.dot(obj, data);
            }
            else if (std.mem.eql(u8, member, "len")) return try self.typechecker.builder.literal(
                try self.typechecker.builder.addConstant(.{ .Integer = .{ .u32 = arr.len } }),
            )
            else if (ref) {
                const len = try self.typechecker.builder.literal(try self.typechecker.builder.addConstant(.{ .Integer = .{ .u32 = arr.len } }));
                const data = try self.typechecker.builder.dot(obj, try self.typechecker.builder.internString("data"));
                return try self.typechecker.builder.construct(try self.typechecker.sliceOf(exprType), &.{data, len});
            }
            else {
                const data = try self.typechecker.builder.internString("data");
                obj = try self.typechecker.builder.dot(obj, data);
            },
        .Pointer => |ptr| switch (self.typechecker.typeTable.get(ptr.child)) {
            .Struct, .Union => return
                if (ref) self.typechecker.builder.reference(obj)
                else if (deref) self.typechecker.builder.dereference(obj)
                else self.typechecker.builder.reference(
                    try self.typechecker.builder.dot(
                        try self.typechecker.builder.dereference(obj),
                        try self.typechecker.builder.internString(member)
                    )
                ),
            else => { },
        },
        else => { },
    }

    return
        if (ref) self.typechecker.builder.reference(obj)
        else if (deref) self.typechecker.builder.dereference(obj)
        else self.typechecker.builder.dot(obj, try self.typechecker.builder.internString(member));
}

fn conditionalExpr(self: *Lowerer, extraPtr: defines.OpaquePtr, ofType: TypeID) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const cndPtr = ast.extra[extraPtr];
    const thenPtr = ast.extra[extraPtr + 1];
    const otherPtr = ast.extra[extraPtr + 2];

    const cnd = try self.expression(cndPtr, Comptime.Folder.Builtin.Type("bool"));
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
        else => common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
    };
}

fn binary(self: *Lowerer, extraPtr: defines.OpaquePtr, ofType: TypeID) Error!JIR.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const op = @as(Lexer.TokenType, @enumFromInt(ast.extra[extraPtr + 1]));

    const operandType = switch (op) {
        .BangEqual, .EqualEqual, .GreaterEqual, .LesserEqual, .Lesser, .Greater =>
            try self.typechecker.typecheckExpression(ast.extra[extraPtr], null),
        .And, .Or => Comptime.Folder.Builtin.Type("bool"),
        else => ofType,
    };

    const lhs = try self.expression(ast.extra[extraPtr], operandType);
    const rhs = try self.expression(ast.extra[extraPtr + 2], operandType);

    return switch (op) {
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
        .Modulo => self.typechecker.builder.mod(lhs, rhs),
        else => common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
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
    const valuePtr = try self.typechecker.folder.eval(exprPtr, null);
    const constant = try self.addConstant(valuePtr, ofType);
    return self.typechecker.builder.literal(constant);
}

fn report(self: *Lowerer, comptime fmt: []const u8, args: anytype) void {
    _ = self.typechecker.setFlag(.AttemptingEval, false);
    return self.typechecker.report("LOWERER: " ++ fmt, args);
}
