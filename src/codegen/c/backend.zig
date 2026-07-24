const std = @import("std");
const common = @import("../../core/common.zig");
const platform = @import("../../core/platform.zig");

pub const JIR = @import("jir.zig");

const Error = @import("../../core/common.zig").CompilerError;
const Dir = std.Io.Dir;

const tcc = @cImport({
    @cInclude("libtcc.h");
    @cInclude("libtcc.h");
});

const files = [_]struct{ []const u8, []const u8 }{
    .{ "stdnoreturn.h", @import("vendor").stdnoreturn },
    .{ "stdalign.h", @import("vendor").stdalign },
    .{ "stdarg.h", @import("vendor").stdarg },
    .{ "stdatomic.h", @import("vendor").stdatomic },
    .{ "stdbool.h", @import("vendor").stdbool },
    .{ "stddef.h", @import("vendor").stddef },
    .{ "libtcc1.a", @import("vendor").libtcc1 },
};

pub fn compile(outDir: Dir, allocator: std.mem.Allocator, context: *common.CompilerContext) Error!void {
    try createStdIncludes(outDir, context.io);

    // Create TCC
    const state = tcc.tcc_new();
    defer tcc.tcc_delete(state);

    // Set TCC lib path
    var cpath = std.mem.zeroes([std.Io.Dir.max_path_bytes]u8);
    const size = outDir.realPath(context.io, &cpath)
        catch return Error.IOError;
    tcc.tcc_set_lib_path(state, cpath[0..size].ptr);

    // Set error callback
    tcc.tcc_set_error_func(state, null, tccErrCallback);

    // Set output type
    if (tcc.tcc_set_output_type(state, tcc.TCC_OUTPUT_EXE) == -1) {
        report("Failed to set output type.");
        return Error.BackendError;
    }

    // Set system includes
    if (!platform.isWindows) {
        if (tcc.tcc_add_include_path(state, "/usr/include") == -1) {
            report("Failed to include libc path.");
            return Error.BackendError;
        }

        if (tcc.tcc_add_include_path(state, "/usr/local/include") == -1) {
            report("Failed to include libc path.");
            return Error.BackendError;
        }

        if (tcc.tcc_add_library_path(state, "/usr/local/lib") == -1) {
            report("Failed to include libc path.");
            return Error.BackendError;
        }
    }

    // Add TCC library includes
    if (tcc.tcc_add_include_path(state, cpath[0..size].ptr) == -1) {
        report("Failed to include TCC libraries.");
        return Error.BackendError;
    }

    // Add custom library dirs
    for (context.settings.linkDirs) |dir| {
        if (tcc.tcc_add_library_path(state, dir.ptr) == -1) {
            report("Failed to add lib path.");
            return Error.BackendError;
        }
    }

    // Add source file
    const input = outDir.realPathFileAlloc(context.io, "source.c", allocator)
        catch return Error.AllocatorFailure;
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
            report("Failed to link library.");
            return Error.BackendError;
        }
    }

    // Finalize
    const outFile = outDir.createFile(context.io, context.settings.outputFile orelse "out", .{})
        catch return Error.IOError;
    outFile.close(context.io);
    const output = outDir.realPathFileAlloc(context.io, context.settings.outputFile orelse "out", allocator)
        catch return Error.AllocatorFailure;
    if (tcc.tcc_output_file(state, output) == -1) {
        report("Failed to link sources.");
        return Error.BackendError;
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

fn report(comptime msg: []const u8) void {
    common.log.err("BACKEND: {s}\n", .{msg});
}

fn tccErrCallback(_: ?*anyopaque, msg: [*c]const u8) callconv(.c) void {
    const len = std.mem.len(msg);
    if (std.mem.find(u8, msg[0..len], "warning")) |_| {
        std.log.warn("{s}", .{msg});
    }
    else {
        common.log.err("{s}", .{msg});
    }
}
