const std = @import("std");
const defines = @import("../core/defines.zig");

const Typechecker = @import("typechecker.zig");
const TypeTable = Typechecker.TypeTable;

// @CompilerOnly
pub const TypeID = u32;

pub const TypeInfo = union(enum) {
    Struct: Struct,
    Union: Union,
    Enum: Enum,
    Array: Array,
    Function: Function,
    Pointer: Pointer,
    Integer: Integer,

    Bool: bool, // mutability bool
    Float: bool, // mutability bool
    Void: bool, // mutability bool
    CInt: bool,
    CUInt: bool,
    CChar: bool,
    CUChar: bool,
    CDouble: bool,
    CLong: bool,
    CULong: bool,
    CShort: bool,
    CUShort: bool,
    CSize: bool,
    Any: bool, // mutability bool
    ComptimeInt, // Must be const
    ComptimeFloat, // Must be const
    EnumLiteral, // Must be const and comptime
    Noreturn,
    Type,

    /// Like type, comptime_int, comptime_float, enum_literal.
    // @CompilerOnly
    pub fn isComptime(self: TypeInfo, types: *const Typechecker.TypeTable.Slice) bool {
        return switch (self) {
            .Function => |func| func.isComptime,
            .Type, .EnumLiteral => true,
            .Struct => |str| blk: {
                for (str.fields) |field| {
                    if (field.isComptime) break :blk true;
                }
                break :blk false;
            },
            .Union => |uni| blk: {
                for (uni.fields) |field| {
                    if (field.isComptime) break :blk true;
                }
                break :blk false;
            },
            .Array => |arr| types.get(arr.child).isComptime(types),
            .Pointer => |ptr| types.get(ptr.child).isComptime(types),
            else => false,
        };
    }

    // @CompilerOnly
    pub fn isZeroBit(self: TypeInfo) bool {
        return switch (self) {
            .Integer => |int| int.size == 0,
            .Noreturn, .Void, .Type => true,
            .Struct => |str| str.fields.len == 0 and !str.isTuple,
            .Union => |uni| uni.fields.len == 0,
            .Enum => |enm| enm.fields.len == 0,
            else => false,
        };
    }

    // @CompilerOnly
    pub fn isMutable(self: TypeInfo) bool {
        return switch (self) {
            .Any => |value| value,
            .Bool => |value| value,
            .Float => |value| value,
            .Struct => |str| str.mutable,
            .Union => |uni| uni.mutable,
            .Enum => |enm| enm.mutable,
            .Integer => |int| int.mutable,
            .Pointer => |ptr| ptr.mutable,
            .Array => |arr| arr.mutable,
            .Function => |func| func.mutable,
            .CInt => |value| value,
            .CUInt => |value| value,
            .CChar => |value| value,
            .CUChar => |value| value,
            .CDouble => |value| value,
            .CLong => |value| value,
            .CULong => |value| value,
            .CShort => |value| value,
            .CUShort => |value| value,
            .CSize => |value| value,
            .Void => |value| value,
            else => false,
        };
    }

    pub fn hash(
        self: TypeInfo,
        typeTable: *TypeTable,
        hasher: *std.hash.Fnv1a_64,
    ) u64 {
        var budget: usize = MaxHashNodes;
        hashTypeInfo(self, typeTable, hasher, 0, &budget);
        return hasher.final();
    }

    pub fn eql(
        self: TypeInfo,
        other: TypeInfo,
        typeTable: *TypeTable,
    ) bool {
        return eqlTypeInfo(self, other, typeTable, null);
    }
};

const MaxHashDepth: usize = 64;
const MaxHashNodes: usize = 4096;

fn hashValue(hasher: *std.hash.Fnv1a_64, value: anytype) void {
    var copy = value;
    hasher.update(std.mem.asBytes(&copy));
}

fn hashCount(hasher: *std.hash.Fnv1a_64, count: usize) void {
    const value: u64 = @intCast(count);
    hashValue(hasher, value);
}

fn hashBytes(hasher: *std.hash.Fnv1a_64, bytes: []const u8) void {
    hashCount(hasher, bytes.len);
    hasher.update(bytes);
}

fn hashChild(
    typeID: TypeID,
    _: *TypeTable,
    hasher: *std.hash.Fnv1a_64,
    _: usize,
    _: *usize,
) void {
    hasher.update(std.mem.asBytes(&typeID));
    // hashTypeInfo(typeTable.get(typeID), typeTable, hasher, depth, budget);
}

fn hashFields(
    fields: []const FieldInfo,
    typeTable: *TypeTable,
    hasher: *std.hash.Fnv1a_64,
    depth: usize,
    budget: *usize,
) void {
    hashCount(hasher, fields.len);

    for (fields) |field| {
        hashValue(hasher, field.public);
        hashValue(hasher, field.name);
        hashValue(hasher, field.isComptime);
        hashChild(field.valueType, typeTable, hasher, depth + 1, budget);
    }
}

fn hashTypeInfo(
    info: TypeInfo,
    typeTable: *TypeTable,
    hasher: *std.hash.Fnv1a_64,
    depth: usize,
    budget: *usize,
) void {
    if (depth >= MaxHashDepth or budget.* == 0) {
        const marker: u8 = 0xFF;
        hasher.update(std.mem.asBytes(&marker));
        return;
    }

    budget.* -= 1;

    const tag = std.meta.activeTag(info);
    hashValue(hasher, tag);

    switch (info) {
        .Bool => |value| hashValue(hasher, value),
        .Float => |value| hashValue(hasher, value),
        .Void => |value| hashValue(hasher, value),

        .CInt => |value| hashValue(hasher, value),
        .CUInt => |value| hashValue(hasher, value),
        .CChar => |value| hashValue(hasher, value),
        .CUChar => |value| hashValue(hasher, value),
        .CDouble => |value| hashValue(hasher, value),
        .CLong => |value| hashValue(hasher, value),
        .CULong => |value| hashValue(hasher, value),
        .CShort => |value| hashValue(hasher, value),
        .CUShort => |value| hashValue(hasher, value),
        .CSize => |value| hashValue(hasher, value),
        .Any => |value| hashValue(hasher, value),

        .Struct => |str| {
            hashValue(hasher, str.mutable);
            hashValue(hasher, str.name);
            hashValue(hasher, str.isTuple);
            hashFields(str.fields, typeTable, hasher, depth, budget);
            hashFields(str.definitions, typeTable, hasher, depth, budget);
        },

        .Union => |uni| {
            hashValue(hasher, uni.isTagged);
            if (uni.isTagged) {
                hashChild(uni.tag, typeTable, hasher, depth + 1, budget);
            }
            hashValue(hasher, uni.mutable);
            hashValue(hasher, uni.name);
            hashFields(uni.fields, typeTable, hasher, depth, budget);
            hashFields(uni.definitions, typeTable, hasher, depth, budget);
        },

        .Enum => |enm| {
            hashValue(hasher, enm.mutable);
            hashValue(hasher, enm.name);
            hashCount(hasher, enm.fields.len);

            for (enm.fields) |field| {
                hashBytes(hasher, field.name);
                hashValue(hasher, field.value);
            }

            hashFields(enm.definitions, typeTable, hasher, depth, budget);
        },

        .Pointer => |ptr| {
            hashValue(hasher, ptr.mutable);
            hashValue(hasher, ptr.size);
            hashChild(ptr.child, typeTable, hasher, depth + 1, budget);
        },

        .Array => |arr| {
            hashValue(hasher, arr.mutable);
            hashValue(hasher, arr.len);
            hashChild(arr.child, typeTable, hasher, depth + 1, budget);
        },

        .Function => |func| {
            hashValue(hasher, func.mutable);
            hashValue(hasher, func.isComptime);
            hashValue(hasher, func.variadic);
            hashCount(hasher, func.argTypes.len);

            for (func.argTypes) |argType| {
                hashChild(argType, typeTable, hasher, depth + 1, budget);
            }

            hashChild(func.returnType, typeTable, hasher, depth + 1, budget);
        },

        .Integer => |int| {
            hashValue(hasher, int.mutable);
            hashValue(hasher, int.size);
            hashValue(hasher, int.signed);
        },

        .ComptimeInt,
        .ComptimeFloat,
        .EnumLiteral,
        .Noreturn,
        .Type,
        => {},
    }
}

const TypePair = struct {
    a: TypeID,
    b: TypeID,
};

const EqlPath = struct {
    pair: TypePair,
    parent: ?*const EqlPath,
};

fn containsPair(path: ?*const EqlPath, a: TypeID, b: TypeID) bool {
    var current = path;
    while (current) |entry| : (current = entry.parent) {
        const pair = entry.pair;
        if ((pair.a == a and pair.b == b) or (pair.a == b and pair.b == a)) {
            return true;
        }
    }
    return false;
}

fn eqlTypeID(
    a: TypeID,
    b: TypeID,
    _: *TypeTable,
    _: ?*const EqlPath,
) bool {
    return a == b;
}

fn eqlFields(
    a: []const FieldInfo,
    b: []const FieldInfo,
    typeTable: *TypeTable,
    path: ?*const EqlPath,
) bool {
    if (a.len != b.len) return false;

    for (a, b) |fieldA, fieldB| {
        if (
            fieldA.public != fieldB.public
            or fieldA.name != fieldB.name
            or fieldA.isComptime != fieldB.isComptime
        ) {
            return false;
        }

        if (!eqlTypeID(fieldA.valueType, fieldB.valueType, typeTable, path)) {
            return false;
        }
    }

    return true;
}

fn eqlTypeInfo(
    a: TypeInfo,
    b: TypeInfo,
    typeTable: *TypeTable,
    path: ?*const EqlPath,
) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

    switch (a) {
        .Bool => |value| return value == b.Bool,
        .Float => |value| return value == b.Float,
        .Void => |value| return value == b.Void,

        .CInt => |value| return value == b.CInt,
        .CUInt => |value| return value == b.CUInt,
        .CChar => |value| return value == b.CChar,
        .CUChar => |value| return value == b.CUChar,
        .CDouble => |value| return value == b.CDouble,
        .CLong => |value| return value == b.CLong,
        .CULong => |value| return value == b.CULong,
        .CShort => |value| return value == b.CShort,
        .CUShort => |value| return value == b.CUShort,
        .CSize => |value| return value == b.CSize,
        .Any => |value| return value == b.Any,

        .Struct => |str| {
            const other = b.Struct;
            if (
                str.mutable != other.mutable
                or str.name != other.name
                or str.isTuple != other.isTuple
            ) {
                return false;
            }

            return
                eqlFields(str.fields, other.fields, typeTable, path)
                and eqlFields(str.definitions, other.definitions, typeTable, path);
        },

        .Union => |uni| {
            const other = b.Union;
            if (
                uni.isTagged != other.isTagged
                or uni.mutable != other.mutable
                or uni.name != other.name
            ) {
                return false;
            }

            if (uni.isTagged and !eqlTypeID(uni.tag, other.tag, typeTable, path)) {
                return false;
            }

            return
                eqlFields(uni.fields, other.fields, typeTable, path)
                and eqlFields(uni.definitions, other.definitions, typeTable, path);
        },

        .Enum => |enm| {
            const other = b.Enum;
            if (
                enm.mutable != other.mutable
                or enm.name != other.name
                or enm.fields.len != other.fields.len
            ) {
                return false;
            }

            for (enm.fields, other.fields) |fieldA, fieldB| {
                if (
                    fieldA.value != fieldB.value
                    or !std.mem.eql(u8, fieldA.name, fieldB.name)
                ) {
                    return false;
                }
            }

            return eqlFields(enm.definitions, other.definitions, typeTable, path);
        },

        .Pointer => |ptr| {
            const other = b.Pointer;
            if (ptr.mutable != other.mutable or ptr.size != other.size) {
                return false;
            }
            return eqlTypeID(ptr.child, other.child, typeTable, path);
        },

        .Array => |arr| {
            const other = b.Array;
            if (arr.mutable != other.mutable or arr.len != other.len) {
                return false;
            }
            return eqlTypeID(arr.child, other.child, typeTable, path);
        },

        .Function => |func| {
            const other = b.Function;
            if (
                func.mutable != other.mutable
                or func.isComptime != other.isComptime
                or func.variadic != other.variadic
                or func.argTypes.len != other.argTypes.len
            ) {
                return false;
            }

            for (func.argTypes, other.argTypes) |argA, argB| {
                if (!eqlTypeID(argA, argB, typeTable, path)) return false;
            }

            return eqlTypeID(func.returnType, other.returnType, typeTable, path);
        },

        .Integer => |int| {
            const other = b.Integer;
            return
                int.mutable == other.mutable
                and int.size == other.size
                and int.signed == other.signed;
        },

        .ComptimeInt,
        .ComptimeFloat,
        .EnumLiteral,
        .Noreturn,
        .Type,
        => return true,
    }
}

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
            and typechecker.nominallyIdentical(this.valueType, that.valueType)
            and (
                typechecker.mutable(this.valueType) and !typechecker.mutable(that.valueType)
                or typechecker.mutable(this.valueType) == typechecker.mutable(that.valueType)
            );
    }
};

pub const Struct = struct {
    mutable: bool,
    name: defines.StringPtr,
    fields: []const FieldInfo,
    definitions: []const FieldInfo,
    isTuple: bool,

    // @CompilerOnly
    scope: defines.ScopePtr,
    expr: defines.ExpressionPtr,
};

pub const Union = struct {
    isTagged: bool,
    /// All unions must have field tags, but only
    /// tagged unions contain them in their layout.
    /// So runtime safety is only present for tagged unions.
    tag: TypeID,
    mutable: bool,
    name: defines.StringPtr,
    fields: []const FieldInfo,
    definitions: []const FieldInfo,

    // @CompilerOnly
    scope: defines.ScopePtr,
    expr: defines.ExpressionPtr,
};

pub const EnumField = struct {
    name: []const u8,
    value: u32,
};

pub const Enum = struct {
    mutable: bool,
    name: defines.StringPtr,
    fields: []const EnumField,
    definitions: []const FieldInfo,

    // @CompilerOnly
    scope: defines.ScopePtr,
    expr: defines.ExpressionPtr,
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
    variadic: bool,
    argTypes: []const TypeID,
    returnType: TypeID,
};

pub const Integer = struct {
    mutable: bool,
    size: u8,
    signed: bool,

    // @CompilerOnly
    pub const Range = struct {
        min: i128,
        max: i128,
    };

    // @CompilerOnly
    pub fn range(self: Integer) Range {
        const max =
            if (self.size == 0) 0
            else (@as(i128, 1) << @intCast(self.size - @intFromBool(self.signed))) - 1;

        const min =
            if (!self.signed) 0
            else if (self.size == 0) 0
            else -(@as(i128, 1) << @intCast(self.size - 1));

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

