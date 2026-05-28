const std = @import("std");
const defines = @import("../core/defines.zig");

const Typechecker = @import("typechecker.zig");

// @CompilerOnly 
pub const TypeID = u32;

pub const TypeInfo = union(enum) {
    Struct: Struct,
    Union: Union,
    Enum: Enum,

    ComptimeInt, // Must be const
    ComptimeFloat, // Must be const
    EnumLiteral, // Must be const and comptime

    Integer: Integer,
    Bool: bool, // mutability bool
    Float: bool, // mutability bool
    Void,

    Array: Array,

    Pointer: Pointer,
    Function: Function,
    Noreturn,
    Any: bool, // mutability bool
    Type,

    /// Like type, comptime_int, comptime_float, enum_literal
    // @CompilerOnly
    pub fn isComptime(self: TypeInfo, typeTable: *const Typechecker.TypeTable) bool {
        return switch (self) {
            .Array, .Type, .ComptimeInt, .ComptimeFloat, .EnumLiteral => true,
            .Enum => self.isZeroBit(),
            .Struct, .Union => self.isZeroBit() or blk: {
                const fields = if (std.meta.activeTag(self) == .Struct) self.Struct.fields else self.Union.fields;

                for (fields) |field| {
                    if (!field.isComptime) {
                        break :blk false;
                    }
                }

                break :blk true;
            },
            .Pointer => |ptr| typeTable.get(ptr.child).isComptime(typeTable),
            else => false,
        };
    }

    // @CompilerOnly
    pub fn isZeroBit(self: TypeInfo) bool {
        return switch (self) {
            .Integer => |int| int.size == 0,
            .Noreturn => true,
            .Void => true,
            .Type => true,
            .Struct => |str| str.fields.len == 0,
            .Union => |uni| uni.fields.len == 0,
            .Enum => |enm| enm.fields.len == 0,
            else => false,
        };
    }
};

pub const FieldInfo = struct {
    public: bool,
    name: defines.StringPtr,
    valueType: TypeID,
    isComptime: bool,

    // @CompilerOnly 
    pub fn eql(this: *const FieldInfo, that: FieldInfo, typechecker: *const Typechecker) bool {
        return
            (this.public and !that.public or this.public == that.public)
            and this.name == that.name
            and typechecker.typeTable.items(.tags)[this.valueType] == typechecker.typeTable.items(.tags)[that.valueType]
            and (
                typechecker.mutable(this.valueType) and !typechecker.mutable(that.valueType)
                or typechecker.mutable(this.valueType) == typechecker.mutable(that.valueType)
            );
        // @Maybe TODO: Structural FieldInfo.valueType check instead.
    }
};

pub const Struct = struct {
    mutable: bool,
    name: defines.StringPtr,
    fields: []const FieldInfo,
    definitions: []const FieldInfo,

    // @CompilerOnly
    scope: defines.ScopePtr,
};

pub const Union = struct {
    isTagged: bool,
    /// All unions must have field tags, but only
    /// tagged unions contain them in their layout.
    /// So runtime safety is only present for tagged
    /// unions.
    tag: TypeID,
    mutable: bool,
    name: defines.StringPtr,
    fields: []const FieldInfo,
    definitions: []const FieldInfo,

    // @CompilerOnly
    scope: defines.ScopePtr,
};

pub const Enum = struct {
    mutable: bool,
    name: defines.StringPtr,
    fields: []const []const u8,
    definitions: []const FieldInfo,

    // @CompilerOnly
    scope: defines.ScopePtr,
};

pub const Pointer = struct {
    mutable: bool,
    child: TypeID,
    size: enum {
        Slice,
        Single,
        C,
    },
};

pub const Array = struct {
    mutable: bool,
    child: TypeID,
    len: u32,
};

pub const Function = struct {
    mutable: bool,
    isComptime: bool, 
    argTypes: []const TypeID,
    returnType: TypeID,
};

pub const Integer = struct {
    mutable: bool,
    size: u6,
    signed: bool,

    // @CompilerOnly 
    pub const Range = struct { 
        min: i64,
        max: i64,
    };

    // @CompilerOnly 
    pub fn range(self: Integer) Range {
        const max =
            if (self.size == 0) 0
            else (@as(i64, 1) << (self.size - @intFromBool(self.signed))) - 1;

        const min =
            if (!self.signed) 0
            else if (self.size == 0) 0
            else -(@as(i64, 1) << (self.size - 1));

        return .{
            .min = min,
            .max = max,
        };
    }

    // @CompilerOnly 
    pub fn canContain(self: Integer, other: Integer) bool {
        const selfRange = self.range();
        const otherRange = other.range();

        return
            selfRange.min <= otherRange.min
            and selfRange.max >= otherRange.max;
    }
};
