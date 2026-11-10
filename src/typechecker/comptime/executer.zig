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
const Comptime = @import("../comptime.zig");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = common.CompilerError;
const TypeID = types.TypeID;
const TypeInfo = types.TypeInfo;
const JIR = @import("../../codegen/c/jir.zig");

const Stack = collections.StaticStack(Scope, defines.comptimeStackLimit);
const Cache = std.hash_map.HashMapUnmanaged(ExecutionKey, ExecutionResult, KeyContext, 75);
 
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: ExecutionKey) u64 {
        var h = std.hash.Wyhash.init(key.function);
        for (key.args) |arg| hashValue(&h, arg);
        return h.final();
    }
 
    pub fn eql(_: KeyContext, a: ExecutionKey, b: ExecutionKey) bool {
        if (a.function != b.function or a.args.len != b.args.len) return false;
        for (a.args, b.args) |x, y| {
            if (!eqlValue(x, y)) return false;
        }
        return true;
    }
};
 
fn hashValue(h: *std.hash.Wyhash, v: Comptime.Value) void {
    const hash = std.hash.autoHash;
    hash(h, std.meta.activeTag(v));
 
    switch (v) {
        .Int => |x| hash(h, x),
        .Float => |x| hash(h, @as(u64, @bitCast(x))),
        .Bool => |x| hash(h, x),
        .Enum => |x| {

            hash(h, x.Type);
            hash(h, x.Value);
        },
        .Union => |x| {
            hash(h, x.Type);
            hash(h, x.Tag);
            hash(h, x.Value);
        },
        .Struct => |x| {
            hash(h, x.Type);
            hash(h, x.Fields.start);
            hash(h, x.Fields.end);
        },
        .Type => |x| hash(h, x),
        .Pointer => |x| {
            hash(h, x.Type);
            hash(h, x.To);
        },
        .String => |x| {
            hash(h, x.type);
            h.update(x.str);
        },
        .Slice => |x| {
            hash(h, x.Type);
            hash(h, x.Size);
            hash(h, x.To);
        },
        .Function => |x| {
            hash(h, x.scope);
            hash(h, x.expr);

        },
        .Void => { },
        .Undefined => |x| hash(h, x),
    }
}
 
fn eqlValue(a: Comptime.Value, b: Comptime.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
 
    return switch (a) {
        .Int => |x| x == b.Int,
        .Float => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.Float)),
        .Bool => |x| x == b.Bool,
        .Enum => |x| x.Type == b.Enum.Type and x.Value == b.Enum.Value,
        .Union => |x| x.Type == b.Union.Type and x.Tag == b.Union.Tag and x.Value == b.Union.Value,
        .Struct => |x| x.Type == b.Struct.Type and x.Fields.start == b.Struct.Fields.start and x.Fields.end == b.Struct.Fields.end,
        .Type => |x| x == b.Type,
        .Pointer => |x| x.Type == b.Pointer.Type and x.To == b.Pointer.To,
        .String => |x| x.type == b.String.type and std.mem.eql(u8, x.str, b.String.str),
        .Slice => |x| x.Type == b.Slice.Type and x.Size == b.Slice.Size and x.To == b.Slice.To,
        .Function => |x| x.scope == b.Function.scope and x.expr == b.Function.expr,
        .Void => true,
        .Undefined => |x| x == b.Undefined,
    };
}


const ExecutionKey = struct {
    function: u64,
    args: []const Comptime.Value,
};

const ExecutionResult = union(enum) {
    InProgress: void,
    Evaluated: Comptime.Value.Ptr,
    NotEvaluated: void,
};

pub const Scope = struct {
    pub const Variables = collections.HashMap(defines.StringPtr, Comptime.Value.Ptr);

    pc: defines.Offset,
    variables: Variables,
    body: []const defines.StatementPtr,
    kind: enum {
        Block,
        Range,
        For,
        While,
    },
    data: union {
        block: void,
        range: struct {
            start: u32,
            end: u32,
            capture: defines.StringPtr,
        },
        over: struct {
            slice: defines.Range,
            index: defines.Offset,
            isPtr: bool,
            capture: defines.StringPtr,
        },
        condition: defines.ExpressionPtr,
    }
};

const Executer = @This();

typechecker: *Typechecker,
arena: Arena,
stack: Stack,
depth: u32,
cache: Cache,

pub fn init(typechecker: *Typechecker, allocator: Allocator) Error!Executer {
    var cache = Cache.empty;
    cache.ensureTotalCapacity(allocator, 100)
        catch return Error.AllocatorFailure;

    return .{
        .arena = Arena.init(allocator),
        .typechecker = typechecker,
        .stack = .{},
        .depth = 0,
        .cache = cache,
    };
}

pub fn executeCall(self: *Executer, func: JIR.Function, args: []const Comptime.Value.Ptr) Error!Comptime.Value.Ptr {
    const argValues = self.arena.allocator().alloc(Comptime.Value, args.len)
    catch return Error.AllocatorFailure;
    for (args, argValues) |ptr, *out| {
        out.* = self.typechecker.folder.getValue(ptr);
    }

    const key = ExecutionKey{
        .function =
            if (self.typechecker.folder.captures.contains(func.scope)) func.scope
            else (@as(u64, 1) << 63) | (@as(u64, func.source) << 32) | func.expr,
        .args = argValues,
    };

    if (self.cache.get(key)) |result| {
        switch (result) {
            .InProgress => {
                self.report("Dependency cycle during comptime execution. Function {s} depends on itself.", .{
                    self.typechecker.builder.getInternedString(func.name),
                });
                return Error.DependencyCycle;
            },
            .Evaluated => |r| return r,
            .NotEvaluated => { },
        }
    }

    if (self.depth >= defines.comptimeCallLimit) {
        self.report("Compile-time call depth limit ({d}) exceeded.", .{defines.comptimeCallLimit});
        return Error.StackOverflow;
    }
    self.depth += 1;
    defer self.depth -= 1;

    self.cache.put(self.arena.allocator(), key, .{ .InProgress = {} })
        catch return Error.AllocatorFailure;

    const sign = self.typechecker.typeTable.get(func.signature).Function;

    const pscope = self.typechecker.currentScope;
    defer self.typechecker.currentScope = pscope;
    self.typechecker.currentScope = func.scope;

    const prevInst = self.typechecker.folder.currentInstantiation;
    self.typechecker.folder.currentInstantiation =
        if (self.typechecker.folder.captures.contains(func.scope)) func.scope
        else null;
    defer self.typechecker.folder.currentInstantiation = prevInst;

    const psrc = self.typechecker.currentFile;
    defer self.typechecker.currentFile = psrc;
    self.typechecker.currentFile = func.source;

    const ast = self.typechecker.context.getAST(func.source);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const bodyPtr = ast.statements.get(func.body).value;

    const bodyRange = defines.Range{
        .start = ast.extra[bodyPtr],
        .end = ast.extra[bodyPtr + 1],
    };

    const body  = ast.extra[bodyRange.start..bodyRange.end];

    const base = self.stack.index;
    try self.stack.push(.{
        .pc = 0,
        .variables = .empty,
        .body = body,
        .kind = .Block,
        .data = .{ .block = {} },
    });
    defer self.stack.revert(base);

    self.stack.peek().variables.ensureTotalCapacity(self.arena.allocator(), @intCast(args.len))
        catch return Error.AllocatorFailure;

    for (args, 0..) |arg, i| {
        self.stack.peek().variables.putAssumeCapacityNoClobber(func.args[i], arg);
    }

    const prevsc = self.typechecker.folder.setFlag(.StaticPass, false);
    defer _ = self.typechecker.folder.setFlag(.StaticPass, prevsc);

    const returnType = 
        if (sign.isComptime) try self.typechecker.folder.determineComptimeReturnTypeDirect(sign.returnType, func, args)
        else sign.returnType;

    if (!self.typechecker.typecheckedBodies.contains((@as(u128, func.source) << 64) | (@as(u128, func.body) << 32) | self.typechecker.folder.instKey())) {
        const pc = self.typechecker.setFlag(.CoveredAllPaths, false);
        defer _ = self.typechecker.setFlag(.CoveredAllPaths, pc);

        const psc = self.typechecker.folder.setFlag(.StaticPass, true);
        defer _ = self.typechecker.folder.setFlag(.StaticPass, psc);

        const early = if (self.typechecker.typecheckStatement(func.body, returnType)) |_| false else |err| switch (err) {
            Error.EarlyEval => true,
            else => return err,
        };

        if (!early and !(
            self.typechecker.typeTable.get(returnType).isZeroBit()
            or self.typechecker.getFlag(.CoveredAllPaths)
        )) {
            self.report("Function with return type '{s}' does not return a value in all code paths.", .{
                try self.typechecker.typeName(self.arena.allocator(), returnType),
            });
            return Error.UncoveredCodePath;
        }

        if (!sign.isComptime) {
            self.typechecker.typecheckedBodies.put(self.arena.allocator(), (@as(u128, func.source) << 64) | (@as(u128, func.body) << 32) | self.typechecker.folder.instKey(), {})
                catch return Error.AllocatorFailure;
        }
    }

    while (self.stack.index > base) {
        const top = self.stack.peekm() orelse break;

        if (top.pc >= top.body.len) {
            switch (top.kind) {
                .Block => _ = self.stack.pop(),
                .While => {
                    const conditionExpr = top.data.condition;
                    const conditionRes = self.typechecker.folder.getValue(
                        try self.typechecker.folder.eval(conditionExpr, comptime Comptime.Folder.Builtin.Type("bool")),
                    ).Bool;

                    if (conditionRes) top.pc = 0
                    else _ = self.stack.pop();
                },
                .Range => {
                    top.data.range.start += 1;
                    if (top.data.range.start >= top.data.range.end) {
                        _ = self.stack.pop();
                    }
                    else {
                        top.pc = 0;

                        const val = self.stack.peek().variables.get(top.data.range.capture)
                            orelse return common.debug.ShouldBeImpossible(undefined, @src());

                        self.typechecker.folder.memory.items[val].Int = top.data.range.start;
                    }
                },
                .For => {
                    top.data.over.index += 1;

                    if (top.data.over.index >= top.data.over.slice.len()) {
                        _ = self.stack.pop();
                    }
                    else {
                        top.pc = 0;

                        if (top.data.over.isPtr) {
                            const val = self.stack.peek().variables.get(top.data.over.capture)
                                orelse return common.debug.ShouldBeImpossible(undefined, @src());
                            self.typechecker.folder.memory.items[val].Pointer.To += 1;
                        }
                        else {
                            self.stack.peek().variables.put(
                                self.arena.allocator(),
                                top.data.over.capture,
                                top.data.over.slice.at(top.data.over.index),
                            ) catch return Error.AllocatorFailure;
                        }
                    }
                },
            }
            continue;
        }

        defer top.pc += 1;
        const statement = ast.statements.get(top.body[top.pc]);

        switch (statement.type) {
            .VariableDefinition => {
                const signature = ast.signatures.get(ast.extra[statement.value]);
                const varType = if (signature.type == Parser.AnyType) null else try self.typechecker.expectType(signature.type);
                const value = try self.typechecker.folder.eval(ast.extra[statement.value + 1], varType);

                const name = try self.typechecker.builder.internString(tokens.get(signature.name).lexeme(self.typechecker.context, tokens.items(.start)[0]));

                top.variables.put(self.arena.allocator(), name, value)
                    catch return Error.AllocatorFailure;
            },
            .Discard => _ = try self.typechecker.folder.eval(statement.value, null),
            .Return => {
                if (statement.value == Parser.AnyType) {
                    self.cache.put(self.arena.allocator(), key, .{ .Evaluated = @intFromEnum(Comptime.Value.Implicit.Void) })
                        catch return Error.AllocatorFailure;
                    return @intFromEnum(Comptime.Value.Implicit.Void);
                }

                const res = try self.typechecker.folder.eval(statement.value, returnType);

                self.cache.put(self.arena.allocator(), key, .{ .Evaluated = res })
                    catch return Error.AllocatorFailure;
                return res;
            },
            .Block => {
                try self.stack.push(.{
                    .pc = 0,
                    .variables = .empty,
                    .body = ast.extra[
                        ast.extra[statement.value]
                        ..
                        ast.extra[statement.value + 1]
                    ],
                    .kind = .Block,
                    .data = .{ .block = {} },
                });
            },
            .Break => {
                while (self.stack.peek().kind == .Block) {
                    _ = self.stack.pop();
                }
                _ = self.stack.pop();
                continue;
            },
            .Continue => {
                while (self.stack.peek().kind == .Block) {
                    _ = self.stack.pop();
                }
                self.stack.peek().pc = @intCast(self.stack.peek().body.len);
                continue;
            },
            .For => {
                if (self.typechecker.hasMetadata(ast.extra[statement.value], "@inline")) {
                    self.report("Comptime execution of inlined for loops is not possible.", .{});
                    return Error.ComptimeNotPossible;
                }

                const isRange = ast.extra[statement.value + 1] == 1;
                const isPtr = ast.extra[statement.value + 5] == 1;
                const capturePtr = ast.extra[statement.value + 3];
                const bptr = ast.extra[statement.value + 4];

                const capture = ast.expressions.get(capturePtr);
                const captureName = tokens.get(capture.value).lexeme(self.typechecker.context, ast.tokens);
                const captureNamePtr = try self.typechecker.builder.internString(captureName);

                const bod = ast.statements.get(bptr);
                const bodyr =
                    if (bod.type == .Block) ast.extra[ast.extra[bod.value]..ast.extra[bod.value + 1]]
                    else ast.extra[statement.value + 4..statement.value + 5];

                if (isRange) {
                    const rangeStart = self.typechecker.folder.getValue(
                        try self.typechecker.folder.eval(ast.extra[statement.value], comptime Comptime.Folder.Builtin.Type("comptime_int")),
                    ).Int;

                    const rangeEnd = self.typechecker.folder.getValue(
                        try self.typechecker.folder.eval(ast.extra[statement.value + 2], comptime Comptime.Folder.Builtin.Type("comptime_int")),
                    ).Int;

                    if (rangeStart < rangeEnd) {
                        try self.stack.push(.{
                            .pc = 0,
                            .variables = .empty,
                            .body = bodyr,
                            .kind = .Range,
                            .data = .{
                                .range = .{
                                    .start = @intCast(rangeStart),
                                    .end = @intCast(rangeEnd),
                                    .capture = captureNamePtr,
                                }
                            }
                        });

                        self.stack.peek().variables.put(
                            self.arena.allocator(),
                            captureNamePtr,
                            try self.typechecker.folder.appendValue(.{ .Int = rangeStart }),
                        ) catch return Error.AllocatorFailure;
                    }
                }
                else {
                    const loopvar = switch (self.typechecker.folder.getValue(
                        try self.typechecker.folder.eval(ast.extra[statement.value], comptime Comptime.Folder.Builtin.Type("comptime_int")),
                    )) {
                        .Slice => |slice| slice,
                        .String => |str| blk: {
                            const to: u32 = @intCast(self.typechecker.folder.memory.items.len);
                            for (str.str) |byte| _ = try self.typechecker.folder.appendValue(.{ .Int = byte });

                            break :blk (Comptime.Value{
                                .Slice = .{
                                    .Type = comptime Comptime.Folder.Builtin.Type("[]u8"),
                                    .Size = @intCast(str.str.len),
                                    .To = to,
                                },
                            }).Slice;
                        },
                        else => return common.debug.ShouldBeImpossible(undefined, @src()),
                    };

                    if (loopvar.Size > 0) {
                        try self.stack.push(.{
                            .pc = 0,
                            .variables = .empty,
                            .body = bodyr,
                            .kind = .For,
                            .data = .{
                                .over = .{
                                    .slice = .{
                                        .start = loopvar.To,
                                        .end = loopvar.To + loopvar.Size,
                                    },
                                    .index = 0,
                                    .isPtr = isPtr,
                                    .capture = captureNamePtr,
                                }
                            }
                        });

                        self.stack.peek().variables.put(
                            self.arena.allocator(),
                            captureNamePtr,
                            if (isPtr) ptr: {
                                const child = switch (self.typechecker.typeTable.get(loopvar.Type)) {
                                    .Pointer => |p| p.child,
                                    .Array => |a| a.child,
                                    else => return common.debug.ShouldBeImpossible(undefined, @src()),
                                };

                                break :ptr try self.typechecker.folder.appendValue(.{
                                    .Pointer = .{
                                        .Type = try self.typechecker.registerType(.{
                                            .Pointer = .{
                                            .mutable = false,
                                            .size = .Single,
                                            .child = child,
                                        }}),
                                        .To = loopvar.To,
                                    },
                                });
                            }
                            else loopvar.To,
                        ) catch return Error.AllocatorFailure;
                    }
                }
            },
            .Expression => _ = try self.typechecker.folder.eval(statement.value, null),
            .While => {
                const conditionExpr = ast.extra[statement.value];
                const bptr = ast.extra[statement.value + 1];

                const conditionRes = self.typechecker.folder.getValue(
                    try self.typechecker.folder.eval(conditionExpr, comptime Comptime.Folder.Builtin.Type("bool")),
                ).Bool;

                if (conditionRes) {
                    const bod = ast.statements.get(bptr);
                    try self.stack.push(.{
                        .pc = 0,
                        .variables = .empty,
                        .body =
                            if (bod.type == .Block) ast.extra[ast.extra[bod.value]..ast.extra[bod.value + 1]]
                            else ast.extra[statement.value + 1..statement.value + 2],
                        .kind = .While,
                        .data = .{ .condition = conditionExpr },
                    });
                }
            },
            .Conditional => {
                const conditionExpr = ast.extra[statement.value];
                const conditionRes = self.typechecker.folder.getValue(
                    try self.typechecker.folder.eval(conditionExpr, comptime Comptime.Folder.Builtin.Type("bool"))
                ).Bool;

                if (conditionRes) {
                    const bptr = ast.extra[statement.value + 1];
                    const bod = ast.statements.get(bptr);
                    try self.stack.push(.{
                        .pc = 0,
                        .variables = .empty,
                        .body =
                            if (bod.type == .Block) ast.extra[ast.extra[bod.value]..ast.extra[bod.value + 1]]
                            else ast.extra[statement.value + 1..statement.value + 2],
                        .kind = .Block,
                        .data = .{ .block = {} },
                    });
                }
                else if (ast.extra[statement.value + 2] == 1) {
                    // @TODO fix this place to account for 'else if' usage.
                    const bPtr = ast.extra[statement.value + 3];
                    const bod = ast.statements.get(bPtr);
                    try self.stack.push(.{
                        .pc = 0,
                        .variables = .empty,
                        .body =
                            if (bod.type == .Block) ast.extra[ast.extra[bod.value]..ast.extra[bod.value + 1]]
                            else ast.extra[statement.value + 3..statement.value + 4],
                        .kind = .Block,
                        .data = .{ .block = {} },
                    });
                }
            },
            .Switch => {
                const itemPtr = try self.typechecker.folder.eval(ast.extra[statement.value], null);

                var labelType: TypeID = undefined;
                var tag: u32 = undefined;
                var payload = itemPtr;
                switch (self.typechecker.folder.getValue(itemPtr)) {
                    .Enum => |e| {
                        labelType = e.Type;
                        tag = @intCast(e.Value);
                    },
                    .Union => |u| {
                        labelType = self.typechecker.typeTable.get(u.Type).Union.tag;
                        tag = @intCast(u.Tag);
                        payload = u.Value;
                    },
                    else => return common.debug.ShouldBeImpossible(undefined, @src()),
                }

                var case = ast.extra[statement.value + 1];
                while (case < ast.extra[statement.value + 2]) : (case += 4) {
                    if (ast.extra[case] != 0) {
                        const label: u32 = @intCast(self.typechecker.folder.getValue(
                            try self.typechecker.folder.eval(ast.extra[case], labelType),
                        ).Enum.Value);

                        if (label != tag) continue;
                    }

                    const bod = ast.statements.get(ast.extra[case + 3]);
                    try self.stack.push(.{
                        .pc = 0,
                        .variables = .empty,
                        .body =
                            if (bod.type == .Block) ast.extra[ast.extra[bod.value]..ast.extra[bod.value + 1]]
                            else ast.extra[case + 3..case + 4],
                        .kind = .Block,
                        .data = .{ .block = {} },
                    });

                    if (ast.extra[case + 1] == 1) {
                        const captureName = tokens.get(ast.expressions.get(ast.extra[case + 2]).value)
                            .lexeme(self.typechecker.context, ast.tokens);

                        self.stack.peek().variables.put(
                            self.arena.allocator(),
                            try self.typechecker.builder.internString(captureName),
                            payload,
                        ) catch return Error.AllocatorFailure;
                    }

                    break;
                }
            },
            .InlineC, .Import => {
                self.report("'{s}' statements are not allowed in comptime scopes.", .{@tagName(statement.type)});
                return Error.ComptimeNotPossible;
            },
            else => {
                self.report("Execution of '{s}' in compile-time scopes is not implemented.", .{@tagName(statement.type)});
                return Error.ShouldBeImpossible;
            },
        }
    }

    self.cache.put(self.arena.allocator(), key, .{ .Evaluated = @intFromEnum(Comptime.Value.Implicit.Void) })
        catch return Error.AllocatorFailure;

    return @intFromEnum(Comptime.Value.Implicit.Void);
}

pub fn executeAssignment(self: *Executer, extraPtr: defines.OpaquePtr) Error!Comptime.Value.Ptr {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const assignee = ast.expressions.get(ast.extra[extraPtr]);
    const assigneeType = try self.typechecker.typecheckExpression(ast.extra[extraPtr], null);
    const value = try self.typechecker.folder.eval(ast.extra[extraPtr + 1], assigneeType);

    switch (assignee.type) {
        .Identifier => {
            const token = try self.typechecker.builder.internString(tokens.get(assignee.value).lexeme(self.typechecker.context, self.typechecker.currentFile));
            self.setVar(token, value);
        },
        .Indexing => {
            const slice = switch (self.typechecker.folder.getValue(try self.typechecker.folder.eval(ast.extra[assignee.value], assigneeType))) {
                .Slice => |s| s.To,
                .Pointer => |p| p.To,
                else => return common.debug.ShouldBeImpossible(undefined, @src()),
            };
            const index = self.typechecker.folder.getValue(try self.typechecker.folder.eval(ast.extra[assignee.value + 1], assigneeType)).Int;

            self.typechecker.folder.memory.items[@intCast(slice + index)] = self.typechecker.folder.getValue(value);
        },
        .Scoping => {
            self.report("Global mutation in compile-time is not supported.", .{});
            return Error.ComptimeNotPossible;
        },
        .Dot => return Error.NotImplemented,
        else => return common.debug.ShouldBeImpossible(undefined, @src()),
    }

    return value;
}

pub fn snapshot(self: *const Executer, allocator: Allocator) Error!Scope.Variables {
    var out: Scope.Variables = .empty;
    for (self.stack.items) |scope| {
        var it = scope.variables.iterator();
        while (it.next()) |e|
            out.put(allocator, e.key_ptr.*, e.value_ptr.*) catch return Error.AllocatorFailure;
    }
    return out;
}

pub fn getVar(self: *const Executer, name: defines.StringPtr) ?Comptime.Value.Ptr {
    var i = self.stack.items.len;
    while (i > 0) {
        i -= 1;
        if (self.stack.items[i].variables.get(name)) |v| return v;
    }

    return null;
}

pub fn setVar(self: *const Executer, name: defines.StringPtr, val: Comptime.Value.Ptr) void {
    var i = self.stack.items.len;
    while (i > 0) {
        i -= 1;
        if (self.stack.items[i].variables.getEntry(name)) |v| {
            v.value_ptr.* = val;
        }
    }
}

fn report(self: *Executer, comptime fmt: []const u8, args: anytype) void {
    return self.typechecker.report("COMPTIME EXECUTER: " ++ fmt, args);
}
