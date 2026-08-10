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
            const Self = @This();

            pub fn hash(_: Self, key: Key) u64 { 
                var hasher = std.hash.XxHash64.init(0);
                std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
                return hasher.final();
            }

            pub fn eql(_: Self, a: Key, b: Key) bool {
                return deepEql(Key, a, b);
            }

            fn deepEql(comptime T: type, a: T, b: T) bool {
                return switch (@typeInfo(T)) {
                    .@"struct" => |s| blk: {
                        inline for (s.fields) |f| {
                            if (!deepEql(f.type, @field(a, f.name), @field(b, f.name))) break :blk false;
                        }
                        break :blk true;
                    },
                    .pointer => |p| switch (p.size) {
                        .slice => blk: {
                            if (a.len != b.len) break :blk false;
                            for (a, b) |ea, eb| {
                                if (!deepEql(p.child, ea, eb)) break :blk false;
                            }
                            break :blk true;
                        },
                        else => a == b,
                    },
                    .optional => |o| blk: {
                        if ((a == null) != (b == null)) break :blk false;
                        return if (a == null) true else deepEql(o.child, a.?, b.?);
                    },
                    .@"union" => |u| blk: {
                        if (u.tag_type == null) break :blk std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)); const Tag = u.tag_type.?;
                        const ta: Tag = a;
                        if (ta != @as(Tag, b)) break :blk false;
                        inline for (u.fields) |f| {
                            if (ta == @field(Tag, f.name)) {
                                break :blk deepEql(f.type, @field(a, f.name), @field(b, f.name));
                            }
                        }
                        break :blk false;
                    },
                    else => a == b,
                };
            }
        }
        else std.hash_map.AutoContext(Key);
}

pub fn HashMap(comptime Key: type, comptime Value: type) type {
    return std.hash_map.HashMapUnmanaged(Key, Value, Context(Key), std.hash_map.default_max_load_percentage);
}

pub fn HashMapCustom(comptime Key: type, comptime Value: type, comptime _eql: *const fn (*anyopaque, Key, Key) bool) type {
    const Ctx = struct {
        context: *anyopaque,

        pub fn hash(_: @This(), key: Key) u64 { 
            var hasher = std.hash.SipHash64(2, 4).init(@ptrCast(&key));
            std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
            return hasher.finalInt();
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

        pub fn init(context: *anyopaque, allocator: std.mem.Allocator, cap: u32) Error!Self {
            var hm = HM.empty;
            hm.ensureTotalCapacityContext(allocator, cap, .{ .context = context }) catch return Error.AllocatorFailure;

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
            return self.hm.putContext(self.allocator, key, val, self.ctx);
        }

        pub fn remove(self: *Self, key: Key) bool {
            return self.hm.removeContext(key, self.ctx);
        }
    };
}
