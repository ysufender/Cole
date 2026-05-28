// @Note Lowering to C IR is requested by the typechecker,
// but it is done by the lowerer.zig, which makes calls to
// JIR.Builder since JIR.Builder itself doesn't know about
// untyped AST.
//
// @Note Defer statements are properly handled in codegen.
// typechecker only typechecks.

const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const functional = @import("../util/functional.zig");
const Types = @import("type.zig");
const backend = @import("../codegen/backend.zig");

const Lowerer = @import("lowerer.zig");
const Parser = @import("../parser/parser.zig");
const Comptime = @import("comptime.zig");
const Resolver = @import("resolver.zig");
const ModuleList = @import("../parser/prepass.zig").ModuleList;
const Lexer = @import("../lexer/lexer.zig");
const TypeInfo = Types.TypeInfo;
const TypeID = Types.TypeID;
const MultiArrayList = std.MultiArrayList;
const Error = common.CompilerError;
const Context = common.CompilerContext;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Callstack = collections.StaticRingStack(defines.DeclPtr, defines.stackLimit);
const FlagMap = std.bit_set.IntegerBitSet(8);

const BuiltinIndex = Resolver.BuiltinIndex;
const deepCopy = collections.deepCopy;
const assert = std.debug.assert;
const eql = std.meta.eql;

pub const TypeTable = MultiArrayList(TypeInfo);
pub const TypeMap = collections.HashMap(TypeInfo, TypeID);
pub const MetadataMap = collections.HashMap(Element, []const Comptime.Value.Ptr);
const LookupMap = collections.HashMap(defines.DeclPtr, TypecheckStatus);

pub const Flags = enum(u8) {
    ConcreteValue = 1,
    LValue = 2,
    AttemptingEval = 3,
    CanCycle = 4,
    NoReturn = 5,
    MustReturn = 6,
    CoveredAllPaths = 7,
    InLoop = 8,

    pub fn flag(flagToGet: Flags) u8 {
        return @intFromEnum(flagToGet);
    }
};

const TypecheckStatus = struct {
    status: enum {
        Checked,
        InProgress,
        NotChecked,
    },

    result: TypeID,
};

pub const Element = struct {
    pub const Kind = enum {
        Statement,
        Expression,
    };

    kind: Kind,
    value: defines.OpaquePtr,
};

pub const Resolution = backend.C.JIR;

const Typechecker = @This();

arena: Arena,
context: *Context,
modules: *const ModuleList,
symbols: *const Resolver.Resolution,

typeTable: TypeTable,
typeMap: TypeMap,
lookup: LookupMap,
metadata: MetadataMap,

executer: Comptime,

currentFile: defines.FilePtr,
currentScope: defines.ScopePtr,
lastToken: defines.TokenPtr,
callstack: Callstack,
flags: FlagMap,

builder: backend.C.JIR.Builder,
lowerer: Lowerer,
typenameMap: std.AutoHashMapUnmanaged(TypeID, defines.StringPtr),

pub fn init(
    gpa: Allocator,
    context: *Context,
    modules: *const ModuleList,
    symbolTable: *const Resolver.Resolution
) Error!Typechecker {
    var arena = Arena.init(gpa);
    const allocator = arena.allocator();

    const counts = context.counts;
    const typeCount = counts.types * 3 + @as(u32, @intCast(Comptime.builtinTypes.len));

    var typeTable = TypeTable{};
    typeTable.ensureTotalCapacity(allocator, typeCount + @as(u32, @intCast(Comptime.builtinTypes.len)))
        catch return Error.AllocatorFailure;
    var typeMap = TypeMap.empty;
    var metadata = MetadataMap.empty;
    var lookup = LookupMap.empty;

    typeMap.ensureTotalCapacity(allocator, typeCount + @as(u32, @intCast(Comptime.builtinTypes.len))) catch return Error.AllocatorFailure;
    lookup.ensureTotalCapacity(allocator, symbolTable.declarations.len) catch return Error.AllocatorFailure;
    metadata.ensureTotalCapacity(allocator, counts.meta * 3) catch return Error.AllocatorFailure;

    var builder = try backend.C.JIR.Builder.init(allocator, counts);

    inline for (Comptime.builtinTypes, 0..) |builtin, id| {
        typeTable.appendAssumeCapacity(builtin.info);
        typeMap.putAssumeCapacityNoClobber(builtin.info, @intCast(id));
        _ = try builder.internString(builtin.name);
    }

    return .{
        .context = context,
        .modules = modules,
        .typeTable = typeTable,
        .typeMap = typeMap,
        .metadata = metadata,
        .lookup = lookup,
        .flags = FlagMap.initEmpty(),
        .executer = undefined,
        .builder = builder,
        .lowerer = undefined,
        .symbols = symbolTable,
        .currentFile = 0,
        .currentScope = 0,
        .lastToken = 0,
        .callstack = .{},
        .typenameMap = .empty,
        .arena = arena,
    };
}

pub fn typecheck(self: *Typechecker, allocator: Allocator) Error!Resolution {
    if (!self.modules.getItem("root", .symbolPtrs).contains("main")) {
        self.report("Couldn't find an entry point in the root module.", .{});
        return Error.MissingDefinition;
    }

    self.builder.allocator = self.arena.allocator();
    self.executer = try Comptime.init(self, allocator);
    self.lowerer = Lowerer.init(self);

    defer self.arena.deinit();
    defer self.executer.deinit();

    // TODO:                                             This part is not really nice, fix it.
    const mainPtr = self.symbols.lookup.get(.{ .scope = self.modules.modules.len - 1, .name = "main" }).?;
    const mainDecl = self.symbols.getDecl(mainPtr);

    if (mainDecl.public) {
        self.report("Expected entry point 'main' to be private.", .{});
        return Error.PublicEntryPoint;
    }

    const mainType = try self.typecheckDecl(mainPtr, null);
    self.clearFlags();
    if (mainType != Comptime.Builtin.Type("entry_point")) {
        const main = self.symbols.getDecl(mainPtr);
        self.lastToken = main.token;
        self.report("Unexpected type of entry point 'main'. Expected '{s}', received '{s}'", .{
            try self.typeName(allocator, Comptime.Builtin.Type("entry_point")),
            try self.typeName(allocator, mainType),
        });
        return Error.TypeMismatch;
    }

    return self.builder.build(allocator, self.typeTable.slice());
}

pub fn typecheckStatement(self: *Typechecker, statementPtr: defines.StatementPtr, expected: TypeID) Error!void {
    const ast = self.context.getAST(self.currentFile);

    const stmt = ast.statements.get(statementPtr);
    return switch (stmt.type) {
        .Block => self.typecheckBlock(stmt.value, expected),
        .Expression => self.typecheckExpressionStatement(stmt.value),
        .Conditional => self.typecheckIfStatement(stmt.value, expected),
        .Return => self.typecheckReturn(stmt.value, expected),
        .Discard => self.typecheckDiscard(stmt.value),
        .Switch => self.typecheckSwitchStatement(stmt.value, expected),
        .While => self.typecheckWhileStatement(stmt.value, expected),
        .Break, .Continue => self.typecheckLoopControl(stmt.value),
        .Import => common.debug.ShouldBeImpossible(@src()),
        // TODO: Continue with defer
        else => |t| {
            self.report("Typechecking of '{s}' statements is not implemented.", .{
                @tagName(t),
            });
            return common.debug.NotImplemented(@src());
        },
    };
}

fn typecheckLoopControl(self: *Typechecker, _: defines.OpaquePtr) Error!void {
    if (!self.getFlag(.InLoop)) {
        self.report("Loop control statement outside loop body.", .{});
        return Error.LoopControlOutsideLoopScope;
    }
}

fn typecheckWhileStatement(self: *Typechecker, extraPtr: defines.OpaquePtr, expected: TypeID) Error!void {
    const ast = self.context.getAST(self.currentFile);

    defer _ = self.setFlag(.CoveredAllPaths, false);

    const conditionPtr = ast.extra[extraPtr];
    const bodyPtr = ast.extra[extraPtr + 1];

    const condition = try self.typecheckExpression(conditionPtr, Comptime.Builtin.Type("bool"));
    if (!self.suitable(Comptime.Builtin.Type("bool"), condition)) {
        self.report("Expected a boolean for condition.", .{});
        return Error.TypeMismatch;
    }

    const prev = self.setFlag(.InLoop, true);
    defer _ = self.setFlag(.InLoop, prev);
    try self.typecheckStatement(bodyPtr, expected);
}

fn typecheckSwitchStatement(self: *Typechecker, extraPtr: defines.OpaquePtr, expected: TypeID) Error!void {
    const ast = self.context.getAST(self.currentFile);

    const item = ast.extra[extraPtr];
    const itemTypeID = try self.typecheckExpression(item, null);
    const itemType = self.typeTable.get(itemTypeID);

    switch (itemType) {
        .Enum => { },
        .Union => |uni| if (!uni.isTagged) {
            self.report("Can't switch on untagged union type '{s}'", .{
                try self.typeName(self.arena.allocator(), itemTypeID),
            });
            return Error.SwitchOnPlainUnion;
        },
        else => {
            self.report("Can't switch on value of type '{s}'", .{
                try self.typeName(self.arena.allocator(), itemTypeID),
            });
            return Error.SwitchOnNonSwitchableValue;
        },
    }

    const range = defines.Range{
        .start = ast.extra[extraPtr + 1],
        .end = ast.extra[extraPtr + 2],
    };

    return switch (itemType) {
        .Enum => |enm| self.typecheckSwitchStatementOnEnum(ast, itemTypeID, &enm, range, expected),
        .Union => |uni| self.typecheckSwitchStatementOnUnion(ast, itemTypeID, &uni, range, expected),
        else => return common.debug.ShouldBeImpossible(@src()),
    };
}

fn typecheckSwitchStatementOnUnion(
    self: *Typechecker,
    ast: *const Parser.AST,
    itemTypeID: TypeID,
    uni: *const Types.Union,
    range: defines.Range,
    expected: TypeID,
) Error!void {
    // @Beware Hardcoded field size, must be kept in sync with parser.(union|struct|enum)Definition
    var fieldBuffer: [512]u32 = undefined;
    var bufferAllocator = std.heap.FixedBufferAllocator.init(@ptrCast(&fieldBuffer));

    const tag = self.typeTable.get(uni.tag).Enum;

    var fieldMap = std.DynamicBitSet.initEmpty(bufferAllocator.allocator(), tag.fields.len)
        catch return common.debug.ShouldBeImpossible(@src());

    var case = range.start;
    while (case < range.end) : (case += 4) {
        if (fieldMap.count() == fieldMap.capacity()) {
            self.report("Unreachable switch case.", .{ });
            return Error.UnreachableCodePath;
        }

        const caseLabel = ast.extra[case];
        const fieldName = 
            if (caseLabel == 0) blk: {
                fieldMap.setRangeValue(.{
                    .start = 0,
                    .end = fieldMap.capacity(),
                }, true);

                break :blk "else";
            }
            else blk: {
                const fieldPtr = try self.executer.eval(caseLabel, uni.tag);
                const field = self.executer.getValue(fieldPtr);

                const enumeration = switch (field) {
                    .Enum => |caseEnum| caseEnum.Value,
                    else => {
                        self.report("Expected a comptime enum for switch case label, received '{s}' instead.", .{
                            try self.typeName(self.arena.allocator(), try self.typecheckValue(fieldPtr, itemTypeID)),
                        });
                        return Error.InvalidSwitchCase;
                    }
                };

                if (fieldMap.isSet(enumeration)) {
                    self.report("Duplicate switch case '{s}'.", .{
                        tag.fields[enumeration],
                    });
                    return Error.DuplicateSwitchCase;
                }

                fieldMap.set(enumeration);
                break :blk tag.fields[enumeration];
            };

        const prev = self.currentScope;
        defer self.currentScope = prev;

        const captureCount = ast.extra[case + 1];
        if (captureCount > 1) {
            self.report("Value destruction is not supported.", .{ });
            return Error.IllegalSyntax;
        }
        else if (captureCount > 0)
        {
            const firstCapture = ast.extra[case + 2];

            const captureDecl = self.symbols.findDecl(.{
                .file = self.currentFile,
                .expr = firstCapture,
            });

            const field = try self.builder.internString(fieldName);
            const captureType = uni.fields[
                self.fieldIndex(itemTypeID, field) catch return common.debug.ShouldBeImpossible(@src())
            ].valueType;

            self.lookup.putNoClobber(self.arena.allocator(), captureDecl, .{
                .status = .Checked,
                .result = captureType,
            }) catch return Error.AllocatorFailure;
        }

        try self.typecheckStatement(ast.extra[case + 3], expected);
    }

    if (fieldMap.count() != fieldMap.capacity()) {
        common.log.err("Missing union fields:", .{});

        var iterator = fieldMap.iterator(.{
            .direction = .forward,
            .kind = .unset,
        });
        while (iterator.next()) |field| {
            const fieldName = tag.fields[field];
            common.log.err(("." ** 4) ++ " {s}", .{
                fieldName,
            });
        }

        self.report("In switch expression.", .{});
        return Error.UnhandledSwitchCases;
    }
}

fn typecheckSwitchStatementOnEnum(
    self: *Typechecker,
    ast: *const Parser.AST,
    itemTypeID: TypeID,
    enm: *const Types.Enum,
    range: defines.Range,
    expected: TypeID,
) Error!void {
    // @Beware Hardcoded field size, must be kept in sync with parser.(union|struct|enum)Definition
    var fieldBuffer: [512]u32 = undefined;
    var bufferAllocator = std.heap.FixedBufferAllocator.init(@ptrCast(&fieldBuffer));

    var fieldMap = std.DynamicBitSet.initEmpty(bufferAllocator.allocator(), enm.fields.len)
        catch return common.debug.ShouldBeImpossible(@src());

    var case = range.start;
    while (case < range.end) : (case += 4) {
        if (fieldMap.count() == fieldMap.capacity()) {
            self.report("Unreachable switch case.", .{ });
            return Error.UnreachableCodePath;
        }

        const caseLabel = ast.extra[case];
        if (caseLabel == 0) {
            fieldMap.setRangeValue(.{
                .start = 0,
                .end = fieldMap.capacity(),
            }, true);
        }
        else {
            const fieldPtr = try self.executer.eval(caseLabel, itemTypeID);
            const field = self.executer.getValue(fieldPtr);

            const enumeration = switch (field) {
                .Enum => |caseEnum| caseEnum.Value,
                else => {
                    self.report("Expected a comptime enum for switch case label, received '{s}' instead.", .{
                        try self.typeName(self.arena.allocator(), try self.typecheckValue(fieldPtr, itemTypeID)),
                    });
                    return Error.InvalidSwitchCase;
                }
            };

            if (fieldMap.isSet(enumeration)) {
                self.report("Duplicate switch case '{s}'.", .{
                    enm.fields[enumeration],
                });
                return Error.DuplicateSwitchCase;
            }

            fieldMap.set(enumeration);
        }

        const captureCount = ast.extra[case + 1];
        if (captureCount > 1) {
            self.report("Too many captures for context.", .{ });
            return Error.IllegalSyntax;
        }
        else if (captureCount > 0) {
            const firstCapture = ast.extra[case + 2];

            const captureDecl = self.symbols.findDecl(.{
                .file = self.currentFile,
                .expr = firstCapture,
            });

            self.lookup.putNoClobber(self.arena.allocator(), captureDecl, .{
                .status = .Checked,
                .result = itemTypeID,
            }) catch return Error.AllocatorFailure;
        }

        try self.typecheckStatement(ast.extra[case + 3], expected);
    }

    if (fieldMap.count() != fieldMap.capacity()) {
        common.log.err("Missing enum fields:", .{});

        var iterator = fieldMap.iterator(.{
            .direction = .forward,
            .kind = .unset,
        });
        while (iterator.next()) |field| {
            const fieldName = enm.fields[field];
            common.log.err(("." ** 4) ++ " {s}", .{
                fieldName,
            });
        }

        self.report("In switch expression.", .{});
        return Error.UnhandledSwitchCases;
    }
}

fn typecheckDiscard(self: *Typechecker, exprPtr: defines.ExpressionPtr) Error!void {
    _ = try self.typecheckExpression(exprPtr, null);
}

fn typecheckReturn(self: *Typechecker, exprPtr: defines.ExpressionPtr, expected: TypeID) Error!void {
    const returnType = try self.typecheckExpression(exprPtr, expected);

    if (!self.suitable(expected, returnType)) {
        self.report("Unsuitable return type, expected '{s}', received '{s}'", .{
            try self.typeName(self.arena.allocator(), expected),
            try self.typeName(self.arena.allocator(), returnType),
        });
        return Error.ReturnTypeMismatch;
    }

    _ = self.setFlag(.CoveredAllPaths, true);
}

fn typecheckIfStatement(self: *Typechecker, extraPtr: defines.OpaquePtr, expected: TypeID) Error!void {
    const ast = self.context.getAST(self.currentFile);

    const conditionExpr = ast.extra[extraPtr];
    const body = ast.extra[extraPtr + 1];
    const maybeOtherwise =
        if (ast.extra[extraPtr + 2] == 1) ast.extra[extraPtr + 3]
        else null;

    const conditionType = try self.typecheckExpression(conditionExpr, Comptime.Builtin.Type("bool"));
    if (!self.suitable(conditionType, Comptime.Builtin.Type("bool"))) {
        self.report("Expected a boolean for condition.", .{});
        return Error.TypeMismatch;
    }

    try self.typecheckStatement(body, expected);
    const coveredIf = self.getFlag(.CoveredAllPaths);

    _ = self.setFlag(.CoveredAllPaths, false);
    const coveredElse =
        if (maybeOtherwise) |otherwise| blk: {
            try self.typecheckStatement(otherwise, expected);
            break :blk self.getFlag(.CoveredAllPaths);
        }
        else false;

    _ = self.setFlag(.CoveredAllPaths, coveredIf and coveredElse);
}

fn typecheckAssignment(self: *Typechecker, extraPtr: defines.OpaquePtr) Error!void {
    _ = extraPtr;
    self.report("Assignment is not supported yet. You have to do a static single assignment.", .{});
    return common.debug.NotImplemented(@src());
}

fn typecheckExpressionStatement(self: *Typechecker, exprPtr: defines.OpaquePtr) Error!void {
    const ast = self.context.getAST(self.currentFile);

    const expression = ast.expressions.get(exprPtr);

    if (expression.type == .Assignment) return self.typecheckAssignment(expression.value);

    const resultType = try self.typecheckExpression(exprPtr, null);

    if (!self.typeTable.get(resultType).isZeroBit()) {
        self.report("Unhandled return value of type '{s}', consider using an explicit discard '_' instead.", .{
            try self.typeName(self.arena.allocator(), resultType),
        });
    }
}

fn typecheckBlock(self: *Typechecker, extraPtr: defines.OpaquePtr, expected: TypeID) Error!void {
    const ast = self.context.getAST(self.currentFile);

    const innerRange = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    for (innerRange.start..innerRange.end) |index| {
        if (self.getFlag(.CoveredAllPaths)) {
            self.report("Unreachable code", .{});
            return Error.UnreachableCodePath;
        }

        try self.typecheckStatement(ast.extra[index], expected);
    }
}

pub fn typecheckVariable(self: *Typechecker, decl: *const Resolver.Declaration) Error!TypeID {
    const expected = try self.expectType(decl.type);

    const initializer =
        if (decl.topLevel or expected == Comptime.Builtin.Type("type"))
            try self.typecheckValue(try self.executer.eval(decl.node, expected), expected)
        else
            try self.typecheckExpression(decl.node, expected);

    const res =
        if (self.suitable(expected, initializer))
            try self.infer(expected, initializer)
        else  {
            self.report(
                "Mismatching initializer type in variable definition."
                ++ " Expected '{s}', received '{s}'.", .{
                try self.typeName(self.arena.allocator(), expected),
                try self.typeName(self.arena.allocator(), initializer),
            });
            return Error.TypeMismatch;
        };

    blk: switch (self.typeTable.get(initializer)) {
        .Type => {
            const newType = self.executer.getValue(try self.executer.eval(decl.node, expected)).Type;
            const name = self.builder.getInternedString(switch (self.typeTable.get(newType)) {
                .Union => |uni| uni.name,
                .Struct => |str| str.name,
                .Enum => |enm| enm.name,
                else => break :blk,
            });

            if (name[0] != '$') {
                break :blk;
            }

            const ast = self.context.getAST(self.currentFile);
            const tokens = self.context.getTokens(ast.tokens);

            const symName = tokens.get(decl.token).lexeme(self.context, self.currentFile);
            const namespace = self.modules.modules.get(self.modules.modules.len - self.currentFile - 1).name;
            const newName = std.fmt.allocPrint(self.arena.allocator(), "{s}::{s}", .{
                namespace,
                symName,
            }) catch return Error.AllocatorFailure;
            const new = try self.builder.internString(newName);

            self.typeTable.set(newType, switch (self.typeTable.get(newType)) {
                .Struct => |str| .{
                    .Struct = .{
                        .mutable = str.mutable,
                        .name = new,
                        .fields = str.fields,
                        .definitions = str.definitions,
                        .scope = str.scope,
                    },
                },

                .Enum => |enm| .{
                    .Enum = .{
                        .mutable = enm.mutable,
                        .name = new,
                        .definitions = enm.definitions,
                        .fields = enm.fields,
                        .scope = enm.scope,
                    },
                },

                .Union => |uni| TypeInfo{
                    .Union = .{
                        .name = new,
                        .isTagged = uni.isTagged,
                        .tag = uni.tag,
                        .mutable = uni.mutable,
                        .definitions = uni.definitions,
                        .fields = uni.fields,
                        .scope = uni.scope,
                    },
                },

                else => unreachable,
            });
        },
        else => { },
    }

    return res;
}

pub fn typecheckExpression(self: *Typechecker, expressionPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const expr = ast.expressions.get(expressionPtr);
    defer _ = self.setFlag(.ConcreteValue, switch (expr.type) {
        .Identifier, .Indexing, .Scoping => true,
        else => false,
    });

    // @Note all literals should be handled here.
    if (self.executer.attemptEval(expressionPtr, maybeExpected)) |result| {
        return self.typecheckValue(result, maybeExpected);
    }

    return switch (expr.type) {
        .Identifier => {
            self.lastToken = expr.value;
            const decl = self.symbols.findDecl(.{ .file = self.currentFile, .expr = expressionPtr });
            return self.typecheckDecl(decl, maybeExpected);
        },
        .Indexing => return self.typecheckIndexing(expr.value),
        .Call => self.typecheckCall(expr.value, maybeExpected),
        .Scoping => return self.typecheckScoping(expressionPtr),
        .ExpressionList => self.typecheckExpressionList(expr.value, maybeExpected),
        .Literal => self.typecheckValue(try self.executer.eval(expressionPtr, maybeExpected), maybeExpected),

        .EnumDefinition, .UnionDefinition, .StructDefinition,
        .ArrayType, .CPointerType, .FunctionType,
        .MutableType, .PointerType, .SliceType,
        .FunctionDefinition, .Lambda => self.typecheckValue(
            try self.executer.eval(expressionPtr, maybeExpected),
            maybeExpected,
        ),

        .Conditional => self.typecheckIfExpression(expr.value, maybeExpected),
        .Switch => self.typecheckSwitchExpression(expr.value, maybeExpected),

        .Unary => self.typecheckUnary(expr.value),
        .Binary => self.typecheckBinary(expr.value),

        .Slicing => self.typecheckSlicing(expr.value),

        .Mark => self.typecheckMark(.Expression, expressionPtr, expr.value, maybeExpected),

        .Dot => self.typecheckDot(expr.value),

        .Assignment => |t| {
            self.report("Expected an expression, received '{s}' instead.", .{
                @tagName(t),
            });
            return Error.IllegalSyntax;
        },
    };
}

pub fn typecheckIfExpression(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const conditional = .{
        .condition = ast.extra[extraPtr],
        .then = ast.extra[extraPtr + 1],
        .otherwise = ast.extra[extraPtr + 2],
    };

    const condition = try self.typecheckExpression(conditional.condition, Comptime.Builtin.Type("bool"));
    if (!self.suitable(Comptime.Builtin.Type("bool"), condition)) {
        self.report("Expected a boolean for condition.", .{});
        return Error.TypeMismatch;
    }

    const thenBranch = try self.typecheckExpression(conditional.then, maybeExpected);
    const elseBranch = try self.typecheckExpression(conditional.otherwise, maybeExpected);

    if (!(
        self.suitable(thenBranch, elseBranch)
        and self.suitable(elseBranch, thenBranch)
    )) {
        self.report("Diverging result types '{s}' and '{s}' in conditional expression.", .{
            try self.typeName(self.arena.allocator(), thenBranch),
            try self.typeName(self.arena.allocator(), elseBranch),
        });
        return Error.DivergingBranches;
    }

    return self.infer(thenBranch, elseBranch) catch common.debug.ShouldBeImpossible(@src());
}

pub fn typecheckValue(self: *Typechecker, val: Comptime.Value.Ptr, maybeExpected: ?TypeID) Error!TypeID {
    const expected =
        if (determineExpected(maybeExpected)) |expected| expected
        else Comptime.Builtin.Type("any");

    return switch (self.executer.getValue(val)) {
        .Int => self.infer(Comptime.Builtin.Type("comptime_int"), expected)
            catch Comptime.Builtin.Type("comptime_int"),
        .Float => self.infer(Comptime.Builtin.Type("comptime_float"), expected)
            catch Comptime.Builtin.Type("comptime_float"),
        .Bool => Comptime.Builtin.Type("bool"),
        .Enum => |enumeration| enumeration.Type,
        .Union => |uni| uni.Type,
        .Struct => |str| str.Type,
        .Type => Comptime.Builtin.Type("type"),
        .Pointer => |ptr| ptr.Type,
        .Function => |func| self.builder.functions.get(func).signature,
        .Void => Comptime.Builtin.Type("void"),
        .Undefined => |undef| undef,
        .Slice => |slice| slice.Type,
        .String => Comptime.Builtin.Type("string"),
    };
}

pub fn typecheckExpressionList(self: *Typechecker, extra: defines.OpaquePtr, _maybeExpected: ?TypeID) Error!TypeID {
    const maybeExpected = determineExpected(_maybeExpected);
    const ast = self.context.getAST(self.currentFile);

    const range = defines.Range{
        .start = ast.extra[extra],
        .end = ast.extra[extra + 1],
    };

    if (
        range.len() == 0
        and (
            maybeExpected == null
            or maybeExpected.? == Comptime.Builtin.Type("void")
        )
    ) {
        return Comptime.Builtin.Type("void");
    }

    const expected =
        if (maybeExpected) |expected| expected
        else if (range.len() == 1) {
            return self.typecheckExpression(ast.extra[range.at(0)], null);
        }
        else {
            self.report("Couldn't infer the type of expression list.", .{});
            return Error.InferenceError;
        };

    return self.typecheckExpressionListRange(range, expected);
}

pub fn typecheckExpressionListRange(self: *Typechecker, range: defines.Range, expected: TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    switch (self.typeTable.get(expected)) {
        .Enum => |enm| try self.typecheckEnumInitialization(ast, &enm, range, expected),
        .Struct => |str| try self.typecheckStructInitialization(ast, &str, range),
        .Union => |uni| try self.typecheckUnionInitialization(ast, &uni, range),
        .Array => |arr| try self.typecheckArrayInitialization(ast, &arr, range),
        .Pointer => |ptr| switch (ptr.size) {
            .Slice, .C => {
                // try self.typecheckGeneralInitialization(ast, ptr.child, range)
                self.report("Initialization of slice/cpointer types via expression lists are not allowed. Use addressing instead.", .{ });
                return Error.SliceInitializationWithExpressionList;
            },
            .Single => {
                if (range.len() != 1) {
                    self.report("Can't initialize '{s}' with {d} values.", .{
                        try self.typeName(self.arena.allocator(), expected),
                        range.len(),
                    });
                    return Error.InitializerCountMismatch;
                }

                try self.typecheckGeneralInitialization(ast, expected, range);
            },
        },
        .Void => try self.typecheckGeneralInitialization(ast, expected, range),
        .Noreturn,
        .Type, .Function,
        .Bool, .Float, .Integer,
        .ComptimeInt, .ComptimeFloat => {
            if (range.len() != 1) {
                self.report("Can't initialize '{s}' with {d} values.", .{
                    try self.typeName(self.arena.allocator(), expected),
                    range.len(),
                });
                return Error.InitializerCountMismatch;
            }

            try self.typecheckGeneralInitialization(ast, expected, range);
        },
        else => return common.debug.ShouldBeImpossible(@src()),
    }

    return expected;
}

fn typecheckGeneralInitialization(self: *Typechecker, ast: *const Parser.AST, expected: TypeID, range: defines.Range) Error!void {
    for (range.start..range.end) |extraPtr| {
        const elem = try self.typecheckExpression(ast.extra[extraPtr], expected);

        if (self.suitable(expected, elem)) {
            continue;
        }

        self.report("Mismatching types in initialization. Expected '{s}', received '{s}'.", .{
            try self.typeName(self.arena.allocator(), expected),
            try self.typeName(self.arena.allocator(), elem),
        });
        return Error.TypeMismatch;
    }
}

fn typecheckEnumInitialization(self: *Typechecker, ast: *const Parser.AST, enm: *const Types.Enum, range: defines.Range, expected: TypeID) Error!void {
    if (range.len() != 1) {
        self.report("Expected an enum literal in enum initialization, received '{d}' expressions instead.", .{
            range.len(),
        });
        return Error.ArgumentCountMismatch;
    }
    else {
        const rhs = try self.typecheckExpression(ast.extra[range.at(0)], expected);

        if (!self.suitable(expected, rhs)) {
            self.report("Expected an initializer of type '{s}', recieved '{s}' instead.", .{
                self.builder.getInternedString(enm.name),
                try self.typeName(self.arena.allocator(), rhs),
            });
            return Error.TypeMismatch;
        }

        _ = try self.infer(expected, rhs);
    }
}

fn typecheckStructInitialization(self: *Typechecker, ast: *const Parser.AST, str: *const Types.Struct, range: defines.Range) Error!void {
    if (str.fields.len != range.len()) {
        self.report("Type '{s}' expects {d} initializer{s}, received {d}.", .{
            self.builder.getInternedString(str.name),
            str.fields.len,
            if (str.fields.len > 1 or str.fields.len == 0) "s" else "",
            range.len(),
        });
        return Error.InitializerCountMismatch;
    }

    for (str.fields, 0..) |field, index| {
        const initializerType =
            if (field.isComptime) try self.typecheckValue(try self.executer.eval(
                ast.extra[range.at(@intCast(index))],
                field.valueType,
            ), null)
            else try self.typecheckExpression(
                ast.extra[range.at(@intCast(index))],
                field.valueType,
            );

        if (self.suitable(field.valueType, initializerType)) {
            continue;
        }

        self.report("'{s}::{s}' expected an initializer of type '{s}'. Received '{s}'.", .{
            self.builder.getInternedString(str.name),
            self.builder.getInternedString(field.name),
            try self.typeName(self.arena.allocator(), field.valueType),
            try self.typeName(self.arena.allocator(), initializerType),
        });
        return Error.TypeMismatch;
    }
}

fn typecheckArrayInitialization(self: *Typechecker, ast: *const Parser.AST, arr: *const Types.Array, range: defines.Range) Error!void {
    if (arr.len != range.len()) {
        self.report("Mismatching element counts in array initialization. Expected {d}, received {d}.", .{
            arr.len,
            range.len(),
        });
        return Error.InitializerCountMismatch;
    }

    for (0..arr.len) |index| {
        const item = try self.typecheckValue(
            try self.executer.eval(ast.extra[range.at(@intCast(index))], arr.child),
            arr.child,
        );

        if (self.suitable(arr.child, item)) {
            continue;
        }

        self.report(
            "Mismatching element types in array initialization."
            ++ " Expected '{s}', received '{s}' (at index {d})", .{
            try self.typeName(self.arena.allocator(), arr.child),
            try self.typeName(self.arena.allocator(), item),
            index,
        });
        return Error.TypeMismatch;
    }
}

fn typecheckUnionInitialization(self: *Typechecker, ast: *const Parser.AST, uni: *const Types.Union, range: defines.Range) Error!void {
    if (range.len() < 1) {
        self.report("Expected a field enum in union initialization.", .{ });
        return Error.InitializerCountMismatch;
    }

    const ptr = try self.executer.eval(ast.extra[range.at(0)], uni.tag);
    const findex = switch (self.executer.getValue(ptr)) {
        .Enum => |enm| blk: {
            if (enm.Type != uni.tag) {
                self.report("Expected field enum of type '{s}', received '{s}' instead.", .{
                    try self.typeName(self.arena.allocator(), uni.tag),
                    try self.typeName(self.arena.allocator(), enm.Type),
                });
                return Error.TypeMismatch;
            }

            break :blk @as(u32, if (uni.isTagged) 1 else 0) + enm.Value;
        },
        else => {
            self.report("Expected field enum of type '{s}', received '{s}' instead.", .{
                try self.typeName(self.arena.allocator(), uni.tag),
                try self.typeName(self.arena.allocator(),
                    try self.typecheckValue(ptr, null)
                ),
            });
            return Error.TypeMismatch;
        }
    };

    const field = uni.fields[findex];
    _ = try self.typecheckExpressionListRange(range.subRange(1), field.valueType);
    if (field.isComptime) {
        _ = try self.executer.constructFromList(
            field.valueType,
            range.subRange(1),
        );
    }
}

pub fn typecheckScoping(self: *Typechecker, expr: defines.ExpressionPtr) Error!TypeID {
    if (self.symbols.resolutionMap.get(.{
        .file = self.currentFile,
        .expr = expr,
    })) |decl| {
        return self.typecheckDecl(decl, null);
    }

    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(ast.tokens);

    const extraPtr: defines.OpaquePtr = ast.expressions.items(.value)[expr];

    const lhsTypePtr = try self.expectType(ast.extra[extraPtr]);
    const lhsType = self.typeTable.get(lhsTypePtr);

    const member = tokens.get(ast.extra[extraPtr + 1]).lexeme(self.context, self.currentFile);

    var defs: []const Types.FieldInfo = undefined;
    var scope: defines.ScopePtr = undefined;
    switch (lhsType) {
        .Enum => |enm| {
            for (enm.fields) |field| {
                if (std.mem.eql(u8, field, member)) {
                    return lhsTypePtr;
                }
            }

            defs = enm.definitions;
            scope = enm.scope;
        },
        .Struct => |str| {
            defs = str.definitions;
            scope = str.scope;
        },
        .Union => |uni| {
            defs = uni.definitions;
            scope = uni.scope;
        },
        else => return common.debug.NotImplemented(@src()),
    }

    for (defs) |def| {
        if (def.name == try self.builder.internString(member)) {
            if (def.public or self.symbols.canAccess(self.currentScope, scope)) {
                return self.discoverScopeDef(lhsTypePtr, &def, scope);
            }

            self.report("'{s}::{s}' is inaccessible due to its visibility level.", .{
                try self.typeName(self.arena.allocator(), lhsTypePtr),
                member,
            });
            return Error.AccessSpecifierMismatch;
        }
    }

    self.report("Couldn't find definition '{s}' in type '{s}'.", .{
        member,
        try self.typeName(self.arena.allocator(), lhsTypePtr),
    });

    return Error.MissingDefinition;
}

pub fn discoverScopeDef(self: *Typechecker, from: TypeID, member: *const Types.FieldInfo, scope: defines.ScopePtr) Error!TypeID {
    if (member.valueType != Comptime.Builtin.Type("incomplete")) {
        return member.valueType;
    }

    const decl = self.symbols.lookup.get(.{
        .scope = scope,
        .name = self.builder.getInternedString(member.name),
    }).?;

    const discoveredType = try self.typecheckDecl(decl, null);
    const memberIndex = try self.definitionIndex(from, member.name);

    switch (self.typeTable.get(from)) {
        .Enum => |enm| {
            var defs: []Types.FieldInfo = @constCast(enm.definitions);
            defs[memberIndex].valueType = discoveredType;

            self.typeTable.set(from, .{
                .Enum = .{
                    .name = enm.name,
                    .definitions = defs,
                    .scope = enm.scope,
                    .fields = enm.fields,
                    .mutable = enm.mutable,
                },
            });
        },
        .Struct => |str| {
            var defs: []Types.FieldInfo = @constCast(str.definitions);
            defs[memberIndex].valueType = discoveredType;

            self.typeTable.set(from, .{
                .Struct = .{
                    .name = str.name,
                    .definitions = defs,
                    .scope = str.scope,
                    .fields = str.fields,
                    .mutable = str.mutable,
                },
            });
        },
        .Union => |uni| {
            var defs: []Types.FieldInfo = @constCast(uni.definitions);
            defs[memberIndex].valueType = discoveredType;

            self.typeTable.set(from, .{
                .Union = .{
                    .isTagged = uni.isTagged,
                    .tag = uni.tag,
                    .name = uni.name,
                    .definitions = defs,
                    .scope = uni.scope,
                    .fields = uni.fields,
                    .mutable = uni.mutable,
                },
            });
        },
        else => return common.debug.ShouldBeImpossible(@src()),
    }

    return discoveredType;
}

pub fn typecheckCall(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    if (ast.expressions.items(.type)[ast.extra[extraPtr]] == .Identifier) blk: {
        if (self.symbols.resolutionMap.get(.{
            .file = self.currentFile,
            .expr = ast.extra[extraPtr], 
        })) |builtinPtr| {
            const decl = self.symbols.declarations.get(builtinPtr);

            if (decl.kind != .Builtin) {
                break :blk;
            }

            if (Comptime.Builtin.isBuiltinType(decl.type)) {
                break :blk;
            }

            return self.typecheckBuiltinCall(extraPtr, decl.type, maybeExpected);
        }
    }

    const lhsType = try self.typecheckExpression(ast.extra[extraPtr], null);
    const maybeFunction = self.typeTable.get(lhsType);
    const func = switch (maybeFunction) {
        .Type => {
            const typeToInit = self.executer.getValue(try self.executer.eval(ast.extra[extraPtr], null)).Type;

            return self.typecheckExpressionList(
                ast.expressions.items(.value)[ast.extra[extraPtr + 1]],
                switch (self.typeTable.get(typeToInit)) {
                    .Type, .Noreturn, .Any,
                    .Function, .EnumLiteral => {
                        self.report("Given type '{s}' is not initializable.", .{
                            try self.typeName(self.arena.allocator(), typeToInit),
                        });
                        return Error.TypeIsNotConstructible;
                    },
                    .Pointer => |ptr| switch (ptr.size) {
                        .Single => {
                            self.report("Given type '{s}' is not initializable.", .{
                                try self.typeName(self.arena.allocator(), typeToInit),
                            });
                            return Error.TypeIsNotConstructible;
                        },
                        else => typeToInit,
                    },
                    else => typeToInit,
                },
            );
        },
        .Function => |func| func,
        else => {
            self.report("Attempt to call non-function type '{s}'.", .{
                try self.typeName(self.arena.allocator(), lhsType),
            });
            return Error.TypeIsNotCallable;
        },
    };

    const exprList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = ast.extra[
        ast.extra[exprList]
        ..
        ast.extra[exprList + 1]
    ];

    if (args.len != func.argTypes.len) {
        self.report("Mismatching argument counts in function call. Expected {d}, received {d}.", .{
            func.argTypes.len,
            args.len,
        });
        return Error.ArgumentCountMismatch;
    }

    for (func.argTypes, args, 0..) |arg, expr, index| {
        const exprType = try self.typecheckExpression(expr, arg);

        if (exprType != arg) {
            self.report(
                "Argument type mismatch in function call."
                ++ " In argument {d}: expected {s}, received {s}", .{
                index,
                try self.typeName(self.arena.allocator(), arg),
                try self.typeName(self.arena.allocator(), exprType),
            });
            return Error.TypeMismatch;
        }
    }

    return func.returnType;
}

pub fn typecheckBuiltinCall(self: *Typechecker, extraPtr: defines.ExpressionPtr, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!TypeID {
    const BI = Resolver.BuiltinIndex;

    return switch (declPtr) {
        BI("cast") => self.typecheckCast(extraPtr, maybeExpected),
        BI("as") => self.typecheckTypeForwarding(extraPtr, maybeExpected),
        BI("typeOf") => self.executer.getValue(try self.executer.evalTypeOf(extraPtr)).Type,
        BI("compileError") => Comptime.Builtin.Type("noreturn"),
        BI("compileLog") => Comptime.Builtin.Type("void"),
        BI("unreachable") => Comptime.Builtin.Type("noreturn"),
        else => {
            self.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[declPtr]});
            return Error.ComptimeNotPossible;
        },
    };
}

pub fn typecheckCast(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const targetType =
        if (determineExpected(maybeExpected)) |target| target
        else {
            self.report("Casting requires a known target type.", .{});
            return Error.InferenceError;
        };

    const ast = self.context.getAST(self.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const thingToCastRange = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (thingToCastRange.len() != 1) {
        self.report("Multi-value type casting is not supported.", .{});
        return Error.NotImplemented;
    }

    const thingToCastType = try self.typecheckExpression(ast.extra[thingToCastRange.at(0)], null);

    self.assertCastable(thingToCastType, targetType) catch |err| {
        const rargs = .{
            try self.typeName(self.arena.allocator(), thingToCastType),
            try self.typeName(self.arena.allocator(), targetType),
        };

        switch (err) {
            Error.IncompatibleTypes => self.report("Given type '{s}' can't be cast to '{s}'.", rargs),
            Error.SizeMismatch => self.report("Type '{s}' is too big for being cast to '{s}'.", rargs),
            Error.MutabilityViolation => self.report("Cast from '{s}' to '{s}' ignores mutability specifiers.", rargs),
            Error.PointerSizeMismatch => self.report("Illegal cast from unknown sized '{s}' to sized '{s}'.", rargs),
            Error.StructuralMismatch => self.report("Illegal cast from structurally incompatible '{s}' to '{s}'", rargs),
            Error.MismatchingSliceChildType => self.report("Cast from slice type '{s}' to '{s}' will alter the length of the slice.", rargs),
            Error.InferenceError => self.report("Illegal cast from '{s}' to unknown type '{s}'.", rargs),
            Error.RedundantCast => self.report("Redundant cast from type '{s}' to '{s}'.", rargs),
            else => return common.debug.ShouldBeImpossible(@src()),
        }

        return err;
    };

    return targetType;
}

pub fn typecheckTypeForwarding(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (args.len() != 2) {
        self.report("Expected 2 arguments, received {d}.", .{
            args.len(),
        });
        return Error.ArgumentCountMismatch;
    }

    const typeToForward = try self.expectType(ast.extra[args.at(0)]);

    if (determineExpected(maybeExpected)) |expected| {
        if (self.suitable(typeToForward, expected)) {
            self.report("Reduntant type forwarding in already inferable context.", .{ });
            return Error.RedundantTypeForwarding;
        }
    }

    const res = try self.typecheckExpression(ast.extra[args.at(1)], typeToForward);
    if (res != typeToForward) {
        self.report("Expected en expression of type '{s}' here.", .{
            try self.typeName(self.arena.allocator(), typeToForward),
        });
        return Error.TypeMismatch;
    }

    return res;
}

pub fn typecheckIndexing(self: *Typechecker, extraPtr: defines.OpaquePtr) Error!TypeID {
    const lValue = self.getFlag(.LValue);

    const ast = self.context.getAST(self.currentFile);

    const maybeIndexableId = try self.typecheckExpression(ast.extra[extraPtr], null);

    // @Note if trying to form an lvalue, maybeIndexable must be a concrete value.
    if (!self.getFlag(.ConcreteValue)) {
        self.report("Attempt to form an lvalue by indexing a non-concrete value.", .{ });
        return Error.UnexpectedRValue;
    }

    const maybeIndexable = self.typeTable.get(maybeIndexableId);
    switch (maybeIndexable) {
        .Array => { },
        .Pointer => |ptr| switch (ptr.size) {
            .Slice, .C => { },
            else => {
                self.report("Attempt to index a singular pointer '{s}'.", .{
                    try self.typeName(self.arena.allocator(), maybeIndexableId),
                });
                return Error.IndexingOfNonIndexableValue;
            },
        },
        else => {
            self.report("Attempt to index non-indexable value of type '{s}'.", .{
                try self.typeName(self.arena.allocator(), maybeIndexableId),
            });
            return Error.IndexingOfNonIndexableValue;
        },
    }

    const maybeIndexPtr = try self.typecheckExpression(ast.extra[extraPtr + 1], null);
    const maybeIndex = self.typeTable.get(maybeIndexPtr);
    switch (maybeIndex) {
        .Integer, .ComptimeInt => {
        },
        else => {
            self.report("Expected an integer type for indexing, received '{s}'.", .{
                try self.typeName(self.arena.allocator(), maybeIndexPtr),
            });
            return Error.NonIntegerIndex;
        },
    }

    switch (maybeIndexable) {
        .Array => |arr| if (self.executer.attemptEval(ast.extra[extraPtr + 1], null)) |_index| {
            const index = self.executer.getValue(_index).Int;
            if (arr.len <= index) {
                self.report("Index out of bounds. Size: {d}, Index: {d}.", .{
                    arr.len,
                    index
                });
                return Error.IndexOutOfBounds;
            }
        },
        else => { },
    }

    return
        if (lValue) blk: {
            const child = switch (maybeIndexable) {
                .Array => |arr| arr.child,
                .Pointer => |ptr| ptr.child,
                else => break :blk common.debug.ShouldBeImpossible(@src()),
            };

            const newPointer = TypeInfo{
                .Pointer = .{
                    .mutable = true,
                    .child = child,
                    .size = .Single,
                },
            };

            break :blk self.registerType(newPointer);
        }
        else switch (maybeIndexable) {
            .Array => |arr| arr.child,
            .Pointer => |ptr| ptr.child,
            else => common.debug.ShouldBeImpossible(@src()),
        };
}

pub fn typecheckDecl(self: *Typechecker, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!TypeID {
    const decl = self.symbols.declarations.get(declPtr);

    if (decl.kind == .Builtin) {
        return if (Comptime.Builtin.isBuiltinType(decl.type)) Comptime.Builtin.Type("type")
        else switch (decl.type) {
            BuiltinIndex("undefined") =>
                if (determineExpected(maybeExpected)) |expected| expected
                else {
                    self.report("Unable to resolve the type of undefined value.", .{});
                    return Error.MissingTypeSpecifier;
                },
            BuiltinIndex("unreachable") => return Comptime.Builtin.Type("noreturn"),
            else => {
                self.report("Builtin '{s}' is not implemented.", .{Resolver.builtins[decl.type]});
                return Error.NotImplemented;
            },
        };
    }

    const allocator = self.arena.allocator();

    const prevToken = self.lastToken;
    const prevFile = self.currentFile;
    const prevScope = self.currentScope;
    self.currentFile = self.modules.modules.items(.dataIndex)[self.symbols.scopes.items(.module)[decl.scope]];
    self.lastToken = decl.token;
    self.currentScope = decl.scope;
    defer self.lastToken = prevToken;
    defer self.currentFile = prevFile;
    defer self.currentScope = prevScope;

    const isPresent = self.lookup.getOrPut(allocator, declPtr) catch return Error.AllocatorFailure;

    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(ast.tokens);

    self.callstack.push(declPtr);
    defer _ = self.callstack.pop();

    if (isPresent.found_existing) {
        switch (isPresent.value_ptr.status) {
            .Checked =>
                if (isPresent.value_ptr.result != Comptime.Builtin.Type("incomplete"))
                    return isPresent.value_ptr.result
                else  { },
            .InProgress => {
                if (!self.getFlag(.CanCycle)) {
                    self.report("Dependency cycle detected. '{s}' depends on itself.", .{
                        tokens.get(decl.token).lexeme(self.context, self.currentFile),
                    });
                }
                return Error.DependencyCycle;
            },
            else => { },
        }
    }

    isPresent.value_ptr.* = .{
        .status = .InProgress,
        .result = 0,
    };
    errdefer isPresent.value_ptr.status = .NotChecked;

    const declType = try switch (decl.kind) {
        .Variable => self.typecheckVariable(&decl),
        .Namespace => {
            self.report("Operations on namespaces are not allowed.", .{});
            return Error.NamespaceAsValue;
        },
        .Builtin, .Capture => return common.debug.ShouldBeImpossible(@src()),
        .Parameter => return common.debug.ShouldBeImpossible(@src()),
        else => {
            self.report("{s} is not implemented.", .{@tagName(decl.kind)});
            return Error.NotImplemented;
        },
    };

    isPresent.value_ptr.* = .{
        .status = .Checked,
        .result = declType,
    };
    
    try self.lowerer.declaration(declPtr, &decl);

    return declType;
}

pub fn typecheckDot(self: *Typechecker, extraPtr: defines.OpaquePtr) Error!TypeID {
    // @Important TODO: This doesn't allow member function calls yet! Add them!

    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(ast.tokens);

    const objectExprPtr = ast.extra[extraPtr];
    const memberPtr = ast.extra[extraPtr + 1];

    const memberToken = tokens.get(memberPtr);

    const objectTypeID = try self.typecheckExpression(objectExprPtr, null);

    switch (memberToken.type) {
        .Ampersand => {
            if (!self.getFlag(.ConcreteValue)) {
                self.report("Attempt to take the address of non-concrete value.", .{ });
                return Error.AddressOfTemporaryValue;
            }

            // @Beware Must be kept in sync with the ConcreteValue check.
            // Hence we assume lhs is something that we can take the address of.
            return self.registerType(.{
                .Pointer = .{
                    .size = .Single,
                    .mutable = self.mutable(objectTypeID),
                    .child = objectTypeID,
                },
            });
        },
        .Star => {
            switch (self.typeTable.get(objectTypeID)) {
                .Pointer => |ptr| switch (ptr.size) {
                    .Single, .C => return ptr.child,
                    else => {
                        self.report("Attempt to dereference a slice of type '{s}', use indexing or access the pointer value instead.", .{
                            try self.typeName(self.arena.allocator(), objectTypeID),
                        });
                        return Error.DereferenceOfSliceType;
                    }
                },
                else => {
                    self.report("Attempt to dereference a non-pointer value of type '{s}'", .{
                        try self.typeName(self.arena.allocator(), objectTypeID),
                    });
                    return Error.DereferenceOfNonPointerValue;
                }
            }
        },
        else => { },
    }

    if (!self.getFlag(.ConcreteValue)) {
        self.report("Field access on non-concrete (temporary) values are not (yet) supported.", .{ });
        return Error.NotImplemented;
    }

    const memberName = memberToken.lexeme(self.context, self.currentFile);
    const objectType = self.typeTable.get(objectTypeID);

    switch (objectType) {
        .Pointer => |ptr| if (ptr.size == .Slice) {
            if (std.mem.eql(u8, memberName, "len")) {
                return Comptime.Builtin.Type("u32");
            }
            else if (std.mem.eql(u8, memberName, "ptr")) {
                return self.registerType(.{
                    .Pointer = .{
                        .size = .C,
                        .mutable = ptr.mutable,
                        .child = ptr.child,
                    },
                });
            }
        },
        .Array => |arr| {
            if (std.mem.eql(u8, memberName, "len")) {
                return Comptime.Builtin.Type("u32");
            }
            else if (std.mem.eql(u8, memberName, "ptr")) {
                return self.registerType(.{
                    .Pointer = .{
                        .size = .C,
                        .mutable = arr.mutable,
                        .child = arr.child,
                    },
                });
            }
        },
        else => { },
    }

    const member = try self.builder.internString(memberName);
    const index = try self.fieldIndex(objectTypeID, member);

    const fields = switch (objectType) {
        .Union => |uni| blk: { 
            if (index == 0) {
                self.report("No field named 'tag' in type '{s}'.", .{
                    try self.typeName(self.arena.allocator(), objectTypeID),
                });
                return Error.FieldNotFound;
            }

            break :blk uni.fields;
        },
        .Struct => |str| str.fields,
        else => return common.debug.ShouldBeImpossible(@src()),
    };

    return fields[index].valueType;
}

pub fn typecheckMark(
    self: *Typechecker,
    kind: Element.Kind,
    ptr: defines.EitherPtr(defines.StatementPtr, defines.ExpressionPtr),
    extraPtr: defines.OpaquePtr,
    maybeExpected: ?TypeID
) Error!TypeID {
    // In case of the mark of a mark, ptr is the marked this, which is the
    // current mark.
    if (self.getMetadata(kind, ptr)) |_| {
        self.report("Redundant marking of already marked {s}.", .{
            if (kind == .Statement) "statement" else "expression",
        });
        return Error.RedundantMark;
    }

    const ast = self.context.getAST(self.currentFile);

    const marks = defines.Range{
        .start = ast.extra[extraPtr], 
        .end = ast.extra[extraPtr + 1], 
    };

    const metadata = self.arena.allocator().alloc(Comptime.Value.Ptr, marks.len())
        catch return Error.AllocatorFailure;

    for (0..marks.len()) |index| {
        metadata[index] = try self.executer.eval(
            ast.extra[marks.at(@intCast(index))],
            Comptime.Builtin.Type("builtin_metadata")
        );
    }

    const marked = ast.extra[extraPtr + 2];
    if (kind == .Statement and ast.statements.items(.type)[marked] == .VariableDefinition) {
        const varDef = ast.statements.get(marked);
        try self.setMetadata(kind, ast.extra[varDef.value + 1], metadata);
    }

    try self.setMetadata(kind, marked, metadata);

    return
        if (kind == .Statement) common.debug.NotImplemented(@src())
        else self.typecheckExpression(marked, maybeExpected);
}

pub fn typecheckSlicing(self: *Typechecker, extraPtr: defines.OpaquePtr) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const maybeSliceableType = try self.typecheckExpression(ast.extra[extraPtr], null);
    const maybeSliceable = self.typeTable.get(maybeSliceableType);
    const resultType = switch (maybeSliceable) {
        .Array => |arr| try self.registerType(.{
            .Pointer = .{
                .size = .Slice,
                .mutable = arr.mutable,
                .child = arr.child,
            },
        }),
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => maybeSliceableType,
            .C => self.registerType(.{
                .Pointer = .{
                    .size = .Slice,
                    .mutable = ptr.mutable,
                    .child = ptr.child,
                },
            }),
            .Single => {
                self.report("Attempt to slice a singular pointer '{s}'.", .{
                    try self.typeName(self.arena.allocator(), maybeSliceableType),
                });
                return Error.SlicingOfNonSliceableValue;
            },
        },
        else => {
            self.report("Attempt to slice a non-sliceable value of type '{s}'.", .{
                try self.typeName(self.arena.allocator(), maybeSliceableType),
            });
            return Error.SlicingOfNonSliceableValue;
        },
    };

    const startType = try self.typecheckExpression(ast.extra[extraPtr + 1], null);
    if (!self.isInt(startType)) {
        self.report("Expected an integer value for slicing start index, received '{s}'.", .{
            try self.typeName(self.arena.allocator(), startType),
        });
        return Error.NonIntegerIndex;
    }

    const endType = try self.typecheckExpression(ast.extra[extraPtr + 2], null);
    if (!self.isInt(endType)) {
        self.report("Expected an integer value for slicing end index, received '{s}'.", .{
            try self.typeName(self.arena.allocator(), endType),
        });
        return Error.NonIntegerIndex;
    }

    if (self.executer.attemptEval(ast.extra[extraPtr + 1], startType)) |startPtr| {
        if (self.executer.attemptEval(ast.extra[extraPtr + 2], endType)) |endPtr| {
            const startIndex = self.executer.getValue(startPtr).Int;
            const endIndex = self.executer.getValue(endPtr).Int;
            if (startIndex > endIndex) {
                self.report("Ill-formed slicing, start index {d} is bigger than end index {d}", .{
                    startIndex,
                    endIndex,
                });
                return Error.IllegalSlicing;
            }
        }
    }

    return resultType;
}

pub fn typecheckBinary(self: *Typechecker, extraPtr: defines.OpaquePtr) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const operator: Lexer.TokenType = @enumFromInt(ast.extra[extraPtr + 1]);

    const lhs = try self.typecheckExpression(ast.extra[extraPtr], null);
    const rhs = try self.typecheckExpression(ast.extra[extraPtr + 2], null);

    return res: switch (operator) {
        .Or, .And => {
            const lhsType = self.typeTable.items(.tags)[lhs];
            const rhsType = self.typeTable.items(.tags)[rhs];

            if (lhsType != .Bool or rhsType != .Bool) {
                self.report("Incompatible types in logic operation. Expected 'bool' on both, received '{s}' and '{s}'", .{
                    try self.typeName(self.arena.allocator(), lhs),
                    try self.typeName(self.arena.allocator(), rhs),
                });
                return Error.LogicOnNonBooleanType;
            }

            break :res lhs;
        },
        .EqualEqual, .BangEqual => {
            self.assertComparable(lhs, rhs) catch {
                self.report("Attempt to compare non-comparable types '{s}' and '{s}'.", .{
                    try self.typeName(self.arena.allocator(), lhs),
                    try self.typeName(self.arena.allocator(), rhs),
                });
                break :res Error.ComparisonOnNonComparableType;
            };
            break :res Comptime.Builtin.Type("bool");
        },
        .Pipe, .Xor, .Ampersand => {
            if (!self.isInt(lhs)) {
                self.report("Attempt to use unsupported type '{s}' on the left hand side of bitwise operation.", .{
                    try self.typeName(self.arena.allocator(), lhs),
                });
                break :res Error.BitwiseOnUnsupportedType;
            }

            if (!self.isInt(rhs)) {
                self.report("Attempt to use unsupported type '{s}' on the left hand side of bitwise operation.", .{
                    try self.typeName(self.arena.allocator(), rhs),
                });
                break :res Error.BitwiseOnUnsupportedType;
            }

            break :res self.infer(lhs, rhs);
        },
        .LeftShift, .RightShift => {
            if (!self.isInt(lhs)) {
                self.report("Attempt to use unsupported type '{s}' on the left hand side of bitwise operation.", .{
                    try self.typeName(self.arena.allocator(), lhs),
                });
                break :res Error.BitwiseOnUnsupportedType;
            }

            if (!self.isInt(rhs)) {
                self.report("Attempt to use unsupported type '{s}' on the right hand side of bitwise operation.", .{
                    try self.typeName(self.arena.allocator(), rhs),
                });
                break :res Error.BitwiseOnUnsupportedType;
            }

            break :res lhs;
        },
        .Lesser, .LesserEqual, .Greater, .GreaterEqual => {
            if (!(self.isInt(lhs) or self.isFloat(lhs))) {
                self.report("Non-numeric type '{s}' on the left hand side of arithmetic comparison.", .{
                    try self.typeName(self.arena.allocator(), lhs),
                });
                break :res Error.ArithmeticOnNonNumericType;
            }

            if (!(self.isInt(rhs) or self.isFloat(rhs))) {
                self.report("Non-numeric type '{s}' on the right hand side of arithmetic comparison.", .{
                    try self.typeName(self.arena.allocator(), rhs),
                });
                break :res Error.ArithmeticOnNonNumericType;
            }

            break :res Comptime.Builtin.Type("bool");
        },
        .Plus, .Minus, .Slash, .Star => {
            // @Important TODO: allow pointer arithmetic on C style pointers.

            if (!(self.isInt(lhs) or self.isFloat(lhs))) {
                self.report("Non-numeric type '{s}' on the left hand side of arithmetic operation.", .{
                    try self.typeName(self.arena.allocator(), lhs),
                });
                break :res Error.ArithmeticOnNonNumericType;
            }

            if (!(self.isInt(rhs) or self.isFloat(rhs))) {
                self.report("Non-numeric type '{s}' on the right hand side of arithmetic operation.", .{
                    try self.typeName(self.arena.allocator(), rhs),
                });
                break :res Error.ArithmeticOnNonNumericType;
            }

            break :res self.infer(lhs, rhs);
        },

        else => common.debug.ShouldBeImpossible(@src()),
    };
}

pub fn typecheckUnary(self: *Typechecker, extraPtr: defines.OpaquePtr) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const token: Lexer.TokenType = @enumFromInt(ast.extra[extraPtr]);
    const rhsType = try self.typecheckExpression(ast.extra[extraPtr + 1], null);
    const rhs = self.typeTable.get(rhsType);

    return switch (token) {
        .Minus => switch (rhs) {
            .ComptimeFloat, .Float, .ComptimeInt => rhsType,
            .Integer => |int|
                if (!int.signed) {
                    self.report("Negation of unsigned integer type '{s}' is not allowed.", .{
                        try self.typeName(self.arena.allocator(), rhsType),
                    });
                    return Error.NegationOfUnsigned;
                }
                else if (int.size == 0) {
                    self.report("Pointless negation of zero-sized integer type '{s}'.", .{
                        try self.typeName(self.arena.allocator(), rhsType),
                    });
                    return Error.OperationOnZeroBitSize;
                }
                else rhsType,
            else => {
                self.report("Attemp to negate non-numeric type '{s}'.", .{
                    try self.typeName(self.arena.allocator(), rhsType),
                });
                return Error.ArithmeticOnNonNumericType;
            },
        },
        .Bang => switch (rhs) {
            .Bool => rhsType,
            else => {
                self.report("Attempt to use logical not '!' operator on non-boolean type '{s}'.", .{
                    try self.typeName(self.arena.allocator(), rhsType),
                });
                return Error.LogicOnNonBooleanType;
            },
        },
        .Tilde => switch (rhs) {
            .ComptimeInt, .Integer => rhsType,
            else => {
                self.report("Attempt to use bitwise not '~' operator on non-numeric type '{s}'.", .{
                    try self.typeName(self.arena.allocator(), rhsType),
                });
                return Error.BitwiseOnUnsupportedType;
            },
        },
        else => common.debug.ShouldBeImpossible(@src()),
    };
}

pub fn typecheckSwitchExpression(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const item = ast.extra[extraPtr];
    const itemTypeID = try self.typecheckExpression(item, null);
    const itemType = self.typeTable.get(itemTypeID);

    switch (itemType) {
        .Enum => { },
        .Union => |uni| if (!uni.isTagged) {
            self.report("Can't switch on untagged union type '{s}'.", .{
                try self.typeName(self.arena.allocator(), itemTypeID),
            });
            return Error.SwitchOnPlainUnion;
        },
        else => {
            self.report("Can't switch on value of type '{s}'.", .{
                try self.typeName(self.arena.allocator(), itemTypeID),
            });
            return Error.SwitchOnNonSwitchableValue;
        }
    }

    const range = defines.Range{
        .start = ast.extra[extraPtr + 1],
        .end = ast.extra[extraPtr + 2],
    };

    return switch (itemType) {
        .Enum => |enm| self.typecheckSwitchOnEnum(ast, itemTypeID, &enm, range, maybeExpected),
        .Union => |uni| self.typecheckSwitchOnUnion(ast, itemTypeID, &uni, range, maybeExpected),
        else => return common.debug.ShouldBeImpossible(@src()),
    };
}

fn typecheckSwitchOnUnion(
    self: *Typechecker,
    ast: *const Parser.AST,
    itemTypeID: TypeID,
    uni: *const Types.Union,
    range: defines.Range,
    maybeExpected: ?TypeID,
) Error!TypeID {
    // @Beware Hardcoded field size, must be kept in sync with parser.(union|struct|enum)Definition
    var fieldBuffer: [512]u32 = undefined;
    var bufferAllocator = std.heap.FixedBufferAllocator.init(@ptrCast(&fieldBuffer));

    const tag = self.typeTable.get(uni.tag).Enum;

    var fieldMap = std.DynamicBitSet.initEmpty(bufferAllocator.allocator(), tag.fields.len)
        catch return common.debug.ShouldBeImpossible(@src());

    var expected: ?TypeID = determineExpected(maybeExpected);
    var case = range.start;
    while (case < range.end) : (case += 4) {
        if (fieldMap.count() == fieldMap.capacity()) {
            self.report("Unreachable switch case.", .{ });
            return Error.UnreachableCodePath;
        }

        const caseLabel = ast.extra[case];
        const fieldName = 
            if (caseLabel == 0) blk: {
                fieldMap.setRangeValue(.{
                    .start = 0,
                    .end = fieldMap.capacity(),
                }, true);

                break :blk "else";
            }
            else blk: {
                const fieldPtr = try self.executer.eval(caseLabel, uni.tag);
                const field = self.executer.getValue(fieldPtr);

                const enumeration = switch (field) {
                    .Enum => |caseEnum| caseEnum.Value,
                    else => {
                        self.report("Expected a comptime enum for switch case label, received '{s}' instead.", .{
                            try self.typeName(self.arena.allocator(), try self.typecheckValue(fieldPtr, itemTypeID)),
                        });
                        return Error.InvalidSwitchCase;
                    }
                };

                if (fieldMap.isSet(enumeration)) {
                    self.report("Duplicate switch case '{s}'.", .{
                        tag.fields[enumeration],
                    });
                    return Error.DuplicateSwitchCase;
                }

                fieldMap.set(enumeration);
                break :blk tag.fields[enumeration];
            };

        const prev = self.currentScope;
        defer self.currentScope = prev;

        const captureCount = ast.extra[case + 1];
        if (captureCount > 1) {
            self.report("Value destruction is not supported.", .{ });
            return Error.IllegalSyntax;
        }
        else if (captureCount > 0)
        {
            const firstCapture = ast.extra[case + 2];

            const captureDecl = self.symbols.findDecl(.{
                .file = self.currentFile,
                .expr = firstCapture,
            });

            const field = try self.builder.internString(fieldName);
            const captureType = uni.fields[
                self.fieldIndex(itemTypeID, field) catch return common.debug.ShouldBeImpossible(@src())
            ].valueType;

            self.lookup.putNoClobber(self.arena.allocator(), captureDecl, .{
                .status = .Checked,
                .result = captureType,
            }) catch return Error.AllocatorFailure;
        }

        const branchType = try self.typecheckExpression(ast.extra[case + 3], expected);
        expected = expected orelse branchType;

        if (!self.suitable(expected.?, branchType)) {
            self.report(
                "Diverging result types '{s}' and '{s}' in switch expression case '{s}'.", .{
                try self.typeName(self.arena.allocator(), expected.?),
                try self.typeName(self.arena.allocator(), branchType),
                fieldName,
            });
            return Error.DivergingBranches;
        }
    }

    if (fieldMap.count() != fieldMap.capacity()) {
        common.log.err("Missing union fields:", .{});

        var iterator = fieldMap.iterator(.{
            .direction = .forward,
            .kind = .unset,
        });
        while (iterator.next()) |field| {
            const fieldName = tag.fields[field];
            common.log.err(("." ** 4) ++ " {s}", .{
                fieldName,
            });
        }

        self.report("In switch expression.", .{});
        return Error.UnhandledSwitchCases;
    }

    return expected orelse common.debug.ShouldBeImpossible(@src());
}

fn typecheckSwitchOnEnum(
    self: *Typechecker,
    ast: *const Parser.AST,
    itemTypeID: TypeID,
    enm: *const Types.Enum,
    range: defines.Range,
    maybeExpected: ?TypeID,
) Error!TypeID {
    // @Beware Hardcoded field size, must be kept in sync with parser.(union|struct|enum)Definition
    var fieldBuffer: [512]u32 = undefined;
    var bufferAllocator = std.heap.FixedBufferAllocator.init(@ptrCast(&fieldBuffer));

    var fieldMap = std.DynamicBitSet.initEmpty(bufferAllocator.allocator(), enm.fields.len)
        catch return common.debug.ShouldBeImpossible(@src());

    var expected: ?TypeID = determineExpected(maybeExpected);
    var case = range.start;
    while (case < range.end) : (case += 4) {
        if (fieldMap.count() == fieldMap.capacity()) {
            self.report("Unreachable switch case.", .{ });
            return Error.UnreachableCodePath;
        }

        const caseLabel = ast.extra[case];
        const field = 
            if (caseLabel == 0) blk: {
                fieldMap.setRangeValue(.{
                    .start = 0,
                    .end = fieldMap.capacity(),
                }, true);

                break :blk "else";
            }
            else blk: {
                const fieldPtr = try self.executer.eval(caseLabel, itemTypeID);
                const field = self.executer.getValue(fieldPtr);

                const enumeration = switch (field) {
                    .Enum => |caseEnum| caseEnum.Value,
                    else => {
                        self.report("Expected a comptime enum for switch case label, received '{s}' instead.", .{
                            try self.typeName(self.arena.allocator(), try self.typecheckValue(fieldPtr, itemTypeID)),
                        });
                        return Error.InvalidSwitchCase;
                    }
                };

                if (fieldMap.isSet(enumeration)) {
                    self.report("Duplicate switch case '{s}'.", .{
                        enm.fields[enumeration],
                    });
                    return Error.DuplicateSwitchCase;
                }

                fieldMap.set(enumeration);
                break :blk enm.fields[enumeration];
            };

        const captureCount = ast.extra[case + 1];
        if (captureCount > 1) {
            self.report("Too many captures for context.", .{ });
            return Error.IllegalSyntax;
        }
        else if (captureCount > 0) {
            const firstCapture = ast.extra[case + 2];

            const captureDecl = self.symbols.findDecl(.{
                .file = self.currentFile,
                .expr = firstCapture,
            });

            self.lookup.putNoClobber(self.arena.allocator(), captureDecl, .{
                .status = .Checked,
                .result = itemTypeID,
            }) catch return Error.AllocatorFailure;
        }

        const branchType = try self.typecheckExpression(ast.extra[case + 3], expected);
        expected = expected orelse branchType;

        if (!self.suitable(expected.?, branchType)) {
            self.report(
                "Diverging result types '{s}' and '{s}' in switch expression case '{s}'.", .{
                try self.typeName(self.arena.allocator(), expected.?),
                try self.typeName(self.arena.allocator(), branchType),
                field,
            });
            return Error.DivergingBranches;
        }
    }

    if (fieldMap.count() != fieldMap.capacity()) {
        common.log.err("Missing enum fields:", .{});

        var iterator = fieldMap.iterator(.{
            .direction = .forward,
            .kind = .unset,
        });
        while (iterator.next()) |field| {
            const fieldName = enm.fields[field];
            common.log.err(("." ** 4) ++ " {s}", .{
                fieldName,
            });
        }

        self.report("In switch expression.", .{});
        return Error.UnhandledSwitchCases;
    }

    return expected orelse common.debug.ShouldBeImpossible(@src());
}

pub fn registerType(self: *Typechecker, newType: TypeInfo) Error!TypeID {
    const isPresent = self.typeMap.getOrPut(self.arena.allocator(), newType)
        catch return Error.AllocatorFailure;

    if (!isPresent.found_existing) {
        const typeID = try self.typeTable.addOne(self.arena.allocator());
        isPresent.value_ptr.* = @intCast(typeID);

        self.typeTable.set(typeID, newType);
    }

    return isPresent.value_ptr.*;
}

pub fn report(self: *Typechecker, comptime fmt: []const u8, args: anytype) void {
    if (self.getFlag(.AttemptingEval)) {
        return;
    }

    common.log.err(fmt, args);
    const token = self.context.getTokens(self.currentFile).get(self.lastToken);
    const position = token.position(self.context, self.currentFile);

    common.log.err(("." ** 4) ++ " In {s} {d}:{d}", .{
        self.context.getFileName(self.currentFile),
        position.line,
        position.column,
    });
    token.printLocation(self.arena.allocator(), self.context, self.currentFile, position, self.callstack.size == 1);
    self.dumpCallStack();
}

pub fn dumpCallStack(self: *Typechecker) void {
    _ = self.callstack.pop();
    while (self.callstack.pop()) |declPtr| {
        const lastDecl = self.symbols.getDecl(declPtr);
        const modulePtr = self.symbols.scopes.get(lastDecl.scope).module;
        const module = self.modules.modules.get(modulePtr);
        const token = self.context.getTokens(module.dataIndex).get(lastDecl.token);
        const position = token.position(self.context, module.dataIndex);
        common.log.err(("." ** 8) ++ " Required from '{s} {d}:{d}'", .{
            self.context.getFileName(module.dataIndex),
            position.line,
            position.column,
        });
        token.printLocation(self.arena.allocator(), self.context, module.dataIndex, position, self.callstack.empty());
    }
}

pub fn assertCastable(self: *Typechecker, from: TypeID, to: TypeID) Error!void {
    const fmax = std.math.floatMax;
    const fmin = struct{fn fmin(comptime T: type) T { return -fmax(T); }}.fmin;

    const fromType = self.typeTable.get(from);
    const toType = self.typeTable.get(to);

    switch (to) {
        Comptime.Builtin.Type("any"),
        Comptime.Builtin.Type("mut any") => return Error.InferenceError,
        else => { },
    }

    if (from == to) {
        return Error.RedundantCast;
    }

    if (!self.mutable(from) and self.mutable(to)) {
        return Error.MutabilityViolation;
    }

    switch (fromType) {
        .Enum => |enm| switch (toType) {
            .Enum => try self.assertStructurallyIdentical(from, to),
            .Integer => |int| {
                try functional.throwIf(int.range().max < enm.fields.len - 1, Error.IncompatibleTypes);
            },
            .ComptimeInt => { },
            else => return Error.IncompatibleTypes,
        },
        .Union, .Struct => try self.assertStructurallyIdentical(from, to),
        .Bool => switch (toType) {
            .Integer => |int| try functional.throwIf(int.size <= 0, Error.SizeMismatch),
            else => return Error.IncompatibleTypes,
        },
        .ComptimeInt => try functional.throwIf(!self.isInt(to), Error.IncompatibleTypes),
        .ComptimeFloat => try functional.throwIf(!self.isFloat(to), Error.IncompatibleTypes),
        .Integer => |fromInt| switch (toType) {
            .Integer => |toInt| try functional.throwIf(!toInt.canContain(fromInt), Error.SizeMismatch),
            .Float => try functional.throwIf(
                fmax(f32) < @as(f32, @floatFromInt(fromInt.range().max))
                or fmin(f32) > @as(f32, @floatFromInt(fromInt.range().min)),
                Error.SizeMismatch,
            ),
            else => return Error.IncompatibleTypes,
        },
        .Float => switch (toType) {
            .Integer => |toInt| try functional.throwIf(
                fmax(f32) > @as(f32, @floatFromInt(toInt.range().max))
                or fmin(f32) < @as(f32, @floatFromInt(toInt.range().min)),
                Error.SizeMismatch,
            ),
            else => return Error.IncompatibleTypes,
        },
        .Pointer => |fromPtr| switch (toType) {
            .Pointer => |toPtr| try self.assertCastablePtr(fromPtr, toPtr),
            else => return Error.IncompatibleTypes,
        },
        .Function => switch (toType) {
            .Function => { },
            else => return Error.IncompatibleTypes,
        },
        .EnumLiteral => return Error.CastOfIncastableValue,
        .Any, .Type,
        .Noreturn, .Array,
        .Void => return Error.IncompatibleTypes,
    }
}

pub fn castable(self: *Typechecker, from: TypeID, to: TypeID) bool {
    self.assertCastable(from, to) catch return false;
    return true;
}

pub fn assertCastablePtr(self: *const Typechecker, this: Types.Pointer, that: Types.Pointer) Error!void {
    switch (this.size) {
        .Slice => try functional.throwIf(that.size == .Slice and self.sizeOf(this.child) != self.sizeOf(that.child), Error.MismatchingSliceChildType),
        .Single => try functional.throwIf(that.size == .Slice, Error.PointerSizeMismatch),
        .C => try functional.throwIf(that.size == .Slice, Error.PointerSizeMismatch),
    }

    try functional.throwIf(!self.mutable(this.child) and self.mutable(that.child), Error.MutabilityViolation);
}

/// Assert that 'this' is structurally identical to 'this'
/// Does no mutability check
pub fn assertStructurallyIdentical(self: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const fromType = self.typeTable.get(this);
    const toType = self.typeTable.get(that);

    if (std.meta.activeTag(fromType) != std.meta.activeTag(toType)) {
        return Error.IncompatibleTypes;
    }

    switch (fromType) {
        .Struct => |fromStruct| {
            if (fromStruct.fields.len != toType.Struct.fields.len) {
                return Error.StructuralMismatch;
            }

            for (fromStruct.fields, toType.Struct.fields) |fromField, toField| {
                if (!fromField.eql(toField, self)) {
                    return Error.StructuralMismatch;
                }
            }
        },
        .Union => |fromUnion| {
            const toUnion = toType.Union;
            if (fromUnion.isTagged != toUnion.isTagged) {
                return Error.StructuralMismatch;
            }

            if (fromUnion.fields.len != toUnion.fields.len) {
                return Error.StructuralMismatch;
            }

            for (fromUnion.fields, toUnion.fields) |fromField, toField| {
                if (!fromField.eql(toField, self)) {
                    return Error.StructuralMismatch;
                }
            }
        },
        .Enum => |fromEnum| {
            const toEnum = toType.Enum;

            if (fromEnum.fields.len != toEnum.fields.len) {
                return Error.StructuralMismatch;
            }

            for (fromEnum.fields, toEnum.fields) |fromField, toField| {
                if (!std.mem.eql(u8, fromField, toField)) {
                    return Error.StructuralMismatch;
                }
            }
        },
        else => return common.debug.ShouldBeImpossible(@src()),
    }
}

/// Check if 'this' is structurally identical to 'this'
pub fn structurallyIdentical(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    self.assertStructurallyIdentical(this, that) catch return false;
    return true;
}

/// Check if 'this' can be assigned to 'that'
pub fn suitable(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    self.assertSuitable(this, that) catch return false;
    return true;
}

/// Assert that 'this' can be assigned to 'that'
pub fn assertSuitable(self: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const thisType = self.typeTable.get(this);
    const thatType = self.typeTable.get(that);

    const thisAny = std.meta.activeTag(thisType) == .Any;
    const thatAny = std.meta.activeTag(thatType) == .Any;

    if (thisAny and thatAny) {
        return Error.InferenceError;
    }
    else if (thisAny) {
        return;
    }
    else if (thatAny) {
        return;
    }

    return switch (thatType) {
        .Noreturn => { },
        .Any => return common.debug.ShouldBeImpossible(@src()),
        else => switch (thisType) {
            .Any => return common.debug.ShouldBeImpossible(@src()),
            .ComptimeInt, .Integer => functional.throwIf(!self.isInt(that), Error.TypeMismatch),
            .ComptimeFloat, .Float => functional.throwIf(!self.isFloat(that), Error.TypeMismatch),
            // @Beware remove this altogether if you don't want structural coercion.
            .Struct, .Union, .Enum =>
                if (self.context.settings.hasFlag("--allow-structural-coercion")) self.assertStructurallyIdentical(this, that)
                else {
                    try functional.throwIf(std.meta.activeTag(thisType) != std.meta.activeTag(thatType), Error.TypeMismatch);
                    const names: struct { usize, usize } = switch (thisType) {
                        .Struct => .{ thisType.Struct.name, thatType.Struct.name },
                        .Union => .{ thisType.Union.name, thatType.Union.name },
                        .Enum => .{ thisType.Enum.name, thatType.Enum.name },
                        else => return common.debug.ShouldBeImpossible(@src()),
                    };
                    try functional.throwIf(names.@"0" != names.@"1", Error.TypeMismatch);
                },
            else => functional.throwIf(std.meta.activeTag(thisType) != std.meta.activeTag(thatType), Error.TypeMismatch),
        },
    };
}

pub fn assertComparable(self: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const thisType = self.typeTable.get(this);
    const thatType = self.typeTable.get(that);

    if (thisType.isZeroBit() or thatType.isZeroBit()) {
        return Error.OperationOnZeroBitSize;
    }

    try switch (thisType) {
        .ComptimeInt => functional.throwIf(!self.isInt(that), Error.ComparisonOnIncompatibleTypes),
        .ComptimeFloat => functional.throwIf(!self.isFloat(that), Error.ComparisonOnIncompatibleTypes),
        .Array => |thisArr| switch (thatType) {
            .Array => |thatArr| self.assertComparable(thisArr.child, thatArr.child),
            else => Error.ComparisonOnIncompatibleTypes,
        },
        .Enum => |thisEnm| switch (thatType) {
            .Enum => |thatEnm|
                if (thisEnm.name == thatEnm.name) { }
                else Error.ComparisonOnIncompatibleTypes,
            else => Error.ComparisonOnIncompatibleTypes,
        },
        .Bool, .Type => functional.throwIf(std.meta.activeTag(thatType) != std.meta.activeTag(thisType), Error.ComparisonOnIncompatibleTypes),
        .EnumLiteral => { }, // @Maybe TODO: do not allow this
        else => Error.ComparisonOnNonComparableType,
    };
}

pub fn comparable(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    self.assertComparable(this, that) catch return false;
    return true;
}

pub fn isInt(self: *const Typechecker, maybeInt: TypeID) bool {
    return switch (self.typeTable.get(maybeInt)) {
        .ComptimeInt, .Integer => true,
        else => false,
    };
}

pub fn isFloat(self: *const Typechecker, maybeFloat: TypeID) bool {
    return switch (self.typeTable.get(maybeFloat)) {
        .ComptimeFloat, .Float => true,
        else => false,
    };
}

pub fn assignable(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    return
        if (!self.mutable(this)) false
        else self.suitable(this, that);
}

pub fn switchable(self: *const Typechecker, this: TypeID) bool {
    return self.maybeSwitchable(this) != null;
}

pub fn maybeSwitchable(self: *const Typechecker, this: TypeID) ?TypeInfo {
    const info = self.typeTable.get(this);
    return switch (info) {
        .Enum => info,
        .Union => |uni| if (uni.isTagged) info else null,
        else => null,
    };
}

/// Assumes Typechecker.suitable has already been called for 'this' and 'that'
pub fn infer(self: *const Typechecker, this: TypeID, that: TypeID) Error!TypeID {
    try self.assertSuitable(this, that);

    const thisType = self.typeTable.get(this);
    const thatType = self.typeTable.get(that);

    return switch (thatType) {
        .Noreturn => that,
        .Any => this,
        .ComptimeInt, .ComptimeFloat => switch (thisType) {
            .Any => that,
            else => this,
        },
        else => switch (thisType) {
            .Any => that,
            .ComptimeInt, .ComptimeFloat => switch (thatType) {
                .Any => this,
                else => that,
            },
            .Integer =>
                if (thatType.Integer.size > thisType.Integer.size) that
                else this,
            else => this,
        },
    };
}

pub fn expectType(self: *Typechecker, exprPtr: defines.ExpressionPtr) Error!TypeID {
    return
        if (self.executer.expectType(exprPtr)) |val| self.executer.getValue(val).Type 
        else |err| err;
}

pub fn mutable(self: *const Typechecker, typeID: TypeID) bool {
    return switch (self.typeTable.get(typeID)) {
        .Any => |any| any,
        .Bool => |b| b,
        .Float => |fl| fl,
        .Struct => |str| str.mutable,
        .Union => |uni| uni.mutable,
        .Enum => |enu| enu.mutable,
        .Integer => |int| int.mutable,
        .Pointer => |ptr| ptr.mutable,
        .Array => |arr| arr.mutable,
        .Function => |func| func.mutable,
        else => false,
    };
}

pub fn canBeMutable(self: *const Typechecker, typeID: TypeID) bool {
    return switch (self.typeTable.get(typeID)) {
        .Any, .Bool, .Float,
        .Struct, .Union, .Enum,
        .Integer, .Pointer, .Array,
        .Function => !self.mutable(typeID),
        else => false,
    };
}

pub fn makeMutable(_: *const Typechecker, info: TypeInfo) TypeInfo {
    return switch (info) {
        .Any => .{ .Any = true },
        .Bool => .{ .Bool = true },
        .Float => .{ .Float = true },
        .Struct => |str| .{
            .Struct = .{
                .mutable = true,
                .name = str.name,
                .fields = str.fields,
                .definitions = str.definitions,
                .scope = str.scope,
            },
        },
        .Union => |uni| .{
            .Union = .{
                .mutable = true,
                .isTagged = uni.isTagged,
                .tag = uni.tag,
                .name = uni.name,
                .fields = uni.fields,
                .definitions = uni.definitions,
                .scope = uni.scope,
            },
        },
        .Enum => |enm| .{
            .Enum = .{
                .mutable = true,
                .name = enm.name,
                .fields = enm.fields,
                .definitions = enm.definitions,
                .scope = enm.scope,
            },
        },
        .Pointer => |ptr| .{
            .Pointer = .{
                .mutable = true,
                .child = ptr.child,
                .size = ptr.size,
            }
        },
        .Array => |arr| .{
            .Array = .{
                .mutable = true,
                .child = arr.child,
                .len = arr.len,
            },
        },
        .Function => |func| .{
            .Function = .{
                .mutable = true,
                .isComptime = func.isComptime,
                .argTypes = func.argTypes,
                .returnType = func.returnType,
            },
        },
        .Integer => |int| .{
            .Integer = .{
                .mutable = true,
                .size = int.size,
                .signed = int.signed,
            },
        },
        else => unreachable,
    };
}

/// In bytes
pub fn sizeOf(self: *const Typechecker, of: TypeID) u32 {
    return ret: switch (self.typeTable.get(of)) {
        .Pointer => @sizeOf(*void),
        .Function => @sizeOf(@TypeOf(&sizeOf)),
        .Enum => @sizeOf(u32),
        .Float, .ComptimeFloat => @sizeOf(f32),
        .Integer => |int| int.size,
        .Bool => @sizeOf(bool),
        .Void, .Noreturn, .EnumLiteral, .Type, .Any => 0,
        .Array => |arr| arr.len * self.sizeOf(arr.child),
        .ComptimeInt => @sizeOf(i64),
        .Struct => |str| {
            var size: u32 = 0;
            for (str.fields) |field| {
                size += self.sizeOf(field.valueType);
            }

            return size;
        },
        .Union => |uni| {
            const fields = uni.fields;

            var size: u32 = 0;
            for (fields) |field| {
                size = @max(size, self.sizeOf(field.valueType));
            }

            break :ret size + @as(u32, if (uni.isTagged) @sizeOf(u32) else 0);
        },
    };
}

pub fn tryGetDefinitionIndex(self: *Typechecker, from: TypeID, memberNamePtr: defines.StringPtr) Error!?defines.Offset {
    const member = self.builder.getInternedString(memberNamePtr);
    const decls = switch (self.typeTable.get(from)) {
        .Enum => |enm| enm.definitions,
        .Struct => |str| str.definitions,
        .Union => |uni| uni.definitions,
        else => {
            self.report("Definition index can only be used for structs, enums and unions. Received '{s}' instead.", .{
                try self.typeName(self.arena.allocator(), from),
            });
            return Error.IllegalSyntax;
        },
    };

    for (decls, 0..) |decl, index| {
        if (decl.name == try self.builder.internString(member)) {
            return @intCast(index);
        }
    }

    return null;
}

pub fn definitionIndex(self: *Typechecker, from: TypeID, member: defines.StringPtr) Error!defines.Offset {
    if (try self.tryGetDefinitionIndex(from, member)) |found| {
        return found;
    }

    self.report("Couldn't find definition '{s}' in type '{s}'.", .{
        self.builder.getInternedString(member),
        try self.typeName(self.arena.allocator(), from),
    });
    return Error.MissingDefinition;
}

pub fn tryGetFieldIndex(self: *Typechecker, from: TypeID, fieldNamePtr: defines.StringPtr) Error!?defines.Offset {
    const fieldName = self.builder.getInternedString(fieldNamePtr);
    const fields = switch (self.typeTable.get(from)) {
        .Struct => |str| str.fields,
        .Union => |uni| uni.fields,
        .Enum => |enm| blk: {
            for (enm.fields, 0..) |field, index| {
                if (std.mem.eql(u8, field, fieldName)) {
                    return @intCast(index);
                }
            }

            break :blk &.{};
        },
        else => {
            self.report("Given type '{s}' contains no fields.", .{
                try self.typeName(self.arena.allocator(), from),
            });
            return Error.FieldNotFound;
        },
    };

    for (fields, 0..) |field, index| {
        if (field.name == fieldNamePtr) {
            return @intCast(index);
        }
    }

    return null;
}

pub fn fieldIndex(self: *Typechecker, from: TypeID, fieldNamePtr: defines.StringPtr) Error!defines.Offset {
    if (try self.tryGetFieldIndex(from, fieldNamePtr)) |found| {
        return found;
    }

    self.report("Couldn't find field '{s}' in type '{s}'.", .{
        self.builder.getInternedString(fieldNamePtr),
        try self.typeName(self.arena.allocator(), from),
    });
    return Error.MissingDefinition;
}

pub fn typeName(self: *Typechecker, allocator: Allocator, typeID: TypeID) Error![]const u8 {
    const typename = struct {
        fn typename(this: *Typechecker, alc: Allocator, tid: TypeID) Error![]const u8 {
            const prefix = if (this.mutable(tid)) "mut " else "";

            const name = switch (this.typeTable.get(tid)) {
                .Struct => |str| this.builder.getInternedString(str.name),
                .Union => |uni| this.builder.getInternedString(uni.name),
                .Enum => |enu| this.builder.getInternedString(enu.name),
                else => unreachable,
            };

            var res = alc.alloc(u8, prefix.len + name.len) catch return Error.AllocatorFailure;
            res = std.fmt.bufPrint(res, "{s}{s}", .{prefix, name}) catch unreachable;
            this.typenameMap.putNoClobber(alc, tid, try this.builder.internString(res)) catch unreachable;
            return res;
        }
    }.typename;

    if (self.typenameMap.get(typeID)) |namePtr| {
        return self.builder.getInternedString(namePtr);
    }
    else return
        if (Comptime.Builtin.isBuiltinType(typeID)) Comptime.Builtin.TypeName(typeID)
        else ret: switch (self.typeTable.get(typeID)) {
            .Pointer => {
                const ptr: Types.Pointer = self.typeTable.get(typeID).Pointer;
                const child = try self.typeName(allocator, ptr.child);

                const mut = if (ptr.mutable) "mut " else "";
                const prefix = switch (ptr.size) {
                    .Slice => "[]",
                    .Single => "*",
                    .C => "[@c]",
                };

                var res = allocator.alloc(u8, child.len + prefix.len + mut.len) catch return Error.AllocatorFailure;
                res = std.fmt.bufPrint(res, "{s}{s}{s}", .{mut, prefix, child}) catch unreachable;
                self.typenameMap.putNoClobber(allocator, typeID, try self.builder.internString(res)) catch unreachable;
                break :ret res;
            },
            .Array => {
                const arr: Types.Array = self.typeTable.get(typeID).Array;
                const child = try self.typeName(allocator, arr.child);

                const prefix = if (arr.mutable) "mut " else "";
                const size = std.fmt.allocPrint(allocator, "[{d}]", .{arr.len})
                    catch return Error.AllocatorFailure;

                var res = allocator.alloc(u8, child.len + prefix.len + size.len) catch return Error.AllocatorFailure;
                res = std.fmt.bufPrint(res, "{s}{s}{s}", .{prefix, size, child}) catch unreachable;
                self.typenameMap.putNoClobber(allocator, typeID, try self.builder.internString(res)) catch unreachable;
                break :ret res;
            },
            .Struct, .Union, .Enum => typename(self, allocator, typeID),
            .Function => |func| {
                var res: []const u8 = if (func.mutable) "mut *fn (" else "*fn (";

                for (0..func.argTypes.len) |index| {
                    res = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                        res,
                        try self.typeName(allocator, func.argTypes[index]),
                        if (index == func.argTypes.len - 1) "" else ", ",
                    }) catch return Error.AllocatorFailure;
                }


                res = std.fmt.allocPrint(allocator, "{s}) -> {s}", .{res, try self.typeName(allocator, func.returnType)}) catch return Error.AllocatorFailure;
                self.typenameMap.putNoClobber(allocator, typeID, try self.builder.internString(res)) catch unreachable;
                break :ret res;
            },
            .EnumLiteral => "enum_literal",
            .ComptimeFloat => "comptime_float",
            .ComptimeInt => "comptime_int",
            .Type => "type",
            .Any => "any",
            .Bool => "bool",
            .Float => "float",
            .Noreturn => "noreturn",
            .Void => "void",
            .Integer => |int| {
                const mut = if (int.mutable) "mut " else "";
                const sign = if (int.signed) "i" else "u"; 
                const size = std.fmt.allocPrint(
                    allocator,
                    "{d}",
                    .{int.size},
                ) catch return Error.AllocatorFailure;

                var res = allocator.alloc(u8, sign.len + size.len + mut.len) catch return Error.AllocatorFailure;
                res = std.fmt.bufPrint(res, "{s}{s}{s}", .{mut, sign, size}) catch unreachable;
                self.typenameMap.putNoClobber(allocator, typeID, try self.builder.internString(res)) catch unreachable;
                break :ret res;
            },
        };
}

pub fn determineExpected(maybeExpected: ?TypeID) ?TypeID {
    return
        if (maybeExpected) |expected|
            if (
                expected == Comptime.Builtin.Type("any")
                or expected == Comptime.Builtin.Type("mut any")
            ) null
            else expected
        else null;
}

pub fn setFlag(self: *Typechecker, comptime flag: Flags, bit: bool) bool {
    defer self.flags.setValue(Flags.flag(flag), bit);
    return self.flags.isSet(Flags.flag(flag));
}

pub fn getFlag(self: *Typechecker, comptime flag: Flags) bool {
    return self.flags.isSet(Flags.flag(flag));
}

fn clearFlags(self: *Typechecker) void {
    const complement = self.flags.complement();
    self.flags.toggleAll();
    self.flags = self.flags.xorWith(complement);
}

/// Assumes metadata doesn't exist for given element
pub fn setMetadata(
    self: *Typechecker,
    kind: Element.Kind,
    element: defines.EitherPtr(defines.ExpressionPtr, defines.StatementPtr),
    metadata: []const Comptime.Value.Ptr,
) Error!void {
    return self.metadata.put(self.arena.allocator(), .{
        .kind = kind,
        .value = element,
    }, metadata) catch Error.AllocatorFailure;
}

pub fn getMetadata(
    self: *const Typechecker,
    elementType: Element.Kind,
    value: defines.EitherPtr(defines.ExpressionPtr, defines.StatementPtr)
) ?[]const defines.ExpressionPtr {
    return self.metadata.get(.{
        .kind = elementType,
        .value = value,
    });
}
