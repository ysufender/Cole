const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;

pub fn throwIf(cond: bool, err: Error) Error!void {
    if (cond) return err;
}

//
// Tests
//
const testing = std.testing;

test "throwIf: returns error when true" {
    try testing.expectError(Error.OutOfMemory, throwIf(true, Error.OutOfMemory));
}

test "throwIf: no-op when false" {
    try throwIf(false, Error.OutOfMemory);
}
