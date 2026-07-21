// TODO: Garbage collecting or something similar

const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const types = @import("type.zig");
const backend = @import("../codegen/backend.zig");

const assert = std.debug.assert;

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("../parser/parser.zig");
const Typechecker = @import("typechecker.zig");
const Resolver = @import("resolver.zig");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = common.CompilerError;
const TypeID = types.TypeID;
const TypeInfo = types.TypeInfo;
const JIR = backend.C.JIR;

const FlagMap = std.bit_set.IntegerBitSet(8);
const Cache = collections.HashMap(Resolver.ResolutionKey, Value.Ptr);
const Memory = std.ArrayList(Value);

pub const Flags = enum(u3) {
    ComptimeBanned = 0,
    LValue = 1,

    pub fn flag(flagToGet: Flags) u3 {
        return @intFromEnum(flagToGet);
    }
};

// TODO: Turn into a manually tagged union
// with possibly flattened fields for performance
// and memory usage
pub const Value = union(enum) {
    pub const Implicit = enum(u8) {
        pub const Type = enum(u8) {
            Any = 0,
            Incomplete = 1,
        };

        Void = 2,
    };

    pub const Ptr = defines.Offset;

    Int: i64,
    Float: f32,
    Bool: bool,
    Enum: struct {
        Type: TypeID,
        Value: u32,
    },
    Union: struct {
        Type: TypeID,
        Tag: u32,
        Value: Value.Ptr,
    },
    Struct: struct {
        Type: TypeID,
        Fields: defines.Range,
    },
    Type: TypeID,
    Pointer: struct {
        Type: TypeID,
        To: Value.Ptr,
    },
    String: []const u8,
    Slice: struct {
        const Self = @This();

        Type: TypeID, 
        Size: u32,
        To: Value.Ptr,

        pub fn at(self: *const Self, index: u32) Value.Ptr {
            assert(index < self.Size);
            return self.To + index;
        }
    },
    Function: JIR.Function,
    Void,
    Undefined: TypeID,
};

const Comptime = @This();

cache: Cache,
typechecker: *Typechecker,

arena: Arena,
gpa: Allocator,

flags: FlagMap,

memory: Memory,

rng: std.Random.DefaultPrng,

pub fn init(typechecker: *Typechecker, gpa: Allocator) Error!Comptime {
    var arena = Arena.init(gpa);
    const allocator = arena.allocator();

    var cache = Cache.empty;
    cache.ensureTotalCapacity(allocator, typechecker.symbols.resolutionMap.count()) catch return Error.AllocatorFailure;

    var memory = Memory.initCapacity(allocator, 512) catch return Error.AllocatorFailure;
    memory.appendAssumeCapacity(.{ .Type = Builtin.Type("any") });
    memory.appendAssumeCapacity(.{ .Type = Builtin.Type("incomplete") });
    memory.appendAssumeCapacity(.{ .Void = { } });

    return .{
        .typechecker = typechecker,
        .gpa = gpa,
        .cache = cache,
        .memory = memory,
        .flags = FlagMap.initEmpty(),
        .rng = std.Random.DefaultPrng.init(5315),
        .arena = arena,
    };
}

pub fn attemptEval(self: *Comptime, exprPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) ?Value.Ptr {
    const prev = self.typechecker.setFlag(.AttemptingEval, true);
    defer _ = self.typechecker.setFlag(.AttemptingEval, prev);
    return self.eval(exprPtr, maybeExpected) catch null;
}

pub fn eval(self: *Comptime, exprPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    const typechecker = self.typechecker;
    const file = typechecker.currentFile;
    const ast = typechecker.context.getAST(file);

    if (
        self.getFlag(.ComptimeBanned)
        and (
            ast.expressions.get(exprPtr).type == .FunctionDefinition
            and typechecker.hasMetadata(exprPtr, "@noComptime")
        )
    ) {
        self.report("Comptime execution is not possible in this context.", .{});
        return Error.ComptimeNotPossible;
    }

    const key = Resolver.ResolutionKey{
        .file = file,
        .expr = exprPtr,
    };

    if (self.cache.get(key)) |cached| {
        return cached;
    }

    const expr = ast.expressions.get(exprPtr);

    const addr = switch (expr.type) {
        .Identifier =>
            if (expr.value == 0) @intFromEnum(Value.Implicit.Type.Any)
            else if (typechecker.symbols.tryGetDecl(.{ .file = file, .expr = exprPtr })) |decl|
                try self.evalDecl(decl, maybeExpected)
            else {
                self.report("Unable to resolve identifier '{s}'.", .{
                    self.typechecker.context
                        .getTokens(self.typechecker.currentFile)
                        .get(expr.value)
                        .lexeme(self.typechecker.context, self.typechecker.currentFile)
                });
                return Error.MissingIdentifier;
            },
        .Call => try self.evalCall(expr.value, maybeExpected),
        .Indexing => try self.evalIndexing(expr.value),
        .Scoping => try self.evalScoping(exprPtr),
        .ExpressionList => try self.evalExpressionList(expr.value, maybeExpected),
        .Literal => try self.evalLiteral(expr.value, maybeExpected),

        .PointerType => try self.evalPtrType(.Single, expr.value),
        .SliceType => try self.evalPtrType(.Slice, expr.value),
        .CPointerType => try self.evalPtrType(.C, expr.value),
        .MutableType => try self.evalMutType(expr.value),
        .ArrayType => try self.evalArrType(expr.value),
        .FunctionType => try self.evalFuncType(exprPtr, expr.value),
        .EnumDefinition => try self.evalEnumType(exprPtr),
        .StructDefinition => try self.evalStructType(exprPtr),
        .UnionDefinition => try self.evalUnionType(exprPtr),

        .Conditional => try self.evalIfExpression(expr.value, maybeExpected),
        .Switch => try self.evalSwitchExpression(expr.value, maybeExpected),

        .Unary => try self.evalUnary(expr.value),
        .Binary => try self.evalBinary(expr.value),

        .Slicing => try self.evalSlicing(expr.value),

        .Mark => try self.evalMark(exprPtr, expr.value, maybeExpected),

        .Dot => try self.evalDot(expr.value),
        
        .Lambda => try self.evalLambda(exprPtr, expr.value, maybeExpected),
        .FunctionDefinition => try self.evalFunction(exprPtr, expr.value),

        // @Note should be handled with the statements.
        .Assignment => try self.typechecker.typecheckExpression(exprPtr, maybeExpected),
    };

    defer self.dumpMem();
    self.cache.putNoClobber(self.arena.allocator(), key, @intCast(addr))
        catch return Error.AllocatorFailure;
    return addr;
}

fn evalFunction(self: *Comptime, exprPtr: defines.ExpressionPtr, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const paramsRange = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    const argTypes = self.typechecker.arena.allocator().alloc(TypeID, paramsRange.len())
        catch return Error.AllocatorFailure;
    const argNames = self.typechecker.arena.allocator().alloc(defines.StringPtr, paramsRange.len())
        catch return Error.AllocatorFailure;

    const returnTypeExpr = ast.extra[extraPtr + 2];
    const bodyPtr = ast.extra[extraPtr + 3];

    var isComptime = self.typechecker.hasMetadata(exprPtr, "@comptime");

    for (paramsRange.start..paramsRange.end) |paramPtrPtr| {
        const param = ast.signatures.get(ast.extra[paramPtrPtr]);
        const argType = self.getValue(try self.expectType(param.type)).Type;
        argTypes[paramPtrPtr - paramsRange.start] = argType;

        const name = tokens.get(param.name).lexeme(self.typechecker.context, self.typechecker.currentFile);
        argNames[paramPtrPtr - paramsRange.start] = try self.typechecker.builder.internString(name);

        if (self.typechecker.typeTable.get(argType).isComptime(&self.typechecker.typeTable)) {
            isComptime = true;
        }
    }

    const returnType = Typechecker.determineExpected(
        self.getValue(try self.expectType(returnTypeExpr)).Type
    ) orelse {
        self.report("Unknown return type in function signatures is not allowed.", .{});
        return Error.IllegalGenericType;
    };

    const functionType = try self.typechecker.registerType(.{
        .Function = .{
            .mutable = false,
            .isComptime = isComptime,
            .argTypes = argTypes,
            .returnType = returnType,
        },
    });

    const prev = self.typechecker.currentScope;
    self.typechecker.currentScope = self.typechecker.symbols.tryGetDecl(.{
        .file = self.typechecker.currentFile,
        .expr = exprPtr
    }) orelse return common.debug.ShouldBeImpossible(@src());
    defer self.typechecker.currentScope = prev;

    const pc = self.typechecker.setFlag(.CoveredAllPaths, false);
    defer _ = self.typechecker.setFlag(.CoveredAllPaths, pc);

    try self.typechecker.typecheckStatement(bodyPtr, returnType);

    if (!(
        self.typechecker.typeTable.get(returnType).isZeroBit()
        or self.typechecker.getFlag(.CoveredAllPaths)
    )) {
        self.typechecker.report("Function with return type '{s}' does not return a value in all code paths.", .{
            try self.typechecker.typeName(self.arena.allocator(), returnType),
        });
        return Error.UncoveredCodePath;
    }

    const functionDef = JIR.Function{
        .signature = functionType,
        .body = try self.typechecker.lowerer.statement(bodyPtr),
        .name = try self.generateRandomName(.Function),
        .args = argNames,
    };

    return self.appendValue(.{
        .Function = functionDef,
    });
}

fn evalLambda(self: *Comptime, exprPtr: defines.ExpressionPtr, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    const expected =
        if (maybeExpected) |expected| switch (expected) {
            Builtin.Type("any"), Builtin.Type("mut any") => {
                self.report("Couldn't infer the type of lambda expression.", .{});
                return error.InferenceError;
            },
            else => switch (self.typechecker.typeTable.get(expected)) {
                .Function => |func| func,
                else => {
                    self.report("Expected '{s}', received lambda expression.", .{
                        try self.typechecker.typeName(self.arena.allocator(), expected),
                    });
                    return error.TypeMismatch;
                },
            },
        }
        else {
            self.report("Couldn't infer the type of lambda expression.", .{});
            return error.InferenceError;
        };

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const paramsRange = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    if (paramsRange.len() != expected.argTypes.len) blk: {
        if (
            paramsRange.len() == 0
            and expected.argTypes.len == 1
            and expected.argTypes[0] == Builtin.Type("void")
        ) {
            break :blk;
        }

        self.report(
            "Mismatching parameter counts in lambda expression. Expected {d}, received {d}", .{
                expected.argTypes.len,
                paramsRange.len(),
            }
        );
        return error.ArgumentCountMismatch;
    }

    const tokens = self.typechecker.context.getTokens(self.typechecker.currentFile);

    const prev = self.typechecker.currentScope;
    self.typechecker.currentScope = self.typechecker.symbols.findDecl(.{
        .file = self.typechecker.currentFile,
        .expr = exprPtr,
    });
    defer self.typechecker.currentScope = prev;

    const argNames = self.typechecker.arena.allocator().alloc(defines.StringPtr, paramsRange.len())
        catch return Error.AllocatorFailure;

    for (paramsRange.start..paramsRange.end) |index| {
        const paramName = tokens.get(ast.extra[index]).lexeme(self.typechecker.context, self.typechecker.currentFile);
        argNames[index - paramsRange.start] = try self.typechecker.builder.internString(paramName);
        if (self.typechecker.symbols.lookup.get(.{ .scope = self.typechecker.currentScope, .name = paramName })) |param| {
            self.typechecker.lookup.put(self.typechecker.arena.allocator(), param, .{
                .status = .Checked,
                .result = expected.argTypes[index - paramsRange.start],
            }) catch return Error.AllocatorFailure;
        }
        else return common.debug.ShouldBeImpossible(@src());
    }

    const declPtr = self.typechecker.callstack.peek() orelse return common.debug.ShouldBeImpossible(@src());
    const declStatus = self.typechecker.lookup.getPtr(declPtr) orelse return common.debug.ShouldBeImpossible(@src());

    // @Beware TODO: May cause strange bugs, properly design sometime.
    if (self.typechecker.context.settings.hasFlag("--allow-recursion")) {
        if (declStatus.status == .InProgress) {
            declStatus.* = .{
                .status = .Checked,
                .result = maybeExpected orelse return common.debug.ShouldBeImpossible(@src()),
            };
        }
    }

    const returnType = try self.typechecker.typecheckExpression(
        ast.extra[extraPtr + 2],
        expected.returnType,
    );

    if (expected.returnType != returnType) {
        self.report(
            "Mismatching return type in lambda expression. Expected '{s}', received '{s}'", .{
                try self.typechecker.typeName(self.arena.allocator(), expected.returnType),
                try self.typechecker.typeName(self.arena.allocator(), returnType),
            }
        );

        return error.TypeMismatch;
    }

    // @Incomplete TOOD: should insert a return statement here instead of a direct
    // expression. Finish after statement typechecking and lowering.
    const retExpr = try self.typechecker.lowerer.expression(ast.extra[extraPtr + 2], expected.returnType);
    const retStmt = try self.typechecker.builder.@"return"(retExpr);
    const functionDef = JIR.Function{
        .signature = maybeExpected orelse return common.debug.ShouldBeImpossible(@src()),
        .body = .{
            .start = retStmt,
            .end = retStmt + 1,
        },
        .name = try self.generateRandomName(.Function),
        .args = argNames,
    };

    return self.appendValue(.{
        .Function = functionDef,
    });
}

pub fn evalDot(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    const resType = try self.typechecker.typecheckDot(extraPtr);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const objectPtr = try self.eval(ast.extra[extraPtr], null);

    const memberToken = tokens.get(ast.extra[extraPtr + 1]);

    switch (memberToken.type) {
        .Ampersand => return self.appendValue(.{
            .Pointer = .{
                .Type = resType,
                .To = objectPtr,
            },
        }),
        .Star => return self.appendValue(self.getValue(self.getValue(objectPtr).Pointer.To)),
        else => { },
    }

    const object = self.getValue(objectPtr);
    const member = memberToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

    return switch (object) {
        .Slice => |slice|
            if (std.mem.eql(u8, member, "len")) self.appendValue(.{ .Int = slice.Size }) 
            else if (std.mem.eql(u8, member, "ptr")) self.appendValue(.{
                .Pointer = .{
                    .Type = resType,
                    .To = slice.To,
                },
            })
            else common.debug.ShouldBeImpossible(@src()),
        .Struct => |str| str.Fields.at(try self.typechecker.fieldIndex(str.Type, try self.typechecker.builder.internString(member))),
        .Union => |uni| {
            const index = try self.typechecker.fieldIndex(uni.Type, try self.typechecker.builder.internString(member));
            const unionType = self.typechecker.typeTable.get(uni.Type).Union;

            // @Beware Union.Tag starts from 0 but the tag field of the union is 
            // at 0 so you should always add 1.
            if (unionType.isTagged and index != uni.Tag + 1) {
                self.report("Attempt to access union field '{s}' while '{s}' is active on type '{s}'.", .{
                    member,
                    self.typechecker.builder.getInternedString(unionType.fields[uni.Tag + 1].name),
                    self.typechecker.builder.getInternedString(unionType.name),
                });
                return Error.UnionLayoutViolation;
            }

            return uni.Value;
        },
        else => common.debug.ShouldBeImpossible(@src()),
    };
}

pub fn evalMark(
    self: *Comptime,
    ptr: defines.EitherPtr(defines.ExpressionPtr, defines.StatementPtr),
    extraPtr: defines.OpaquePtr,
    maybeExpected: ?TypeID,
) Error!Value.Ptr {
    _ = try self.typechecker.typecheckMark(ptr, extraPtr, maybeExpected);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    if (self.typechecker.hasMetadata(ast.extra[extraPtr + 2], "@comptime")) {
        const exprType = try self.typechecker.typecheckExpression(ast.extra[extraPtr + 2], maybeExpected);

        // @Note force comptime eval when calling said function.
        if (self.typechecker.typeTable.get(exprType) != .Function) {
            self.report("Redundant @comptime mark in already comptime scope.", .{});
            return Error.RedundantMark;
        }
    }
    else if (
        self.typechecker.hasMetadata(ast.extra[extraPtr + 2], "@noComptime")
        and !self.typechecker.getFlag(.AttemptingEval)
    ) {
        const exprType = try self.typechecker.typecheckExpression(ast.extra[extraPtr + 2], maybeExpected);

        // @Note force comptime eval when calling said function.
        if (self.typechecker.typeTable.get(exprType) != .Function) {
            self.report("Comptime evaluation of expression is not possible due to '@noComptime' mark.", .{ });
            return Error.ComptimeNotPossible;
        }
    }

    return self.eval(ast.extra[extraPtr + 2], maybeExpected);
}

pub fn evalSlicing(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    const resType = try self.typechecker.typecheckSlicing(extraPtr);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const startIndex = self.getValue(try self.expectDefined(ast.extra[extraPtr + 1], null)).Int;
    const endIndex = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], null)).Int;

    const slice = switch (self.getValue(try self.expectDefined(ast.extra[extraPtr], null))) {
        .Slice => |slice| slice,
        .Pointer => |ptr| (Value{
            .Slice = .{
                .Type = resType,
                .Size = @intCast(endIndex - startIndex),
                .To = ptr.To,
            },
        }).Slice,
        else => return common.debug.ShouldBeImpossible(@src()),
    };

    if (startIndex >= self.memory.items.len or endIndex > self.memory.items.len) {
        self.report("Range [{d}..{d}] is outside out the bound of comptime memory.", .{
            startIndex,
            endIndex,
        });
        return Error.OutOfMemory;
    }

    if (startIndex >= slice.Size) {
        self.report("Invalid slice starting position {d}. Slice length is {d}.", .{
            startIndex,
            slice.Size,
        });
        return Error.IndexOutOfBounds;
    }

    if (endIndex > slice.Size) {
        self.report("Invalid slice ending position {d}. Slice length is {d}.", .{
            endIndex,
            slice.Size,
        });
        return Error.IndexOutOfBounds;
    }


    return self.appendValue(.{
        .Slice = .{
            .Type = resType,
            .Size = @intCast(endIndex - startIndex),
            .To = @intCast(slice.To + startIndex),
        },
    });
}

pub fn evalBinary(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    _ = try self.typechecker.typecheckBinary(extraPtr);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const operation: Lexer.TokenType = @enumFromInt(ast.extra[extraPtr + 1]);

    switch (operation) {
        .Or, .And => |logic| {
            const isOr = logic == .Or;
            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], null));

            if (lhs.Bool == if (isOr) true else false) {
                return self.appendValue(.{
                    .Bool = isOr,
                });
            }

            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 1], null));
            return self.appendValue(.{
                .Bool =
                    if (isOr) lhs.Bool or rhs.Bool
                    else lhs.Bool and rhs.Bool,
            });
        },
        .EqualEqual, .BangEqual => |equality| {
            const multiplier = equality == .EqualEqual;

            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], null));
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], null));

            return self.appendValue(.{
                .Bool = multiplier and self.comptimeEq(lhs, rhs)
            });
        },
        .LeftShift, .RightShift,
        .Pipe, .Xor, .Ampersand => |bitwise| {
            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], null)).Int;
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], null)).Int;

            return self.appendValue(.{
                .Int = switch (bitwise) {
                    .LeftShift => lhs << @intCast(rhs),
                    .RightShift => lhs >> @intCast(rhs),
                    .Pipe => lhs | rhs,
                    .Xor => lhs ^ rhs,
                    .Ampersand => lhs & rhs,
                    else => return common.debug.ShouldBeImpossible(@src()),
                },
            });
        },
        .Greater, .LesserEqual => |comparison| {
            const multiplier = comparison == .Greater;

            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], null));
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], null));

            return self.appendValue(.{
                .Bool = multiplier and switch (lhs) {
                    .Int => lhs.Int > rhs.Int,
                    .Float => lhs.Float > rhs.Float,
                    else => return common.debug.ShouldBeImpossible(@src()),
                }
            });
        },
        .Lesser, .GreaterEqual => |comparison| {
            const multiplier = comparison == .Lesser;

            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], null));
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], null));

            return self.appendValue(.{
                .Bool = multiplier and switch (lhs) {
                    .Int => lhs.Int < rhs.Int,
                    .Float => lhs.Float < rhs.Float,
                    else => return common.debug.ShouldBeImpossible(@src()),
                }
            });

        },
        .Plus, .Minus, .Slash, .Star => |arithmetic| {
            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], null));
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], null));

            return self.appendValue(switch (arithmetic) {
                .Plus => switch (lhs) {
                    .Int => .{ .Int = lhs.Int + rhs.Int },
                    .Float => .{ .Float = lhs.Float + rhs.Float },
                    else => return common.debug.ShouldBeImpossible(@src()),
                },
                .Minus => switch (lhs) {
                    .Int => .{ .Int = lhs.Int - rhs.Int },
                    .Float => .{ .Float = lhs.Float - rhs.Float },
                    else => return common.debug.ShouldBeImpossible(@src()),
                },
                .Slash => switch (lhs) {
                    .Int => .{
                        .Int = blk: {
                            if (rhs.Int == 0) {
                                self.report("Division by zero.", .{});
                                return Error.DivisionByZero;
                            }

                            break :blk @divTrunc(lhs.Int, rhs.Int);
                        }
                    },
                    .Float => .{
                        .Float = blk: {
                            if (rhs.Float == 0) {
                                self.report("Division by zero.", .{});
                                return Error.DivisionByZero;
                            }

                            break :blk lhs.Float / rhs.Float;
                        }
                    },
                    else => return common.debug.ShouldBeImpossible(@src()),
                },
                .Star => switch (lhs) {
                    .Int => .{ .Int = lhs.Int * rhs.Int },
                    .Float => .{ .Float = lhs.Float * rhs.Float },
                    else => return common.debug.ShouldBeImpossible(@src()),
                },
                else => return common.debug.ShouldBeImpossible(@src()),
            });
        },
        else => return common.debug.ShouldBeImpossible(@src()),
    }
}

pub fn evalUnary(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    _ = try self.typechecker.typecheckUnary(extraPtr);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const operator: Lexer.TokenType = @enumFromInt(ast.extra[extraPtr]);
    const rhsPtr = try self.expectDefined(ast.extra[extraPtr + 1], null);
    const rhs = self.getValue(rhsPtr);
    switch (operator) {
        .Minus => switch (rhs) {
            .Float => |float| self.setValue(rhsPtr, .{ .Float = -float }),
            .Int => |int| self.setValue(rhsPtr, .{ .Int = -int }),
            else => return common.debug.ShouldBeImpossible(@src()),
        },
        .Tilde => self.setValue(rhsPtr, .{ .Int = ~rhs.Int }),
        .Bang => self.setValue(rhsPtr, .{ .Bool = !rhs.Bool }),
        else => return common.debug.ShouldBeImpossible(@src()),
    }

    return rhsPtr;
}

fn evalSwitchExpression(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    const resultType = try self.typechecker.typecheckSwitchExpression(extraPtr, maybeExpected);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const varToSwitchOn = try self.expectDefined(ast.extra[extraPtr], null);

    switch (self.getValue(varToSwitchOn)) {
        .Enum => |enm| {
            const cases = defines.Range{
                .start = ast.extra[extraPtr + 1],
                .end = ast.extra[extraPtr + 2],
            };

            var case = cases.start;
            while (case < cases.end) : (case += 4) {
                const fieldExprPtr = ast.extra[case];

                if (fieldExprPtr == 0) {
                    return self.expectDefined(ast.extra[case + 3], resultType);
                }

                const fieldPtr = try self.expectDefined(fieldExprPtr, varToSwitchOn);
                const field = self.getValue(fieldPtr);
                
                if (field.Enum.Value != enm.Value) {
                    continue;
                }

                const captureCount = ast.extra[case + 1];
                if (captureCount > 1) {
                    return common.debug.ShouldBeImpossible(@src());
                }
                else if (captureCount > 0) {
                    const firstCapture = ast.extra[case + 2];

                    self.cache.putNoClobber(self.arena.allocator(), .{
                        .file = self.typechecker.currentFile,
                        .expr = firstCapture,
                    }, varToSwitchOn) catch return Error.AllocatorFailure;
                }

                return self.expectDefined(ast.extra[case + 3], resultType);
            }

            return common.debug.ShouldBeImpossible(@src());
        },
        .Union => |uni| {
            const cases = defines.Range{
                .start = ast.extra[extraPtr + 1],
                .end = ast.extra[extraPtr + 2],
            };

            var case = cases.start;
            while (case < cases.end) : (case += 4) {
                const fieldExprPtr = ast.extra[case];

                if (fieldExprPtr == 0) {
                    return self.expectDefined(ast.extra[case + 3], resultType);
                }

                const fieldPtr = try self.expectDefined(fieldExprPtr, varToSwitchOn);
                const field = self.getValue(fieldPtr);

                if (field.Enum.Value != uni.Tag) {
                    continue;
                }

                const captureCount = ast.extra[case + 1];
                if (captureCount > 1) {
                    return common.debug.ShouldBeImpossible(@src());
                }
                else if (captureCount > 0) {
                    const firstCapture = ast.extra[case + 2];

                    self.cache.putNoClobber(self.arena.allocator(), .{
                        .file = self.typechecker.currentFile,
                        .expr = firstCapture,
                    }, uni.Value) catch return Error.AllocatorFailure;
                }

                return self.expectDefined(ast.extra[case + 3], resultType);
            }

            return common.debug.ShouldBeImpossible(@src());
        },
        else => return common.debug.ShouldBeImpossible(@src()),
    }
}

fn evalIfExpression(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    _ = try self.typechecker.typecheckIfExpression(extraPtr, maybeExpected);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const conditional = .{
        .condition = ast.extra[extraPtr],
        .then = ast.extra[extraPtr + 1],
        .otherwise = ast.extra[extraPtr + 2],
    };

    const condition = self.getValue(try self.expectDefined(conditional.condition, Builtin.Type("bool"))).Bool;
    
    return
        if (condition) self.expectDefined(conditional.then, maybeExpected)
        else self.expectDefined(conditional.otherwise, maybeExpected);
}

fn evalDecl(self: *Comptime, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!Value.Ptr {    const decls = self.typechecker.symbols.declarations;
    const decl  = decls.get(declPtr);

    const prevToken = self.typechecker.lastToken;
    const prevFile = self.typechecker.currentFile;
    const prevScope = self.typechecker.currentScope;
    if (decl.kind != .Builtin) {
        self.typechecker.currentScope = decl.scope;
        self.typechecker.currentFile = self.typechecker.modules.modules.items(.dataIndex)[self.typechecker.symbols.scopes.items(.module)[decl.scope]];
        self.typechecker.lastToken = decl.token;
    }
    defer self.typechecker.lastToken = prevToken;
    defer self.typechecker.currentFile = prevFile;
    defer self.typechecker.currentScope = prevScope;

    return switch (decl.kind) {
        .Builtin => try self.evalBuiltin(&decl, maybeExpected),
        .Variable => blk: {
            const expected = try self.typechecker.typecheckDecl(declPtr, maybeExpected);

            if (self.typechecker.mutable(expected)) {
                self.report("Comptime evaluation of mutable variable is not possible.", .{});
                return Error.ComptimeNotPossible;
            }

            const valuePtr = try self.expectDefined(decl.node, maybeExpected);
            break :blk self.castValue(valuePtr, expected);
        },
        .Capture => if (self.cache.get(.{
            .file = prevFile,
            .expr = decl.node,
        })) |capture| capture
        else Error.ComptimeNotPossible,
        else => |t| {
            self.report("{s} declaration is not implemented.", .{@tagName(t)});
            return common.debug.NotImplemented(@src());
        },
    };
}

fn evalBuiltinCall(self: *Comptime, extraPtr: defines.OpaquePtr, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    const BI = Resolver.BuiltinIndex;

    return switch (declPtr) {
        BI("cast") => self.evalCast(extraPtr, maybeExpected),
        BI("as") => self.evalTypeForwarding(extraPtr, maybeExpected),
        BI("typeOf") => self.evalTypeOf(extraPtr),
        BI("compileError") => self.evalCompileError(extraPtr),
        BI("unreachable") => {
            self.report("Reached unreachable code.", .{});
            return Error.UnreachableCodePath;
        },
        BI("compileLog") => self.evalCompileLog(extraPtr),
        else => {
            self.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[declPtr]});
            return Error.ComptimeNotPossible;
        },
    };
}

fn evalBuiltin(self: *Comptime, decl: *const Resolver.Declaration, maybeExpected: ?TypeID) Error!Value.Ptr {
    const BI = Resolver.BuiltinIndex;

    return
        if (Builtin.isBuiltinType(decl.type)) self.appendValue( .{ .Type = decl.type })
        else switch (decl.type) {
            BI("undefined") =>
                if (Typechecker.determineExpected(maybeExpected)) |expected|
                    if (self.typechecker.suitable(expected, comptime Builtin.Type("any")))
                        self.constructUndefined(expected)
                    else  {
                        self.report("Given type '{s}' can't be undefined.", .{
                            try self.typechecker.typeName(self.arena.allocator(), expected),
                        });
                        return Error.MissingTypeSpecifier;
                    }
                else {
                    self.report("Unable to infer the type of undefined value.", .{});
                    return Error.MissingTypeSpecifier;
                },
            BI("unreachable") => {
                self.report("Reached unreachable code.", .{});
                return Error.UnreachableCodePath;
            },
            else => {
                self.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[decl.type]});
                return Error.IllegalSyntax;
            },
        };
}

fn evalLiteral(self: *Comptime, tokenPtr: defines.TokenPtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    const token = self.typechecker.context.getTokens(self.typechecker.currentFile).get(tokenPtr);
    const lexeme = token.lexeme(self.typechecker.context, self.typechecker.currentFile);
    const value: Value = switch (token.type) {
        .True, .False => .{ .Bool = token.type == .True },
        .Float => .{ .Float = std.fmt.parseFloat(f32, lexeme) catch unreachable },
        .Integer => .{ .Int = std.fmt.parseInt(u32, lexeme, 10) catch |err| switch (err) {
            error.Overflow => {
                self.report("Given literal '{s}' is too big for comptime evaluation.", .{lexeme});
                return Error.IntegerOverflow;
            },
            else => unreachable,
        }},
        .String => .{ .String = lexeme },
        .EnumLiteral =>
            if (Typechecker.determineExpected(maybeExpected)) |expected|
                if (Builtin.Metadata(lexeme)) |metadata| .{
                    .Enum = .{
                        .Type = expected,
                        .Value = metadata,
                    },
                }
                else switch (self.typechecker.typeTable.get(expected)) {
                    .Enum => |enm| ret: for (enm.fields, 0..) |field, index| {
                        if (std.mem.eql(u8, field, lexeme[1..])) {
                            break :ret Value{
                                .Enum = .{
                                    .Type = expected,
                                    .Value = @intCast(index),
                                },
                            };
                        }
                    } else {
                        self.report("Couldn't find enumeration '{s}' in '{s}'.", .{
                            lexeme[1..],
                            try self.typechecker.typeName(self.arena.allocator(), expected),
                        });
                        return Error.FieldNotFound;
                    },
                    else => {
                        self.report("Failed to resolve the type of enum literal '{s}'. Context requires type '{s}'.", .{
                            lexeme,
                            try self.typechecker.typeName(self.arena.allocator(), expected),
                        });
                        return Error.TypeMismatch;
                    },
                }
            else {
                self.report("Couldn't infer the type of enum literal '{s}'.", .{
                    lexeme,
                });
                return Error.InferenceError;
            },
        else => return common.debug.ShouldBeImpossible(@src()),
    };

    return self.appendValue(value);
}

fn evalPtrType(
    self: *Comptime,
    comptime ptrType: @FieldType(types.Pointer, "size"),
    innerType: defines.ExpressionPtr
) Error!Value.Ptr {
    const prev = self.typechecker.setFlag(.CanCycle, true);
    defer _ = self.typechecker.setFlag(.CanCycle, prev);
    const inner = self.expectType(innerType) catch |err| switch (err) {
        Error.DependencyCycle => @intFromEnum(Value.Implicit.Type.Incomplete),
        else => return err,
    };

    const newType = TypeInfo{
        .Pointer = .{
            .size = ptrType,
            .mutable = false,
            .child = self.getValue(inner).Type,
        },
    };

    return self.appendValue(.{
        .Type = (try self.typechecker.registerType(newType)),
    });
}

fn evalFuncType(self: *Comptime, exprPtr: defines.ExpressionPtr, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const args = self.getValue(try self.expectDefined(ast.extra[extraPtr], null));
    const argSize: u32 = ret: switch (args) {
        .Slice => |slice| {
            var sub: u32 = 0;

            for (0..slice.Size) |index| {
                switch (self.memory.items[slice.at(@intCast(index))]) {
                    .Type => |t| sub += if (t == Builtin.Type("void")) 1 else 0,
                    else => |t|{
                        self.report("Expected a type expression, got '{s}' instead.", .{
                            @tagName(std.meta.activeTag(t)),
                        });
                        return Error.TypeMismatch;
                    },
                }
            }

            break :ret slice.Size;
        },
        .Type => |t| if (t == Builtin.Type("void")) 0 else 1,
        else => |t| {
            self.report(
                "Expected an argument type list in function type expression,"
                ++ " got '{s}' instead.", .{@tagName(std.meta.activeTag(t))});
            return Error.TypeMismatch;
        },
    };

    var argTypes = self.arena.allocator().alloc(TypeID, argSize) catch return Error.AllocatorFailure;
    var isComptime = self.typechecker.hasMetadata(exprPtr, "@comptime");

    switch (args) {
        .Type => |argType| if (argSize != 0) {
            argTypes[0] = argType;

            if (self.typechecker.typeTable.get(argType).isComptime(&self.typechecker.typeTable)) {
                isComptime = true;
            }
        },
        .Slice => |slice| {
            var realIndex: u32 = 0;
            for (0..slice.Size) |index| {
                if (self.memory.items[slice.at(@intCast(index))].Type != Builtin.Type("void")) {
                    const argType = self.memory.items[slice.at(@intCast(index))].Type;
                    argTypes[realIndex] = argType;
                    realIndex += 1;

                    if (self.typechecker.typeTable.get(argType).isComptime(&self.typechecker.typeTable)) {
                        isComptime = true;
                    }
                }
            }
        },
        else => unreachable,
    }

    const returnType = self.getValue(try self.expectType(ast.extra[extraPtr + 1]));
    const typeID = try self.typechecker.registerType(.{
        .Function = .{
            .mutable = false,
            .isComptime = isComptime,
            .argTypes = argTypes,
            .returnType = returnType.Type,
        },
    });

    return self.appendValue(.{
        .Type = typeID,
    });
}

fn evalEnumType(self: *Comptime, expr: defines.ExpressionPtr) Error!Value.Ptr {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const extraPtr: defines.OpaquePtr = ast.expressions.items(.value)[expr];

    const fieldRange = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[extraPtr + 2],
        .end = ast.extra[extraPtr + 3],
    };

    var fields = allocator.alloc([]const u8, fieldRange.len()) catch return Error.AllocatorFailure;

    for (0..fieldRange.len()) |index| {
        const token = tokens.get(ast.extra[fieldRange.at(@intCast(index))]);
        const lexeme = token.lexeme(self.typechecker.context, self.typechecker.currentFile);
        fields[index] = lexeme;
    }

    const name = try self.generateRandomName(.Enum);
    const newType = TypeInfo{
        .Enum = .{
            .mutable = false,
            .name = name,
            .fields = fields,
            .definitions = try self.handleScopeDecls(ast, tokens, defRange),
            .scope = self.typechecker.symbols.findDecl(.{
                .file = self.typechecker.currentFile,
                .expr = expr,
            })
        },
    };

    return self.appendValue(.{
        .Type = try self.typechecker.registerType(newType)
    });
}

fn evalStructType(self: *Comptime, expr: defines.ExpressionPtr) Error!Value.Ptr {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const extraPtr: defines.OpaquePtr = ast.expressions.items(.value)[expr];

    const fieldRange = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[extraPtr + 2],
        .end = ast.extra[extraPtr + 3],
    };

    var fields = allocator.alloc(types.FieldInfo, fieldRange.len()) catch return Error.AllocatorFailure;

    for (0..fieldRange.len()) |index| {
        const symbol = ast.signatures.get(ast.extra[fieldRange.at(@intCast(index))]);

        const symbolToken = tokens.get(symbol.name);
        const symbolName = symbolToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        const fieldType = try self.typechecker.expectType(symbol.type);

        fields[index] = types.FieldInfo{
            .public = symbol.public,
            .name = try self.typechecker.builder.internString(symbolName),
            .valueType = fieldType,
            .isComptime = self.typechecker.typeTable.get(fieldType).isComptime(&self.typechecker.typeTable),
        };
    }

    const name = try self.generateRandomName(.Struct);
    const newType = TypeInfo{
        .Struct = .{
            .mutable = false,
            .name = name,
            .fields = fields,
            .definitions = try self.handleScopeDecls(ast, tokens, defRange),
            .scope = self.typechecker.symbols.findDecl(.{
                .file = self.typechecker.currentFile,
                .expr = expr,
            })
        },
    };

    return self.appendValue(.{
        .Type = try self.typechecker.registerType(newType),
    });
}

fn evalUnionType(self: *Comptime, expr: defines.ExpressionPtr) Error!Value.Ptr {
    // @Beware manually tagged unions are banned, so some things are hardcoded here.

    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const extraPtr: defines.OpaquePtr = ast.expressions.items(.value)[expr];

    const tagged = ast.extra[extraPtr] == 1;
    const offset: u32 =
        if (tagged) 2
        else 1;

    const fieldRange = defines.Range{
        .start = ast.extra[extraPtr + offset],
        .end = ast.extra[extraPtr + offset + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[extraPtr + offset + 2],
        .end = ast.extra[extraPtr + offset + 3],
    };

    var tags = allocator.alloc([]const u8, fieldRange.len()) catch return Error.AllocatorFailure;

    for (0..fieldRange.len()) |index| {
        const symbolTokenPtr: defines.TokenPtr = ast.signatures.items(.name)[
            ast.extra[fieldRange.at(@intCast(index))]
        ];
        const symbolToken = tokens.get(symbolTokenPtr);
        const symbolName = symbolToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        tags[index] = symbolName;
    }

    const tagType = TypeInfo{
        .Enum = .{
            .mutable = true,
            .name = try self.generateRandomName(.Enum),
            .definitions = &.{},
            .fields = tags,
            .scope = self.typechecker.symbols.findDecl(.{
                .file = self.typechecker.currentFile,
                .expr = expr,
            })
        },
    };

    if (fieldRange.len() <= 1) {
        self.report("Pointless definition of union type with {d} field{s}.", .{
            fieldRange.len(),
            if (fieldRange.len() == 0) "s" else ""
        });
        return Error.PointlessUnionDefinition;
    }

    // @Beware manually tagged unions are not supported so this is fine,
    // however this must be properly handled when they are allowed.
    const tag = try self.typechecker.registerType(tagType);

    var fields = allocator.alloc(types.FieldInfo, fieldRange.len() + @intFromBool(tagged)) catch return Error.AllocatorFailure;

    if (tagged) {
        fields[0] = .{
            .public = false,
            .name = try self.typechecker.builder.internString("tag"),
            .valueType = tag,
            .isComptime = false,
        };
    }

    for (0..fieldRange.len()) |index| {
        const symbol = ast.signatures.get(ast.extra[fieldRange.at(@intCast(index))]);

        const symbolToken = tokens.get(symbol.name);
        const symbolName = symbolToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        const fieldType = try self.typechecker.expectType(symbol.type);

        fields[index + @intFromBool(tagged)] = types.FieldInfo{
            .public = symbol.public,
            .name = try self.typechecker.builder.internString(symbolName),
            .valueType = fieldType,
            .isComptime = self.typechecker.typeTable.get(fieldType).isComptime(&self.typechecker.typeTable),
        };
    }

    const name = try self.generateRandomName(.Union);
    const newType = TypeInfo{
        .Union = .{
            .isTagged = tagged,
            .tag = tag,
            .mutable = false,
            .name = name,
            .fields = fields,
            .definitions = try self.handleScopeDecls(ast, tokens, defRange),
            .scope = self.typechecker.symbols.findDecl(.{
                .file = self.typechecker.currentFile,
                .expr = expr,
            }),
        }
    };

    return self.appendValue(.{
        .Type = try self.typechecker.registerType(newType),
    });
}

fn evalCast(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    const targetType = try self.typechecker.typecheckCast(extraPtr, maybeExpected);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const thingToCastRange = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (thingToCastRange.len() != 1) {
        self.report("Multi-value type casting is not supported.", .{});
        return Error.MultivalueCast;
    }

    const thingToCast = try self.expectDefined(ast.extra[thingToCastRange.at(0)], null);

    return self.castValue(thingToCast, targetType);
}

pub fn evalCompileLog(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (args.len() != 1) {
        self.report("'compileLog' expects a single expression argument, received {d}.", .{
            args.len(),
        });
        return Error.ArgumentCountMismatch;
    }

    const message = switch (self.getValue(try self.eval(ast.extra[args.at(0)], null))) {
        .String => |str| str,
        else => {
            self.report("Expected a string message in compile log.", .{});
            return Error.TypeMismatch;
        },
    };

    if (self.typechecker.getFlag(.AttemptingEval)) {
        return @intFromEnum(Value.Implicit.Void);
    }

    common.log.info("COMPILE LOG: {s}", .{message});
    const token = self.typechecker.context.getTokens(self.typechecker.currentFile).get(self.typechecker.lastToken);
    const position = token.position(self.typechecker.context, self.typechecker.currentFile);

    common.log.info(("." ** 4) ++ " In {s} {d}:{d}", .{
        self.typechecker.context.getFileName(self.typechecker.currentFile),
        position.line,
        position.column,
    });
    token.printLocation(self.arena.allocator(), self.typechecker.context, self.typechecker.currentFile, position, self.typechecker.callstack.size == 1);
    return @intFromEnum(Value.Implicit.Void);
}

pub fn evalCompileError(self: *Comptime, extraPtr: defines.OpaquePtr) Error {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (args.len() != 1) {
        self.report("'compileError' expects a single expression argument, received {d}.", .{
            args.len(),
        });
        return Error.ArgumentCountMismatch;
    }

    const message = switch (self.getValue(try self.eval(ast.extra[args.at(0)], null))) {
        .String => |str| str,
        else => {
            self.report("Expected a string message in compile error.", .{});
            return Error.TypeMismatch;
        },
    };

    self.report("USERSPACE ERROR: {s}", .{message});
    return Error.UserspaceError;
}

pub fn evalTypeOf(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };
    
    if (args.len() != 1) {
        self.report("'typeOf' expects a single expression argument, received {d}.", .{
            args.len(),
        });
        return Error.ArgumentCountMismatch;
    }

    return self.appendValue(.{
        .Type = try self.typechecker.typecheckExpression(ast.extra[args.at(0)], Builtin.Type("type")),
    });
}

fn evalTypeForwarding(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    _ = try self.typechecker.typecheckTypeForwarding(extraPtr, maybeExpected);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    const typeToForward = self.getValue((try self.expectType(ast.extra[args.at(0)]))).Type;
    return self.expectDefined(ast.extra[args.at(1)], typeToForward);
}

fn evalExpressionList(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    const typeToInit = try self.typechecker.typecheckExpressionList(extraPtr, maybeExpected);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const range = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    if (maybeExpected == null and range.len() == 1) {
        return self.expectDefined(ast.extra[range.at(0)], null);
    }

    return self.constructFromList(typeToInit, range);
}

pub fn constructFromList(self: *Comptime, typeID: TypeID, _range: defines.Range) Error!Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    var range = _range;

    return ret: switch (self.typechecker.typeTable.get(typeID)) {
        .Void => {
            for (range.start..range.end) |extra| {
                _ = try self.expectDefined(ast.extra[extra], typeID);
            }

            break :ret @intFromEnum(Value.Implicit.Void);
        },
        .Enum => self.expectDefined(ast.extra[range.at(0)], typeID),
        .Struct => |str| self.constructStruct(ast, typeID, &str, range),
        .Union => |uni| self.constructUnion(ast, typeID, &uni, range),
        .Array => |arr| {
            while (range.len() != arr.len) {
                // @Beware trusting the typechecker to only allow
                // single item expression lists here.
                const exprPtr = ast.extra[range.at(0)];
                const expr = ast.expressions.get(exprPtr);
                range = switch (expr.type) {
                    .ExpressionList => .{
                        .start = ast.extra[expr.value],
                        .end = ast.extra[expr.value + 1],
                    },
                    else => return self.expectDefined(exprPtr, typeID),
                };
            }

            return self.constructArrayFromList(typeID, arr.child, range);
        },
        .Noreturn,
        .Type, .Function,
        .Bool, .Float, .Integer,
        .ComptimeInt, .ComptimeFloat => self.expectDefined(ast.extra[range.at(0)], typeID),
        else => common.debug.ShouldBeImpossible(@src())
    };
}

fn constructStruct(
    self: *Comptime,
    ast: *const Parser.AST,
    typeID: TypeID,
    str: *const types.Struct,
    range: defines.Range,
) Error!Value.Ptr {
    var start: isize = -1;
    for (0..range.len()) |idx| {
        const addr = try self.eval(
            ast.extra[range.at(@intCast(idx))],
            str.fields[idx].valueType
        );

        start = if (start == -1) addr else start;
    }

    return self.appendValue(.{
        .Struct = .{
            .Type = typeID,
            .Fields = defines.Range{
                .start = @intCast(start),
                .end = @intCast(start + range.len()),
            },
        },
    });
}

fn constructUnion(
    self: *Comptime,
    ast: *const Parser.AST,
    typeID: TypeID,
    uni: *const types.Union,
    range: defines.Range,
) Error!Value.Ptr {
    const tag = self.getValue(try self.eval(ast.extra[range.at(0)], uni.tag)).Enum.Value;
    const fieldType = uni.fields[tag + 1].valueType;
    const value = try self.constructFromList(fieldType, range.subRange(1));

    return self.appendValue(.{
        .Union = .{
            .Type = typeID,
            .Tag = tag,
            .Value = value,
        },
    });
}

fn constructArrayFromList(self: *Comptime, arr: TypeID, child: TypeID, range: defines.Range) Error!Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    var address: i64 = -1;

    for (range.start..range.end) |ptr| {
        const addr = try self.eval(ast.extra[ptr], child);

        address = if (address == -1) addr else address;
    }

    return self.appendValue(.{
        .Slice = .{
            .Type = arr,
            .To = @intCast(address),
            .Size = range.len(),
        },
    });
}

fn evalScoping(self: *Comptime, expr: defines.ExpressionPtr) Error!Value.Ptr {
    if (self.typechecker.symbols.resolutionMap.get(.{
        .file = self.typechecker.currentFile,
        .expr = expr,
    })) |decl| {
        return self.evalDecl(decl, null);
    }

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const extraPtr = ast.expressions.items(.value)[expr];

    _ = try self.typechecker.typecheckScoping(expr);
    const res = self.getValue(try self.expectType(ast.extra[extraPtr])).Type;

    const member = std.fmt.allocPrint(self.arena.allocator(),
        "{s}::{s}", .{
        try self.typechecker.typeName(self.arena.allocator(), res),
        tokens.get(ast.extra[extraPtr + 1]).lexeme(self.typechecker.context, ast.tokens),
    }) catch return Error.AllocatorFailure;

    const scope = switch (self.typechecker.typeTable.get(res)) {
        .Enum => |enm| ret: {
            if (try self.typechecker.tryGetFieldIndex(res, try self.typechecker.builder.internString(member))) |found| {
                return self.appendValue(.{
                    .Enum = .{
                        .Type = res,
                        .Value = found,
                    },
                });
            }

            break :ret enm.scope;
        },
        .Struct => |str| str.scope,
        .Union => |uni| uni.scope,
        else => {
            self.report("Attempt to scope on type '{s}', which contains no scope.", .{
                try self.typechecker.typeName(self.arena.allocator(), res),
            });
            return Error.ScopingOnNonScopedType;
        },
    };

    return self.evalDecl(self.typechecker.symbols.lookup.get(.{
        .scope = scope,
        .name = member,
    }) orelse return common.debug.ShouldBeImpossible(@src()), null);
}

fn evalCall(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    if (self.typechecker.symbols.resolutionMap.get(.{
        .file = self.typechecker.currentFile,
        .expr = ast.extra[extraPtr], 
    })) |builtinPtr| blk: {
        const decl = self.typechecker.symbols.declarations.get(builtinPtr);

        if (decl.kind != .Builtin) {
            break :blk;
        }

        if (Builtin.isBuiltinType(decl.type)) {
            break :blk;
        }

        return self.evalBuiltinCall(extraPtr, decl.type, maybeExpected);
    }

    _ = try self.typechecker.typecheckCall(extraPtr, maybeExpected);

    const maybeFunction = self.getValue(try self.expectDefined(ast.extra[extraPtr], null));
    const function = switch (maybeFunction) {
        .Type => |id| return self.evalExpressionList(
            ast.expressions.items(.value)[ast.extra[extraPtr + 1]],
            id,
        ),
        .Function => |func| func,
        else => return common.debug.ShouldBeImpossible(@src()),
    };

    _ = function;
    self.report("Comptime function calls are not (yet) supported.", .{});
    return common.debug.NotImplemented(@src());
}

fn evalIndexing(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    _ = try self.typechecker.typecheckIndexing(extraPtr);

    const lValue = self.getFlag(.LValue);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const slicePtr = try self.expectDefined(ast.extra[extraPtr], null);
    const slice = self.getValue(slicePtr);

    const indexPtr = try self.expectDefined(ast.extra[extraPtr + 1], null);
    const index = self.getValue(indexPtr);

    const size = switch (slice) {
        .Slice => |s| s.Size,
        .String => |s| s.len,
        .Pointer => |ptr|
            if (lValue) {
                const ptrType = TypeInfo{
                    .Pointer = .{
                        .mutable = true,
                        .child = self.typechecker.typeTable.get(ptr.Type).Pointer.child,
                        .size = .Single,
                    },
                };
                const ptrTypeID = (try self.typechecker.registerType(ptrType));

                return self.appendValue(.{
                    .Pointer = .{
                        .Type = ptrTypeID,
                        .To = @intCast(ptr.To + index.Int),
                    },
                });
            }
            else return @intCast(ptr.To + index.Int),
        else => {
            return common.debug.ShouldBeImpossible(@src());
        },
    };

    if (size <= index.Int) {
        self.report("Index out of bounds. Size: {d}, Index: {d}.", .{
            size,
            index.Int,
        });
        return Error.IndexOutOfBounds;
    }

    return
        if (lValue) ret: switch (slice) {
            .String => {
                self.report("Attempt to mutate immutable string literal.", .{});
                break :ret Error.MutabilityViolation;
            },
            .Slice => {
                const ptrType = TypeInfo{
                    .Pointer = .{
                        .mutable = true,
                        .child = self.typechecker.typeTable.get(slice.Slice.Type).Pointer.child,
                        .size = .Single,
                    },
                };
                const ptrTypeID = (try self.typechecker.registerType(ptrType));

                break :ret self.appendValue(.{
                    .Pointer = .{
                        .Type = ptrTypeID,
                        .To = slice.Slice.at(@intCast(index.Int)),
                    },
                });
            },
            else => common.debug.ShouldBeImpossible(@src()),
        }
        else switch (slice) {
            .String => |s| self.appendValue(.{
                .Int = s[@intCast(index.Int)],
            }),
            .Slice => slice.Slice.at(@intCast(index.Int)),
            else => common.debug.ShouldBeImpossible(@src()),
        };
}

fn evalMutType(self: *Comptime, exprPtr: defines.OpaquePtr) Error!Value.Ptr {
    const inner = self.getValue(try self.expectType(exprPtr));

    if (self.typechecker.canBeMutable(inner.Type)) {
        const typeInfo = self.typechecker.typeTable.get(inner.Type);
        const typeID = try self.typechecker.registerType(self.typechecker.makeMutable(typeInfo));

        return self.appendValue(.{
            .Type = typeID,
        });
    }
    else {
        self.report("Redundant 'mut' specifier on already mutable type '{s}'.", .{
            try self.typechecker.typeName(self.typechecker.arena.allocator(), inner.Type)
        });
        return Error.InvalidSpecifier;
    }
}

fn evalArrType(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const ptr = try self.expectDefined(ast.extra[extraPtr], null);
    const size = switch (self.getValue(ptr)) {
        .Int => |val|
            if (val <= std.math.maxInt(u32)) val
            else {
                self.report(
                    "Given value '{d}' exceeds the maximum supported array size of "
                    ++ "{d}.", .{
                        val,
                        std.math.maxInt(u32),
                    });
                return Error.SizeViolation;
            },
        else => {
            self.report("Expected a 'comptime_int' value as size specifier. Got '{s}' instead.", .{
                try self.typechecker.typeName(self.arena.allocator(),
                    try self.typechecker.typecheckValue(ptr, null),
                ),
            });
            return Error.TypeMismatch;
        },
    };

    const inner = self.getValue(try self.expectType(ast.extra[extraPtr + 1]));

    const newType = TypeInfo{
        .Array = .{
            .len = @intCast(size),
            .mutable = false,
            .child = inner.Type,
        },
    };

    return self.appendValue(.{
        .Type = try self.typechecker.registerType(newType),
    });
}

pub fn expectType(self: *Comptime, exprPtr: defines.ExpressionPtr) Error!Value.Ptr {
    const valuePtr = try self.expectDefined(exprPtr, Builtin.Type("type"));
    const value = self.getValue(valuePtr);
    return switch (value) {
        .Type => valuePtr,
        else => {
            self.report("Expected a type expression, got '{s}' instead.", .{
                try self.typechecker.typeName(self.arena.allocator(), try self.typechecker.typecheckValue(valuePtr, null))
            });
            return Error.UnexpectedNonTypeExpression;
        }
    };
}

fn expectDefined(self: *Comptime, exprPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) Error!Value.Ptr {
    const valuePtr = try self.eval(exprPtr, maybeExpected);
    const value = self.getValue(valuePtr);
    return switch (value) {
        .Undefined => {
            self.report("Attempt to perform operations on undefined value of type '{s}'.", .{
                try self.typechecker.typeName(self.arena.allocator(), try self.typechecker.typecheckValue(valuePtr, null))
            });
            return Error.UseOfUndefinedValue;
        },
        else => valuePtr,
    };
}

pub fn constructUndefined(self: *Comptime, valueType: TypeID) Error!Value.Ptr {
    return switch (self.typechecker.typeTable.get(valueType)) {
        .Function, .Type, .Any, .Noreturn, .EnumLiteral => {
            self.report("Given type '{s}' can't be undefined.", .{
                try self.typechecker.typeName(self.arena.allocator(), valueType)
            });
            return Error.IllegalSyntax;
        },
        else => self.appendValue(.{ .Undefined = valueType }),
    };
}

pub fn generateRandomName(self: *Comptime, comptime mode: @TypeOf(.EnumLiteral)) Error!u32 {
    return self.typechecker.builder.internString(
        try self.generateRandomNameString(mode)
    );
}

pub fn generateRandomNameString(self: *Comptime, comptime mode: @TypeOf(.EnumLiteral)) Error![]const u8 {
    const randint = self.rng.next();

    return std.fmt.allocPrint(self.arena.allocator(), "$$anon_"++@tagName(mode)++"_{d}", .{
        randint
    }) catch Error.AllocatorFailure;
}

// @Beware, scope declarations must be comptime since they are technically
// top-level declarations.
fn handleScopeDecls(
    self: *Comptime,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    defRange: defines.Range,
) Error![]types.FieldInfo {
    const allocator = self.arena.allocator();

    const defsBuffer = allocator.alloc(types.FieldInfo, defRange.len()) catch return Error.AllocatorFailure;
    var defs = std.ArrayList(types.FieldInfo).initBuffer(defsBuffer);

    for (0..defRange.len()) |defIndex| {
        const defPtr = ast.extra[defRange.at(@intCast(defIndex))];
        const valPtr: defines.OpaquePtr = ast.statements.items(.value)[defPtr];

        const signature = ast.extra[valPtr];

        const sig = ast.signatures.get(signature);
        const symbolToken = tokens.get(sig.name);
        const symbolName = symbolToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        defs.appendAssumeCapacity(types.FieldInfo{
            .public = sig.public,
            .name = try self.typechecker.builder.internString(symbolName),
            .valueType = Builtin.Type("incomplete"),
            .isComptime = false,
            // .valueType = (try self.typechecker.expectType(sig.type)),
        });
    }

    return defs.items;
}

fn castValue(self: *Comptime, valuePtr: Value.Ptr, to: TypeID) Error!Value.Ptr {
    const value = self.getValue(valuePtr);
    const newValue: Value = switch (value) {
        .Pointer => |ptr| .{
            .Pointer = .{
                .Type = to,
                .To = ptr.To,
            },
        },
        .Function => value,
        .Float => |fromFloat| .{
            .Int = @intFromFloat(fromFloat),
        },
        .Int => |fromInt| switch (self.typechecker.typeTable.get(to)) {
            .Integer => value,
            else => .{ .Float = @floatFromInt(fromInt) },
        },
        .Bool => |fromBool| switch (self.typechecker.typeTable.get(to)) {
            .Bool => .{ .Bool = fromBool },
            else => .{ .Int = @intFromBool(fromBool) },
        },
        .Enum => |fromEnum| .{
            .Enum = .{
                .Type = to,
                .Value = fromEnum.Value,
            },
        },
        .Struct => |fromStruct| Value{
            .Struct = .{
                .Type = to,
                .Fields = fromStruct.Fields,
            },
        },
        .Union => |fromUni| Value{
            .Union = .{
                .Type = to,
                .Tag = fromUni.Tag,
                .Value = fromUni.Value,
            },
        },
        .Slice => |slice| switch (self.typechecker.typeTable.get(to).Pointer.size) {
            .Single, .C => |size| .{
                .Pointer = .{
                    .Type = self.typechecker.typeMap.get(TypeInfo{
                        .Pointer = .{
                            .mutable = self.typechecker.mutable(slice.Type), 
                            .size = size,
                            .child = self.typechecker.typeTable.get(slice.Type).Pointer.child,
                        },
                    }).?,
                    .To = slice.To,
                },
            },
            .Slice => .{
                .Slice = .{
                    .Size = slice.Size,
                    .To = slice.To,
                    .Type = to,
                },
            },
        },
        .Undefined => .{
            .Undefined = to, 
        },

        .Type =>
            if (self.typechecker.typeTable.get(to) == .Type) value
            else {
                self.report("Attempt to cast value of type 'type'.", .{});
                return Error.CastOfIncastableValue;
            },

        else => {
            self.report("Attempt to cast value of type '{s}.'", .{@tagName(value)});
            return Error.CastOfIncastableValue;
        }
    };

    self.memory.items[valuePtr] = newValue;
    return valuePtr;
}

fn comptimeEq(self: *const Comptime, lhs: Value, rhs: Value) bool {
    assert(std.meta.activeTag(lhs) == std.meta.activeTag(rhs));

    return switch (lhs) {
        .Int => lhs.Int == rhs.Int,
        .Float => lhs.Float == rhs.Float,
        .Slice => blk: {
            if (lhs.Slice.Size != rhs.Slice.Size) {
                break :blk false;
            }

            for (0..lhs.Slice.Size) |index| {
                const left = lhs.Slice.at(@intCast(index));
                const right = rhs.Slice.at(@intCast(index));
                if (!self.comptimeEq(self.getValue(left), self.getValue(right))) {
                    return false;
                }
            }

            return true;
        },
        .Enum => {
            assert(lhs.Enum.Type == rhs.Enum.Type);
            return lhs.Enum.Value == rhs.Enum.Value;
        },
        .Bool => lhs.Bool == rhs.Bool,
        .Type => lhs.Type == rhs.Type,
        else => unreachable,
    };
}

fn report(self: *Comptime, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME: " ++ fmt, args);
}

pub fn getValue(self: *const Comptime, address: defines.Offset) Value {
    assert(address <= self.memory.items.len);
    return self.memory.items[address];
}

fn setValue(self: *const Comptime, address: defines.Offset, new: Value) void {
    assert(address <= self.memory.items.len);
    self.memory.items[address] = new;
}

fn appendValue(self: *Comptime, value: Value) Error!Value.Ptr {
    const addr = self.memory.items.len;
    self.memory.append(self.arena.allocator(), value)
        catch return Error.AllocatorFailure;
    return @intCast(addr);
}

pub fn setFlag(self: *Comptime, comptime flag: Flags, bit: bool) bool {
    defer self.flags.setValue(Flags.flag(flag), bit);
    return self.flags.isSet(Flags.flag(flag));
}

pub fn getFlag(self: *Comptime, comptime flag: Flags) bool {
    return self.flags.isSet(Flags.flag(flag));
}

pub fn deinit(self: *Comptime) void {
    self.arena.deinit();
}

pub fn dumpMem(self: *const Comptime) void {
    if (common.debug.isDebug and self.typechecker.context.settings.hasFlag("--dump-memory")) {
        common.log.debug("MemDump:", .{});
        for (self.memory.items, 0..) |item, addr| {
            common.log.debug("    {d}: {any}{s}", .{
                addr,
                item,
                if (addr == self.memory.items.len - 1) "\n" else "",
            });
        }
    }
}

pub const Builtin = struct {
    pub fn isBuiltinType(typeID: TypeID) bool {
        return typeID <= Builtin.Type("any");
    }

    pub fn TypeName(btype: TypeID) []const u8 {
        assert(btype < builtinTypes.len);
        return builtinTypes[btype].name;
    }

    pub fn Type(btype: []const u8) TypeID {
        if (@typeInfo(@TypeOf(.{btype})).@"struct".fields[0].is_comptime) comptime {
            for (builtinTypes, 0..) |item, index| {
                if (std.mem.eql(u8, item.name, btype)) {
                    return index;
                }
            }

            @compileError("Unknown type.");
        };

        for (builtinTypes, 0..) |item, i| {
            if (std.mem.eql(u8, item.name, btype)) {
                return @intCast(i);
            }
        }

        common.debug.ShouldBeImpossible(@src()) catch unreachable;
    }

    pub fn Metadata(metadata: []const u8) ?defines.Offset {
        comptime if (@typeInfo(@TypeOf(.{metadata})).@"struct".fields[0].is_comptime) {
            for (builtinMetadata, 0..) |item, index| {
                if (std.mem.eql(u8, item, metadata)) {
                    return index;
                }
            }

            @compileError("Unknown metadata.");
        };

        for (builtinMetadata, 0..) |item, index| {
            if (std.mem.eql(u8, item, metadata)) {
                return @intCast(index);
            }
        }
        
        return null;
    }
};

pub const builtinTypes = [_]struct {
    name: []const u8,
    info: TypeInfo,
}{
    // u32
    .{ .name = "u32", .info = .{ .Integer = .{ .mutable = false, .size = 32, .signed = false, } } },
    // i32
    .{ .name = "i32", .info = .{ .Integer = .{ .mutable = false, .size = 32, .signed = true, } } },
    // u8
    .{ .name = "u8", .info = .{ .Integer = .{ .mutable = false, .size = 8, .signed = false, } } },
    // i8
    .{ .name = "i8", .info = .{ .Integer = .{ .mutable = false, .size = 8, .signed = true, } } },
    // bool
    .{ .name = "bool", .info = .{ .Bool = false } },
    // flaot
    .{ .name = "float", .info = .{ .Float = false } },
    // void
    .{ .name = "void", .info = .{ .Void = { }, } },
    // comptime int
    .{ .name = "comptime_int", .info = .{ .ComptimeInt = { }, } },
    // comptime float
    .{ .name = "comptime_float", .info = .{ .ComptimeFloat = { }, } },
    // type
    .{ .name = "type", .info = .{ .Type = { }, } },
    // noreturn
    .{ .name = "noreturn", .info = .{ .Noreturn = { }, } },
    // enum literal
    .{ .name = "enum_literal", .info = .{ .EnumLiteral = { } } },
    // any
    .{ .name = "any", .info = .{ .Any = false } },

    // mut any
    .{ .name = "mut any", .info = .{ .Any = true } },
    // incomplete
    .{ .name = "incomplete", .info = .{ .Struct = .{ .mutable = false, .name = Resolver.BuiltinIndex("any") + 3, .fields = &.{}, .definitions = &.{}, .scope = 0 } } },
    // entry_point
    .{ .name = "entry_point", .info = .{ .Function = .{ .mutable = false, .isComptime = false, .argTypes = &.{}, .returnType = 1 } } },
    // builtin_metadata
    .{ .name = "builtin_metadata", .info = .{ .Enum = .{ .mutable = false, .name = Resolver.BuiltinIndex("any") + 5, .fields = &.{}, .definitions = &.{}, .scope = 0 } } },
    // []u8
    .{ .name = "string", .info = .{ .Pointer = .{ .mutable = false, .child = 2, .size = .Slice, }, } },
};

pub const builtinMetadata = [_][]const u8 {
    "@noComptime",
    "@comptime",
    "@export",
    "@extern",
};
