const std = @import("std");
const defines = @import("../core/defines.zig");
const types = @import("type.zig");
const backend = @import("../codegen/backend.zig");

const assert = std.debug.assert;

const Resolver = @import("resolver.zig");
const TypeID = types.TypeID;
const JIR = backend.C.JIR;

pub const Folder = @import("comptime/folder.zig");
pub const Executer = @import("comptime/executer.zig");

// TODO: Turn into a manually tagged union
// with possibly flattened fields for performance
// and memory usage
pub const Value = union(enum) {
    pub const Implicit = enum(u8) {
        pub const Type = enum(u8) {
            Any = 0,
            Incomplete = 1,
        };

        Void = 2,
    };

    pub const Ptr = defines.Offset;

    Int: i64,
    Float: f32,
    Bool: bool,
    Enum: struct {
        Type: TypeID,
        Value: u32,
    },
    Union: struct {
        Type: TypeID,
        Tag: u32,
        Value: Value.Ptr,
    },
    Struct: struct {
        Type: TypeID,
        Fields: defines.Range,
    },
    Type: TypeID,
    Pointer: struct {
        Type: TypeID,
        To: Value.Ptr,
    },
    String: struct {
        type: enum {
            Cole,
            C,
        },
        str: []const u8,
    },
    Slice: struct {
        const Self = @This();

        Type: TypeID, 
        Size: u32,
        To: Value.Ptr,

        pub fn at(self: *const Self, index: u32) Value.Ptr {
            assert(index < self.Size);
            return self.To + index;
        }
    },
    Function: JIR.Function,
    Void,
    Undefined: TypeID,
};
