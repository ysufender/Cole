const std = @import("std");

fn Context(comptime Key: type) type {
    return
        if (
            Key == []const u8
            or
            @typeInfo(Key) == .@"struct"
            or
            @typeInfo(Key) == .@"union"
        ) struct {
            const Self = @This();

            pub fn hash(_: Self, key: Key) u64 { 
                var hasher = std.hash.XxHash64.init(0);
                std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
                return hasher.final();
            }

            // TODO: A more performant equality function
            pub fn eql(self: Self, a: Key, b: Key) bool {
                return self.hash(a) == self.hash(b);
            }
        }
        else std.hash_map.AutoContext(Key);
}

pub fn HashMap(comptime Key: type, comptime Value: type) type {
    return std.hash_map.HashMapUnmanaged(Key, Value, Context(Key), std.hash_map.default_max_load_percentage);
}
