const std = @import("std");
const common = @import("../core/common.zig");
const prepass = @import("prepass.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");

const Module = prepass.Module;
const ModuleList = prepass.ModuleList;
const Context = common.CompilerContext;
const Error = common.CompilerError;
const Level = std.ArrayList(Graph.Node);
const LevelList = []const Level;

/// Does not resolve circular dependencies, such dependencies
/// should be handled in typechecking by waiting for dependencies
/// to be handle e.g. marking unknowns as waiting/resolved etc..
pub const Graph = struct {
    pub const Node = struct {
        name: []const u8,
        depends: []const defines.Offset,

        pub fn dupe(self: *const Node, allocator: std.mem.Allocator) Error!Node {
            return .{
                .name = self.name,
                .depends = try collections.deepCopy(self.depends, allocator),
            };
        }
    };

    pub const Iterator = struct {
        const Frame = struct {
            idx: u32,
            depIndex: u32,
        };

        const NodeState = enum(u8) {
            unvisited,
            visiting,
            visited,
        };

        nodes: []const Node,
        stack: []Frame,
        states: []NodeState,
        
        sp: usize,
        nextRoot: u32,

        pub fn init(nodes: []const Node, allocator: std.mem.Allocator) !Iterator {
            const stack = try allocator.alloc(Frame, nodes.len);
            errdefer allocator.free(stack);

            const states = try allocator.alloc(NodeState, nodes.len);
            @memset(states, .unvisited);

            return .{
                .nodes = nodes,
                .stack = stack,
                .states = states,
                .sp = 0,
                .nextRoot = 0,
            };
        }

        pub fn next(self: *Iterator) ?Node {
            while (true) {
                if (self.sp == 0) {
                    while (self.nextRoot < self.nodes.len and self.states[self.nextRoot] != .unvisited) {
                        self.nextRoot += 1;
                    }

                    if (self.nextRoot >= self.nodes.len) {
                        return null;
                    }

                    self.stack[self.sp] = .{ .idx = self.nextRoot, .depIndex = 0 };
                    self.states[self.nextRoot] = .visiting;
                    self.sp += 1;
                    self.nextRoot += 1;
                    continue;
                }

                var top = &self.stack[self.sp - 1];
                const node = self.nodes[top.idx];

                if (top.depIndex < node.depends.len) {
                    const dep = node.depends[top.depIndex];
                    top.depIndex += 1;

                    if (self.states[dep] == .unvisited) {
                        self.stack[self.sp] = .{ .idx = dep, .depIndex = 0 };
                        self.states[dep] = .visiting;
                        self.sp += 1;
                    }
                    
                    continue;
                }

                self.states[top.idx] = .visited;
                self.sp -= 1;

                return node;
            }
        }

        pub fn exhaust(self: *Iterator, allocator: std.mem.Allocator) Error![]Node {
            var items = allocator.alloc(Node, self.nodes.len) catch return error.AllocatorFailure;
            var count: usize = 0;

            while (self.next()) |item| {
                items[count] = item;
                count += 1;
            }

            return items;
        }
    };

    nodes: []Node,

    pub fn init(allocator: std.mem.Allocator, size: u32) Error!Graph {
        return .{
            .nodes = allocator.alloc(Node, size) catch return error.AllocatorFailure,
        };
    }

    pub fn iterator(self: *const Graph, allocator: std.mem.Allocator) Error!Iterator {
        return Iterator.init(self.nodes, allocator);
    }
};

const Self = @This();

modules: *const ModuleList,
context: *Context,
arena: std.heap.ArenaAllocator,
resolved: std.array_hash_map.String(defines.Offset),

pub fn init(context: *Context, modules: *const ModuleList) Self {
    return .{
        .context = context,
        .modules = modules,
        .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator),
        .resolved = .empty,
    };
}

pub fn generate(self: *Self, owner: std.mem.Allocator) Error!Graph {
    defer self.arena.deinit();

    const allocator = self.arena.allocator();

    self.resolved.ensureTotalCapacity(allocator, self.modules.modules.len) catch return error.AllocatorFailure;

    var graph = try Graph.init(allocator, self.modules.modules.len);

    for (1..self.modules.modules.len) |i| {
        _ = try self.generateNode(@intCast(i), &graph);
    }

    return collections.deepCopy(graph, owner);
}

fn generateNode(self: *Self, moduleIndex: u32, graph: *Graph) Error!u32 {
    const allocator = self.arena.allocator();

    const name = self.modules.modules.items(.name)[moduleIndex];

    if (self.resolved.get(name)) |node| {
        return node;
    }

    const dependencies = self.modules.modules.items(.dependencies)[moduleIndex].items;

    var depends = allocator.alloc(defines.Offset, dependencies.len) catch return error.AllocatorFailure;
    const idx = self.resolved.size;
    self.resolved.putAssumeCapacityNoClobber(name, idx);

    for (dependencies, 0..) |dependency, i| {
        depends[i] = try self.generateNode(self.modules.ids.get(dependency).?, graph);
    }

    graph.nodes[idx] = .{
        .name = name,
        .depends = depends,
    };
    return idx;
}
