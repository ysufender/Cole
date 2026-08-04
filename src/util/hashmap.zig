const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;

fn Context(comptime Key: type) type {
    return
        if (
            Key == []const u8
            or
            @typeInfo(Key) == .@"struct"
            or
            @typeInfo(Key) == .@"union"
        ) struct {
            pub fn hash(_: @This(), key: Key) u64 { 
                var hasher = std.hash.XxHash64.init(0);
                std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
                return hasher.final();
            }

            // TODO: A more performant equality function
            pub fn eql(_: @This(), a: Key, b: Key) bool {
                var hasher = std.hash.XxHash64.init(0);
                std.hash.autoHashStrat(&hasher, a, .DeepRecursive);
                const first = hasher.final();

                hasher = std.hash.XxHash64.init(0);
                std.hash.autoHashStrat(&hasher, b, .DeepRecursive);
                const second = hasher.final();

                return first == second;
            }
        }
        else std.hash_map.AutoContext(Key);
}

pub fn HashMap(comptime Key: type, comptime Value: type) type {
    return std.hash_map.HashMapUnmanaged(Key, Value, Context(Key), std.hash_map.default_max_load_percentage);
}

pub fn HashMapCustom(comptime Key: type, comptime Value: type, comptime _eql: *fn (*anyopaque, Key, Key) bool) type {
    const Ctx = struct {
        context: *anyopaque,

        pub fn hash(_: @This(), key: Key) u64 { 
            var hasher = std.hash.XxHash64.init(0);
            std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(self: @This(), a: Key, b: Key) bool {
            return _eql(self.context, a, b);
        }
    };

    return struct {
        const Self = @This();
        const HM = std.hash_map.HashMapUnmanaged(Key, Value, Ctx, std.hash_map.default_max_load_percentage);

        ctx: Ctx,
        hm: HM,
        allocator: std.mem.Allocator,

        pub fn init(context: *anyopaque, allocator: std.mem.ALlocator, cap: u32) Error!Self {
            var hm = HM.empty;
            hm.ensureTotalCapacity(allocator, cap) catch return Error.AllocatorFailure;

            return .{
                .ctx = .{ .context = context },
                .hm = hm,
                .allocator = allocator,
            };
        }

        pub fn get(self: *Self, key: Key) ?Value {
            return self.hm.getContext(key, self.ctx);
        }

        pub fn put(self: *Self, key: Key, val: Value) Error!void {
            return self.hm.putContext(key, val, self.ctx);
        }
    };
}
