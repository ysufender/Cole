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

        pub fn peek(self: *const Self) *T {
            std.debug.assert(self.index > 0);
            return &self.items[self.index - 1];
        }

        pub fn revert(self: *Self, index: u32) void {
            std.debug.assert(self.index > index);
            self.index = index;
        }
    };
}

//
// Tests
//
const testing = std.testing;

test "StaticStack: push/pop LIFO order" {
    var s = StaticStack(i32, 4){};
    try s.push(1);
    try s.push(2);
    try s.push(3);

    try testing.expectEqual(@as(i32, 3), s.pop().?);
    try testing.expectEqual(@as(i32, 2), s.pop().?);
    try testing.expectEqual(@as(i32, 1), s.pop().?);
    try testing.expectEqual(@as(?i32, null), s.pop());
}

test "StaticStack: push past capacity returns OutOfMemory" {
    var s = StaticStack(i32, 2){};
    try s.push(1);
    try s.push(2);
    try testing.expectError(Error.OutOfMemory, s.push(3));
}

test "StaticStack: empty() reflects state" {
    var s = StaticStack(i32, 2){};
    try testing.expect(s.empty());
    try s.push(1);
    try testing.expect(!s.empty());
    _ = s.pop();
    try testing.expect(s.empty());
}

test "StaticStack: peek doesn't consume" {
    var s = StaticStack(i32, 2){};
    try s.push(42);
    try testing.expectEqual(@as(i32, 42), s.peek().*);
    try testing.expectEqual(@as(i32, 42), s.peek().*);
    try testing.expectEqual(@as(i32, 42), s.pop().?);
}

test "Stack: grows past initial capacity" {
    var s = try Stack(i32).init(testing.allocator, 1);
    defer s.allocator.free(s.items);

    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try s.push(i);
    }

    i = 99;
    while (i >= 0) : (i -= 1) {
        try testing.expectEqual(i, s.pop().?);
    }
    try testing.expectEqual(@as(?i32, null), s.pop());
}

test "Stack: empty/peek" {
    var s = try Stack(i32).init(testing.allocator, 4);
    defer s.allocator.free(s.items);

    try testing.expect(s.empty());
    try s.push(7);
    try testing.expect(!s.empty());
    try testing.expectEqual(@as(i32, 7), s.peek().*);
}

test "StaticRingStack: LIFO within capacity" {
    var s = StaticRingStack(i32, 4){};
    s.push(1);
    s.push(2);
    s.push(3);

    try testing.expectEqual(@as(?i32, 3), s.pop());
    try testing.expectEqual(@as(?i32, 2), s.pop());
    try testing.expectEqual(@as(?i32, 1), s.pop());
    try testing.expectEqual(@as(?i32, null), s.pop());
}

test "StaticRingStack: pushing past capacity overwrites oldest, size caps at Size" {
    var s = StaticRingStack(i32, 3){};
    s.push(1);
    s.push(2);
    s.push(3);
    s.push(4); // overwrites the slot 1 occupied

    try testing.expect(!s.empty());
    // Most recent 3 values survive, in LIFO order: 4, 3, 2.
    try testing.expectEqual(@as(?i32, 4), s.pop());
    try testing.expectEqual(@as(?i32, 3), s.pop());
    try testing.expectEqual(@as(?i32, 2), s.pop());
    try testing.expectEqual(@as(?i32, null), s.pop());
}

test "StaticRingStack: empty() reflects state" {
    var s = StaticRingStack(i32, 2){};
    try testing.expect(s.empty());
    s.push(1);
    try testing.expect(!s.empty());
}

