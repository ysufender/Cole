// @TODO: Garbage collecting or something similar

const std = @import("std");
const common = @import("../../core/common.zig");
const defines = @import("../../core/defines.zig");
const collections = @import("../../util/collections.zig");
const types = @import("../type.zig");
const backend = @import("../../codegen/backend.zig");

const assert = std.debug.assert;

const Lexer = @import("../../lexer/lexer.zig");
const Parser = @import("../../parser/parser.zig");
const Typechecker = @import("../typechecker.zig");
const Resolver = @import("../resolver.zig");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = common.CompilerError;
const TypeID = types.TypeID;
const TypeInfo = types.TypeInfo;
const JIR = backend.C.JIR;
const Comptime = @import("../comptime.zig");

const FlagMap = std.bit_set.IntegerBitSet(8);

pub const FolderCacheKey = struct {
    file: defines.FilePtr,
    expr: defines.ExpressionPtr,
};
const Cache = collections.HashMap(FolderCacheKey, Comptime.Value.Ptr);
const DeclCache = collections.HashMap(defines.DeclPtr, Comptime.Value.Ptr);
const Memory = std.ArrayList(Comptime.Value);

pub const Flags = enum(u3) {
    ComptimeBanned = 0,
    LValue = 1,
    InComptimeCall = 2,

    pub fn flag(flagToGet: Flags) u3 {
        return @intFromEnum(flagToGet);
    }
};

const Folder = @This();

cache: Cache,

typechecker: *Typechecker,

arena: Arena,

flags: FlagMap,

memory: Memory,

rng: std.Random.DefaultPrng,

pub fn init(typechecker: *Typechecker, gpa: Allocator) Error!Folder {
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
        .cache = cache,
        .memory = memory,
        .flags = FlagMap.initEmpty(),
        .rng = std.Random.DefaultPrng.init(5315),
        .arena = arena,
    };
}

pub fn attemptEval(self: *Folder, exprPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) ?Comptime.Value.Ptr {
    const prev = self.typechecker.setFlag(.AttemptingEval, true);
    defer _ = self.typechecker.setFlag(.AttemptingEval, prev);
    return self.eval(exprPtr, maybeExpected) catch null;
}

pub fn eval(self: *Folder, exprPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
    const typechecker = self.typechecker;
    const file = typechecker.currentFile;

    const key = FolderCacheKey{
        .file = file,
        .expr = exprPtr,
    };

    const ast = typechecker.context.getAST(file);

    if (
        self.getFlag(.ComptimeBanned)
        or (
            ast.expressions.get(exprPtr).type != .FunctionDefinition
            and typechecker.hasMetadata(exprPtr, "@noComptime")
        )
    ) {
        self.report("Comptime execution is not possible in this context.", .{});
        return Error.ComptimeNotPossible;
    }

    if (self.cache.get(key)) |cached| {
        return cached;
    }

    const expr = ast.expressions.get(exprPtr);

    const addr = switch (expr.type) {
        .Identifier => addr: {
            self.typechecker.lastToken = expr.value;

            break :addr
                if (expr.value == 0) @intFromEnum(Comptime.Value.Implicit.Type.Any)
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
                };
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
        .TupleDefinition => try self.evalTuple(expr.value),

        .Conditional => try self.evalIfExpression(expr.value, maybeExpected),
        .Switch => try self.evalSwitchExpression(expr.value, maybeExpected),

        .Unary => try self.evalUnary(expr.value, maybeExpected),
        .Binary => try self.evalBinary(expr.value, maybeExpected),

        .Slicing => try self.evalSlicing(expr.value),

        .Mark => try self.evalMark(exprPtr, expr.value, maybeExpected),

        .Dot => try self.evalDot(expr.value),
        
        .Lambda => return common.debug.NotImplemented(self.typechecker.context.log, @src()),
        .FunctionDefinition => try self.evalFunction(exprPtr, expr.value),

        // @Note should be handled with the statements.
        .Assignment => try self.typechecker.typecheckExpression(exprPtr, maybeExpected),
    };

    if (
        self.typechecker.hasMetadata(exprPtr, "@comptime")
        and self.memory.items[addr] != .Function
    ) {
        self.report("Redundant comptime marking in already comptime scope.", .{});
        return Error.RedundantMark;
    }

    try self.cacheValue(key, addr);

    defer self.dumpMem();
    return addr;
}

fn evalFunction(self: *Folder, exprPtr: defines.ExpressionPtr, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
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

    const returnType = Typechecker.determineExpected(
        self.getValue(try self.expectType(returnTypeExpr)).Type
    ) orelse res: {
        isComptime = true;
        break :res Builtin.Type("any");
    };

    if (self.typechecker.typeTable.get(returnType).isComptime(undefined)) {
        isComptime = true;
    }

    const oldScope = self.typechecker.symbols.resolutionMap.get(.{
        .file = self.typechecker.currentFile,
        .expr = exprPtr,
    }).?;

    const scope = self.typechecker.symbols.scopes.addOne(self.typechecker.arena.allocator())
        catch return Error.AllocatorFailure;
    self.typechecker.symbols.scopes.set(scope, self.typechecker.symbols.scopes.get(oldScope));

    const prev = self.typechecker.currentScope;
    self.typechecker.currentScope = scope;
    defer self.typechecker.currentScope = prev;

    for (paramsRange.start..paramsRange.end) |paramPtrPtr| {
        const param = ast.signatures.get(ast.extra[paramPtrPtr]);
        const argType = Typechecker.determineExpected(
            self.getValue(try self.expectType(param.type)).Type
        ) orelse res: {
            isComptime = true;
            break :res Builtin.Type("any");
        };

        argTypes[paramPtrPtr - paramsRange.start] = argType;

        const name = tokens.get(param.name).lexeme(self.typechecker.context, self.typechecker.currentFile);
        argNames[paramPtrPtr - paramsRange.start] = try self.typechecker.builder.internString(name);

        if (self.typechecker.typeTable.get(argType).isComptime(&self.typechecker.typeTable)) {
            isComptime = true;
        }

        const declPtr = self.typechecker.symbols.lookup.get(.{
            .name = name,
            .scope = oldScope,
        }).?;
        const decl = self.typechecker.symbols.getDecl(declPtr);

        const newDecl = self.typechecker.symbols.declarations.addOne(self.typechecker.arena.allocator())
            catch return Error.AllocatorFailure;

        self.typechecker.lastToken = decl.token;

        self.typechecker.symbols.declarations.set(newDecl, .{
            .scope = scope,
            .name = try self.typechecker.builder.internString(name),
            .kind = decl.kind,
            .node = decl.node,
            .public = decl.public,
            .token = decl.token,
            .topLevel = decl.topLevel,
            .type = decl.type,
            .parent = decl.parent,
        });

        self.typechecker.symbols.lookup.put(self.typechecker.arena.allocator(), .{
            .scope = scope,
            .name = name
        }, newDecl) catch return Error.AllocatorFailure;

        if (self.typechecker.typeTable.get(argType).isZeroBit() and !isComptime) {
            self.report("Zero bit-sized parameter '{s}' is not allowed.", .{
                name
            });
            return Error.OperationOnZeroBitSize;
        }
    }

    const lret = self.typechecker.lowerer.lastReturnType;
    defer self.typechecker.lowerer.lastReturnType = lret;
    self.typechecker.lowerer.lastReturnType = returnType;

    if (
        self.typechecker.hasMetadata(exprPtr, "@variadic")
        and !self.typechecker.hasMetadata(exprPtr, "@extern")
    ) {
        self.report("Variadic arguments are only accepted for external functions.", .{});
        return Error.NonExternVariadicFunction;
    }

    if (
        self.typechecker.hasMetadata(exprPtr, "@variadic")
        and argTypes.len == 0
    ) {
        self.report("ISO C does not allow variadic arguments without a named parameter..", .{});
        return Error.UnnamedVariadic;
    }

    const functionType = try self.typechecker.registerType(.{
        .Function = .{
            .mutable = false,
            .isComptime = isComptime,
            .argTypes = argTypes,
            .returnType = returnType,
            .variadic = self.typechecker.hasMetadata(exprPtr, "@variadic"),
        },
    });

    // @Note comptime functions get typechecked on-the-fly.
    if (isComptime) {
        if (self.typechecker.hasMetadata(exprPtr, "@extern")) {
            self.report("Attempt to mark a comptime function as extern.", .{});
            return Error.ExternComptime;
        }

        const functionDef = JIR.Function{
            .signature = functionType,
            .body = bodyPtr,
            .name = try self.generateRandomName(.Function),
            .args = argNames,
            .source = self.typechecker.currentFile,
            .scope = scope,
            .expr = exprPtr,
        };

        return self.appendValue(.{
            .Function = functionDef,
        });
    }

    if (!self.typechecker.hasMetadata(exprPtr, "@extern")) {
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
    }

    const functionDef = JIR.Function{
        .signature = functionType,
        .body = try self.typechecker.lowerer.statement(bodyPtr),
        .name = try self.generateRandomName(.Function),
        .args = argNames,
        .source = self.typechecker.currentFile,
        .scope = scope,
        .expr = exprPtr,
    };

    return self.appendValue(.{
        .Function = functionDef,
    });
}

pub fn evalDot(self: *Folder, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
    const resType = try self.typechecker.typecheckDot(extraPtr);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const memberToken = tokens.get(ast.extra[extraPtr + 1]);

    // @TODO Handle proper addressing
    switch (memberToken.type) {
        .Ampersand, .Star => {
            self.report("Attempt to use pointers in compile time scope.", .{});
            return Error.ExistentialDilemma;
        },
        else => { },
    }

    const objectPtr = try self.eval(ast.extra[extraPtr], null);

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
            else common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
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
        else => common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
    };
}

pub fn evalMark(
    self: *Folder,
    ptr: defines.EitherPtr(defines.ExpressionPtr, defines.StatementPtr),
    extraPtr: defines.OpaquePtr,
    maybeExpected: ?TypeID,
) Error!Comptime.Value.Ptr {
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
    else if (self.typechecker.hasMetadata(ast.extra[extraPtr + 2], "@noComptime")) {
        const exprType = try self.typechecker.typecheckExpression(ast.extra[extraPtr + 2], maybeExpected);

        // @Note force comptime eval when calling said function.
        if (self.typechecker.typeTable.get(exprType) != .Function) {
            self.report("Comptime evaluation of expression is not possible due to '@noComptime' mark.", .{ });
            return Error.ComptimeNotPossible;
        }
    }

    return self.eval(ast.extra[extraPtr + 2], maybeExpected);
}

pub fn evalSlicing(self: *Folder, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
    const resType = try self.typechecker.typecheckSlicing(extraPtr);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const startIndex = self.getValue(try self.expectDefined(ast.extra[extraPtr + 1], null)).Int;
    const endIndex = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], null)).Int;

    const slice = switch (self.getValue(try self.expectDefined(ast.extra[extraPtr], null))) {
        .Slice => |slice| slice,
        .Pointer => |ptr| (Comptime.Value{
            .Slice = .{
                .Type = resType,
                .Size = @intCast(endIndex - startIndex),
                .To = ptr.To,
            },
        }).Slice,
        else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
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

pub fn evalBinary(self: *Folder, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
    _ = try self.typechecker.typecheckBinary(extraPtr, maybeExpected);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const lhsType = try self.typechecker.typecheckExpression(ast.extra[extraPtr], null);

    const operation: Lexer.TokenType = @enumFromInt(ast.extra[extraPtr + 1]);

    switch (operation) {
        .Or, .And => |logic| {
            const isOr = logic == .Or;
            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], lhsType));

            if (lhs.Bool == if (isOr) true else false) {
                return self.appendValue(.{
                    .Bool = isOr,
                });
            }

            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 1], lhsType));
            return self.appendValue(.{
                .Bool =
                    if (isOr) lhs.Bool or rhs.Bool
                    else lhs.Bool and rhs.Bool,
            });
        },
        .EqualEqual, .BangEqual => |equality| {
            const multiplier = equality == .EqualEqual;

            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], lhsType));
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], lhsType));

            return self.appendValue(.{
                .Bool = multiplier and self.comptimeEq(lhs, rhs)
            });
        },
        .LeftShift, .RightShift,
        .Pipe, .Xor, .Ampersand => |bitwise| {
            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], lhsType)).Int;
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], lhsType)).Int;

            return self.appendValue(.{
                .Int = switch (bitwise) {
                    .LeftShift => lhs << @intCast(rhs),
                    .RightShift => lhs >> @intCast(rhs),
                    .Pipe => lhs | rhs,
                    .Xor => lhs ^ rhs,
                    .Ampersand => lhs & rhs,
                    else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
                },
            });
        },
        .Greater, .LesserEqual => |comparison| {
            const multiplier = comparison == .Greater;

            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], lhsType));
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], lhsType));

            return self.appendValue(.{
                .Bool = multiplier and switch (lhs) {
                    .Int => lhs.Int > rhs.Int,
                    .Float => lhs.Float > rhs.Float,
                    else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
                }
            });
        },
        .Lesser, .GreaterEqual => |comparison| {
            const multiplier = comparison == .Lesser;

            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], lhsType));
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], lhsType));

            return self.appendValue(.{
                .Bool = multiplier and switch (lhs) {
                    .Int => lhs.Int < rhs.Int,
                    .Float => lhs.Float < rhs.Float,
                    else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
                }
            });

        },
        .Plus, .Minus, .Slash, .Star => |arithmetic| {
            const lhs = self.getValue(try self.expectDefined(ast.extra[extraPtr], lhsType));
            const rhs = self.getValue(try self.expectDefined(ast.extra[extraPtr + 2], null));

            return self.appendValue(switch (arithmetic) {
                .Plus => switch (lhs) {
                    .Int => .{ .Int = lhs.Int + rhs.Int },
                    .Float => .{ .Float = lhs.Float + rhs.Float },
                    else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
                },
                .Minus => switch (lhs) {
                    .Int => .{ .Int = lhs.Int - rhs.Int },
                    .Float => .{ .Float = lhs.Float - rhs.Float },
                    else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
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
                    else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
                },
                .Star => switch (lhs) {
                    .Int => .{ .Int = lhs.Int * rhs.Int },
                    .Float => .{ .Float = lhs.Float * rhs.Float },
                    else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
                },
                else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
            });
        },
        else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
    }
}

pub fn evalUnary(self: *Folder, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
    _ = try self.typechecker.typecheckUnary(extraPtr, maybeExpected);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const operator: Lexer.TokenType = @enumFromInt(ast.extra[extraPtr]);
    const rhsPtr = try self.expectDefined(ast.extra[extraPtr + 1], maybeExpected);
    const rhs = self.getValue(rhsPtr);
    switch (operator) {
        .Minus => switch (rhs) {
            .Float => |float| self.setValue(rhsPtr, .{ .Float = -float }),
            .Int => |int| self.setValue(rhsPtr, .{ .Int = -int }),
            else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
        },
        .Tilde => self.setValue(rhsPtr, .{ .Int = ~rhs.Int }),
        .Bang => self.setValue(rhsPtr, .{ .Bool = !rhs.Bool }),
        else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
    }

    return rhsPtr;
}

fn evalSwitchExpression(self: *Folder, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
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
                    return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
                }
                else if (captureCount > 0) {
                    const firstCapture = ast.extra[case + 2];

                    const capture = self.typechecker.symbols.findDecl(.{
                        .file = self.typechecker.currentFile,
                        .expr = firstCapture,
                    });
                    try self.cacheValue(.{
                        .file = self.typechecker.currentFile,
                        .expr = capture,
                    }, varToSwitchOn);
                }

                return self.expectDefined(ast.extra[case + 3], resultType);
            }

            return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
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
                    return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
                }
                else if (captureCount > 0) {
                    const firstCapture = ast.extra[case + 2];

                    const capture = self.typechecker.symbols.findDecl(.{
                        .file = self.typechecker.currentFile,
                        .expr = firstCapture,
                    });

                    try self.cacheValue(.{
                        .file = self.typechecker.currentFile,
                        .expr = capture,
                    }, varToSwitchOn);
                }

                return self.expectDefined(ast.extra[case + 3], resultType);
            }

            return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
        },
        else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
    }
}

fn evalIfExpression(self: *Folder, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
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

pub fn evalDecl(self: *Folder, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
    const decls = self.typechecker.symbols.declarations;

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

    const res = try switch (decl.kind) {
        .Builtin => try self.evalBuiltin(&decl, maybeExpected),
        .Variable => blk: {
            if (
                !decl.topLevel
                and !self.typechecker.context.settings.canFold()
            ) {
                self.report("Can't fold comptime expression in Og optimization mode.", .{});
                return Error.ComptimeNotPossible;
            }

            const expected = try self.typechecker.typecheckDecl(declPtr, maybeExpected);

            if (self.typechecker.mutable(expected)) {
                self.report("Comptime evaluation of mutable variable is not possible.", .{});
                return Error.ComptimeNotPossible;
            }

            switch (self.typechecker.typeTable.get(expected)) {
                .Pointer => {
                    self.report("Comptime evaluation of variable of type '{s}' is not possible.", .{
                        try self.typechecker.typeName(self.arena.allocator(), expected),
                    });
                    return Error.ComptimeNotPossible;
                },
                else => { },
            }

            const valuePtr = try self.expectDefined(decl.node, maybeExpected);
            break :blk self.castValue(valuePtr, expected, false);
        },
        .Capture =>
            if (self.cache.get(.{
                .file = self.typechecker.currentFile,
                .expr = decl.node,
            })) |capture| capture
            else Error.ComptimeNotPossible,
        .Parameter => return Error.EarlyEval,
        else => |t| {
            self.report("{s} declaration is not implemented.", .{@tagName(t)});
            return common.debug.NotImplemented(self.typechecker.context.log, @src());
        },
    };

    return res;
}

fn evalBuiltinCall(self: *Folder, extraPtr: defines.OpaquePtr, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
    const BI = Resolver.BuiltinIndex;

    return switch (declPtr) {
        BI("cast") => self.evalCast(extraPtr, maybeExpected, false),
        BI("unsafeCast") => self.evalCast(extraPtr, maybeExpected, true),
        BI("as") => self.evalTypeForwarding(extraPtr, maybeExpected),
        BI("typeOf") => self.evalTypeOf(extraPtr),
        BI("compileError") => self.evalCompileError(extraPtr),
        BI("typeName") => self.evalTypeName(extraPtr),
        BI("Tuple") => self.evalNewTuple(extraPtr),
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

fn evalBuiltin(self: *Folder, decl: *const Resolver.Declaration, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
    const BI = Resolver.BuiltinIndex;

    return
        if (Builtin.isBuiltinType(decl.type)) self.appendValue( .{ .Type = decl.type })
        else switch (decl.type) {
            BI("undefined") =>
                if (Typechecker.determineExpected(maybeExpected)) |expected| {
                    switch (self.typechecker.typeTable.get(expected)) {
                        .Function => {
                            self.report("Can't construct an undefined value of type '{s}'", .{
                                try self.typechecker.typeName(self.arena.allocator(), expected),
                            });
                            return Error.UndefinedPointerType;
                        },

                        else => { },
                    }

                    return self.constructUndefined(expected);
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

fn evalLiteral(self: *Folder, tokenPtr: defines.TokenPtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
    const token = self.typechecker.context.getTokens(self.typechecker.currentFile).get(tokenPtr);
    const lexeme = token.lexeme(self.typechecker.context, self.typechecker.currentFile);
    const value: Comptime.Value = switch (token.type) {
        .True, .False => .{ .Bool = token.type == .True },
        .Float => .{ .Float = std.fmt.parseFloat(f32, lexeme) catch unreachable },
        .Integer => .{ .Int = std.fmt.parseInt(u32, lexeme, 10) catch |err| switch (err) {
            error.Overflow => {
                self.report("Given literal '{s}' is too big for comptime evaluation.", .{lexeme});
                return Error.IntegerOverflow;
            },
            else => {
                self.report("Error while parsing integer literal '{s}'. {s}", .{lexeme, @errorName(err)});
                return Error.InternalError;
            },
        }},
        .String => .{
            .String = .{
                .type = .Cole,
                .str = lexeme,
            },
        },
        .LiteralPrefix =>
            if (Typechecker.determineExpected(maybeExpected)) |expected|
                if (Builtin.Metadata(lexeme)) |metadata| .{
                    .Enum = .{
                        .Type = expected,
                        .Value = metadata,
                    },
                }
                else switch (self.typechecker.typeTable.get(expected)) {
                    .Enum => |enm|
                    ret: for (enm.fields) |field| {
                        if (std.mem.eql(u8, field.name, lexeme[1..])) {
                            break :ret Comptime.Value{
                                .Enum = .{
                                    .Type = expected,
                                    .Value = field.value,
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
        else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
    };

    const res = try self.appendValue(value);
    const rest = try self.typechecker.typecheckValue(res, null);

    if (
        maybeExpected != null
        and maybeExpected.? != Builtin.Type("any")
        and maybeExpected.? != Builtin.Type("mut any")
        and self.typechecker.castable(rest, maybeExpected orelse rest, false)
    ) {
        return self.castValue(res, maybeExpected orelse rest, false);
    } else {
        return res;
    }
}

fn evalPtrType(
    self: *Folder,
    comptime ptrType: @FieldType(types.Pointer, "size"),
    innerType: defines.ExpressionPtr
) Error!Comptime.Value.Ptr {
    const prev = self.typechecker.setFlag(.CanCycle, true);
    defer _ = self.typechecker.setFlag(.CanCycle, prev);
    const inner = self.expectType(innerType) catch |err| switch (err) {
        Error.DependencyCycle => @intFromEnum(Comptime.Value.Implicit.Type.Incomplete),
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

fn evalFuncType(self: *Folder, exprPtr: defines.ExpressionPtr, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    // @Must be an expression list
    const argsExpr = ast.expressions.get(ast.extra[extraPtr]);

    const range = defines.Range{
        .start = ast.extra[argsExpr.value],
        .end = ast.extra[argsExpr.value + 1],
    };

    var argTypes = self.arena.allocator().alloc(TypeID, range.len()) catch return Error.AllocatorFailure;
    var isComptime = self.typechecker.hasMetadata(exprPtr, "@comptime");

    var realIndex: u32 = 0;
    for (range.start..range.end) |index| {
        const argType = self.getValue(try self.expectType(ast.extra[@intCast(index)])).Type;

        if (self.typechecker.typeTable.get(argType).isZeroBit()) {
            self.report("Zero bit sized function parameter '{s}' is not allowed.", .{
                try self.typechecker.typeName(self.arena.allocator(), argType),
            });
        }

        argTypes[realIndex] = argType;
        realIndex += 1;

        if (self.typechecker.typeTable.get(argType).isComptime(&self.typechecker.typeTable)) {
            isComptime = true;
        }
    }

    const returnType = self.getValue(try self.expectType(ast.extra[extraPtr + 1]));
    const typeID = try self.typechecker.registerType(.{
        .Function = .{
            .mutable = false,
            .isComptime = isComptime,
            .argTypes = argTypes,
            .returnType = returnType.Type,
            .variadic = self.typechecker.hasMetadata(exprPtr, "@variadic")
        },
    });

    return self.appendValue(.{
        .Type = typeID,
    });
}

fn evalEnumType(self: *Folder, expr: defines.ExpressionPtr) Error!Comptime.Value.Ptr {
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

    var fields = allocator.alloc(types.EnumField, fieldRange.len()) catch return Error.AllocatorFailure;

    var idx: u32 = 0;
    for (0..fieldRange.len()) |index| {
        defer idx += 1;

        const fieldPtr = ast.extra[fieldRange.at(@intCast(index))];

        const enumField: struct {
            name: defines.TokenPtr,
            isAssigned: u32,
            assignment: defines.ExpressionPtr,
        } = .{
            .name = ast.extra[fieldPtr],
            .isAssigned = ast.extra[fieldPtr + 1],
            .assignment = ast.extra[fieldPtr + 2],
        };

        if (enumField.isAssigned == 1) {
            const value = switch (self.getValue(try self.eval(enumField.assignment, null))) {
                .Int => |i| i,
                else => |val| {
                    self.report("Expected a compile time integer in enumeration assignment. Received '{s}' insteead.", .{
                        try self.typechecker.typeName(undefined, try self.typechecker.typecheckValueDirect(val, null))
                    });
                    return Error.TypeMismatch;
                },
            };

            idx = @intCast(value);
        }

        self.typechecker.lastToken = enumField.name;
        const token = tokens.get(self.typechecker.lastToken);
        const lexeme = token.lexeme(self.typechecker.context, self.typechecker.currentFile);
        fields[index] = .{
            .name = lexeme,
            .value = idx,
        };
    }

    const oldScope = self.typechecker.symbols.resolutionMap.get(.{
        .file = self.typechecker.currentFile,
        .expr = expr,
    }).?;

    if (self.getFlag(.InComptimeCall)) {
        const newScope = try self.typechecker.symbols.scopes.addOne(self.typechecker.arena.allocator());
        self.typechecker.symbols.scopes.set(newScope, self.typechecker.symbols.scopes.get(oldScope));
        self.typechecker.currentScope = newScope;
    }

    const scope =
        if (self.getFlag(.InComptimeCall) )self.typechecker.currentScope
        else oldScope;

    const name = try self.generateRandomName(.Enum);
    const newType = TypeInfo{
        .Enum = .{
            .mutable = false,
            .name = name,
            .fields = fields,
            .definitions = try self.handleScopeDecls(oldScope, scope, ast, tokens, defRange),
            .scope = scope,
            .external = self.typechecker.hasMetadata(expr, "@extern"),
        },
    };

    return self.appendValue(.{
        .Type = try self.typechecker.registerType(newType)
    });
}

fn evalStructType(self: *Folder, expr: defines.ExpressionPtr) Error!Comptime.Value.Ptr {
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

        self.typechecker.lastToken = symbol.name;

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

    const oldScope = self.typechecker.symbols.resolutionMap.get(.{
        .file = self.typechecker.currentFile,
        .expr = expr,
    }).?;

    if (self.getFlag(.InComptimeCall)) {
        const newScope = try self.typechecker.symbols.scopes.addOne(self.typechecker.arena.allocator());
        self.typechecker.symbols.scopes.set(newScope, self.typechecker.symbols.scopes.get(oldScope));
        self.typechecker.currentScope = newScope;
    }

    const scope =
        if (self.getFlag(.InComptimeCall)) self.typechecker.currentScope
        else oldScope;

    const name = try self.generateRandomName(.Struct);
    const newType = TypeInfo{
        .Struct = .{
            .mutable = false,
            .name = name,
            .fields = fields,
            .definitions = try self.handleScopeDecls(oldScope, scope, ast, tokens, defRange),
            .scope = scope,
            .external = self.typechecker.hasMetadata(expr, "@extern"),
            .isTuple = false,
        },
    };

    const res = try self.appendValue(.{
        .Type = try self.typechecker.registerType(newType),
    });

    if (self.getFlag(.InComptimeCall)) {
        self.cache.put(self.arena.allocator(), .{
            .file = self.typechecker.currentFile,
            .expr = expr,
        }, res) catch return Error.AllocatorFailure;
    }

    return res;
}

fn evalUnionType(self: *Folder, expr: defines.ExpressionPtr) Error!Comptime.Value.Ptr {
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

    var tags = allocator.alloc(types.EnumField, fieldRange.len()) catch return Error.AllocatorFailure;

    for (0..fieldRange.len()) |index| {
        const symbolTokenPtr: defines.TokenPtr = ast.signatures.items(.name)[
            ast.extra[fieldRange.at(@intCast(index))]
        ];

        self.typechecker.lastToken = symbolTokenPtr;

        const symbolToken = tokens.get(symbolTokenPtr);
        const symbolName = symbolToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        tags[index] = .{
            .name = symbolName,
            .value = @intCast(index),
        };
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
            }),
            .external = self.typechecker.hasMetadata(expr, "@extern"),
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

        self.typechecker.lastToken = symbol.name;

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

    const oldScope = self.typechecker.symbols.resolutionMap.get(.{
        .file = self.typechecker.currentFile,
        .expr = expr,
    }).?;

    if (self.getFlag(.InComptimeCall)) {
        const newScope = try self.typechecker.symbols.scopes.addOne(self.typechecker.arena.allocator());
        self.typechecker.symbols.scopes.set(newScope, self.typechecker.symbols.scopes.get(oldScope));
        self.typechecker.currentScope = newScope;
    }

    const scope =
        if (self.getFlag(.InComptimeCall) )self.typechecker.currentScope
        else oldScope;

    const name = try self.generateRandomName(.Union);
    const newType = TypeInfo{
        .Union = .{
            .isTagged = tagged,
            .tag = tag,
            .mutable = false,
            .name = name,
            .fields = fields,
            .definitions = try self.handleScopeDecls(oldScope, scope, ast, tokens, defRange),
            .scope = scope,
            .external = self.typechecker.hasMetadata(expr, "@extern"),
        }
    };

    return self.appendValue(.{
        .Type = try self.typechecker.registerType(newType),
    });
}

fn evalTuple(self: *Folder, exprListPtr: defines.ExpressionPtr) Error!Comptime.Value.Ptr {
    const tupleType = try self.typechecker.typecheckTupleDefinition(exprListPtr);
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const exprList: defines.OpaquePtr = ast.expressions.items(.value)[exprListPtr];
    return self.evalExpressionList(exprList, tupleType);
}

fn evalCast(self: *Folder, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID, unsafe: bool) Error!Comptime.Value.Ptr {
    const targetType = try self.typechecker.typecheckCast(extraPtr, maybeExpected, unsafe);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const thingToCastRange = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (thingToCastRange.len() > 1) {
        self.report("Multi-value type casting is not supported.", .{});
        return Error.MultivalueCast;
    }
    else if (thingToCastRange.len() == 0) {
        self.report("Can't cast void.", .{});
        return Error.CastOfIncastableValue;
    }

    const thingToCast = try self.expectDefined(ast.extra[thingToCastRange.at(0)], null);

    return self.castValue(thingToCast, targetType, false);
}

pub fn evalCompileLog(self: *Folder, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
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

    common.log.info("COMPILE LOG: {s}", .{message.str});
    const token = self.typechecker.context.getTokens(self.typechecker.currentFile).get(self.typechecker.lastToken);
    const position = token.position(self.typechecker.context, self.typechecker.currentFile);

    common.log.info(("." ** 4) ++ " In {s} {d}:{d}", .{
        self.typechecker.context.getFileName(self.typechecker.currentFile),
        position.line,
        position.column,
    });
    token.printLocationInfo(self.arena.allocator(), self.typechecker.context, self.typechecker.currentFile, position, self.typechecker.callstack.size == 1);
    return @intFromEnum(Comptime.Value.Implicit.Void);
}

pub fn evalNewTuple(self: *Folder, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    var fields = self.typechecker.arena.allocator().alloc(types.FieldInfo, args.len())
        catch return Error.AllocatorFailure;

    for (args.start..args.end, 0..) |ptr, idx| {
        const exprPtr = ast.extra[ptr];
        const fieldType = self.getValue(try self.expectType(exprPtr)).Type;

        const name = std.fmt.allocPrint(self.typechecker.arena.allocator(), "_{d}", .{idx})
            catch return Error.AllocatorFailure;

        fields[idx] = .{
            .name = try self.typechecker.builder.internString(name),
            .isComptime = self.typechecker.typeTable.get(fieldType).isComptime(undefined),
            .public = true,
            .valueType = fieldType,
        };
    }

    const newType = TypeInfo{
        .Struct = .{
            .name = try self.generateRandomName(.Tuple),
            .fields = fields,
            .definitions = &.{},
            .external = false,
            .mutable = false,
            .scope = 0,
            .isTuple = true,
        },
    };

    return self.typechecker.registerType(newType);
}

pub fn evalTypeName(self: *Folder, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (args.len() != 1) {
        self.report("'typeName' expects a single expression argument, received {d}.", .{
            args.len(),
        });
        return Error.ArgumentCountMismatch;
    }

    return self.appendValue(switch (self.getValue(try self.eval(ast.extra[args.at(0)], null))) {
        .Type => |t| .{
            .String = .{
                .type = .Cole,
                .str = self.typechecker.builder.getInternedString(
                    self.typechecker.typenameMap.get(t) orelse return common.debug.ShouldBeImpossible(undefined, @src()),
                ),
            },
        },
        .Function => |func| .{
            .String = .{
                .type = .Cole,
                .str = self.typechecker.builder.getInternedString(func.name),
            }
        },
        else => {
            self.report("Expected a type expression.", .{});
            return Error.TypeMismatch;
        },
    });
}

pub fn evalCompileError(self: *Folder, extraPtr: defines.OpaquePtr) Error {
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

    self.report("USERSPACE ERROR: {s}", .{message.str});
    return Error.UserspaceError;
}

pub fn evalTypeOf(self: *Folder, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
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

fn evalTypeForwarding(self: *Folder, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
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

fn evalExpressionList(self: *Folder, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
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

pub fn constructFromList(self: *Folder, typeID: TypeID, _range: defines.Range) Error!Comptime.Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    var range = _range;

    return ret: switch (self.typechecker.typeTable.get(typeID)) {
        .Void => {
            for (range.start..range.end) |extra| {
                _ = try self.expectDefined(ast.extra[extra], typeID);
            }

            break :ret @intFromEnum(Comptime.Value.Implicit.Void);
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
        else => common.debug.ShouldBeImpossible(self.typechecker.context.log, @src())
    };
}

fn constructStruct(
    self: *Folder,
    ast: *const Parser.AST,
    typeID: TypeID,
    str: *const types.Struct,
    range: defines.Range,
) Error!Comptime.Value.Ptr {
    const start = self.memory.items.len;

    for (0..range.len()) |idx| {
        const addr = try self.eval(
            ast.extra[range.at(@intCast(idx))],
            str.fields[idx].valueType
        );

        _ = try self.appendValue(self.getValue(addr));
    }

    return self.appendValue(.{
        .Struct = .{
            .Type = typeID,
            .Fields = defines.Range{
                .start = @intCast(start),
                .end = @intCast(self.memory.items.len),
            },
        },
    });
}

fn constructUnion(
    self: *Folder,
    ast: *const Parser.AST,
    typeID: TypeID,
    uni: *const types.Union,
    range: defines.Range,
) Error!Comptime.Value.Ptr {
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

fn constructArrayFromList(self: *Folder, arr: TypeID, child: TypeID, range: defines.Range) Error!Comptime.Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const address = self.memory.items.len;

    for (range.start..range.end) |ptr| {
        const addr = try self.eval(ast.extra[ptr], child);

        _ = try self.appendValue(self.getValue(addr));
    }

    return self.appendValue(.{
        .Slice = .{
            .Type = arr,
            .To = @intCast(address),
            .Size = range.len(),
        },
    });
}

fn evalScoping(self: *Folder, expr: defines.ExpressionPtr) Error!Comptime.Value.Ptr {
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
    }) orelse return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()), null);
}

pub fn evalCall(self: *Folder, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
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

    var maybeFunction = &self.memory.items[(try self.expectDefined(ast.extra[extraPtr], null))];
    const function = switch (maybeFunction.*) {
        .Type => |id| {
            _ = try self.typechecker.typecheckCall(extraPtr, maybeExpected);
            return self.evalExpressionList(
                ast.expressions.items(.value)[ast.extra[extraPtr + 1]],
                id,
            );
        },
        .Function => &maybeFunction.Function,
        else => return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
    };

    _ = try self.typechecker.typecheckCall(extraPtr, maybeExpected);
        
    const signature = self.typechecker.typeTable.get(function.signature).Function;

    const argsListPtr = ast.extra[extraPtr + 1];
    const argsList: defines.OpaquePtr = ast.expressions.items(.value)[argsListPtr];

    const argsRange = defines.Range{
        .start = ast.extra[argsList],
        .end = ast.extra[argsList + 1],
    };

    var args = self.arena.allocator().alloc(Comptime.Value.Ptr, argsRange.len())
        catch return Error.AllocatorFailure;

    for (argsRange.start..argsRange.end, 0..) |ptr, idx| {
        args[idx] = try self.eval(ast.extra[@intCast(ptr)], if (idx >= signature.argTypes.len) null else signature.argTypes[idx]);
    }

    const prev = self.setFlag(.InComptimeCall, true);
    defer _ = self.setFlag(.InComptimeCall, prev);

    const val = try self.typechecker.executer.executeCall(function, args);

    return switch (val) {
        .Void => @intFromEnum(Comptime.Value.Implicit.Void),
        else => self.appendValue(val),
    };
}

fn evalIndexing(self: *Folder, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
    _ = try self.typechecker.typecheckIndexing(extraPtr);

    const lValue = self.getFlag(.LValue);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const slicePtr = try self.expectDefined(ast.extra[extraPtr], null);
    const slice = self.getValue(slicePtr);

    const indexPtr = try self.expectDefined(ast.extra[extraPtr + 1], null);
    const index = self.getValue(indexPtr);

    const size = switch (slice) {
        .Slice => |s| s.Size,
        .String => |s| s.str.len,
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
            return common.debug.ShouldBeImpossible(self.typechecker.context.log, @src());
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
            else => common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
        }
        else switch (slice) {
            .String => |s| self.appendValue(.{
                .Int = s.str[@intCast(index.Int)],
            }),
            .Slice => slice.Slice.at(@intCast(index.Int)),
            else => common.debug.ShouldBeImpossible(self.typechecker.context.log, @src()),
        };
}

fn evalMutType(self: *Folder, exprPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
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

fn evalArrType(self: *Folder, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
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

pub fn expectType(self: *Folder, exprPtr: defines.ExpressionPtr) Error!Comptime.Value.Ptr {
    const valuePtr = try self.eval(exprPtr, Builtin.Type("type"));
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

fn expectDefined(self: *Folder, exprPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) Error!Comptime.Value.Ptr {
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

pub fn constructUndefined(self: *Folder, valueType: TypeID) Error!Comptime.Value.Ptr {
    return switch (self.typechecker.typeTable.get(valueType)) {
        .Void, .Function, .Type, .Any, .Noreturn, .EnumLiteral => {
            self.report("Given type '{s}' can't be undefined.", .{
                try self.typechecker.typeName(self.arena.allocator(), valueType)
            });
            return Error.IllegalSyntax;
        },
        else => self.appendValue(.{ .Undefined = valueType }),
    };
}

pub fn generateRandomName(self: *Folder, comptime mode: @TypeOf(.EnumLiteral)) Error!u32 {
    const str = try self.generateRandomNameString(mode);
    return self.typechecker.builder.internString(str);
}

pub fn generateRandomNameString(self: *Folder, comptime mode: @TypeOf(.EnumLiteral)) Error![]u8 {
    const randint = self.rng.next();

    return std.fmt.allocPrint(self.arena.allocator(), "__anon_"++@tagName(mode)++"_{d}", .{
        randint
    }) catch Error.AllocatorFailure;
}

// @Beware, scope declarations must be comptime since they are technically
// top-level declarations.
fn handleScopeDecls(
    self: *Folder,
    scope: defines.ScopePtr,
    newScope: defines.ScopePtr,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    defRange: defines.Range,
) Error![]types.FieldInfo {
    // @TODO if InComptimeCall is set, typecheck, evaluate and cache
    // definitions.

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

        const declPtr = self.typechecker.symbols.lookup.get(.{
            .scope = scope,
            .name = symbolName,
        }) orelse return common.debug.ShouldBeImpossible(undefined, @src());
        const decl = self.typechecker.symbols.getDecl(declPtr);

        const newDecl = try self.typechecker.symbols.declarations.addOne(self.typechecker.arena.allocator());
        self.typechecker.symbols.declarations.set(newDecl, decl);
        self.typechecker.symbols.declarations.items(.scope)[newDecl] = newScope;

        self.typechecker.symbols.lookup.put(self.typechecker.arena.allocator(), .{
            .scope = newScope,
            .name = symbolName,
        }, newDecl) catch return Error.AllocatorFailure;

        const valueType =
            if (self.getFlag(.InComptimeCall)) try self.typechecker.typecheckDecl(newDecl, null)
            else Builtin.Type("incomplete");

        const newName = try self.typechecker.builder.internString(symbolName);
        defs.appendAssumeCapacity(.{
            .public = sig.public,
            .name = newName,
            .valueType = valueType,
            .isComptime = false,
        });
    }

    return defs.items;
}

fn castValue(self: *Folder, valuePtr: Comptime.Value.Ptr, to: TypeID, unsafe: bool) Error!Comptime.Value.Ptr {
    const value = self.getValue(valuePtr);

    const valueType = try self.typechecker.typecheckValueDirect(value, to);
    try self.typechecker.assertCastable(valueType, to, unsafe);

    const newValue: Comptime.Value = switch (value) {
        .Pointer => |ptr| .{
            .Pointer = .{
                .Type = to,
                .To = ptr.To,
            },
        },
        .Function => |func| switch (self.typechecker.typeTable.get(to)) {
            .Type => .{ .Type = func.signature },
            .Function => .{
                .Function = .{
                    .args = func.args,
                    .body = func.body,
                    .name = func.name,
                    .signature = to,
                    .source = func.source,
                    .scope = func.scope,
                    .expr = func.expr,
                },
            },
            else => return common.debug.ShouldBeImpossible(undefined, @src()),
        },
        .Float => |fromFloat|
            if (self.typechecker.isFloat(to)) value
            else .{ .Int = @intFromFloat(fromFloat) },
        .Int => |fromInt| switch (self.typechecker.typeTable.get(to)) {
            .Pointer => .{
                .Pointer = .{
                    .Type = to,
                    .To = @intCast(fromInt),
                },
            },
            else =>
                if (self.typechecker.isInt(to)) value
                else .{ .Float = @floatFromInt(fromInt) },
        },
        .Bool => |fromBool| switch (self.typechecker.typeTable.get(to)) {
            .Bool => value,
            else => .{ .Int = @intFromBool(fromBool) },
        },
        .Enum => |fromEnum| .{
            .Enum = .{
                .Type = to,
                .Value = fromEnum.Value,
            },
        },
        .Struct => |fromStruct| Comptime.Value{
            .Struct = .{
                .Type = to,
                .Fields = fromStruct.Fields,
            },
        },
        .Union => |fromUni| Comptime.Value{
            .Union = .{
                .Type = to,
                .Tag = fromUni.Tag,
                .Value = fromUni.Value,
            },
        },
        .Slice => |slice| switch (self.typechecker.typeTable.get(to)) {
            .Pointer => |ptr| switch (ptr.size) {
                .Single, .C => |size| .{
                    .Pointer = .{
                        .Type = self.typechecker.typeMap.get(TypeInfo{
                            .Pointer = .{
                                .mutable = self.typechecker.mutable(slice.Type), 
                                .size = size,
                                .child = switch (self.typechecker.typeTable.get(slice.Type)) {
                                    .Pointer => |slicePtr| slicePtr.child,
                                    .Array => |arr| arr.child,
                                    else => return common.debug.ShouldBeImpossible(undefined, @src()),
                                },
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
            .Array => |arr| .{
                .Slice = .{
                    .Type = to,
                    .Size = arr.len,
                    .To = slice.To,
                },
            },
            else => return common.debug.ShouldBeImpossible(undefined, @src()),
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

        .String => |str| 
            if (self.typechecker.isCStr(to)) .{
                .String = .{
                    .type = .C,
                    .str = str.str,
                },
            }
            else .{
                .String = .{
                    .type = .Cole,
                    .str = str.str,
                },
            },

        else => {
            self.report("Attempt to cast value of type '{s}.'", .{@tagName(value)});
            return Error.CastOfIncastableValue;
        }
    };

    self.memory.items[valuePtr] = newValue;
    return valuePtr;
}

pub fn comptimeEq(self: *const Folder, lhs: Comptime.Value, rhs: Comptime.Value) bool {
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
        .Function => lhs.Function.body == rhs.Function.body,
        else => false,
    };
}

fn report(self: *Folder, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME FOLDER: " ++ fmt, args);
}

pub fn getValue(self: *const Folder, address: defines.Offset) Comptime.Value {
    assert(address <= self.memory.items.len);
    return self.memory.items[address];
}

fn setValue(self: *const Folder, address: defines.Offset, new: Comptime.Value) void {
    assert(address <= self.memory.items.len);
    self.memory.items[address] = new;
}

fn cacheValue(self: *Folder, ptr: FolderCacheKey, val: Comptime.Value.Ptr) Error!void {
    const value = self.getValue(val);
    if (value == .Function and self.typechecker.typeTable.get(value.Function.signature).Function.isComptime) {
        return;
    }

    if (!self.getFlag(.InComptimeCall)) {
        self.cache.put(self.arena.allocator(), ptr, val)
            catch return Error.AllocatorFailure;
    }
}

pub fn appendValue(self: *Folder, value: Comptime.Value) Error!Comptime.Value.Ptr {
    const addr = self.memory.items.len;
    self.memory.append(self.arena.allocator(), value)
        catch return Error.AllocatorFailure;
    return @intCast(addr);
}

pub fn setFlag(self: *Folder, comptime flag: Flags, bit: bool) bool {
    defer self.flags.setValue(Flags.flag(flag), bit);
    return self.flags.isSet(Flags.flag(flag));
}

pub fn getFlag(self: *Folder, comptime flag: Flags) bool {
    return self.flags.isSet(Flags.flag(flag));
}

pub fn deinit(self: *Folder) void {
    self.arena.deinit();
}

pub fn dumpMem(self: *const Folder) void {
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

        unreachable;
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
    // c_int
    .{ .name = "c_int", .info = .{ .CInt = false }, },
    // c_uint
    .{ .name = "c_uint", .info = .{ .CUInt = false }, },
    // c_char
    .{ .name = "c_char", .info = .{ .CChar = false }, },
    // c_uchar
    .{ .name = "c_uchar", .info = .{ .CUChar = false }, },
    // c_double
    .{ .name = "c_double", .info = .{ .CDouble = false }, },
    // c_long
    .{ .name = "c_long", .info = .{ .CLong = false }, },
    // c_ulong
    .{ .name = "c_ulong", .info = .{ .CULong = false }, },
    // c_short
    .{ .name = "c_short", .info = .{ .CShort = false }, },
    // c_ushort
    .{ .name = "c_ushort", .info = .{ .CUShort = false }, },
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
    .{ .name = "incomplete", .info = .{ .Struct = .{ .mutable = false, .name = Resolver.BuiltinIndex("any") + 3, .fields = &.{}, .definitions = &.{}, .scope = 0, .external = true, .isTuple = false } } },
    // builtin_metadata
    .{ .name = "builtin_metadata", .info = .{ .Enum = .{ .mutable = false, .name = Resolver.BuiltinIndex("any") + 5, .fields = &.{}, .definitions = &.{}, .scope = 0, .external = true } } },
    // []u8
    .{ .name = "[]u8", .info = .{ .Pointer = .{ .mutable = false, .child = 2, .size = .Slice, }, } },
};

pub const builtinMetadata = [_][]const u8 {
    "@noComptime",
    "@comptime",
    "@export",
    "@extern",
    "@variadic",
};
