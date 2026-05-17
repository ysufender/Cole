pub const Backend = enum {
    c,
};

pub fn importBackend(comptime backend: Backend) type {
    return switch (backend) {
        .c => @import("c.zig"),
    };
}
