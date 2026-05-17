const std = @import("std");
const types = @import("type.zig");
const backend = @import("../codegen/backend.zig");

const TypeID = types.TypeID;
const TypeInfo = types.TypeInfo;
const MultiArray = @import("../util/arraylist.zig").MultiArrayList;

pub fn JIR(comptime jirBackend: backend.Backend) type {
    return backend.importBackend(jirBackend).JIR;
}
