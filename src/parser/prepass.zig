const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("parser.zig");
const Resolver = @import("../typechecker/resolver.zig");

const Context = common.CompilerContext;
const Error = common.CompilerError;

/// Contains both public and private top level
/// symbols.
pub const Module = struct {
    pub const Symbol = struct {
        name: defines.TokenPtr,
        value: defines.StatementPtr,
        type: defines.ExpressionPtr,
        public: bool,
    };

    /// namespace of the module
    name: []const u8,

    /// Also file and token list index
    dataIndex: defines.Offset,

    symbolPtrs: SymbolMap,
    symbols: SymbolList,
    dependencies: DependencyList,

    pub fn print(self: *const Module, context: *Context) void {
        const ast = context.getAST(self.dataIndex);
        std.debug.print("\nModule {s}:\n", .{self.name});
        std.debug.print("\tFile: {s}\n", .{context.getFileName(self.dataIndex)});
        std.debug.print("\tData Index: {d}\n", .{self.dataIndex});
        std.debug.print("\tAST:\n", .{});
        ast.print(context);
        std.debug.print("\tDependencies:\n", .{});
        for (self.dependencies.items[0..@min(16, self.dependencies.items.len)]) |dependency| {
            std.debug.print("\t\t{s}\n", .{dependency});
        }
        std.debug.print("\tSymbols:\n", .{});
        for (self.symbols.items(.name), 0..) |symbol, i| {
            std.debug.print("\t\t{s}{s}\n", .{
                if (self.symbols.items(.public)[i]) "pub " else "",
                context.getTokens(ast.tokens).get(symbol).lexeme(context, self.dataIndex)
            });
        }
    }
};

pub const ModuleList = struct {
    pub const List = collections.MultiArrayList(Module);
    pub const Map = std.StringHashMapUnmanaged(u32);

    modules: List,
    ids: Map,

    pub fn init(allocator: std.mem.Allocator, cap: u32) Error!ModuleList {
        var ids = Map.empty;

        ids.ensureTotalCapacity(allocator, cap) catch return Error.AllocatorFailure;

        return .{
            .modules = try List.init(allocator, cap),
            .ids = ids,
        };
    }

    pub fn get(self: *const ModuleList, name: []const u8) defines.ModulePtr {
        return self.ids.get(name).?;
    }

    pub fn getItem(self: *const ModuleList, name: []const u8, comptime field: std.meta.FieldEnum(Module)) @FieldType(Module, @tagName(field)) {
        return self.modules.items(field)[self.ids.get(name).?];
    }

    pub fn dupe(self: *const ModuleList, allocator: std.mem.Allocator) Error!ModuleList {
        return .{
            .modules = try collections.deepCopy(self.modules.mutableSlice(), allocator),
            .ids= try collections.deepCopy(self.ids, allocator),
        };
    }
};

pub const SymbolList = collections.MultiArrayList(Module.Symbol);
pub const SymbolMap = std.StringHashMapUnmanaged(defines.SymbolPtr);
pub const ModuleMap = std.StringHashMapUnmanaged(defines.ModulePtr);
pub const DependencyList = std.ArrayList([]const u8);

const Prepass = @This();

initial: *const Parser.AST,
arena: std.heap.ArenaAllocator,

/// Maps the module names (scoping::expressions::mhm) to ModulePtr's
modules: ModuleList,
context: *Context,

/// Uses multithreaded allocator under the hood
pub fn init(context: *Context, initial: defines.ASTPtr, allocator: std.mem.Allocator) Error!Prepass {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    return .{
        .initial = context.getAST(initial),
        .context = context,
        .modules = try ModuleList.init(arena.allocator(), 128),
        .arena = arena,
    };
}

/// Returns a module list slice containing all modules. Releases the ownership.
pub fn prepass(self: *Prepass, allocator: std.mem.Allocator) Error!ModuleList {
    defer self.arena.deinit();

    const bname: []const u8 = "builtin";
    const builtin = try self.modules.modules.addOne(allocator);
    self.modules.modules.set(builtin, .{
        .name = try collections.deepCopy(bname, allocator), 
        .dataIndex = 0,
        .dependencies = .empty,
        .symbolPtrs = .empty,
        .symbols = try .init(allocator, 0),
    });
    self.modules.ids.putAssumeCapacityNoClobber(bname, builtin);

    try self.prepassImpl(self.initial, "root");

    for (1..self.modules.modules.len) |i| {
        self.modules.modules.items(.dependencies)[i].shrinkAndFree(
            self.arena.allocator(),
            self.modules.modules.items(.dependencies)[i].items.len
        );
    }

    return collections.deepCopy(self.modules, allocator);
}

/// Threaded recursive prepassing. Uses mutexes.
fn prepassImpl(self: *Prepass, ast: *const Parser.AST, name: []const u8) Error!void {
    const tokens = self.context.getTokens(ast.tokens);
    const allocator = self.arena.allocator();

    var file = Module{
        .dataIndex = tokens.items(.start)[0],
        .name = name,
        .dependencies = DependencyList.initCapacity(allocator, @max(tokens.len / 32, 16)) catch |e| return e,
        .symbolPtrs = .empty,
        .symbols = SymbolList.init(allocator, @max(tokens.len / 16, 16)) catch |e| return e,
    };

    file.symbolPtrs.ensureTotalCapacity(allocator, @max(tokens.len / 16, 16)) catch |e| return e;

    var lastErr: ?Error = null;
    var errc: u32 = 0;

    var statement: Parser.Statement = undefined;
    var first = true;
    var stmt: u32 = 0;
    statementLoop: while (stmt < ast.statementMask.len) {
        if (errc == self.context.settings.maxErr) {
            self.report("Too many errors, aborting the prepass of module '{s}'\n", .{
                name
            }, file.dataIndex, null);

            break :statementLoop;
        }

        if (first) {
            first = false;
            statement = ast.statements.get(ast.statementMask[stmt]);
        }

        case: switch (statement.type) {
            .Import => self.prepassImport(ast, statement.value, &file) catch |err| {
                lastErr = err;
                errc += 1;
                break :case;
            },
            .InlineC => { },
            .VariableDefinition => self.prepassVariableDef(ast, tokens, &file, statement.value) catch |err| {
                lastErr = err;
                errc += 1;
                break :case;
            },
            else => {
                self.report(
                    "Only definitions are allowed at top-level. Received: {s}",
                    .{@tagName(statement.type)},
                    file.dataIndex,
                    null
                );

                lastErr = Error.MissingStatement;
                errc += 1;
                break :case;
            },
        }

        stmt += 1;
        statement = if (stmt >= ast.statementMask.len) statement else ast.statements.get(ast.statementMask[stmt]);
    }

    if (errc > 1) {
        return Error.MultipleErrors;
    }
    else if (errc == 1) {
        return lastErr.?;
    }

    const index = self.modules.modules.addOne(allocator) catch |e| return e;

    self.modules.ids.put(allocator, file.name, index) catch |e| return e;
    self.modules.modules.set(index, file);

    if (self.modules.ids.count() > defines.rehashLimit) {
        self.modules.ids.rehash(std.hash_map.StringContext{});
    }

    return self.context.registerModule(&file, index);
}

fn prepassImport(
    self: *Prepass,
    ast: *const Parser.AST,
    stmt: defines.OpaquePtr,
    file: *Module,
) Error!void {
    const module = getModuleName(stmt, ast, self.context);
    file.dependencies.append(self.arena.allocator(), module)
        catch return Error.AllocatorFailure;

    const path = getModulePathWithExtension(self.arena.allocator(), stmt, ast, self.context) catch |err| {
        self.report("Couldn't get module path for {s}: {s}.",
            .{module, @errorName(err)},
            file.dataIndex,
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1],
        );

        return err;
    };

    if (self.context.isProcessed(path)) {
        return;
    }

    var lexer = Lexer.init(self.arena.allocator(), self.context, path) catch |err| {
        self.report("Couldn't scan module at path {s}.", .{path}, self.context.getFileId(path),
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1]
        );

        return err;
    };

    const moduleTokens = lexer.lex() catch |err| {
        self.report("Couldn't scan module at path {s}.", .{path}, file.dataIndex,
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1]
        );

        return err;
    };

    var prs = Parser.init(self.arena.allocator(), self.context, moduleTokens) catch |err| {
        self.report("Couldn't parse module at path {s}.", .{path}, file.dataIndex,
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1]
        );

        return err;
    };

    const imported = prs.parse() catch |err| {
        self.report("Couldn't parse module at path {s}.", .{path}, file.dataIndex,
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1]
        );

        return err;
    };

    return self.prepassImpl(self.context.getAST(imported), module);
}

fn prepassVariableDef(
    self: *Prepass,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    file: *Module,
    stmt: defines.OpaquePtr,
) Error!void {
    const signature = ast.extra[stmt];

    const sig = ast.signatures.get(signature);
    const sigName = tokens.get(sig.name).lexeme(self.context, file.dataIndex);

    for (Resolver.builtins) |builtin| {
        if (std.mem.eql(u8, builtin, sigName)) {
            self.report("Given symbol '{s}' collides with the builtin '{s}'.", .{
                sigName, sigName,
            }, file.dataIndex, sig.name);
            return Error.DuplicateSymbol;
        }
    }

    const idx = file.symbols.addOne(self.arena.allocator()) catch
        return Error.AllocatorFailure;

    const res = file.symbolPtrs.getOrPut(self.arena.allocator(), sigName) catch
        return Error.AllocatorFailure;

    if (res.found_existing) {
        self.report("Given symbol '{s}' collides with the previous definition of '{s}'.",
            .{sigName, sigName},
            file.dataIndex,
            sig.name,
        );

        return Error.DuplicateSymbol;
    }

    res.value_ptr.* = idx;

    file.symbols.set(idx, .{
        .public = sig.public,
        .name = sig.name,
        .value = stmt,
        .type = sig.type,
    });
}

fn getModulePathWithExtension(allocator: std.mem.Allocator, id: u32, ast: *const Parser.AST, context: *Context) Error![]const u8 {
    return context.realpath(
        std.fmt.allocPrint(allocator, "{s}.jasl", .{
            try getModulePath(allocator, id, ast, context)
        }) catch return Error.AllocatorFailure
    );
}

/// Returned path is owned by the allocator.
fn getModulePath(allocator: std.mem.Allocator, id: defines.ExpressionPtr, ast: *const Parser.AST, context: *Context) Error![]const u8 {
    const file = context.getTokens(ast.tokens).items(.start)[0];

    var parts = collections.ReverseStackArray([]const u8, std.fs.max_path_bytes).init();
    var current = ast.extra[id];

    while (true) {
        const expr = ast.expressions.get(current);
        switch (expr.type) {
            .Identifier => {
                const lexeme = context.getTokens(ast.tokens).get(expr.value).lexeme(context, file);
                parts.append(lexeme) catch return Error.PathNameTooLong;
                break;
            },
            .Scoping => {
                const lhsExpr = ast.extra[expr.value];
                const rhsExpr = ast.extra[expr.value + 1];

                const rhsStr = context.getTokens(ast.tokens).get(rhsExpr).lexeme(context, file);
                parts.append(rhsStr) catch return Error.PathNameTooLong;

                current = lhsExpr;
            },
            else => unreachable,
        }
    }

    return std.fs.path.join(allocator, parts.items) catch Error.AllocatorFailure;
}

fn getModuleName(id: defines.ExpressionPtr, ast: *const Parser.AST, context: *Context) []const u8 {
    const file = context.getTokens(ast.tokens).items(.start)[0];
    const expr = ast.expressions.get(ast.extra[id]);

    const end = switch (expr.type) {
        .Identifier => context.getTokens(ast.tokens).items(.end)[expr.value],
        .Scoping => context.getTokens(ast.tokens).items(.end)[ast.extra[expr.value + 1]],
        else => unreachable,
    };
    const start = getModuleNameStartIndex(ast.extra[id], ast, context);

    return context.getFile(file)[start..end];
}

fn getModuleNameStartIndex(id: defines.ExpressionPtr, ast: *const Parser.AST, context: *Context) u32 {
    var current = id;
    var start = context.getTokens(ast.tokens).len;

    while (true) {
        const expr = ast.expressions.get(current);
        switch (expr.type) {
            .Identifier => {
                start = context.getTokens(ast.tokens).items(.start)[expr.value];
                break;
            },
            .Scoping => {
                current = ast.extra[expr.value];
            },
            else => unreachable,
        }
    }

    return start;
}

fn report(self: *Prepass, comptime fmt: []const u8, args: anytype, file: u32, token: ?u32) void {
    common.log.err(fmt, args);
    if (
        self.context.astMap.items.len > file
        and self.context.getTokens(self.context.getAST(file).tokens).len > 0
    ) {
        const t_idx = token orelse 0;
        if (t_idx < self.context.getTokens(self.context.getAST(file).tokens).len) {
            const tt = self.context.getTokens(self.context.getAST(file).tokens).get(t_idx);
            const position = tt.position(self.context, file);
            common.log.err(("." ** 4) ++ " In {s} {d}:{d}", .{self.context.getFileName(file), position.line, position.column});
            tt.printLocation(self.arena.allocator(), self.context, file, position, true);
            return;
        }
    }
    
    common.log.err(("." ** 4) ++ " In {s} (no location available)\n", .{self.context.getFileName(file)});
}
