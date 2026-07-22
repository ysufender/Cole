const std = @import("std");
const arraylist = @import("arraylist.zig");
const stack = @import("stack.zig");

const Error = @import("../core/common.zig").CompilerError;
const Allocator = std.mem.Allocator;

pub const MultiArrayList = arraylist.MultiArrayList;
pub const ReverseStackArray = arraylist.ReverseStackArray;
pub const StaticStack = stack.StaticStack;
pub const StaticRingStack = stack.StaticRingStack;
pub const HashMap = @import("hashmap.zig").HashMap;

fn determine(comptime ptr: type) struct {
    PtrType: std.builtin.Type.Pointer.Size,
    ElemType: type,
    SelfType: type,
} {
    return switch (@typeInfo(ptr)) {
        .pointer => |p| .{
            .PtrType = p.size,
            .ElemType = p.child,
            .SelfType = switch (p.size) {
                .one => *p.child,
                .many => ptr,
                .slice => []p.child,
                .c => ptr,
            },
        },
        else => @compileError("Expected pointer type."),
    };
}

/// Attempts deep copy depending on the passed ptr type
/// - One: deep copy
/// - Slice: Deep copy each element
/// - Many: Shallow Copy
/// - C: Shallow Copy
pub fn deepCopyPtr(ptr: anytype, allocator: Allocator) Error!determine(@TypeOf(ptr)).SelfType {
    const info = determine(@TypeOf(ptr));

    var result: info.SelfType = undefined;

    switch (info.PtrType) {
        .one => {
            result = allocator.create(info.ElemType) catch return Error.AllocatorFailure;
            result.* = try deepCopy(ptr.*, allocator);
        },
        .many => result = ptr,
        .slice => {
            result = allocator.alloc(info.ElemType, ptr.len) catch return Error.AllocatorFailure;
            for (0..ptr.len) |i| {
                result[i] = try deepCopy(ptr[i], allocator);
            }
        },
        .c => result = ptr,
    }

    return result;
}

/// Attempts to deep copy a value,
/// - If value is a pointer/slice, calls deepCopyPtr
/// - If value is a struct, and contains a method with name "dupe" or "clone"
/// with signature fn (*const Self, Allocator) Self or fn (Self, Allocator) Self,
/// calls it.
/// - Otherwise performs a shallow copy.
pub fn deepCopy(item: anytype, allocator: Allocator) Error!@TypeOf(item) {
    const T = @TypeOf(item);
    const info = @typeInfo(T);

    switch (info) {
        .pointer => return deepCopyPtr(item, allocator),
        .@"struct" => |obj| {
            const copy = @as(?[]const u8,
                if (std.meta.hasMethod(T, "dupe")) "dupe"
                else if (std.meta.hasMethod(T, "clone")) "clone"
                else null
            );

            if (copy) |func| {
                const copyFunc = @TypeOf(@field(T, func));
                const args = std.meta.ArgsTuple(copyFunc);

                return (
                    if (@typeInfo(args).@"struct".fields[0].type == *const T)
                        @call(.auto, @field(T, func), .{&item, allocator})
                    else
                        @call(.auto, @field(T, func), .{item, allocator})
                ) catch Error.AllocatorFailure;

            }
            else {
                var ret: T = undefined;

                inline for (obj.fields) |field| {
                    @field(ret, field.name) =
                        try deepCopy(@field(item, field.name), allocator);
                }

                return ret;
            }
        },
        .optional => {
            return
                if (item) |underlying| try deepCopy(underlying, allocator)
                else null;
        },
        .array => |arr| {
            var new: [arr.len]arr.child = undefined;

            if (arr.len <= 5) {
                inline for (0..arr.len) |i| {
                    new[i] = try deepCopy(item[i], allocator);
                }
            }
            else {
                for (0..arr.len) |i| {
                    new[i] = try deepCopy(item[i], allocator);
                }
            }

            return new;
        },
        else => return item,
    }

    unreachable;
}

/// Attempts to deep free a value,
/// - If value is a pointer/slice, calls deepFreePtr
/// - If value is a struct, and contains a method with name "deinit"
/// with signature 'fn (*Self, Allocator) void' or 'fn (*Self, Allocator) void',
/// calls it.
/// - Otherwise performs a default free.
pub fn deepFree(_item: anytype, allocator: Allocator) Error!void {
    var item = _item;
    const T = @TypeOf(_item);
    const info = @typeInfo(T);

    switch (info) {
        .pointer => return deepFreePtr(item, allocator),
        .@"struct" => |obj| {
            const free = @as(?[]const u8,
                if (std.meta.hasMethod(T, "deinit")) "deinit"
                else null
            );

            if (free) |func| {
                const freeFunc = @TypeOf(@field(T, func));
                const args = std.meta.ArgsTuple(freeFunc);

                if (@typeInfo(args).@"struct".fields[0].type == *T) {
                    @call(.auto, @field(T, func), .{&item, allocator});
                }
                else {
                    @call(.auto, @field(T, func), .{item, allocator});
                }

            }
            else {
                inline for (obj.fields) |field| {
                    try deepFree(@field(item, field.name), allocator);
                }
            }
        },
        .optional => {
            if (item) |underlying| {
                try deepFree(underlying, allocator);
            }
        },
        .array => |arr| {
            if (arr.len <= 5) {
                inline for (0..arr.len) |i| {
                    try deepFree(item[i], allocator);
                }
            }
            else {
                for (0..arr.len) |i| {
                    try deepFree(item[i], allocator);
                }
            }
        },
        .@"union" => |uni| {
            const tag = std.meta.activeTag(item);
            inline for (uni.fields) |field| {
                if (std.mem.eql(u8, @tagName(tag), field.name)) {
                    return deepFree(@field(item, field.name), allocator);
                }
            }
        },
        else => { },
    }
}

/// Attempts deep free depending on the passed ptr type
/// - One: deep free
/// - Slice: Deep free each element
/// - Many: default free 
/// - C: default free
pub fn deepFreePtr(ptr: anytype, allocator: Allocator) Error!void {
    const info = determine(@TypeOf(ptr));

    switch (info.PtrType) {
        .one => {
            try deepFree(ptr.*, allocator);
            allocator.destroy(ptr);
        },
        .many => allocator.free(ptr),
        .slice => {
            for (0..ptr.len) |i| {
                try deepFree(ptr[i], allocator);
            }
            allocator.free(ptr);
        },
        .c => allocator.free(ptr),
    }
}

//
// Tests
//
const testing = std.testing;

test "deepCopy/deepFree: pointer + slice fields round-trip without leaks" {
    const Inner = struct { value: i32 };
    const Outer = struct {
        ptr: *Inner,
        list: []i32,
    };

    const originalPtr = try testing.allocator.create(Inner);
    originalPtr.* = .{ .value = 7 };
    const originalList = try testing.allocator.alloc(i32, 3);
    @memcpy(originalList, &[_]i32{ 1, 2, 3 });
    defer testing.allocator.destroy(originalPtr);
    defer testing.allocator.free(originalList);

    const original = Outer{ .ptr = originalPtr, .list = originalList };

    const copy = try deepCopy(original, testing.allocator);
    defer deepFree(copy, testing.allocator) catch unreachable;

    // Distinct allocations...
    try testing.expect(copy.ptr != original.ptr);
    try testing.expect(copy.list.ptr != original.list.ptr);
    // ...with equal contents.
    try testing.expectEqual(original.ptr.value, copy.ptr.value);
    try testing.expectEqualSlices(i32, original.list, copy.list);

    // Mutating the copy must not affect the original (true deep copy).
    copy.ptr.value = 99;
    try testing.expectEqual(@as(i32, 7), original.ptr.value);
}

test "deepCopy: null optional stays null, non-null gets deep-copied" {
    const Inner = struct { value: i32 };
    const Holder = struct { maybe: ?*Inner };

    var none = Holder{ .maybe = null };
    const noneCopy = try deepCopy(none, testing.allocator);
    try testing.expect(noneCopy.maybe == null);
    _ = &none;

    const innerPtr = try testing.allocator.create(Inner);
    innerPtr.* = .{ .value = 3 };
    defer testing.allocator.destroy(innerPtr);
    const some = Holder{ .maybe = innerPtr };

    const someCopy = try deepCopy(some, testing.allocator);
    defer deepFree(someCopy, testing.allocator) catch unreachable;

    try testing.expect(someCopy.maybe.? != innerPtr);
    try testing.expectEqual(@as(i32, 3), someCopy.maybe.?.value);
}

var customDupeCalls: u32 = 0;
var customDeinitCalls: u32 = 0;

const CustomHooked = struct {
    tag: u32,

    pub fn dupe(self: *const CustomHooked, allocator: std.mem.Allocator) CustomHooked {
        _ = allocator;
        customDupeCalls += 1;
        return .{ .tag = self.tag };
    }

    pub fn deinit(self: *CustomHooked, allocator: std.mem.Allocator) void {
        _ = allocator;
        customDeinitCalls += 1;
        self.tag = 0;
    }
};

test "deepCopy/deepFree: prefers a type's own dupe()/deinit() over field-by-field copy" {
    customDupeCalls = 0;
    customDeinitCalls = 0;

    const original = CustomHooked{ .tag = 5 };
    const copy = try deepCopy(original, testing.allocator);

    try testing.expectEqual(@as(u32, 1), customDupeCalls);
    try testing.expectEqual(@as(u32, 5), copy.tag);

    try deepFree(copy, testing.allocator);
    try testing.expectEqual(@as(u32, 1), customDeinitCalls);
}

test "deepCopy: array field is deep-copied element-wise" {
    const Inner = struct { value: i32 };
    const Holder = struct { arr: [2]*Inner };

    const a = try testing.allocator.create(Inner);
    a.* = .{ .value = 1 };
    const b = try testing.allocator.create(Inner);
    b.* = .{ .value = 2 };
    defer testing.allocator.destroy(a);
    defer testing.allocator.destroy(b);

    const original = Holder{ .arr = .{ a, b } };
    const copy = try deepCopy(original, testing.allocator);
    defer deepFree(copy, testing.allocator) catch unreachable;

    try testing.expect(copy.arr[0] != a);
    try testing.expect(copy.arr[1] != b);
    try testing.expectEqual(@as(i32, 1), copy.arr[0].value);
    try testing.expectEqual(@as(i32, 2), copy.arr[1].value);
}
