const std = @import("std");
const defines = @import("../core/defines.zig");

const Typechecker = @import("typechecker.zig");
const TypeTable = Typechecker.TypeTable.Slice;

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
    pub fn isComptime(self: TypeInfo, _: *const Typechecker.TypeTable) bool {
        return switch (self) {
            .Function, .Type, .ComptimeInt, .ComptimeFloat, .EnumLiteral => true,
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

    pub fn isMutable(self: TypeInfo) bool {
        return switch (self) {
            .Any => |any| any,
            .Bool => |b| b,
            .Float => |fl| fl,
            .Struct => |str| str.mutable,
            .Union => |uni| uni.mutable,
            .Enum => |enu| enu.mutable,
            .Integer => |int| int.mutable,
            .Pointer => |ptr| ptr.mutable,
            .Array => |arr| arr.mutable,
            .Function => |func| func.mutable,
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

//
// Tests
//
const testing = std.testing;
const MultiArrayList = @import("../util/arraylist.zig").MultiArrayList;

test "Integer.range: unsigned" {
    const u8_ = Integer{ .mutable = false, .size = 8, .signed = false };
    const r = u8_.range();
    try testing.expectEqual(@as(i64, 0), r.min);
    try testing.expectEqual(@as(i64, 255), r.max);
}

test "Integer.range: signed" {
    const i8_ = Integer{ .mutable = false, .size = 8, .signed = true };
    const r = i8_.range();
    try testing.expectEqual(@as(i64, -128), r.min);
    try testing.expectEqual(@as(i64, 127), r.max);
}

test "Integer.range: zero-size is zero-zero" {
    const zero = Integer{ .mutable = false, .size = 0, .signed = true };
    const r = zero.range();
    try testing.expectEqual(@as(i64, 0), r.min);
    try testing.expectEqual(@as(i64, 0), r.max);
}

test "Integer.canContain: wider signed contains narrower signed" {
    const i32_ = Integer{ .mutable = false, .size = 32, .signed = true };
    const i8_ = Integer{ .mutable = false, .size = 8, .signed = true };
    try testing.expect(i32_.canContain(i8_));
    try testing.expect(!i8_.canContain(i32_));
}

test "Integer.canContain: signed does NOT contain same-width unsigned" {
    // i8 range [-128,127], u8 range [0,255] — u8's max (255) exceeds i8's
    // max (127), so i8 cannot represent every u8 value.
    const i8_ = Integer{ .mutable = false, .size = 8, .signed = true };
    const u8_ = Integer{ .mutable = false, .size = 8, .signed = false };
    try testing.expect(!i8_.canContain(u8_));
}

test "Integer.canContain: unsigned wider contains narrower unsigned" {
    const u32_ = Integer{ .mutable = false, .size = 32, .signed = false };
    const u8_ = Integer{ .mutable = false, .size = 8, .signed = false };
    try testing.expect(u32_.canContain(u8_));
}

test "Integer.canContain: same type contains itself" {
    const i16_ = Integer{ .mutable = false, .size = 16, .signed = true };
    try testing.expect(i16_.canContain(i16_));
}

test "TypeInfo.isZeroBit: Void/Noreturn/Type are zero-bit" {
    try testing.expect((TypeInfo{ .Void = {} }).isZeroBit());
    try testing.expect((TypeInfo{ .Noreturn = {} }).isZeroBit());
    try testing.expect((TypeInfo{ .Type = {} }).isZeroBit());
}

test "TypeInfo.isZeroBit: zero-size Integer is zero-bit, i32 is not" {
    try testing.expect((TypeInfo{ .Integer = .{ .mutable = false, .size = 0, .signed = true } }).isZeroBit());
    try testing.expect(!(TypeInfo{ .Integer = .{ .mutable = false, .size = 32, .signed = true } }).isZeroBit());
}

test "TypeInfo.isZeroBit: empty Struct/Union/Enum are zero-bit" {
    try testing.expect((TypeInfo{ .Struct = .{
        .mutable = false, .name = 0, .fields = &.{}, .definitions = &.{}, .scope = 0,
    } }).isZeroBit());
    try testing.expect((TypeInfo{ .Enum = .{
        .mutable = false, .name = 0, .fields = &.{}, .definitions = &.{}, .scope = 0,
    } }).isZeroBit());
}

test "TypeInfo.isZeroBit: non-empty Struct is not zero-bit" {
    const fields = [_]FieldInfo{
        .{ .public = true, .name = 0, .valueType = 0, .isComptime = false },
    };
    try testing.expect(!(TypeInfo{ .Struct = .{
        .mutable = false, .name = 0, .fields = &fields, .definitions = &.{}, .scope = 0,
    } }).isZeroBit());
}

test "TypeInfo.isComptime: ComptimeInt/Float/EnumLiteral/Array/Type are always comptime" {
    var table = try MultiArrayList(TypeInfo).init(testing.allocator, 1);
    defer {
        var s = table.slice();
        s.free(testing.allocator);
    }

    try testing.expect((TypeInfo{ .ComptimeInt = {} }).isComptime(&table));
    try testing.expect((TypeInfo{ .ComptimeFloat = {} }).isComptime(&table));
    try testing.expect((TypeInfo{ .EnumLiteral = {} }).isComptime(&table));
    try testing.expect((TypeInfo{ .Type = {} }).isComptime(&table));
    try testing.expect((TypeInfo{ .Array = .{ .mutable = false, .child = 0, .len = 3 } }).isComptime(&table));
}

test "TypeInfo.isComptime: plain runtime types are not comptime" {
    var table = try MultiArrayList(TypeInfo).init(testing.allocator, 1);
    defer {
        var s = table.slice();
        s.free(testing.allocator);
    }

    try testing.expect(!(TypeInfo{ .Integer = .{ .mutable = false, .size = 32, .signed = true } }).isComptime(&table));
    try testing.expect(!(TypeInfo{ .Bool = false }).isComptime(&table));
    try testing.expect(!(TypeInfo{ .Void = {} }).isComptime(&table));
}

test "TypeInfo.isComptime: Pointer defers to its child's comptime-ness via the type table" {
    var table = try MultiArrayList(TypeInfo).init(testing.allocator, 2);
    defer {
        var s = table.slice();
        s.free(testing.allocator);
    }

    const comptimeChildId = try table.addOne(testing.allocator);
    table.set(comptimeChildId, .{ .ComptimeInt = {} });

    const runtimeChildId = try table.addOne(testing.allocator);
    table.set(runtimeChildId, .{ .Integer = .{ .mutable = false, .size = 32, .signed = true } });

    const ptrToComptime = TypeInfo{ .Pointer = .{ .mutable = false, .child = comptimeChildId, .size = .Single } };
    const ptrToRuntime = TypeInfo{ .Pointer = .{ .mutable = false, .child = runtimeChildId, .size = .Single } };

    try testing.expect(ptrToComptime.isComptime(&table));
    try testing.expect(!ptrToRuntime.isComptime(&table));
}
