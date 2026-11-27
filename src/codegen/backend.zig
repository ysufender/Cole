pub const C = @import("c/backend.zig");
pub const QBE = @import("qbe/backend.zig");

pub const Backend = enum {
    C,
    QBE,
};
