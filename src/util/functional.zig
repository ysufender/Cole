const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;

pub fn throwIf(cond: bool, err: Error) Error!void {
    if (cond) return err;
}
