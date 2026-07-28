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
pub const TypeNameMap = std.AutoHashMapUnmanaged(TypeID, defines.StringPtr);
pub const MetadataMap = collections.HashMap(defines.ExpressionPtr, []const Comptime.Value.Ptr);
const LookupMap = collections.HashMap(defines.DeclPtr, TypecheckStatus);

pub const Flags = enum(u8) {
    ConcreteValue = 0,
    LValue = 1,
    AttemptingEval = 2,
    CanCycle = 3,
    CoveredAllPaths = 4,
    InLoop = 5,
    InDefer = 6,

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

pub const Resolution = backend.C.JIR;

const Typechecker = @This();

arena: Arena,
context: *Context,
modules: *const ModuleList,
symbols: *Resolver.Resolution,

typeTable: TypeTable,
typeMap: TypeMap,
lookup: LookupMap,
metadata: MetadataMap,

folder: Comptime.Folder,

currentFile: defines.FilePtr,
currentScope: defines.ScopePtr,
lastToken: defines.TokenPtr,
callstack: Callstack,
flags: FlagMap,

builder: backend.C.JIR.Builder,
lowerer: Lowerer,
typenameMap: TypeNameMap,

pub fn init(
    gpa: Allocator,
    context: *Context,
    modules: *const ModuleList,
    symbolTable: *Resolver.Resolution
) Error!Typechecker {
    var arena = Arena.init(gpa);
    const allocator = arena.allocator();

    const counts = context.counts;
    const typeCount = counts.types * 3 + @as(u32, @intCast(Comptime.Folder.builtinTypes.len));

    var typeTable = TypeTable{};
    typeTable.ensureTotalCapacity(allocator, typeCount + @as(u32, @intCast(Comptime.Folder.builtinTypes.len)))
        catch return Error.AllocatorFailure;
    var typeMap = TypeMap.empty;
    var metadata = MetadataMap.empty;
    var lookup = LookupMap.empty;

    typeMap.ensureTotalCapacity(allocator, 2 + typeCount + @as(u32, @intCast(Comptime.Folder.builtinTypes.len))) catch return Error.AllocatorFailure;
    lookup.ensureTotalCapacity(allocator, symbolTable.declarations.len) catch return Error.AllocatorFailure;
    metadata.ensureTotalCapacity(allocator, counts.meta * 3) catch return Error.AllocatorFailure;

    return .{
        .context = context,
        .modules = modules,
        .typeTable = typeTable,
        .typeMap = typeMap,
        .metadata = metadata,
        .lookup = lookup,
        .flags = FlagMap.initEmpty(),
        .folder = undefined,
        .builder = try backend.C.JIR.Builder.init(allocator, counts),
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

pub fn deinit(self: *Typechecker) void {
    self.arena.deinit();
}

pub fn typecheck(self: *Typechecker, allocator: Allocator) Error!Resolution {
    if (!self.modules.getItem("root", .symbolPtrs).contains("main")) {
        self.report("Couldn't find an entry point in the root module.", .{});
        return Error.MissingDefinition;
    }

    inline for (Comptime.Folder.builtinTypes, 0..) |builtin, id| {
        self.typeTable.appendAssumeCapacity(builtin.info);
        self.typeMap.putAssumeCapacityNoClobber(builtin.info, @intCast(id));
    }

    const entryPointID = comptime Comptime.Folder.Builtin.Type("[]u8") + 1;
    const complexBuiltinTypes = [_]TypeInfo{
        // entry_point
        .{ .Function = .{
            .mutable = false,
            .isComptime = false,
            .argTypes = &.{ entryPointID + 1 },
            .returnType = Comptime.Folder.Builtin.Type("i32"),
        }},

        // [][]u8
        .{ .Pointer = .{
            .size = .Slice,
            .child = Comptime.Folder.Builtin.Type("[]u8"),
            .mutable = false,
        }}
    };

    inline for (complexBuiltinTypes, 0..) |builtin, id| {
        self.typeTable.appendAssumeCapacity(builtin);
        self.typeMap.putAssumeCapacityNoClobber(builtin, @intCast(id + entryPointID));
    }

    self.builder.allocator = self.arena.allocator();
    self.folder = try Comptime.Folder.init(self, allocator);
    self.lowerer = try Lowerer.init(self);

    defer self.arena.deinit();
    defer self.folder.deinit();

    // @Note detect all top-level asms, they are not like imports.
    {
        var iter = self.modules.modules.iterator();
        while (iter.next()) |module| {
            const ast = self.context.getAST(module.dataIndex);

            for (ast.statementMask) |_stmt| {
                const stmt = ast.statements.get(_stmt);
                if (stmt.type != .InlineC) {
                    continue;
                }

                const cstart = ast.extra[stmt.value];
                const cend = ast.extra[stmt.value + 1];
                const scode = self.context.getFile(ast.tokens)[cstart..cend];
                const code = try self.builder.internString(scode);
                self.builder.topLevelAsms.append(self.builder.allocator, code)
                    catch return Error.AllocatorFailure;
            }
        }
    }

    // TODO:                                             This part is not really nice, fix it.
    const mainPtr = self.symbols.lookup.get(.{ .scope = self.modules.modules.len - 1, .name = "main" }).?;
    const mainDecl = self.symbols.getDecl(mainPtr);

    if (mainDecl.public) {
        self.report("Expected entry point 'main' to be private.", .{});
        return Error.PublicEntryPoint;
    }

    const mainType = try self.typecheckDecl(mainPtr, entryPointID);
    self.clearFlags();
    if (mainType != entryPointID) {
        const main = self.symbols.getDecl(mainPtr);
        self.lastToken = main.token;
        self.report("Unexpected type of entry point 'main'. Expected '{s}', received '{s}'", .{
            try self.typeName(allocator, entryPointID),
            try self.typeName(allocator, mainType),
        });
        return Error.TypeMismatch;
    }

    return self.builder.build(allocator, self);
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
        .Import => common.debug.ShouldBeImpossible(self.context.log, @src()),
        .Defer => self.typecheckDefer(stmt.value),
        .VariableDefinition => try self.typecheckVarDefStatement(stmt.value),
        .InlineC => { }, // @Note allow direct C code insertion
        else => |t| {
            self.report("Typechecking of '{s}' statements is not implemented.", .{
                @tagName(t),
            });
            return common.debug.NotImplemented(self.context.log, @src());
        },
    };
}

fn typecheckVariableDef(
    self: *Typechecker,
    decl: *const Resolver.Declaration,
) Error!TypeID {
    const expected = try self.expectType(decl.type);

    const initializer =
        if (decl.topLevel or expected == Comptime.Folder.Builtin.Type("type"))
            try self.typecheckValue(try self.folder.eval(decl.node, expected), expected)
        else
            try self.typecheckExpression(decl.node, expected);

    const res =
        if (self.suitable(expected, initializer))
            try self.coerce(expected, initializer)
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
            const newType = self.folder.getValue(try self.folder.eval(decl.node, expected)).Type;

            const ast = self.context.getAST(self.currentFile);
            const tokens = self.context.getTokens(ast.tokens);

            const symName = tokens.get(decl.token).lexeme(self.context, self.currentFile);

            const namespace =
                if (decl.parent != null and self.typeTable.get(try self.typecheckDecl(decl.parent.?, null)) == .Type) hasParent: {
                    const rtypePtr = try self.folder.eval(self.symbols.getDecl(decl.parent.?).node, null);
                    const rtype = self.folder.getValue(rtypePtr).Type;

                    break :hasParent self.builder.getInternedString(switch (self.typeTable.get(rtype)) {
                        .Struct => |str| str.name,
                        .Enum => |enm| enm.name,
                        .Union => |uni| uni.name,
                        else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
                    });
                }
                else if (decl.topLevel) self.modules.modules.get(self.symbols.scopes.items(.module)[decl.scope]).name
                else try self.folder.generateRandomNameString(.Type);

            const newName =
                if (self.hasMetadata(decl.node, "@extern")) symName
                else std.fmt.allocPrint(self.arena.allocator(), "{s}::{s}", .{
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

                else => break :blk,
            });

            self.typenameMap.put(self.arena.allocator(), newType, new)
                catch return Error.AllocatorFailure;

            var defs: []Types.FieldInfo = @constCast(switch (self.typeTable.get(newType)) {
                .Struct => |str| str.definitions,
                .Enum => |enm| enm.definitions,
                .Union => |uni| uni.definitions,
                else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
            });

            for (defs, 0..) |def, idx| {
                const nname = std.fmt.allocPrint(self.arena.allocator(),
                    "{s}::{s}", .{
                        newName,
                        self.builder.getInternedString(def.name),
                }) catch return Error.AllocatorFailure;

                defs[idx] = Types.FieldInfo{
                    .name = try self.builder.internString(nname),
                    .valueType = def.valueType,
                    .public = def.public,
                    .isComptime = def.isComptime,
                };

                const scope = self.symbols.resolutionMap.get(.{
                    .file = self.currentFile,
                    .expr = self.unwrapMark(decl.node),
                }) orelse return common.debug.ShouldBeImpossible(self.context.log, @src());

                const rres = self.symbols.lookup.fetchRemove(.{
                    .scope = scope,
                    .name = self.builder.getInternedString(def.name),
                }) orelse return common.debug.ShouldBeImpossible(self.context.log, @src());

                self.symbols.lookup.putAssumeCapacityNoClobber(.{
                    .scope = scope,
                    .name = nname,
                }, rres.value);
            }
        },
        .Function => {
            const ast = self.context.getAST(self.currentFile);
            const tokens = self.context.getTokens(ast.tokens);

            const symName = tokens.get(decl.token).lexeme(self.context, self.currentFile);
            const namespace =
                if (decl.parent != null and self.typeTable.get(try self.typecheckDecl(decl.parent.?, null)) == .Type) hasParent: {
                    const rtypePtr = try self.folder.eval(self.symbols.getDecl(decl.parent.?).node, null);
                    const rtype = self.folder.getValue(rtypePtr).Type;

                    break :hasParent self.builder.getInternedString(switch (self.typeTable.get(rtype)) {
                        .Struct => |str| str.name,
                        .Enum => |enm| enm.name,
                        .Union => |uni| uni.name,
                        else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
                    });
                }
                else if (decl.topLevel) self.modules.modules.get(self.symbols.scopes.items(.module)[decl.scope]).name
                else try self.folder.generateRandomNameString(.Type);
            const newName =
                if (self.hasMetadata(decl.node, "@export")) symName
                else std.fmt.allocPrint(self.arena.allocator(), "{s}::{s}", .{
                    namespace,
                    symName,
                }) catch return Error.AllocatorFailure;
            const new = try self.builder.internString(newName);

            if (std.mem.eql(u8, namespace, "root") and std.mem.eql(u8, newName, "main")) {
                self.report("Main function can't be exported.", .{});
                return Error.ExportOfMainFunction;
            }

            const val = try self.folder.eval(decl.node, expected);
            var func = self.folder.getValue(val).Function;
            func.name = new;

            self.folder.memory.items[val] = .{
                .Function = .{
                    .name = func.name,
                    .signature = func.signature,
                    .body = func.body,
                    .args = func.args,
                },
            };

            try self.builder.functionDef(new, try self.builder.addFunction(func));
        },
        else => { },
    }

    return res;
}

fn typecheckVarDefStatement(self: *Typechecker, extraPtr: defines.OpaquePtr) Error!void {
    const ast = self.context.getAST(self.currentFile);

    const signature = ast.signatures.get(ast.extra[extraPtr]);

    const decl = ast.extra[extraPtr + 2];
    _ = try self.typecheckDecl(decl, try self.expectType(signature.type));
}

fn typecheckDefer(self: *Typechecker, stmtPtr: defines.StatementPtr) Error!void {
    if (self.getFlag(.InDefer)) {
        self.report("Defer statements can't have defer statements inside them.", .{});
        return Error.DeferOutsideDeferrableScope;
    }

    _ = self.setFlag(.InDefer, true);
    defer _ = self.setFlag(.InDefer, false);
    try self.typecheckStatement(stmtPtr, Comptime.Folder.Builtin.Type("void"));
}

fn typecheckLoopControl(self: *Typechecker, _: defines.OpaquePtr) Error!void {
    if (!self.getFlag(.InLoop)) {
        self.report("Loop control statement outside loop body.", .{});
        return Error.LoopControlOutsideLoopScope;
    }
    else if (self.getFlag(.InDefer)) {
        self.report("Defer statements can't have loop control statements.", .{});
        return Error.DeferOutsideDeferrableScope;
    }
}

fn typecheckWhileStatement(self: *Typechecker, extraPtr: defines.OpaquePtr, expected: TypeID) Error!void {
    const ast = self.context.getAST(self.currentFile);

    defer _ = self.setFlag(.CoveredAllPaths, false);

    const conditionPtr = ast.extra[extraPtr];
    const bodyPtr = ast.extra[extraPtr + 1];

    const condition = try self.typecheckExpression(conditionPtr, Comptime.Folder.Builtin.Type("bool"));
    if (!self.suitable(Comptime.Folder.Builtin.Type("bool"), condition)) {
        self.report("Expected a boolean for condition.", .{});
        return Error.TypeMismatch;
    }

    if (self.folder.attemptEval(conditionPtr, Comptime.Folder.Builtin.Type("bool"))) |_cnd| {
        const cnd = self.folder.getValue(_cnd).Bool;

        if (cnd) {
            const prev = self.setFlag(.InLoop, true);
            defer _ = self.setFlag(.InLoop, prev);
            try self.typecheckStatement(bodyPtr, expected);
        }

        return;
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
        else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
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
        catch return common.debug.ShouldBeImpossible(self.context.log, @src());

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
                const fieldPtr = try self.folder.eval(caseLabel, uni.tag);
                const field = self.folder.getValue(fieldPtr);

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
                self.fieldIndex(itemTypeID, field) catch return common.debug.ShouldBeImpossible(self.context.log, @src())
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
        catch return common.debug.ShouldBeImpossible(self.context.log, @src());

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
            const fieldPtr = try self.folder.eval(caseLabel, itemTypeID);
            const field = self.folder.getValue(fieldPtr);

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
    if (self.getFlag(.InDefer)) {
        self.report("Return statements in defer statements are not allowed.", .{});
        return Error.DeferOutsideDeferrableScope;
    }

    const returnType =
        if (exprPtr != 0) try self.typecheckExpression(exprPtr, expected)
        else Comptime.Folder.Builtin.Type("void");

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

    const conditionType = try self.typecheckExpression(conditionExpr, Comptime.Folder.Builtin.Type("bool"));
    if (!self.suitable(conditionType, Comptime.Folder.Builtin.Type("bool"))) {
        self.report("Expected a boolean for condition.", .{});
        return Error.TypeMismatch;
    }

    if (self.folder.attemptEval(conditionExpr, Comptime.Folder.Builtin.Type("bool"))) |_cnd| {
        const cnd = self.folder.getValue(_cnd).Bool;

        if (cnd) {
            try self.typecheckStatement(body, expected);
        }
        else {
            _ = self.setFlag(.CoveredAllPaths, false);
            const coveredIf = self.getFlag(.CoveredAllPaths);
            const coveredElse =
                if (maybeOtherwise) |otherwise| blk: {
                    try self.typecheckStatement(otherwise, expected);
                    break :blk self.getFlag(.CoveredAllPaths);
                }
                else false;
            _ = self.setFlag(.CoveredAllPaths, coveredIf and coveredElse);
        }

        return;
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
    const ast = self.context.getAST(self.currentFile);

    const expr = ast.extra[extraPtr];
    const rhs = ast.extra[extraPtr + 1];

    const vtype = try self.typecheckExpression(expr, null);

    if (!self.getFlag(.ConcreteValue)) {
        self.report("Expected a concrete value for assignment.", .{});
        return Error.AssignationOfNonConcreteValue;
    }

    if (ast.expressions.get(expr).type == .Indexing) {
        const indexable = ast.extra[ast.expressions.get(expr).value];
        const indexableType = try self.typecheckExpression(indexable, null);

        if (
            self.typeTable.get(indexableType) == .Array
            and !self.mutable(indexableType)
        ) {
            self.report("Attempt to modify non-mutable value of type '{s}'.", .{
                self.builder.getInternedString(self.typenameMap.get(indexableType).?), 
            });
            return Error.MutabilityViolation;
        }
    }

    if (!self.mutable(vtype)) {
        self.report("Attempt to modify non-mutable value of type '{s}'.", .{
            self.builder.getInternedString(self.typenameMap.get(vtype).?), 
        });
        return Error.MutabilityViolation;
    }

    const rtype = try self.typecheckExpression(rhs, vtype);

    if (!self.suitable(vtype, rtype)) {
        self.report("Can't assign value of type '{s}' to value of type '{s}'.", .{
            try self.typeName(self.arena.allocator(), vtype),
            try self.typeName(self.arena.allocator(), rtype),
        });
        return Error.TypeMismatch;
    }
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
            self.report("Unreachable code detected.", .{});
            return Error.UnreachableCodePath;
        }

        try self.typecheckStatement(ast.extra[index], expected);
    }
}

pub fn typecheckField(self: *Typechecker, decl: *const Resolver.Declaration) Error!TypeID {
    return self.expectType(decl.type);
}

pub fn typecheckParameter(self: *Typechecker, decl: *const Resolver.Declaration) Error!TypeID {
    return self.expectType(decl.type);
}

pub fn typecheckExpression(self: *Typechecker, expressionPtr: defines.ExpressionPtr, _maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const maybeExpected =
        if (_maybeExpected) |ex| ex
        else Comptime.Folder.Builtin.Type("any");

    const expr = ast.expressions.get(expressionPtr);
    defer _ = self.setFlag(.ConcreteValue, switch (expr.type) {
        .Identifier, .Indexing, .Scoping, .Dot => true,
        else => false,
    });

    if (self.hasMetadata(expressionPtr, "@comptime")) {
        const val = try self.folder.eval(expressionPtr, maybeExpected);
        return self.typecheckValue(val, maybeExpected);
    }

    // @Note all literals should be handled here.
    if (self.folder.attemptEval(expressionPtr, maybeExpected)) |result| {
        return self.typecheckValue(result, maybeExpected);
    }

    return switch (expr.type) {
        .Identifier => {
            self.lastToken = expr.value;
            const decl = self.symbols.findDecl(.{ .file = self.currentFile, .expr = expressionPtr });
            const discoveredType = try self.typecheckDecl(decl, maybeExpected);
            return discoveredType;
        },
        .Indexing => return self.typecheckIndexing(expr.value),
        .Call => self.typecheckCall(expr.value, maybeExpected),
        .Scoping => return self.typecheckScoping(expressionPtr),
        .ExpressionList => self.typecheckExpressionList(expr.value, maybeExpected),
        .Literal => self.typecheckValue(try self.folder.eval(expressionPtr, maybeExpected), maybeExpected),

        .EnumDefinition, .UnionDefinition, .StructDefinition,
        .ArrayType, .CPointerType, .FunctionType,
        .MutableType, .PointerType, .SliceType,
        .FunctionDefinition, .Lambda => self.typecheckValue(
            try self.folder.eval(expressionPtr, maybeExpected),
            maybeExpected,
        ),

        .Conditional => self.typecheckIfExpression(expr.value, maybeExpected),
        .Switch => self.typecheckSwitchExpression(expr.value, maybeExpected),

        .Unary => self.typecheckUnary(expr.value, maybeExpected),
        .Binary => self.typecheckBinary(expr.value, maybeExpected),

        .Slicing => self.typecheckSlicing(expr.value),

        .Mark => self.typecheckMark(expressionPtr, expr.value, maybeExpected),

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

    const condition = try self.typecheckExpression(conditional.condition, Comptime.Folder.Builtin.Type("bool"));
    if (!self.suitable(Comptime.Folder.Builtin.Type("bool"), condition)) {
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

    return self.coerce(thenBranch, elseBranch) catch common.debug.ShouldBeImpossible(self.context.log, @src());
}

pub fn typecheckValue(self: *Typechecker, val: Comptime.Value.Ptr, maybeExpected: ?TypeID) Error!TypeID {
    const expected = determineExpected(maybeExpected) orelse
        if (false) {
            self.report("Expected a known target type for comptime typechecking.", .{});
            return Error.InferenceError;
        }
        else Comptime.Folder.Builtin.Type("any");

    return self.coerce(expected, switch (self.folder.getValue(val)) {
        .Int => Comptime.Folder.Builtin.Type("comptime_int"),
        .Float => Comptime.Folder.Builtin.Type("comptime_float"),
        .Bool => Comptime.Folder.Builtin.Type("bool"),
        .Enum => |enumeration| enumeration.Type,
        .Union => |uni| uni.Type,
        .Struct => |str| str.Type,
        .Type => Comptime.Folder.Builtin.Type("type"),
        .Pointer => |ptr| ptr.Type,
        .Function => |func| func.signature,
        .Void => Comptime.Folder.Builtin.Type("void"),
        .Undefined => |undef| undef,
        .Slice => |slice| slice.Type,
        .String => Comptime.Folder.Builtin.Type("[]u8"),
    });
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
            maybeExpected orelse Comptime.Folder.Builtin.Type("void") == Comptime.Folder.Builtin.Type("void")
        )
    ) {
        return Comptime.Folder.Builtin.Type("void");
    }

    const expected =
        if (maybeExpected) |expected|
            if (range.len() == 1) switch (self.typeTable.get(expected)) {
                .Struct, .Union, .Enum, .Array => return self.typecheckExpressionListRange(range, expected),
                else => return self.typecheckExpression(ast.extra[range.at(0)], expected),
            }
            else expected
        else if (range.len() == 1) return self.typecheckExpression(ast.extra[range.at(0)], maybeExpected)
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
        else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
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

        _ = try self.coerce(expected, rhs);
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
            if (field.isComptime) try self.typecheckValue(try self.folder.eval(
                ast.extra[range.at(@intCast(index))],
                field.valueType,
            ), field.valueType)
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
        const item = try self.typecheckExpression(ast.extra[range.at(@intCast(index))], arr.child);

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

    const ptr = try self.folder.eval(ast.extra[range.at(0)], uni.tag);
    const findex = switch (self.folder.getValue(ptr)) {
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
        _ = try self.folder.constructFromList(
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

    const lhsTypeID = try self.expectType(ast.extra[extraPtr]);
    const lhsType = self.typeTable.get(lhsTypeID);

    var member = tokens.get(ast.extra[extraPtr + 1]).lexeme(self.context, self.currentFile);
    member = std.fmt.allocPrint(self.arena.allocator(),
        "{s}::{s}", .{
            self.builder.getInternedString(switch (lhsType) {
                .Struct => |str| str.name,
                .Union => |str| str.name,
                .Enum => |str| str.name,
                else => return common.debug.NotImplemented(self.context.log, @src()),
            }),
            member
    }) catch return Error.AllocatorFailure;

    var defs: []const Types.FieldInfo = undefined;
    var scope: defines.ScopePtr = undefined;
    switch (lhsType) {
        .Enum => |enm| {
            for (enm.fields) |field| {
                if (std.mem.eql(u8, field, member)) {
                    return lhsTypeID;
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
        else => return common.debug.NotImplemented(self.context.log, @src()),
    }

    const index = try self.definitionIndex(lhsTypeID, try self.builder.internString(member));

    return self.discoverScopeDef(lhsTypeID, &defs[index], scope, expr);
}

pub fn discoverScopeDef(
    self: *Typechecker,
    from: TypeID,
    member: *const Types.FieldInfo,
    scope: defines.ScopePtr,
    expr: defines.ExpressionPtr
) Error!TypeID {
    if (member.valueType != Comptime.Folder.Builtin.Type("incomplete")) {
        return member.valueType;
    }

    const decl = self.symbols.lookup.get(.{
        .scope = scope,
        .name = self.builder.getInternedString(member.name),
    }) orelse return common.debug.ShouldBeImpossible(self.context.log, @src());

    self.symbols.resolutionMap.put(self.arena.allocator(), .{
        .file = self.currentFile,
        .expr = expr,
    }, decl) catch return Error.AllocatorFailure;

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
        else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
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

            if (Comptime.Folder.Builtin.isBuiltinType(decl.type)) {
                break :blk;
            }

            return self.typecheckBuiltinCall(extraPtr, decl.type, maybeExpected);
        }
    }

    const lhsType = try self.typecheckExpression(ast.extra[extraPtr], null);
    const maybeFunction = self.typeTable.get(lhsType);
    const func = switch (maybeFunction) {
        .Type => {
            const typeToInit =
                if (determineExpected(maybeExpected)) |exp| exp
                else self.folder.getValue(try self.folder.eval(ast.extra[extraPtr], null)).Type;

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

    for (func.argTypes, args, 0..) |argType, expr, index| {
        const exprType = try self.typecheckExpression(expr, argType);

        self.assertCanCoerce(argType, exprType) catch {
            self.report(
                "Argument type mismatch in function call."
                ++ " In argument {d}: expected {s}, received {s}", .{
                index,
                try self.typeName(self.arena.allocator(), argType),
                try self.typeName(self.arena.allocator(), exprType),
            });
            return Error.TypeMismatch;
        };
    }

    return func.returnType;
}

pub fn typecheckBuiltinCall(self: *Typechecker, extraPtr: defines.ExpressionPtr, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!TypeID {
    const BI = Resolver.BuiltinIndex;

    return switch (declPtr) {
        BI("cast") => self.typecheckCast(extraPtr, maybeExpected, false),
        BI("unsafeCast") => self.typecheckCast(extraPtr, maybeExpected, true),
        BI("as") => self.typecheckTypeForwarding(extraPtr, maybeExpected),
        BI("typeOf") => Comptime.Folder.Builtin.Type("type"), // self.executer.getValue(try self.executer.evalTypeOf(extraPtr)).Type,
        BI("compileError") => return self.folder.evalCompileError(extraPtr),
        BI("sizeOf") => return Comptime.Folder.Builtin.Type("u32"),
        BI("compileLog") => {
            _ = try self.folder.evalCompileLog(extraPtr);
            return Comptime.Folder.Builtin.Type("void");
        },
        BI("unreachable") => Comptime.Folder.Builtin.Type("noreturn"),
        else => {
            self.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[declPtr]});
            return Error.ComptimeNotPossible;
        },
    };
}

pub fn typecheckCast(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID, unsafe: bool) Error!TypeID {
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

    if (thingToCastRange.len() > 1) {
        self.report("Multi-value type casting is not supported.", .{});
        return Error.NotImplemented;
    }
    else if (thingToCastRange.len() == 0) {
        self.report("Can't cast void.", .{});
        return Error.CastOfIncastableValue;
    }

    const thingToCastType = try self.typecheckExpression(ast.extra[thingToCastRange.at(0)], null);

    self.assertCastable(thingToCastType, targetType, unsafe) catch |err| {
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
            else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
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
    if (!self.suitable(typeToForward, res)) {
        self.report("Expected en expression of type '{s}' here.", .{
            try self.typeName(self.arena.allocator(), typeToForward),
        });
        return Error.TypeMismatch;
    }

    return typeToForward;
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
    _ = switch (maybeIndexable) {
        .Array => |arr| arr.child,
        .Pointer => |ptr| switch (ptr.size) {
            .Slice, .C => ptr.child,
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
    };

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
        .Array => |arr| if (self.folder.attemptEval(ast.extra[extraPtr + 1], null)) |_index| {
            const index = self.folder.getValue(_index).Int;
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
                else => break :blk common.debug.ShouldBeImpossible(self.context.log, @src()),
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
            else => common.debug.ShouldBeImpossible(self.context.log, @src()),
        };
}

pub fn typecheckDecl(self: *Typechecker, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!TypeID {
    var decl = self.symbols.declarations.get(declPtr);

    if (decl.kind == .Builtin) {
        return if (Comptime.Folder.Builtin.isBuiltinType(decl.type)) Comptime.Folder.Builtin.Type("type")
        else switch (decl.type) {
            BuiltinIndex("undefined") => blk: {
                const expected =
                    if (determineExpected(maybeExpected)) |expected| expected
                    else {
                        self.report("Unable to resolve the type of undefined value.", .{});
                        return Error.MissingTypeSpecifier;
                    };

                switch (self.typeTable.get(expected)) {
                    .Function => {
                        self.report("Can't construct an undefined value of type '{s}'", .{
                            try self.typeName(self.arena.allocator(), expected),
                        });
                        return Error.UndefinedPointerType;
                    },

                    else => break :blk expected,
                }
            },
            BuiltinIndex("unreachable") => return Comptime.Folder.Builtin.Type("noreturn"),
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

    self.callstack.push(declPtr);
    defer _ = self.callstack.pop();

    if (isPresent.found_existing) {
        switch (isPresent.value_ptr.status) {
            .Checked =>
                if (isPresent.value_ptr.result != Comptime.Folder.Builtin.Type("incomplete")) {
                    return isPresent.value_ptr.result;
                } else {},
            .InProgress => {
                if (!self.getFlag(.CanCycle)) {
                    self.report("Dependency cycle detected. '{s}' depends on itself.", .{
                        self.builder.getInternedString(decl.name),
                    });
                }
                return Error.DependencyCycle;
            },
            else => { },
        }
    }

    const tokens = self.context.getTokens(self.currentFile);

    self.symbols.declarations.set(declPtr, .{
        .type = decl.type,
        .scope = decl.scope,
        .node = decl.node,
        .kind = decl.kind,
        .token = decl.token,
        .topLevel = decl.topLevel,
        .public = decl.public,
        .parent = decl.parent,
        .name = res: {
            const symName = tokens.get(decl.token).lexeme(self.context, self.currentFile);

            const namespace =
                if (decl.parent != null and self.typeTable.get(try self.typecheckDecl(decl.parent.?, null)) == .Type) hasParent: {
                    const rtypePtr = try self.folder.eval(self.symbols.getDecl(decl.parent.?).node, null);
                    const rtype = self.folder.getValue(rtypePtr).Type;

                    break :hasParent self.builder.getInternedString(switch (self.typeTable.get(rtype)) {
                        .Struct => |str| str.name,
                        .Enum => |enm| enm.name,
                        .Union => |uni| uni.name,
                        else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
                    });
                }
                else if (decl.topLevel) self.modules.modules.get(self.symbols.scopes.items(.module)[decl.scope]).name
                else null;

            const newName =
                if (self.hasMetadata(decl.node, "@extern")) symName
                else std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{s}", .{
                    namespace orelse "",
                    if (namespace) |_| "::" else "",
                    symName,
                }) catch return Error.AllocatorFailure;
            const new = try self.builder.internString(newName);

            break :res new;
        },
    });
    decl = self.symbols.declarations.get(declPtr);

    isPresent.value_ptr.* = .{
        .status = .InProgress,
        .result = Comptime.Folder.Builtin.Type("incomplete"),
    };
    errdefer isPresent.value_ptr.status = .NotChecked;

    const declType = try switch (decl.kind) {
        .Variable => self.typecheckVariableDef(&decl),
        .Namespace => {
            self.report("Operations on namespaces are not allowed.", .{});
            return Error.NamespaceAsValue;
        },
        .Builtin, .Capture => return common.debug.ShouldBeImpossible(self.context.log, @src()),
        .Parameter => self.typecheckParameter(&decl),
        .Field => self.typecheckField(&decl),
    };

    isPresent.value_ptr.* = .{
        .status = .Checked,
        .result = declType,
    };

    if (decl.topLevel) {
        try self.lowerer.topLevelDeclaration(isPresent.key_ptr.*, &decl);
    }

    return declType;
}

pub fn typecheckFieldAccess(self: *Typechecker, on: TypeID, field: []const u8) Error!TypeID {
    const objectType = self.typeTable.get(on);

    switch (objectType) {
        .Pointer => |ptr| if (ptr.size == .Slice) {
            if (std.mem.eql(u8, field, "len")) {
                return Comptime.Folder.Builtin.Type("u32");
            }
            else if (std.mem.eql(u8, field, "ptr")) {
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
            if (std.mem.eql(u8, field, "len")) {
                return Comptime.Folder.Builtin.Type("u32");
            }
            else if (std.mem.eql(u8, field, "ptr")) {
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

    const member = try self.builder.internString(field);

    const fields = switch (objectType) {
        .Union => |uni| uni.fields,
        .Struct => |str| str.fields,
        .Pointer => |ptr| switch (ptr.size) {
            .Single, .C => switch (self.typeTable.get(ptr.child)) {
                .Struct, .Union => return self.registerType(.{
                    .Pointer = .{
                        .size = ptr.size,
                        .child = try self.typecheckFieldAccess(ptr.child, field),
                        .mutable = true,
                    },
                }),
                else => {
                    self.report("Couldn't find field '{s}' in type '{s}'.", .{
                        field,
                        try self.typeName(self.arena.allocator(), on),
                    });
                    return Error.FieldNotFound;
                },
            },
            else => {
                self.report("Couldn't find field '{s}' in type '{s}'.", .{
                    field,
                    try self.typeName(self.arena.allocator(), on),
                });
                return Error.FieldNotFound;
            },
        },
        else => {
            self.report("Couldn't find field '{s}' in type '{s}'.", .{
                field,
                try self.typeName(self.arena.allocator(), on),
            });
            return Error.FieldNotFound;
        },
    };

    const index = try self.fieldIndex(on, member);
    return fields[index].valueType;
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

    const memberName = memberToken.lexeme(self.context, ast.tokens);

    return self.typecheckFieldAccess(objectTypeID, memberName);
}

pub fn typecheckMark(
    self: *Typechecker,
    ptr: defines.EitherPtr(defines.StatementPtr, defines.ExpressionPtr),
    extraPtr: defines.OpaquePtr,
    maybeExpected: ?TypeID
) Error!TypeID {
    // @Note In case of the mark of a mark, ptr is the marked this, which is the
    // current mark.
    if (self.getMetadata(ptr)) |_| {
        self.report("Redundant marking of already marked expression.", .{ });
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
        metadata[index] = try self.folder.eval(
            ast.extra[marks.at(@intCast(index))],
            Comptime.Folder.Builtin.Type("builtin_metadata")
        );
    }

    const marked = ast.extra[extraPtr + 2];
    try self.setMetadata(marked, metadata);
    return self.typecheckExpression(marked, maybeExpected);
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

    if (self.folder.attemptEval(ast.extra[extraPtr + 1], startType)) |startPtr| {
        if (self.folder.attemptEval(ast.extra[extraPtr + 2], endType)) |endPtr| {
            const startIndex = self.folder.getValue(startPtr).Int;
            const endIndex = self.folder.getValue(endPtr).Int;
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

pub fn typecheckBinary(self: *Typechecker, extraPtr: defines.OpaquePtr, _: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const operator: Lexer.TokenType = @enumFromInt(ast.extra[extraPtr + 1]);

    const lhs = try self.typecheckExpression(ast.extra[extraPtr], null);
    const rhs = try self.typecheckExpression(ast.extra[extraPtr + 2], lhs);

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
            break :res Comptime.Folder.Builtin.Type("bool");
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

            break :res self.coerce(lhs, rhs);
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

            break :res Comptime.Folder.Builtin.Type("bool");
        },
        .Plus, .Minus, .Slash, .Star, .Modulo => {
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

            break :res self.coerce(lhs, rhs);
        },

        else => common.debug.ShouldBeImpossible(self.context.log, @src()),
    };
}

pub fn typecheckUnary(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    const token: Lexer.TokenType = @enumFromInt(ast.extra[extraPtr]);
    const rhsType = try self.typecheckExpression(ast.extra[extraPtr + 1], maybeExpected);
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
        else => common.debug.ShouldBeImpossible(self.context.log, @src()),
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
        else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
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
        catch return common.debug.ShouldBeImpossible(self.context.log, @src());

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
                const fieldPtr = try self.folder.eval(caseLabel, uni.tag);
                const field = self.folder.getValue(fieldPtr);

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
                self.fieldIndex(itemTypeID, field) catch return common.debug.ShouldBeImpossible(self.context.log, @src())
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

    return expected orelse common.debug.ShouldBeImpossible(self.context.log, @src());
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
        catch return common.debug.ShouldBeImpossible(self.context.log, @src());

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
                const fieldPtr = try self.folder.eval(caseLabel, itemTypeID);
                const field = self.folder.getValue(fieldPtr);

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

    return expected orelse common.debug.ShouldBeImpossible(self.context.log, @src());
}

pub fn registerType(self: *Typechecker, newType: TypeInfo) Error!TypeID {
    const isPresent = self.typeMap.getOrPut(self.arena.allocator(), newType)
        catch return Error.AllocatorFailure;

    if (!isPresent.found_existing) {
        const typeID = try self.typeTable.addOne(self.arena.allocator());
        isPresent.value_ptr.* = @intCast(typeID);

        self.typeTable.set(typeID, newType);
        _ = try self.typeName(self.arena.allocator(), isPresent.value_ptr.*); // force intern type name
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

pub fn assertCastable(self: *Typechecker, from: TypeID, to: TypeID, unsafe: bool) Error!void {
    const fromType = self.typeTable.get(from);
    const toType = self.typeTable.get(to);

    switch (to) {
        Comptime.Folder.Builtin.Type("any"),
        Comptime.Folder.Builtin.Type("mut any") => return Error.InferenceError,
        else => { },
    }

    if (from == to) {
        return Error.RedundantCast;
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
        .ComptimeInt => try functional.throwIf(!self.isInt(to) and !self.isFloat(to) and !(unsafe and self.isCPtr(to)), Error.IncompatibleTypes),
        .ComptimeFloat => try functional.throwIf(!self.isFloat(to) and !self.isInt(to), Error.IncompatibleTypes),
        .Integer => |fromInt| switch (toType) {
            .Integer => |toInt| try functional.throwIf(
                if (unsafe) !self.isInt(to) and !self.isCPtr(to)
                else !toInt.canContain(fromInt),
                Error.SizeMismatch
            ),
            .ComptimeInt => {},
            .Float => {},
            else => return Error.IncompatibleTypes,
        },
        .Float => switch (toType) {
            .Integer, .ComptimeInt, .ComptimeFloat => {},
            else => return Error.IncompatibleTypes,
        },
        .Pointer => |fromPtr| switch (toType) {
            .Pointer => |toPtr| {
                try self.assertCastablePtr(fromPtr, toPtr, unsafe);
                try functional.throwIf((toPtr.mutable and !fromPtr.mutable) and !unsafe, Error.MutabilityViolation);
            },
            else => try functional.throwIf(!unsafe or !self.isInt(to), Error.IncompatibleTypes),
        },
        .Function => switch (toType) {
            .Function => { },
            else => return Error.IncompatibleTypes,
        },
        .Any, .Type,
        .Noreturn, .Array,
        .Void, .EnumLiteral => return Error.CastOfIncastableValue,
    }
}

pub fn castable(self: *Typechecker, from: TypeID, to: TypeID) bool {
    self.assertCastable(from, to) catch return false;
    return true;
}

pub fn assertCastablePtr(self: *const Typechecker, this: Types.Pointer, that: Types.Pointer, unsafe: bool) Error!void {
    switch (this.size) {
        .Slice => try functional.throwIf(!unsafe and that.size == .Slice and self.sizeOf(this.child) != self.sizeOf(that.child), Error.MismatchingSliceChildType),
        .Single => try functional.throwIf(!unsafe and that.size == .Slice, Error.PointerSizeMismatch),
        .C => try functional.throwIf(!unsafe and that.size == .Slice, Error.PointerSizeMismatch),
    }

    try functional.throwIf(!self.mutable(this.child) and self.mutable(that.child) and !unsafe, Error.MutabilityViolation);
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
        else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
    }
}

/// Check if 'this' is structurally identical to 'this'
pub fn structurallyIdentical(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    self.assertStructurallyIdentical(this, that) catch return false;
    return true;
}

/// Check if 'this' can be assigned to 'that'
pub fn suitable(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    self.assertCanCoerce(this, that) catch return false;
    return true;
}

/// Assert that 'that' can coerce to 'this'
pub fn assertCanCoerce(self: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const thisType = self.typeTable.get(this);
    const thatType = self.typeTable.get(that);

    const thisAny = std.meta.activeTag(thisType) == .Any;
    const thatAny = std.meta.activeTag(thatType) == .Any;

    if (thisAny and thatAny) {
        return Error.InferenceError;
    }
    else if (thisAny or thatAny) {
        return;
    }

    return switch (thatType) {
        .Noreturn => { },
        .ComptimeInt => functional.throwIf(!self.isInt(this) and !self.isFloat(this), Error.TypeMismatch),
        .ComptimeFloat => functional.throwIf(!self.isFloat(this) and !self.isInt(this), Error.TypeMismatch),
        .Float => functional.throwIf(!self.isFloat(this), Error.TypeMismatch),
        .Integer => |itype| switch (thisType) {
            .Integer => |i2type| functional.throwIf(itype.size > i2type.size, Error.TypeMismatch),
            else => functional.throwIf(!self.isInt(this), Error.TypeMismatch),
        },
        else => switch (thisType) {
            .ComptimeInt, .Integer,
            .ComptimeFloat, .Float => Error.TypeMismatch,
            .Struct, .Union, .Enum => {
                try functional.throwIf(std.meta.activeTag(thisType) != std.meta.activeTag(thatType), Error.TypeMismatch);
                const names: struct { usize, usize } = switch (thisType) {
                    .Struct => .{ thisType.Struct.name, thatType.Struct.name },
                    .Union => .{ thisType.Union.name, thatType.Union.name },
                    .Enum => .{ thisType.Enum.name, thatType.Enum.name },
                    else => return common.debug.ShouldBeImpossible(self.context.log, @src()),
                };
                try functional.throwIf(names.@"0" != names.@"1", Error.TypeMismatch);
            },
            .Function => |f1| {
                try functional.throwIf(std.meta.activeTag(thisType) != std.meta.activeTag(thatType), Error.TypeMismatch);
                try functional.throwIf(!std.mem.eql(u32, f1.argTypes, thatType.Function.argTypes), Error.IncompatibleTypes);
                try functional.throwIf(f1.returnType != thatType.Function.returnType, Error.IncompatibleTypes);
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
        .Integer => functional.throwIf(!self.isInt(that), Error.ComparisonOnIncompatibleTypes),
        .Float => functional.throwIf(!self.isFloat(that), Error.ComparisonOnIncompatibleTypes),
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

pub fn isCPtr(self: *const Typechecker, maybeCPtr: TypeID) bool {
    return switch (self.typeTable.get(maybeCPtr)) {
        .Pointer => |ptr| switch (ptr.size) {
            .C => true,
            else => false,
        },
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
/// Checks which of 'this' or 'that' is more suitable in general.
pub fn coerce(self: *Typechecker, this: TypeID, that: TypeID) Error!TypeID {
    self.assertCanCoerce(this, that) catch |err| {
        self.report("Failed to infer type ('{s}' and '{s}')", .{
            try self.typeName(self.arena.allocator(), this),
            try self.typeName(self.arena.allocator(), that),
        });
        return err;
    };

    const thisType = self.typeTable.get(this);
    const thatType = self.typeTable.get(that);

    if (thisType == .Any and thatType == .Any) {
        self.report("Failed to infer type in unknown context ('any' and 'any').", .{});
        return Error.InferenceError;
    }
    else if (thisType == .Any) {
        if (thisType.Any) {
            return self.registerType(self.makeMutable(thatType));
        }
        else return that;
    }
    else if (thatType == .Any) {
        return this;
    }

    return switch (thatType) {
        .Noreturn => that,
        .ComptimeInt, .ComptimeFloat => this,
        else => switch (thisType) {
            .ComptimeInt, .ComptimeFloat => that,
            .Integer => switch (thatType) {
                .Integer =>
                    if (thatType.Integer.size > thisType.Integer.size) that
                    else this,
                else => this,
            },
            .Noreturn => that,
            else => this,
        },
    };
}

pub fn expectType(self: *Typechecker, exprPtr: defines.ExpressionPtr) Error!TypeID {
    return
        if (self.folder.expectType(exprPtr)) |val| self.folder.getValue(val).Type 
        else |err| err;
}

pub fn mutable(self: *const Typechecker, typeID: TypeID) bool {
    return self.typeTable.get(typeID).isMutable();
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

pub fn getMutable(self: *Typechecker, id: TypeID) Error!TypeID {
    const immut = self.typeTable.get(id);
    const mut = self.makeMutable(immut);
    return self.registerType(mut);
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

/// Assumes 'of' is an array type.
pub fn sliceOf(self: *Typechecker, of: TypeID) Error!u32 {
    const info = self.typeTable.get(of);
    return switch (info) {
        .Array => |arr| self.registerType(.{
            .Pointer = .{
                .mutable = arr.mutable,
                .size = .Slice,
                .child = arr.child,
            },
        }),

        .Pointer => |ptr| self.registerType(.{
            .Pointer = .{
                .mutable = ptr.mutable,
                .size = .Slice,
                .child = ptr.child,
            },
        }),

        else => common.debug.ShouldBeImpossible(undefined, @src()),
    };
}

/// In bytes
pub fn sizeOf(self: *const Typechecker, of: TypeID) u32 {
    return ret: switch (self.typeTable.get(of)) {
        .Pointer => @bitSizeOf(*void),
        .Function => @bitSizeOf(@TypeOf(&sizeOf)),
        .Enum => @bitSizeOf(u32),
        .Float, .ComptimeFloat => @bitSizeOf(f32),
        .Integer => |int| int.size,
        .Bool => @bitSizeOf(bool),
        .Void, .Noreturn, .EnumLiteral, .Type, .Any => 0,
        .Array => |arr| arr.len * self.sizeOf(arr.child),
        .ComptimeInt => @bitSizeOf(i64),
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

            break :ret size + @as(u32, if (uni.isTagged) @bitSizeOf(u32) else 0);
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
    else return ret: switch (self.typeTable.get(typeID)) {
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
                expected == Comptime.Folder.Builtin.Type("any")
                or expected == Comptime.Folder.Builtin.Type("mut any")
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
    element: defines.ExpressionPtr,
    metadata: []const Comptime.Value.Ptr,
) Error!void {
    return self.metadata.put(self.arena.allocator(), element, metadata) catch Error.AllocatorFailure;
}

pub fn getMetadata(
    self: *const Typechecker,
    value: defines.EitherPtr(defines.ExpressionPtr, defines.StatementPtr)
) ?[]const defines.ExpressionPtr {
    return self.metadata.get(value);
}

pub fn hasMetadata(
    self: *const Typechecker,
    _value: defines.ExpressionPtr,
    _meta: []const u8,
) bool {
    const ast = self.context.getAST(self.currentFile);

    const value = blk: {
        const expr = ast.expressions.get(_value);

        break :blk
            if (expr.type == .Mark) ast.extra[expr.value + 2]
            else _value;
    };

    return
        if (self.getMetadata(value)) |metadata| blk: {
            for (metadata) |meta| {
                const meval = self.folder.getValue(meta);

                switch (meval) {
                    .Enum => |enm|
                        if (
                            enm.Type == Comptime.Folder.Builtin.Type("builtin_metadata")
                            and enm.Value == Comptime.Folder.Builtin.Metadata(_meta)
                        ) break :blk true,

                    else => { },
                }
            }

            break :blk false;
        }
        else false;
}

fn unwrapMark(self: *Typechecker, exprPtr: defines.ExpressionPtr) defines.ExpressionPtr {
    const ast = self.context.getAST(self.currentFile);
    var e = exprPtr;
    while (ast.expressions.items(.type)[e] == .Mark) {
        e = ast.extra[ast.expressions.items(.value)[e] + 2];
    }
    return e;
}
