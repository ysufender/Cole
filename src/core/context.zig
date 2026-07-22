const std = @import("std");
const defines = @import("defines.zig");
const collections = @import("../util/collections.zig");
const cli = @import("cli.zig");
const Log = @import("log.zig");

const Error = @import("common.zig").CompilerError;
const Lexer = @import("../lexer/lexer.zig");
const CompilerSettings = @import("settings.zig");
const Parser = @import("../parser/parser.zig");
const Prepass = @import("../parser/prepass.zig");

const assert = std.debug.assert;

/// Central database of compilation
/// - Assumes there is a single AST and
/// a single token list per file.
/// - Hence file indices are also token
/// and ast indices.
const Context = @This();

const FileNameMap = std.ArrayList([]const u8);
const ModuleNameMap = std.ArrayList([]const u8);
const FileMap = std.ArrayList([]const u8);
const TokenMap = std.ArrayList(Lexer.TokenList.Slice);
const ASTMap = std.ArrayList(Parser.AST);
const ResolveMap = std.StringHashMapUnmanaged(defines.FilePtr);

pub const Counts = struct {
    topLevels: u32 = 0,
    modules: u32 = 0,
    tokens: u32 = 0,
    expressions: u32 = 0,
    statements: u32 = 0,
    extras: u32 = 0,

    functions: u32 = 0,

    integer: u32 = 0,
    float: u32 = 0,
    string: u32 = 0,
    bool: u32 = 0,
    types: u32 = 0,

    meta: u32 = 0,

    pub fn sum(self: @This()) u32 {
        var total: u32 = 0;
        for (@typeInfo(@This()).@"struct".fields) |field| {
            total += @field(self, field.name);
        }
        return total;
    }
};

// Source Files
filenameMap: FileNameMap,
fileMap: FileMap,
resolved: ResolveMap,
moduleNameMap: ModuleNameMap,

// Tokens
tokenMap: TokenMap,

// ASTs
astMap: ASTMap,

arena: std.heap.ArenaAllocator,
io: std.Io,

counts: Counts,

settings: CompilerSettings,
log: Log = undefined,

pub fn init(baseAllocator: std.mem.Allocator, mainInit: std.process.Init) Error!Context {
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();

    const settings = cli.parseCLI(allocator, mainInit.minimal.args, mainInit.io) catch |err| {
        if (err != error.Terminate) {
            Log.err("Couldn't parse CLI input.", .{});
        }
        return err;
    };
    settings.print(allocator);

    var resolved = ResolveMap.empty;
    resolved.ensureTotalCapacity(allocator, 512) catch return error.AllocatorFailure;

    return .{
        .filenameMap = FileNameMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .moduleNameMap = ModuleNameMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .fileMap = FileMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .tokenMap = TokenMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .astMap = ASTMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .arena = arena,
        .io = mainInit.io,
        .resolved = resolved,
        .settings = settings,
        .counts = .{},
    };
}

pub fn initForTest(baseAllocator: std.mem.Allocator, io: std.Io, inputFile: []const u8) Error!Context {
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();

    var resolved = ResolveMap.empty;
    resolved.ensureTotalCapacity(allocator, 512) catch return error.AllocatorFailure;

    const settings = CompilerSettings{
        .inputFile = inputFile,
        .outputFile = null,
        .workingDir = ".",
        .includeDirs = &.{},
        .maxErr = 5,
        .backend = .C,
        .backendFlags = "",
        .flags = blk: {
            var f = CompilerSettings.FlagSet.empty;
            f.ensureTotalCapacity(allocator, 32) catch return error.AllocatorFailure;
            break :blk f;
        },
    };

    return .{
        .filenameMap = FileNameMap.initCapacity(allocator, 32) catch return error.AllocatorFailure,
        .moduleNameMap = ModuleNameMap.initCapacity(allocator, 32) catch return error.AllocatorFailure,
        .fileMap = FileMap.initCapacity(allocator, 32) catch return error.AllocatorFailure,
        .tokenMap = TokenMap.initCapacity(allocator, 32) catch return error.AllocatorFailure,
        .astMap = ASTMap.initCapacity(allocator, 32) catch return error.AllocatorFailure,
        .arena = arena,
        .io = io,
        .resolved = resolved,
        .settings = settings,
        .counts = .{},
    };
}

pub fn deinit(self: *Context) void {
    self.arena.deinit();
}

pub fn openRead(self: *Context, file: []const u8) Error!defines.FilePtr {
    const path = try self.realpath(file);

    if (self.resolved.get(path)) |id| {
        return id;
    }

    self.filenameMap.append(self.arena.allocator(), path) catch return error.AllocatorFailure;

    var sourceFile = std.Io.Dir.openFileAbsolute(self.io, path, .{ }) catch {
        Log.err("Couldn't open source file '{s}'.", .{file});
        return error.IOError;
    };
    defer sourceFile.close(self.io);

    var fileReader = sourceFile.reader(self.io, &.{});
    const sourceSize = fileReader.getSize() catch {
        Log.err("Couldn't get the size of file {s}", .{path});
        return error.IOError;
    };

    self.fileMap.append(
        self.arena.allocator(),
        fileReader.interface.readAlloc(self.arena.allocator(), sourceSize) catch |err| {
            Log.err("Couldn't read file {s}\n\tInfo: {s}", .{path, @errorName(err)});
            return error.IOError;
        }
    ) catch return error.AllocatorFailure;

    self.resolved.putNoClobber(
        self.arena.allocator(),
        path,
        @intCast(self.fileMap.items.len - 1)
    ) catch return error.AllocatorFailure;

    return @intCast(self.fileMap.items.len - 1);
}

pub fn openWrite(self: *Context, file: []const u8) Error!std.fs.File {
    return std.Io.Dir.createFileAbsolute(self.io, file, .{ .truncate = true }) catch {
        Log.err("Couldn't open target file {s}", .{file});
        return error.IOError;
    };
}

pub fn getFile(self: *const Context, file: defines.FilePtr) []const u8 {
    assert(file < self.fileMap.items.len);
    return self.fileMap.items[file];
}

pub fn getFileName(self: *const Context, file: defines.FilePtr) []const u8 {
    assert(file < self.filenameMap.items.len);
    return self.filenameMap.items[file];
}

pub fn registerTokens(self: *Context, tokens: Lexer.TokenList.Slice) Error!defines.TokenPtr {
    self.counts.tokens += tokens.len;

    self.tokenMap.append(self.arena.allocator(), try collections.deepCopy(tokens, self.arena.allocator())) catch return error.AllocatorFailure;

    return @intCast(self.tokenMap.items.len - 1);
}

pub fn getTokens(self: *const Context, tokens: defines.TokenListPtr) *const Lexer.TokenList.Slice {
    assert(tokens < self.tokenMap.items.len);
    return &self.tokenMap.items[tokens];
}

pub fn registerAST(self: *Context, ast: Parser.AST) Error!defines.ASTPtr {
    const ptr: defines.ASTPtr = @intCast(self.astMap.items.len);
    _ = self.astMap.addOne(self.arena.allocator()) catch return error.AllocatorFailure;

    self.counts.modules += 1;
    self.counts.expressions += ast.expressions.len;
    self.counts.statements += ast.statements.len;
    self.counts.extras += @intCast(ast.extra.len);

    self.counts.integer += ast.stats.integer;
    self.counts.float += ast.stats.float;
    self.counts.string += ast.stats.string;
    self.counts.bool += ast.stats.bool;
    self.counts.types += ast.stats.types;

    self.counts.functions += ast.stats.functions;

    self.counts.meta += ast.stats.meta;

    self.astMap.items[ptr] = try collections.deepCopy(ast, self.arena.allocator());

    return ptr;
}

pub fn getAST(self: *const Context, ast: defines.ASTPtr) *const Parser.AST {
    assert(ast < self.astMap.items.len);
    return &self.astMap.items[ast];
}

pub fn registerModule(self: *Context, module: *const Prepass.Module) Error!void {
    self.moduleNameMap.ensureTotalCapacity(self.arena.allocator(), module.dataIndex + 1)
        catch return Error.AllocatorFailure;
    self.moduleNameMap.expandToCapacity();
    self.moduleNameMap.items[module.dataIndex] = module.name;
    self.counts.topLevels += module.symbols.len;
}

pub fn isProcessed(self: *Context, file: []const u8) bool {
    return self.resolved.contains(file);
}

var pathBuf: [std.fs.max_path_bytes]u8 = undefined;
pub fn realpath(self: *Context, file: []const u8) Error![]const u8 {
    var allocator = std.heap.FixedBufferAllocator.init(&pathBuf);

    var path: []const u8 = undefined;

    path = std.Io.Dir.cwd().realPathFileAlloc(self.io, file, allocator.allocator()) catch |err| pblk: {
        if (err == error.OutOfMemory) {
            return error.AllocatorFailure;
        }

        loop: for (self.settings.includeDirs) |dir| {
            path = std.fs.path.join(allocator.allocator(), &.{dir, file}) catch return error.AllocatorFailure;
            defer allocator.allocator().free(path);

            break :pblk
                std.Io.Dir.cwd().realPathFileAlloc(self.io, path, allocator.allocator())
                    catch continue :loop;
        }

        return error.FileNotFound;
    };

    return self.arena.allocator().dupe(u8, path) catch error.AllocatorFailure;
}

pub fn getFileId(self: *Context, file: []const u8) defines.FilePtr {
    assert(self.resolved.contains(file));
    return
        if (self.resolved.get(file)) |f| f
        else unreachable;
}

pub fn stats(self: *Context) void {
    Log.info("Stats:", .{});
    Log.info("\tTotal Module Count:              {d}", .{self.counts.modules});
    Log.info("\tTotal Top-Level Signature Count: {d}", .{self.counts.topLevels});
    Log.info("\tTotal Tokens:                    {d}", .{self.counts.tokens});
    Log.info("\tTotal Expressions:               {d}", .{self.counts.expressions});
    Log.info("\tTotal Extras:                    {d}", .{self.counts.extras});
    Log.info("", .{});

    Log.info("\tProcessed Files:", .{});
    for (self.filenameMap.items) |file| {
        Log.info("\t\t{s}", .{file});
    }
    Log.info("", .{});
}
