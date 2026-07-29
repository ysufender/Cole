const std = @import("std");
const builtin = @import("builtin");

const platform = @import("../core/platform.zig");
const common = @import("../core/common.zig");

const mimalloc = @cImport(
    @cInclude("mimalloc-2.4/mimalloc.h"),
);

const mem = std.mem;
const posix = std.posix;
const windows = std.os.windows;

const Alignment = std.mem.Alignment;

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

pub fn init() std.mem.Allocator {
    return .{
        .ptr = @ptrCast(mimalloc.mi_heap_new()),
        .vtable = &vtable,
    };
}

pub fn alloc(self: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    return @ptrCast(mimalloc.mi_heap_malloc_aligned(@ptrCast(self), len, alignment.toByteUnits()));
}

pub fn resize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    return mimalloc.mi_usable_size(memory.ptr) >= new_len;
}

pub fn remap(self: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
    return @ptrCast(mimalloc.mi_heap_realloc_aligned(@ptrCast(self), memory.ptr, new_len, alignment.toByteUnits()));
}

pub fn free(_: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    mimalloc.mi_free_aligned(memory.ptr, alignment.toByteUnits());
}
