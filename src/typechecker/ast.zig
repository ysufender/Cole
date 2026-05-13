const defines = @import("../core/defines.zig");
const types = @import("type.zig");

const TypeID = types.TypeID;

pub const Definition = struct {
    pub const Type = enum {
        Function,
        Variable,
    };
};
