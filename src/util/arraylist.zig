const std = @import("std");
const collections = @import("collections.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Error = @import("../core/common.zig").CompilerError;

/// Faster for structs compared to std.MultiArrayList, not tested for unions
pub fn MultiArrayList(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") {
        @compileError("MultiArrayList is only available to structs.");
    }

    return StructMultiArrayList(T);
}

fn StructMultiArrayList(comptime T: type) type {
    const info = @typeInfo(T).@"struct";

    const fields = info.fields;

    comptime var newFieldsNames: [fields.len][]const u8 = undefined;
    comptime var newFieldsTypes: [fields.len]type = undefined;
    comptime var newFieldsAttrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    
    for (fields, 0..) |field, i| {
        newFieldsNames[i] = field.name;
        newFieldsTypes[i] = []field.type;
        newFieldsAttrs[i] = std.builtin.Type.StructField.Attributes{
            .@"align" = @alignOf([]field.type),
            .@"comptime" = false,
            .default_value_ptr = null,
        };
    }


    const Inner = @Struct(
        .auto,
        null,
        &newFieldsNames,
        &newFieldsTypes,
        &newFieldsAttrs,
    );

    return struct {
        const Self = @This();

        pub const Iterator = struct {
            ctx: Slice,
            idx: u32 = 0,

            pub fn next(self: *Iterator) ?T {
                if (self.eos()) {
                    return null;
                }

                defer self.idx += 1;
                return self.ctx.get(self.idx);
            }

            pub fn eos(self: *const Iterator) bool {
                return self.idx >= self.ctx.len;
            }

            /// Return the last index returned
            pub fn last(self: *const Iterator) u32 {
                return @max(self.idx - 1, 0);
            }

            /// Roll back to index 0
            pub fn reset(self: *Iterator) void {
                self.idx = 0;
            }

            pub fn exhaust(self: *Iterator, allocator: Allocator) Error![]T {
                var mem = allocator.alloc(T, self.ctx.len) catch return Error.AllocatorFailure;
                var i: u32 = 0;

                while (self.next()) |item| : (i += 1) {
                    mem[i] = item;
                }

                return mem;
            }
        };

        /// Readonly slice
        pub const Slice = struct {
            inner: Inner,
            len: u32,

            pub fn items(self: *const Slice, comptime field: std.meta.FieldEnum(Inner)) []@typeInfo(std.meta.fieldInfo(Inner, field).type).pointer.child {
                return @field(self.inner, std.meta.fieldInfo(Inner, field).name)[0..self.len];
            }

            pub fn get(self: *const Slice, index: u32) T {
                assert(index < self.len);

                var ret: T = undefined;

                inline for (fields) |field| {
                    @field(ret, field.name) = @field(self.inner, field.name)[0..self.len][index];
                }

                return ret;
            }

            pub fn capacity(self: *const Slice) u32 {
                return @intCast(@field(self.inner, fields[0].name).len);
            }

            /// Frees all owned memory, slice shouldn't be used after free.
            pub fn free(self: *Slice, allocator: Allocator) void {
                inline for (fields) |field| {
                    allocator.free(@field(self.inner, field.name));
                }

                self = .{
                    .len = 0,
                    .inner = undefined,
                };
            }

            pub fn iterator(self: *const Slice) Iterator {
                return .{
                    .ctx = self.*,
                };
            }

            pub fn eql(self: *const Slice, other: *const Slice) bool {
                if (self.len != other.len) {
                    return false;
                }

                for (0..self.len) |i| {
                    inline for (fields) |field| {
                        if (
                            @field(self.inner, field.name)[i] != @field(other.inner, field.name)[i]
                        ) {
                            return false;
                        }
                    }
                }

                return true;
            }
        };

        inner: Inner,
        len: u32,

        pub fn init(allocator: Allocator, cap: usize) Error!Self {
            var self = Self{
                .len = 0,
                .inner = undefined,
            };

            inline for (fields) |field| {
                @field(self.inner, field.name) = allocator.alloc(field.type, cap) catch return Error.AllocatorFailure;
            }

            try self.ensureTotalCapacity(allocator, cap);

            return self;
        }
        
        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, cap: usize) Error!void {
            if (self.capacity() >= cap) {
                return;
            }

            inline for (fields) |field| {
                var new: []field.type = undefined;

                if (@field(self.inner, field.name).len != 0) {
                    if (allocator.remap(@field(self.inner, field.name), cap)) |mem| {
                        new = mem;
                    }
                    else {
                        const mem = allocator.alloc(field.type, cap) catch return Error.AllocatorFailure;
                        @memcpy(mem.ptr, @field(self.inner, field.name)[0..self.len]);
                        allocator.free(@field(self.inner, field.name));
                        new = mem;
                    }
                }
                else {
                    new = allocator.alloc(field.type, cap) catch return Error.AllocatorFailure;
                }

                @field(self.inner, field.name) = new;
            }
        }

        pub fn addOne(self: *Self, allocator: Allocator) Error!u32 {
            const cap = self.capacity();

            if (self.len >= cap) {
                try self.ensureTotalCapacity(allocator, @max(cap, 8) * 2);
            }

            defer self.len += 1;
            return self.len;
        }

        pub fn append(self: *Self, allocator: Allocator, element: T) Error!void {
            const cap = self.capacity();

            if (cap <= self.len) {
                try self.ensureTotalCapacity(allocator, @max(cap, 8) * 2);
            }

            self.appendAssumeCapacity(element);
        }

        pub fn appendAssumeCapacity(self: *Self, element: T) void {
            defer self.len += 1;
            inline for (fields) |array| {
                @field(self.inner, array.name)[self.len] = @field(element, array.name);
            }
        }

        pub fn items(self: *const Self, comptime field: std.meta.FieldEnum(Inner)) []@typeInfo(std.meta.fieldInfo(Inner, field).type).pointer.child {
            return @field(self.inner, std.meta.fieldInfo(Inner, field).name)[0..self.len];
        }

        pub fn get(self: *const Self, index: u32) T {
            assert(index < self.len);

            var ret: T = undefined;

            inline for (fields) |field| {
                @field(ret, field.name) = @field(self.inner, field.name)[0..self.len][index];
            }

            return ret;
        }

        pub fn set(self: *Self, index: u32, value: T) void {
            inline for (fields) |field| {
                @field(self.inner, field.name)[index] = @field(value, field.name);
            }
        }

        pub fn capacity(self: *Self) u32 {
            return @intCast(@field(self.inner, fields[0].name).len);
        }

        /// Clears all internal data and releases the ownership
        /// self is uninitialized after this call. Self.init must be called
        /// before use.
        pub fn toOwnedSlice(self: *Self) Slice {
            defer {
                self.len = 1;

                inline for (fields) |field| {
                    @field(self.inner, field.name) = &.{};
                }
            }
            return .{
                .len = self.len,
                .inner = self.inner,
            };
        }

        /// Returns a readonly slice without releasing ownership
        pub fn slice(self: *const Self) Slice {
            var inner: Inner = undefined;

            inline for (fields) |field| {
                @field(inner, field.name) = @field(self.inner, field.name)[0..self.len];
            }

            return .{
                .len = self.len,
                .inner = inner,
            };
        }

        pub fn mutableSlice(self: *const Self) Self {
            var ret: Inner = undefined;

            inline for (fields) |field| {
                @field(ret, field.name) = @field(self.inner, field.name)[0..self.len];
            }

            return .{
                .inner = ret,
                .len = self.len,
            };
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ 
                .ctx = self.slice(),
            };
        }
    };
}

pub fn ReverseStackArray(comptime T: type, comptime capacity: u32) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T,
        items: []T,

        pub fn init() Self {
            return .{
                .buffer = undefined,
                .items = &[_]T{},
            };
        }

        pub fn append(self: *Self, element: T) Error!void {
            if (self.items.len >= capacity) {
                return Error.OutOfMemory;
            }

            const index = capacity - self.items.len - 1;

            defer self.items = self.buffer[index..];
            self.buffer[index] = element;
        }

        /// Clears all internal data and releases the ownership
        /// self is uninitialized after this call. Self.init must be called
        /// before use.
        pub fn toOwnedSlice(self: *Self, allocator: Allocator) Error![]T {
            defer self.* = .{
                .len = 0,
                .items = &[_]T{},
                .buffer = &[_]T{},
            };

            return allocator.dupe(T, self.items) catch Error.AllocatorFailure;
        }
    };
}

//
// Tests
//
pub const Tests = struct {
    test "UnionArrayList" {
    }
};
