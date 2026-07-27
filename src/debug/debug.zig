const std = @import("std");

const common = @import("../core/common.zig");
pub const ASTPrinter = @import("ast_printer.zig");

const Error = common.CompilerError;

pub const isDebug = @import("config").isDebug;

pub fn NotImplemented(log: common.log, comptime src: std.builtin.SourceLocation) Error {
    log.warn("Not implemented in " ++ locationString(src) , .{});
    return Error.NotImplemented;
}

pub fn ShouldBeImpossible(_: common.log, comptime src: std.builtin.SourceLocation) Error {
    std.log.err("Reached impossible branch in " ++ locationString(src) , .{});
    return Error.ShouldBeImpossible;
}

pub fn hello(num: usize) void {
    common.log.debug("Hello {d}", .{num});
}

pub fn locationString(comptime location: std.builtin.SourceLocation) []const u8 {
    return std.fmt.comptimePrint("{s} at {d}:{d}", .{
        location.file,
        location.line,
        location.column,
    });
}

pub fn stackTrace(stack: ?usize, stderr: *std.Io.Writer) void {
    defer stderr.flush() catch {};
    if (std.debug.sys_can_stack_trace) {
        stderr.writeAll("\n") catch {};
        if (stack) |addr| {
            var addrBuf: [512]usize = undefined;
            const trace = std.debug.captureCurrentStackTrace(.{
                    .first_address = addr,
                },
                &addrBuf,
            );
            std.debug.dumpStackTrace(&trace);
        }
        else {
            std.debug.dumpCurrentStackTrace(.{});
        }
        stderr.writeAll("\n") catch {};
    }
    else {
        _ = stderr.write("Stack trace is not available.");
    }
}
