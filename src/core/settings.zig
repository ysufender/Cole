const std = @import("std");
const log = @import("log.zig");
const hashmap = @import("../util/hashmap.zig");

const Error = @import("../core/common.zig").CompilerError;
const Backend = @import("../codegen/backend.zig").Backend;

pub const FlagSet = hashmap.HashMap([]const u8, void);

pub const Optimize = enum(u3) {
    Og = 0,
    O1 = 1,
    O2 = 2,
    O3 = 3,
};

const Self = @This();

inputFile: []const u8,
outputFile: []const u8,
workingDir: []const u8,
includeDirs: []const []const u8,
linkDirs: []const []const u8,
libraries: []const []const u8,
optimize: Optimize,
maxErr: u32,
backend: Backend,
flags: FlagSet,

pub fn print(self: *const Self, allocator: std.mem.Allocator) void {
    log.info(
        "Compilation settings:"
        ++ "\n\tInput File  : {s}"
        ++ "\n\tOutput File : {s}"
        ++ "\n\tWorking Dir : {s}"
        ++ "\n\tMax Errors  : {d}"
        ++ "\n\tOptimize    : {s}"
        ++ "\n\tBackend     : {s}"
        ++ "\n\tInclude Dirs: [{s}]"
        ++ "\n\tLink Dirs   : [{s}]"
        ++ "\n\tLibraries   : [{s}]\n",
        .{
            self.inputFile,
            self.outputFile,
            self.workingDir,
            self.maxErr,
            @tagName(self.optimize),
            @tagName(self.backend),
            std.mem.join(allocator, ", ", self.includeDirs) catch "",
            std.mem.join(allocator, ", ", self.linkDirs) catch "",
            std.mem.join(allocator, ", ", self.libraries) catch "",
        }
    );
}

pub fn setFlag(self: *Self, flag: []const u8) Error!void {
    const status = self.flags.getOrPutAssumeCapacity(flag);

    if (status.found_existing) {
        log.err("Duplicated commandline input '{s}'", .{status.key_ptr.*});
        return Error.DuplicateCommandLineInput;
    }
}

pub fn hasFlag(self: *const Self, flag: []const u8) bool {
    return self.flags.contains(flag);
}

pub fn canFold(self: *const Self) bool {
    return
        self.optimize != Optimize.Og
        and !self.hasFlag("--debug");
}
