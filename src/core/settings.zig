const std = @import("std");
const log = @import("log.zig");
const hashmap = @import("../util/hashmap.zig");

const Error = @import("../core/common.zig").CompilerError;
const Backend = @import("../codegen/backend.zig").Backend;

pub const FlagSet = hashmap.HashMap([]const u8, void);

const Self = @This();

inputFile: []const u8,
outputFile: ?[]const u8,
workingDir: []const u8,
includeDirs: [][]const u8,
maxErr: u32,
backend: Backend,
flags: FlagSet,

pub fn print(self: *const Self, allocator: std.mem.Allocator) void {
    log.info(
        "Compilation settings:"
        ++ "\n\tInput File: {s}"
        ++ "\n\tWorking Dir: {s}"
        ++ "\n\tInclude Dirs: [{s}]\n",
        .{self.inputFile, self.workingDir, std.mem.join(allocator, ", ", self.includeDirs) catch ""}
    );
}

pub fn setFlag(self: *Self, flag: []const u8) Error!void {
    const status = self.flags.getOrPutAssumeCapacity(flag);

    if (status.found_existing) {
        log.err("Duplicated commandline input '{s}'", .{status.key_ptr.*});
        return Error.DuplicateCommandLineInput;
    }
}

pub fn hasFlag(self: *Self, flag: []const u8) bool {
    return self.flags.contains(flag);
}
