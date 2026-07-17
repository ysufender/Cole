const std = @import("std");
const common = @import("core/common.zig");
const perfAllc = @import("util/allocator.zig");
const collections = @import("util/collections.zig");
const defines = @import("core/defines.zig");
const debug = @import("debug/debug.zig");
const platform = @import("core/platform.zig");

const Error = common.CompilerError;
const Lexer = @import("lexer/lexer.zig");
const Parser = @import("parser/parser.zig");
const Prepass = @import("parser/prepass.zig");
const Resolver = @import("typechecker/resolver.zig");
const Typechecker = @import("typechecker/typechecker.zig");

pub fn main(init: std.process.Init) void {
    MainProcInit = init;

    innerMain(
        if (common.debug.isDebug) init.arena.allocator()
        else if (platform.isPosix) blk: {
            var hugepage = perfAllc.HugePageAllocator.init(init.gpa);
            common.log.debug("Using huge pages.", .{});
            break :blk hugepage.allocator();
        } else init.gpa,
        init
    ) catch |err| blk: {
        switch (err) {
            Error.ShouldBeImpossible => common.log.err(
                "This is a compiler bug, a part of impossible branch has been reached."
                ++ " Please inform the authors about it.", .{ }
            ),
            Error.NotImplemented => common.log.err(
                "The compiler has hit an unfinished part of the codebase, stay tuned.", .{ }
            ),
            Error.Terminate => break :blk,
            else => { }, 
        }

        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(@ptrCast(trace));
        }

        return common.log.err(
            "Compiler exited with code {d} <{s}>", .{
            @intFromError(err),
            @errorName(err)
        });
    };

    common.log.info("Compiler exited successfully.", .{});
}

fn innerMain(allocator: std.mem.Allocator, init: std.process.Init) common.CompilerError!void {
    // Init Context
    var context = try common.CompilerContext.init(allocator, init);
    errdefer context.deinit();

    var lexer = try Lexer.init(
        allocator,
        &context,
        context.settings.inputFile,
    );
    const tokens = try lexer.lex();

    var parser = try Parser.init(
        allocator,
        &context,
        tokens,
    );
    const ast = try parser.parse();

    if (common.debug.isDebug and context.settings.hasFlag("--print-ast")) {
        debug.ASTPrinter.printAST(ast, &context);
    }

    if (context.settings.hasFlag("--parse-only")) {
        return;
    }

    var prepass = try Prepass.init(&context, ast, allocator);
    const modules = try prepass.prepass(allocator);

    if (common.debug.isDebug and context.settings.hasFlag("--print-ast-full")) {
        debug.ASTPrinter.printASTs(&context, &modules);
    }

    var resolver = try Resolver.init(allocator, &context, &modules);
    var resolved = try resolver.resolve(allocator);

    defer if (common.debug.isDebug and context.settings.hasFlag("--dump-stats")) {
        context.stats();

        var miterator = modules.modules.iterator();
        _ = miterator.next();
        while (miterator.next()) |mod| {
            mod.print(&context);
        }

        common.log.info("", .{});
        common.log.info("Resolution Map:", .{});
        var iterator = resolved.declarations.iterator();
        while (iterator.next()) |decl| {
            const dataIndex = modules.modules.items(.dataIndex)[resolved.scopes.items(.module)[decl.scope]];
            const module = modules.modules.items(.name)[resolved.scopes.items(.module)[decl.scope]];
            common.log.info("\tFrom {s} decl {s}{s} = {d}:", .{
                module,
                if (decl.public) "pub " else "",
                context.getTokens(dataIndex)
                    .get(decl.token)
                    .lexeme(&context, dataIndex),
                decl.node,
            });
        }
    };

    if (context.settings.hasFlag("--resolve-only")) {
        return;
    }

    var typechecker = try Typechecker.init(allocator, &context, &modules, &resolved);
    var loweredIR = try typechecker.typecheck(allocator);

    if (context.settings.hasFlag("--dump-jir")) {
        loweredIR.dump();
    }

    if (context.settings.hasFlag("--typecheck-only")) {
        return;
    }

    // @Note codegen shouldn't depend on anything but the typechecker
    // output from now on. Also it shouldn't error too. Validation
    // has ended.
    _ = context.arena.reset(.retain_capacity);

    try loweredIR.codegen(&context);
}

var MainProcInit: std.process.Init = undefined;
fn panicHandler(msg: []const u8, stack: ?usize) noreturn {
    const _stderr = std.Io.File.stderr().writer(MainProcInit.io, &common.log.wbuf);
    var stderr = _stderr.interface;

    stderr.writeAll("\nRuntime invoked panic:\nInfo: ") catch {};
    stderr.writeAll(msg) catch {};
    common.debug.stackTrace(stack, &stderr);
    std.process.exit(1);
}
