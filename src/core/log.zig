const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");

const Log = @This();

context: *const common.CompilerContext,

pub fn init(context: *const common.CompilerContext) Log {
    return .{ .context = context };
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        std.log.info(fmt, args);
    }
}

pub fn warn(self: Log, comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test and !self.context.settings.hasFlag("--supress-warnings")) {
        std.log.warn(fmt, args);
    }
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        std.log.err(fmt, args);
    }
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test and common.debug.isDebug) {
        std.log.debug(fmt, args);
    }
}

pub var wbuf = std.mem.zeroes([512]u8);
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        const stdout = std.Io.File.stdout();
        var writer = stdout.writer(io, &wbuf);
        writer.interface.print(fmt, args) catch undefined;
        writer.interface.flush() catch undefined;
    }
}
