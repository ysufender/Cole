const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;

fn InnerStaticStack(comptime T: type, comptime Size: usize) type {
    return struct {
        const Self = @This();

        values: [Size]T = undefined,
        index: u32 = 0,
        items: []T = &.{},

        pub fn push(stack: *Self, value: T) Error!void {
            if (stack.index >= Size) {
                return Error.OutOfMemory;
            }

            defer stack.items = stack.values[0..stack.index];
            defer stack.index += 1;
            stack.values[stack.index] = value;
        }

        pub fn pop(stack: *Self) ?T {
            if (stack.index <= 0) {
                return null;
            }

            defer stack.items = stack.values[0..stack.index];
            stack.index -= 1;
            return stack.values[stack.index];
        }

        pub fn empty(stack: *const Self) bool {
            return stack.index == 0;
        }

        pub fn peek(stack: *const Self) *T {
            return &stack.items[stack.items.len - 1];
        }

        pub fn peekm(stack: *const Self) ?*T {
            return if (stack.items.len == 0) null else &stack.items[stack.items.len - 1];
        }

        pub fn revert(self: *Self, index: u32) void {
            if (self.index <= index) {
                return;
            }

            self.index = index;
        }
    };
}

pub fn StaticStack(comptime T: type, comptime Size: usize) type {
    return InnerStaticStack(T, Size);
}

pub fn StaticRingStack(comptime T: type, comptime Size: usize) type {
    return struct {
        const Self = @This();

        values: [Size]T = undefined,
        top: u32 = 0,
        size: u32 = 0,

        pub fn push(stack: *Self, value: T) void {
            if (stack.top >= Size) {
                stack.top = 0;
                stack.size -= 1;
            }

            defer stack.top += 1;
            defer stack.size += 1;

            stack.values[stack.top] = value;
        }

        pub fn pop(stack: *Self) ?T {
            if (stack.top <= 0 and stack.size > 0) {
                stack.top = Size - 1;
            }
            else if (stack.top <= 0) {
                return null;
            }

            defer stack.top -= 1;
            defer stack.size -= 1;
            return stack.peek();
        }

        pub fn peek(stack: *const Self) ?T {
            const top =
                if (stack.top <= 0 and stack.size > 0) Size - 1
                else if (stack.top <= 0) return null
                else stack.top - 1;

            return stack.values[top];
        }

        pub fn empty(stack: *const Self) bool {
            return stack.size <= 0;
        }
    };
}

pub fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T = &.{},
        index: u32 = 0,

        pub fn init(allocator: std.mem.Allocator, capacity: u32) Error!Self {
            var self = Self{
                .allocator = allocator,
            };

            try self.ensureTotalCapacity(capacity);
            return self;
        }

        pub fn ensureTotalCapacity(self: *Self, cap: u32) Error!void {
            if (self.items.len >= cap) {
                return;
            }

            const new = self.allocator.alloc(T, cap)
                catch return Error.AllocatorFailure;
            @memcpy(new[0..self.index], self.items[0..self.index]);
            self.allocator.free(self.items);
            self.items = new;
        }

        pub fn push(self: *Self, value: T) Error!void {
            if (self.index >= self.items.len) {
                try self.ensureTotalCapacity(if (self.items.len == 0) 8 else @intCast(self.items.len * 2));
            }

            defer self.index += 1;
            self.items[self.index] = value;
        }

        pub fn pop(self: *Self) ?T {
            if (self.index == 0) {
                return null;
            }

            self.index -= 1;
            return self.items[self.index];
        }

        pub fn empty(self: *const Self) bool {
            return self.index == 0;
        }

        pub fn peek(self: *const Self) ?*T {
            if (self.index == 0) {
                return null;
            }
            else {
                return &self.items[self.index - 1];
            }
        }

        pub fn revert(self: *Self, index: u32) void {
            std.debug.assert(self.index > index);
            self.index = index;
        }
    };
}
