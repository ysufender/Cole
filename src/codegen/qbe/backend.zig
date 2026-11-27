const std = @import("std");
const common = @import("../../core/common.zig");
const platform = @import("../../core/platform.zig");

const Error = @import("../../core/common.zig").CompilerError;
const Dir = std.Io.Dir;

pub const JAIR = @import("jair.zig");

const qbe = @import("qbe");
const tcc = @import("tcc");
const minias = @import("minias");

const QBE = @This();

const files = [_]struct{ []const u8, []const u8 }{
    .{ "libtcc1.a",  @embedFile("../../res/vendor/tcc/libtcc1.a") },
};

var ctx: *common.CompilerContext = undefined;

pub fn compile(outDir: Dir, allocator: std.mem.Allocator, context: *common.CompilerContext) Error!void {
    ctx = context;
    try createStdIncludes(outDir, context.io);

    const target: c_int = if (context.settings.buildInfo.platform == .Windows) 0 else 1;
    const ssaPath = outDir.realPathFileAlloc(context.io, "source.ssa", allocator) catch return Error.AllocatorFailure;
    const _asmPath = std.fmt.allocPrint(allocator, "{s}.s", .{context.settings.outputFile}) catch return Error.AllocatorFailure;
    {
        const file = outDir.createFile(context.io, _asmPath, .{ }) catch return Error.IOError;
        file.close(context.io);
    }
    const asmPath = outDir.realPathFileAlloc(context.io, _asmPath, allocator) catch return Error.AllocatorFailure;

    if (qbe.qbe_compile(target, ssaPath.ptr, asmPath.ptr) == 1) {
        report("Failed to generate assembly output.");
        return Error.BackendError;
    }

    const _objPath = std.fmt.allocPrint(allocator, "{s}.o", .{context.settings.outputFile}) catch return Error.AllocatorFailure;
    {
        const file = outDir.createFile(context.io, _objPath, .{ }) catch return Error.IOError;
        file.close(context.io);
    }
    const objPath = outDir.realPathFileAlloc(context.io, _objPath, allocator) catch return Error.AllocatorFailure;

    if (minias.minias_assemble(asmPath.ptr, objPath.ptr) == 1) {
        report("Failed to assemble output.");
        return Error.BackendError;
    }

    const state = tcc.tcc_new();
    defer tcc.tcc_delete(state);

    // Set TCC lib path
    var cpath = std.mem.zeroes([std.Io.Dir.max_path_bytes]u8);
    const size = outDir.realPath(context.io, &cpath)
        catch return Error.IOError;
    tcc.tcc_set_lib_path(state, cpath[0..size].ptr);

    // Set debug
    if (context.settings.hasFlag("--debug")) {
        if (tcc.tcc_set_options(state, "-gdwarf -bt128 -rdynamic") == -1) {
            report("Failed to set backend settings.");
            return Error.BackendError;
        }
    }

    // Set error callback
    tcc.tcc_set_error_func(state, null, tccErrCallback);

    // Set output type
    if (tcc.tcc_set_output_type(state, tcc.TCC_OUTPUT_EXE) == -1) {
        report("Failed to set output type.");
        return Error.BackendError;
    }

    // Set system includes
    if (!platform.isWindows) {
        if (tcc.tcc_add_library_path(state, "/usr/local/lib") == -1) {
            report("Failed to include libc path.");
            return Error.BackendError;
        }
    }

    // Add custom library dirs
    for (context.settings.linkDirs) |dir| {
        if (tcc.tcc_add_library_path(state, dir.ptr) == -1) {
            report("Failed to add lib path.");
            return Error.BackendError;
        }
    }

    // Add source file
    const input = objPath;
    if (tcc.tcc_add_file(state, input) == -1) {
        report("Failed to compile source file.");
        return Error.BackendError;
    }

    // Add custom libraries
    for (context.settings.libraries) |lib| {
        const isPath = std.mem.indexOfScalar(u8, lib, '/') != null;
        const ok = if (isPath)
            tcc.tcc_add_file(state, lib.ptr) != -1
        else
            tcc.tcc_add_library(state, lib.ptr) != -1;

        if (!ok) {
            report("Failed to link libraies.");
            return Error.BackendError;
        }
    }

    // Finalize
    const outFile = outDir.createFile(context.io, context.settings.outputFile, .{})
        catch return Error.IOError;
    outFile.close(context.io);
    const output = outDir.realPathFileAlloc(context.io, context.settings.outputFile, allocator)
        catch return Error.AllocatorFailure;
    if (tcc.tcc_output_file(state, output) == -1) {
        report("Failed to link sources.");
        return Error.BackendError;
    }
}

fn report(comptime msg: []const u8) void {
    common.log.err("BACKEND: {s}\n", .{msg});
}

fn tccErrCallback(_: ?*anyopaque, msg: [*c]const u8) callconv(.c) void {
    const len = std.mem.len(msg);
    if (std.mem.find(u8, msg[0..len], "warning")) |_| {
        common.log.warn(ctx.log, "{s}", .{msg});
    }
    else {
        common.log.err("{s}", .{msg});
    }
}

fn createStdIncludes(dir: Dir, io: std.Io) Error!void {
    for (files) |stdh| {
        var file = dir.createFile(io, stdh.@"0", .{ })
            catch return Error.IOError;

        file.writePositionalAll(io, stdh.@"1", 0)
            catch return Error.IOError;
    }
}
