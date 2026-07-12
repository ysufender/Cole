const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("../parser/parser.zig");
const Prepass = @import("../parser/prepass.zig");

const MultiArrayList = collections.MultiArrayList;
const ModuleList = Prepass.ModuleList;
const Error = common.CompilerError;
const Context = common.CompilerContext;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;

const assert = std.debug.assert;

pub const ScopeList = MultiArrayList(Scope);
pub const DeclarationList = MultiArrayList(Declaration);
pub const LookupMap = collections.HashMap(LookupKey([]const u8), defines.DeclPtr);
pub const ResolutionMap = collections.HashMap(ResolutionKey, defines.DeclPtr);

pub const Scope = struct {
    pub const Kind = enum {
        Module,
        Block,
        Enum,
        Struct,
        Union,
    };

    parent: ?defines.ScopePtr,
    module: defines.ModulePtr,
    kind: Kind,
};

pub const Declaration = struct {
    pub const Kind = enum {
        Variable,
        Capture,
        Parameter,
        Namespace,
        Field,
        Builtin,
    };

    scope: defines.ScopePtr,
    token: defines.TokenPtr,
    node: defines.StatementPtr,
    type: defines.ExpressionPtr,
    topLevel: bool,
    kind: Kind,
    public: bool,
};

pub const ResolutionKey = struct {
    file: defines.FilePtr,
    expr: defines.ExpressionPtr,
};

pub fn LookupKey(comptime T: type) type {
    return struct {
        scope: defines.OpaquePtr,
        name: T,
    };
}

pub fn LookupContext(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Key = LookupKey(T);

        pub fn hash(_: Self, key: Key) u64 { 
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(_: Self, a: Key, b: Key) bool {
            return
                a.scope == b.scope
                and
                switch (@typeInfo(T)) {
                    .Pointer => |ptr| std.mem.eql(ptr.child, a.name, b.name),
                    else => a.name == b.name,
                };
        }
    };
}

pub const Resolution = struct {
    resolutionMap: ResolutionMap,
    declarations: DeclarationList.Slice,
    lookup: LookupMap,
    scopes: ScopeList.Slice,

    pub fn tryGetDecl(self: *const Resolution, key: ResolutionKey) ?defines.DeclPtr {
        return self.resolutionMap.get(key);
    }

    pub fn getDecl(self: *const Resolution, key: defines.DeclPtr) Declaration {
        assert(self.declarations.len > key);
        return self.declarations.get(key);
    }

    pub fn findDecl(self: *const Resolution, key: ResolutionKey) defines.DeclPtr {
        assert(self.resolutionMap.contains(key));
        return self.resolutionMap.get(key).?;
    }

    pub fn findGetDecl(self: *const Resolution, key: ResolutionKey) Declaration {
        return self.getDecl(self.findDecl(key));
    }

    pub fn canAccess(self: *const Resolution, child: defines.ScopePtr, parent: defines.ScopePtr) bool {
        var maybeCurrent: ?defines.ScopePtr = child;
        while (maybeCurrent) |current| {
            if (current == parent) {
                return true;
            }

            maybeCurrent = self.scopes.items(.parent)[current];
        }

        return false;
    }
};

const Resolver = @This();

arena: Arena,
context: *Context,
scopes: ScopeList,
lookup: LookupMap,
decls: DeclarationList,
resolved: ResolutionMap,
currentScope: defines.ScopePtr,
modules: *const ModuleList,
lastToken: defines.TokenPtr,

pub fn init(gpa: Allocator, context: *Context, modules: *const ModuleList) Error!Resolver {
    var arena = Arena.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const scopeCap = (context.counts.statements / 4) + context.counts.modules;
    const declCap = (context.counts.expressions / 8) + context.counts.topLevels;

    var scopes = try ScopeList.init(allocator, scopeCap + 1);
    var decls = try DeclarationList.init(allocator, declCap + builtins.len);
    var lookup = LookupMap.empty;
    var reso = ResolutionMap.empty;

    lookup.ensureTotalCapacity(allocator, declCap) catch return Error.AllocatorFailure;
    reso.ensureTotalCapacity(allocator, declCap) catch return Error.AllocatorFailure;

    const builtin = try scopes.addOne(allocator);
    scopes.set(builtin, .{
        .parent = null,
        .module = modules.ids.get("builtin").?,
        .kind = .Module,
    });

    for (builtins, 0..) |b, i| {
        const decl = try decls.addOne(allocator);
        decls.set(decl, .{
            .kind = .Builtin,
            .scope = builtin,
            .public = true,
            .token = 0,
            .node = @intCast(i),
            .type = @intCast(i),
            .topLevel = true,
        });

        lookup.putNoClobber(allocator, .{ .name = b, .scope = builtin }, decl)
            catch return Error.AllocatorFailure;
    }

    var iterator = modules.modules.iterator();
    _ = iterator.next();
    while (iterator.next()) |module| {
        const tokens = context.getTokens(module.dataIndex);

        const scope = try scopes.addOne(allocator);
        scopes.set(scope, .{
            .parent = builtin,
            .module = iterator.idx - 1,
            .kind = .Module,
        });

        var siterator = module.symbols.iterator();
        while (siterator.next()) |symbol| {
            const name = tokens.get(symbol.name).lexeme(context, module.dataIndex);

            const decl = try decls.addOne(allocator);
            decls.set(decl, .{
                .scope = scope,
                .kind = .Variable,
                .public = symbol.public,
                .token = symbol.name,
                .node = symbol.value,
                .type = symbol.type,
                .topLevel = true,
            });

            lookup.putNoClobber(allocator, .{
                .scope = scope,
                .name = name,
            }, decl) catch return Error.AllocatorFailure;
        }
    }

    return .{
        .context = context,
        .scopes = scopes,
        .lookup = lookup,
        .decls = decls,
        .resolved = reso,
        .modules = modules,
        .currentScope = 1,
        .lastToken = 0,
        .arena = arena,
    };
}

pub fn resolve(self: *Resolver, allocator: Allocator) Error!Resolution {
    defer self.arena.deinit();

    var errCount: u32 = 0;
    var lastErr: common.CompilerError = undefined;

    const modules = self.scopes.len;
    for (1..modules) |i| {
        self.currentScope = @intCast(i);
        self.resolveModule() catch |err| {
            errCount += 1;
            lastErr = err;
            if (errCount == self.context.settings.maxErr) {
                common.log.err("Too many errors, aborting compilation.\n", .{});
                return err;
            }
        };
    }

    if (errCount > 1) {
        lastErr = Error.MultipleErrors;
    }

    if (errCount > 0) {
        return lastErr;
    }

    return collections.deepCopy(Resolution{
        .resolutionMap = self.resolved,
        .declarations = self.decls.slice(),
        .scopes = self.scopes.slice(),
        .lookup = self.lookup,
    }, allocator);
}

fn resolveModule(self: *Resolver) Error!void {
    const module = self.modules.modules.items(.name)[self.scopes.items(.module)[self.currentScope]];

    const kind = self.scopes.items(.kind)[self.currentScope];
    if (kind != .Module) {
        return Error.UnexpectedScope;
    }

    var errCount: u32 = 0;
    var lastErr: common.CompilerError = undefined;

    const ast = self.context.getAST(self.dataIndex());
    const allocator = self.arena.allocator();
    _ = allocator;

    for (ast.statementMask) |item| {
        self.resolveStatement(item, true) catch |err| {
            errCount += 1;
            lastErr = err;
            common.log.err("Error: {d} <{s}>\n", .{ @intFromError(err), @errorName(err) });
            if (errCount == self.context.settings.maxErr) {
                common.log.err("Too many errors, aborting current module '{s}'.\n", .{module});
                return err;
            }
        };
    }

    if (errCount > 1) {
        lastErr = Error.MultipleErrors;
    }

    if (errCount > 0) {
        return lastErr;
    }
}

fn resolveStatement(self: *Resolver, stmt: defines.StatementPtr, topLevel: bool) Error!void {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(ast.tokens);

    const statement = ast.statements.get(stmt);
    switch (statement.type) {
        .Block => {
            const stmts = defines.Range{
                .start = ast.extra[statement.value],
                .end = ast.extra[statement.value + 1]
            };

            const block = try self.scopes.addOne(allocator);
            self.scopes.set(block, .{
                .module = self.scopes.items(.module)[self.currentScope],
                .parent = self.currentScope,
                .kind = .Block,
            });

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = block;

            for (stmts.start..stmts.end) |stmtPtrPtr| {
                const stmtPtr = ast.extra[stmtPtrPtr];
                try self.resolveStatement(stmtPtr, false);
            }
        },
        .Conditional => {
            const condition = ast.extra[statement.value];
            try self.resolveExpression(condition);

            const body = ast.extra[statement.value + 1];
            try self.resolveStatement(body, false);

            const hasElse = ast.extra[statement.value + 2] == 1;
            if (hasElse) {
                const elseBody = ast.extra[statement.value + 3];
                try self.resolveStatement(elseBody, false);
            }
        },
        .Switch => try self.resolveSwitch(.Statement, ast, tokens, statement.value),
        .While => {
            const condition = ast.extra[statement.value];
            try self.resolveExpression(condition);

            const body = ast.extra[statement.value + 1];
            try self.resolveStatement(body, false);
        },
        .Mark => {
            const marks = defines.Range{
                .start = ast.extra[statement.value],
                .end = ast.extra[statement.value + 1],
            };

            for (marks.start..marks.end) |mark| {
                try self.resolveExpression(ast.extra[mark]);
            }

            const marked = ast.extra[statement.value + 2];
            try self.resolveStatement(marked, topLevel);
        },
        .VariableDefinition => {
            const signature = ast.signatures.get(ast.extra[statement.value]);
            const initializer = ast.extra[statement.value + 1];

            if (signature.type != 0) {
                try self.resolveExpression(signature.type);
            }

            const decl =
                if (topLevel) try self.look(signature.name)
                else try self.decls.addOne(allocator);

            self.decls.set(decl, .{
                .kind = .Variable,
                .scope = self.currentScope,
                .public = signature.public,
                .token = signature.name,
                .node = initializer,
                .type = signature.type,
                .topLevel = topLevel,
            });

            if (topLevel) {
                return self.resolveExpression(initializer);
            }

            const name = tokens.get(signature.name).lexeme(self.context, self.dataIndex());
            const isPresent = self.lookup.getOrPut(allocator, .{ .name = name, .scope = self.currentScope })
                catch return Error.AllocatorFailure;

            if (isPresent.found_existing) {
                self.report("Given symbol '{s}' collides with the previous definition of '{s}'.", .{name, name});

                const found = self.decls.get(isPresent.value_ptr.*);
                if (found.kind != .Builtin) {
                    self.lastToken = found.token;
                    self.report("Found here.", .{});
                }

                return Error.DuplicateSymbol;
            }

            isPresent.value_ptr.* = decl;

            try self.resolveExpression(initializer);
        },
        .Import => {
            const modulename = self.getModuleName(ast.extra[statement.value]);
            const moduleID = self.modules.get(modulename);
            const isAlias = ast.extra[statement.value + 1] == 1;
            const alias =
                if (isAlias) ast.extra[statement.value + 2]
                else 0;

            const decl = try self.decls.addOne(allocator);
            self.decls.set(decl, .{
                .kind = .Namespace,
                .scope = self.currentScope,
                .public = false,
                .token = if (isAlias) alias else ast.extra[statement.value],
                .node = moduleID,
                .type = ast.extra[statement.value],
                .topLevel = true,
            });

            const lexeme =
                if (isAlias) tokens.get(alias).lexeme(self.context, self.dataIndex())
                else modulename;

            const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
                catch return Error.AllocatorFailure;

            if (isPresent.found_existing) {
                const kind: Declaration.Kind = self.decls.items(.kind)[isPresent.value_ptr.*];

                switch (kind) {
                    .Namespace => self.report("Duplicate import of '{s}'.", .{lexeme}),
                    else => self.report("Given definition '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme}),
                }

                const found = self.decls.get(isPresent.value_ptr.*);
                if (found.kind != .Builtin) {
                    self.lastToken = found.token;
                    self.report("Found here.", .{});
                }
                
                return Error.DuplicateSymbol;
            }

            isPresent.value_ptr.* = decl;
        },

        // Single expr statements
        .Defer, .Return, .Discard, .Expression => try self.resolveExpression(statement.value),

        else => {},
    }
}

fn resolveExpression(self: *Resolver, exprPtr: defines.ExpressionPtr) Error!void {
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(ast.tokens);

    const allocator = self.arena.allocator();

    const expr = ast.expressions.get(exprPtr);
    switch (expr.type) {
        .Identifier => {
            const identifier = expr.value;
            self.lastToken = identifier;

            if (identifier == 0) return;

            const decl = try self.look(identifier);

            const status = self.resolved.getOrPut(allocator, .{ .file = ast.tokens, .expr = exprPtr })
                catch return Error.AllocatorFailure;

            if (status.found_existing) {
                self.report(
                    "This is an internal compiler bug."
                    ++ " Attempt to resolve identifier '{s}', multiple times.", .{
                    tokens.get(identifier).lexeme(self.context, ast.tokens)
                });
                return common.debug.ShouldBeImpossible(@src());
            }

            status.value_ptr.* = decl;
        },
        .Indexing, .Assignment => {
            const lhs = ast.extra[expr.value];
            try self.resolveExpression(lhs);

            const rhs = ast.extra[expr.value + 1];
            try self.resolveExpression(rhs);
        },
        .Slicing => {
            const ptr = ast.extra[expr.value];
            try self.resolveExpression(ptr);

            const rangeStart = ast.extra[expr.value + 1];
            try self.resolveExpression(rangeStart);

            const rangeEnd = ast.extra[expr.value + 2];
            try self.resolveExpression(rangeEnd);
        },
        .Binary => {
            const lhs = ast.extra[expr.value];
            try self.resolveExpression(lhs);

            const rhs = ast.extra[expr.value + 2];
            try self.resolveExpression(rhs);
        },
        .Unary => {
            const rhs = ast.extra[expr.value + 1];
            try self.resolveExpression(rhs);
        },
        .StructDefinition => {
            const body = try self.scopes.addOne(allocator);
            self.scopes.set(body, .{
                .parent = self.currentScope,
                .module = self.scopes.items(.module)[self.currentScope],
                .kind = .Struct,
            });

            self.resolved.putNoClobber(allocator, .{
                .file = self.dataIndex(),
                .expr = exprPtr,
            }, body) catch return Error.AllocatorFailure;

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = body;

            const defs = defines.Range{
                .start = ast.extra[expr.value + 2],
                .end = ast.extra[expr.value + 3],
            };

            try self.handleScopeDefs(defs);

            const fields = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            for (fields.start..fields.end) |fieldPtrPtr| {
                if (try self.resolveSignature(ast.extra[fieldPtrPtr], .Field, .Struct)) {
                    const lexeme = tokens.get(ast.signatures.get(ast.extra[fieldPtrPtr]).name).lexeme(self.context, self.dataIndex());
                    self.report("Given field '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});
                    return Error.DuplicateSymbol;
                }
            }
        },
        .EnumDefinition => {
            const body = try self.scopes.addOne(allocator);
            self.scopes.set(body, Scope{
                .parent = self.currentScope,
                .module = self.scopes.items(.module)[self.currentScope],
                .kind = .Enum,
            });

            self.resolved.putNoClobber(allocator, .{
                .file = self.dataIndex(),
                .expr = exprPtr,
            }, body) catch return Error.AllocatorFailure;

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = body;

            const defs = defines.Range{
                .start = ast.extra[expr.value + 2],
                .end = ast.extra[expr.value + 3],
            };

            try self.handleScopeDefs(defs);

            const fields = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            for (fields.start..fields.end) |fieldPtrPtr| {
                if (try self.resolveSignature(ast.extra[fieldPtrPtr], .Field, .Enum)) {
                    const lexeme = tokens.get(ast.signatures.get(ast.extra[fieldPtrPtr]).name).lexeme(self.context, self.dataIndex());
                    self.report("Given field '{s}' is already present in the enum body.", .{lexeme});
                    return Error.DuplicateSymbol;
                }
            }
        },
        .UnionDefinition => {
            const body = try self.scopes.addOne(allocator);
            self.scopes.set(body, Scope{
                .parent = self.currentScope,
                .module = self.scopes.items(.module)[self.currentScope],
                .kind = .Union,
            });

            self.resolved.putNoClobber(allocator, .{
                .file = self.dataIndex(),
                .expr = exprPtr,
            }, body) catch return Error.AllocatorFailure;

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = body;

            var offset: u32 = 1;
            const tagged = ast.extra[expr.value] == 1;
            if (tagged) {
                const explicit = ast.extra[expr.value + 1] == 1;
                if (explicit) {
                    const tag = ast.extra[expr.value + 2];
                    try self.resolveExpression(tag);
                }

                offset = if (explicit) 3 else 2;
            }

            const defs = defines.Range{
                .start = ast.extra[expr.value + offset + 2],
                .end = ast.extra[expr.value + offset + 3],
            };

            try self.handleScopeDefs(defs);

            const fields = defines.Range{
                .start = ast.extra[expr.value + offset],
                .end = ast.extra[expr.value + offset + 1],
            };

            for (fields.start..fields.end) |fieldPtrPtr| {
                if (try self.resolveSignature(ast.extra[fieldPtrPtr], .Field, .Union)) {
                    const lexeme = tokens.get(ast.signatures.get(ast.extra[fieldPtrPtr]).name).lexeme(self.context, self.dataIndex());
                    self.report("Given field '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});
                    return Error.DuplicateSymbol;
                }
            }
        },
        .FunctionDefinition => {
            const params = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            const function = try self.scopes.addOne(allocator);
            self.scopes.set(function, .{
                .module = self.scopes.items(.module)[self.currentScope],
                .parent = self.currentScope,
                .kind = .Block,
            });

            self.resolved.putNoClobber(allocator, .{
                .file = self.dataIndex(),
                .expr = exprPtr,
            }, function) catch return Error.AllocatorFailure;

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = function;

            for (params.start..params.end) |paramPtrPtr| {
                const lexeme = tokens.get(ast.signatures.get(ast.extra[paramPtrPtr]).name).lexeme(self.context, self.dataIndex());
                if (try self.resolveSignature(ast.extra[paramPtrPtr], .Parameter, .Block)) {
                    self.report("Duplicate parameter name '{s}'.", .{lexeme});
                    return Error.DuplicateSymbol;
                }
            }

            const returns = ast.extra[expr.value + 2];
            try self.resolveExpression(returns);

            const body = ast.extra[expr.value + 3];
            try self.resolveStatement(body, false);
        },
        .Mark => {
            const marks = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            for (marks.start..marks.end) |mark| {
                try self.resolveExpression(ast.extra[mark]);
            }

            const marked = ast.extra[expr.value + 2];
            try self.resolveExpression(marked);
        },
        .Lambda => {
            const captures = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            const lambda = try self.scopes.addOne(allocator);
            self.scopes.set(lambda, .{
                .module = self.scopes.items(.module)[self.currentScope],
                .parent = self.currentScope,
                .kind = .Block,
            });

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = lambda;

            self.resolved.putNoClobber(allocator, .{
                .file = self.dataIndex(),
                .expr = exprPtr,
            }, lambda) catch return Error.AllocatorFailure;

            for (captures.start..captures.end) |capturePtrPtr| {
                const name = ast.extra[capturePtrPtr];
                const lexeme = tokens.get(name).lexeme(self.context, self.dataIndex());

                const decl = try self.decls.addOne(allocator);
                self.decls.set(decl, .{
                    .kind = .Parameter,
                    .scope = self.currentScope,
                    .public = false,
                    .token = name,
                    .node = name,
                    .type = 0,
                    .topLevel = false,
                });

                const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
                    catch return Error.AllocatorFailure;

                if (isPresent.found_existing) {
                    self.report("Duplicate capture '{s}'.", .{lexeme});
                    return Error.DuplicateSymbol;
                }

                isPresent.value_ptr.* = decl;
            }

            const body = ast.extra[expr.value + 2];
            try self.resolveExpression(body);
        },
        .Call => {
            const function = ast.extra[expr.value];
            try self.resolveExpression(function);

            const args = ast.extra[expr.value + 1];
            try self.resolveExpression(args);
        },
        .Conditional => {
            const condition = ast.extra[expr.value];
            try self.resolveExpression(condition);

            const body = ast.extra[expr.value + 1];
            try self.resolveExpression(body);

            const elseBody = ast.extra[expr.value + 2];
            try self.resolveExpression(elseBody);
        },
        .Switch => try self.resolveSwitch(.Expression, ast, tokens, expr.value),
        .MutableType, .PointerType, .SliceType, .CPointerType => try self.resolveExpression(expr.value),
        .ArrayType => {
            const size = ast.extra[expr.value];
            try self.resolveExpression(size);

            const inner = ast.extra[expr.value + 1];
            try self.resolveExpression(inner);
        },
        .FunctionType => {
            const args = ast.extra[expr.value];
            try self.resolveExpression(args);

            const returns = ast.extra[expr.value + 1];
            try self.resolveExpression(returns);
        },
        .Scoping => _ = try self.resolveScoping(ast, tokens, exprPtr, false),
        .ExpressionList => {
            const expressions = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            for (expressions.start..expressions.end) |expressionPtrPtr| {
                try self.resolveExpression(ast.extra[expressionPtrPtr]);
            }
        },
        .Dot => try self.resolveExpression(ast.extra[expr.value]),
        else => {},
    }
}

fn resolveScoping(
    self: *Resolver,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    expr: defines.ExpressionPtr,
    inside: bool,
) Error!?defines.Offset {
    // TODO: A non-allocating scope resolution function

    const extra: defines.OpaquePtr = ast.expressions.items(.value)[expr];
    
    const lhsPtr = ast.extra[extra];

    const lhs = ast.expressions.get(lhsPtr);
    const leftMost = blk: switch (lhs.type) {
        .Identifier => {
            const left = tokens.get(lhs.value).lexeme(self.context, ast.tokens);

            if (try self.tryLookName(left)) |found| {
                self.resolved.putNoClobber(self.arena.allocator(), .{
                    .file = ast.tokens,
                    .expr = lhsPtr,
                }, found) catch return Error.AllocatorFailure;
            }

            break :blk @as(defines.Offset, tokens.items(.start)[lhs.value]);
        },
        .Scoping => try self.resolveScoping(ast, tokens, lhsPtr, true),
        else => {
            try self.resolveExpression(lhsPtr);
            break :blk null;
        },
    };

    if (leftMost) |left| {
        const file = self.context.getFile(ast.tokens);

        const rightMost: defines.Offset = tokens.items(.end)[ast.extra[extra + 1]];
        const scoping = file[left..rightMost];

        if (try self.tryLookName(scoping)) |decl| {
            self.resolved.putNoClobber(self.arena.allocator(), .{
                .file = ast.tokens,
                .expr = expr,
            }, decl) catch return Error.AllocatorFailure;

            return leftMost;
        }
    }

    if (self.resolved.get(.{
        .file = ast.tokens,
        .expr = lhsPtr
    })) |declPtr| blk: {
        const decl = self.decls.get(declPtr);

        if (decl.kind != .Namespace) {
            break :blk;
        }

        const member = tokens.get(ast.extra[extra + 1]).lexeme(self.context, ast.tokens);

        if (try self.tryLookNameAt(member, decl.node)) |foundPtr| {
            self.resolved.putNoClobber(self.arena.allocator(), .{
                .file = ast.tokens,
                .expr = expr,
            }, foundPtr) catch return Error.AllocatorFailure;

            return leftMost;
        }
        else if (!inside) {
            self.report("Couldn't find given symbol '{s}' in module '{s}'.", .{
                member,
                self.modules.modules.get(self.scopes.get(decl.node).module).name
            });
            return Error.InvalidIdentifier;
        }
    }

    const moduleName = self.getModuleName(lhsPtr);

    // TODO: I don't like this hardcoded
    if (moduleName[0] == '/') {
        return leftMost;
    }

    if (self.modules.ids.contains(moduleName)) {
        self.report("Given module '{s}' is not imported into the current scope.", .{
            moduleName,
        });
        return Error.ModuleNotInScope;
    }

    return leftMost;
}

fn resolveSignature(self: *Resolver, signaturePtr: defines.SignaturePtr, comptime signatureType: Declaration.Kind, comptime bodyType: Scope.Kind) Error!bool {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(self.dataIndex());

    switch (signatureType) {
        .Field, .Parameter => |t| {
            if (bodyType == .Enum) {
                if (t != .Field) {
                    @compileError("Illegal signature type.");
                }

                const field = tokens.get(signaturePtr);
                self.lastToken = signaturePtr;
                const lexeme = field.lexeme(self.context, self.dataIndex());

                const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
                    catch return Error.AllocatorFailure;

                return isPresent.found_existing;
            }
            else {
                const field = ast.signatures.get(signaturePtr);
                self.lastToken = field.name;
                const lexeme = tokens.get(field.name).lexeme(self.context, self.dataIndex());

                if (field.type != 0) {
                    try self.resolveExpression(field.type);
                }

                const decl = try self.decls.addOne(allocator);
                self.decls.set(decl, .{
                    .kind = t,
                    .scope = self.currentScope,
                    .public = field.public,
                    .token = field.name,
                    .node = field.type,
                    .type = field.type,
                    .topLevel = false,
                });

                const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
                    catch return Error.AllocatorFailure;

                return
                    if (isPresent.found_existing) true
                    else blk: {
                        isPresent.value_ptr.* = decl;
                        break :blk false;
                    };
            }
        },
        else => common.debug.ShouldBeImpossible(@src()),
    }
}

fn resolveSwitch(
    self: *Resolver,
    switchType: enum {
        Statement,
        Expression
    },
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    extraPtr: defines.OpaquePtr
) Error!void {
    const allocator = self.arena.allocator();

    const item = ast.extra[extraPtr];
    try self.resolveExpression(item);

    const cases = defines.Range{
        .start = ast.extra[extraPtr + 1],
        .end = ast.extra[extraPtr + 2],
    };

    var case: u32 = cases.start;
    while (case < cases.end) : (case += 4) {
        const pattern = ast.extra[case];

        if (pattern != 0) {
            try self.resolveExpression(pattern);
        }

        const caseScope = try self.scopes.addOne(allocator);
        self.scopes.set(caseScope, .{
            .module = self.scopes.items(.module)[self.currentScope],
            .parent = self.currentScope,
            .kind = .Block,
        });

        const previous = self.currentScope;
        defer self.currentScope = previous;
        self.currentScope = caseScope;

        const captureCount = ast.extra[case + 1];
        const firstCapture = ast.extra[case + 2];
        const firstCaptureToken: defines.TokenPtr = ast.expressions.items(.value)[firstCapture];
        for (0..captureCount) |captureIndex| {
            const captureToken: u32 = @intCast(firstCaptureToken + 2 * captureIndex);
            self.lastToken = captureToken;

            const decl = try self.decls.addOne(allocator);
            self.decls.set(decl, .{
                .scope = self.currentScope,
                .kind = .Capture,
                .public = false,
                .token = captureToken,
                .node = firstCapture,
                .type = firstCapture,
                .topLevel = false,
            });

            // @Beware must be kept in sync with the typechecker,
            // destructuring is not supported yet
            self.resolved.put(allocator, .{
                .file = self.dataIndex(),
                .expr = firstCapture,
            }, decl) catch return Error.AllocatorFailure;

            const lexeme = tokens.get(captureToken).lexeme(self.context, self.dataIndex());
            self.lookup.putNoClobber(allocator, .{ .name = lexeme, .scope = self.currentScope }, decl)
                catch return Error.AllocatorFailure;
        }

        const body = ast.extra[case + 3];
        try switch (switchType) {
            .Statement => self.resolveStatement(body, false),
            .Expression => self.resolveExpression(body),
        };
    }
}

fn prepassScope(self: *Resolver, declarations: defines.Range) Error!void {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(self.dataIndex());

    for (declarations.start..declarations.end) |declarationPtrPtr| {
        const expr = ast.statements.items(.value)[ast.extra[declarationPtrPtr]];

        const signature = ast.extra[expr];
        
        const field = ast.signatures.items(.name)[signature];
        self.lastToken = field;
        const lexeme = tokens.get(field).lexeme(self.context, self.dataIndex());

        const decl = try self.decls.addOne(allocator);
        self.decls.set(decl, .{
            .kind = .Variable,
            .scope = self.currentScope,
            .public = false,
            .token = field,
            .node = ast.extra[expr + 1],
            .type = ast.signatures.items(.type)[signature],
            .topLevel = true,
        });

        const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
            catch return Error.AllocatorFailure;

        if (isPresent.found_existing) {
            self.report("Given definition '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});

            const found = self.decls.get(isPresent.value_ptr.*);
            if (found.kind != .Builtin) {
                self.lastToken = found.token;
                self.report("Found here.", .{});
            }

            return Error.DuplicateSymbol;
        }

        isPresent.value_ptr.* = decl;
    }
}

fn handleScopeDefs(self: *Resolver, declarations: defines.Range) Error!void {
    const ast = self.context.getAST(self.dataIndex());

    try self.prepassScope(declarations);

    for (declarations.start..declarations.end) |declPtrPtr| {
        const def = ast.statements.items(.value)[ast.extra[declPtrPtr]];

        const signature = ast.extra[def]; 
        const initializer = ast.extra[def + 1];

        const field = ast.signatures.get(signature);
        self.lastToken = field.name;

        if (field.type != 0) {
            try self.resolveExpression(field.type);
        }

        const decl = try self.look(field.name);
        self.decls.set(decl, .{
            .kind = .Variable,
            .scope = self.currentScope,
            .public = field.public,
            .token = field.name,
            .node = initializer,
            .type = field.type,
            .topLevel = true,
        });
        

        try self.resolveExpression(initializer);
    }
}

fn lookNameAt(self: *Resolver, name: []const u8, scope: defines.ScopePtr) Error!defines.DeclPtr {
    const currentModule = self.modules.modules.items(.name)[self.scopes.items(.module)[scope]];

    var current: ?defines.ScopePtr = scope;
    while (current) |s| {
        if (self.lookup.get(.{ .scope = s, .name = name })) |declPtr| {
            const module = self.scopes.items(.module)[self.decls.items(.scope)[declPtr]];
            const public = self.decls.items(.public)[declPtr];

            if (public or module == self.scopes.items(.module)[self.currentScope]) {
                return declPtr;
            }

            const modulename = self.modules.modules.items(.name)[module];
            self.report("'{s}::{s}' is inaccessible due to its visibility level.", .{modulename, name});
            return Error.AccessSpecifierMismatch;
        }
        current = self.scopes.items(.parent)[s];
    }

    self.report("Couldn't resolve given identifier '{s}' in the given scope ({s}).", .{
        name,
        currentModule,
    });
    return Error.InvalidIdentifier;
}

fn lookAt(self: *Resolver, namePtr: defines.TokenPtr, scope: defines.ScopePtr) Error!defines.DeclPtr {
    self.lastToken = namePtr;
    const name = self.context
        .getTokens(self.dataIndex())
        .get(namePtr)
        .lexeme(self.context, self.dataIndex());
    return self.lookNameAt(name, scope);
}

fn tryLookNameAt(self: *Resolver, name: []const u8, scope: defines.ScopePtr) Error!?defines.DeclPtr {
    var current: ?defines.ScopePtr = scope;
    while (current) |s| {
        if (self.lookup.get(.{ .scope = s, .name = name })) |declPtr| {
            const module = self.scopes.items(.module)[self.decls.items(.scope)[declPtr]];
            const public = self.decls.items(.public)[declPtr];

            if (public or module == self.scopes.items(.module)[self.currentScope]) {
                return declPtr;
            }

            const modulename = self.modules.modules.items(.name)[module];
            self.report("'{s}::{s}' is inaccessible due to its visibility level.", .{modulename, name});
            return Error.AccessSpecifierMismatch;
        }
        current = self.scopes.items(.parent)[s];
    }

    return null;
}

fn tryLookName(self: *Resolver, name: []const u8) Error!?defines.DeclPtr {
    return self.tryLookNameAt(name, self.currentScope);
}

fn lookName(self: *Resolver, name: []const u8) Error!defines.DeclPtr {
    return self.lookNameAt(name, self.currentScope);
}

fn look(self: *Resolver, namePtr: defines.TokenPtr) Error!defines.DeclPtr {
    self.lastToken = namePtr;
    return self.lookAt(namePtr, self.currentScope);
}

fn report(self: *Resolver, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = self.context.getTokens(self.dataIndex()).get(self.lastToken);
    const position = token.position(self.context, self.dataIndex());
    common.log.err(("." ** 4) ++ " In {s} {d}:{d}", .{ self.context.getFileName(self.dataIndex()), position.line, position.column});
    token.printLocation(self.arena.allocator(), self.context, self.dataIndex(), position, true);
}

fn dataIndex(self: *const Resolver) u32 {
    return self.modules.modules.items(.dataIndex)[self.scopes.items(.module)[self.currentScope]];
}

fn getModuleName(self: *Resolver, module: defines.ExpressionPtr) []const u8 {
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(self.dataIndex());

    if (ast.expressions.items(.type)[module] == .Identifier) {
        self.lastToken = ast.expressions.items(.value)[module];
        return tokens.get(self.lastToken).lexeme(self.context, self.dataIndex());
    }

    if (ast.expressions.items(.type)[module] != .Scoping) {
        return "/Couldn't Do it/";
    }

    const exprPtr = ast.expressions.items(.value)[module];
    var expr = ast.extra[exprPtr];

    while (ast.expressions.items(.type)[expr] != .Identifier) {
        if (ast.expressions.items(.type)[expr] != .Scoping) {
            return "/Couldn't Do it/";
        }
        expr = ast.extra[ast.expressions.items(.value)[expr]];
    }

    self.lastToken = ast.expressions.items(.value)[expr];
    const member = ast.extra[exprPtr + 1];
    const end = tokens.items(.end)[member];
    const start = tokens.items(.start)[self.lastToken];

    return self.context.getFile(self.dataIndex())[start..end];
}

pub const builtins = [_][]const u8 {
    "u32", "i32", "u8", "i8", "bool",
    "float", "void", "comptime_int", "comptime_float",
    "type", "noreturn", "enum_literal", "any",

    "undefined", "typeInfo", "hasField", "compileError",
    "bitSizeOf", "unreachable", "enumStr", "typeOf",
    "field", "fieldIndex", "hasDef", "definitionIndex",
    "this", "sizeOf", "bitSet", "cast",
    "as", "compileLog",
};

pub fn BuiltinIndex(comptime builtin: []const u8) u32 {
    var index: u32 = 0;
    inline for (builtins) |b| {
        defer index += 1;
        if (std.mem.eql(u8, b, builtin)) {
            return index;
        }
    }

    unreachable;
}
