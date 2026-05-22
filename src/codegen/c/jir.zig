// @Note this JIR backend is fairly high level,
// it doesn't have low-level info about the stack
// indices etc since it passes all those problems
// to the C compiler. Keep in mind that such thing
// won't be the case for future backends.

const std = @import("std");
const common = @import("../../core/common.zig");
const defines = @import("../../core/defines.zig");
const collections = @import("../../util/collections.zig");
const Types = @import("../../typechecker/type.zig");

const Typechecker = @import("../../typechecker/typechecker.zig");
const MultiArrayList = @import("../../util/collections.zig").MultiArrayList;
const TypeID = Types.TypeID;
const Allocator = std.mem.Allocator;
const Error = common.CompilerError;

pub const InternTable = std.array_hash_map.String(void);

pub const Constants = []const Constant;

pub const Ptr = defines.Offset;

const Node = struct {
    pub const List = MultiArrayList(Node);

    pub const Type = enum {
        TypeDef, // ok
        FunctionDef, // ok
        VariableDef, // ok
        Assignment, // ok
        Store, // ok
        Reference, // StringPtr
        Dereference, // Ptr
        Call, // Ptr, []const Ptr
        Literal, // Constant.Ptr
        Add, // Ptr, Ptr
        Sub, // Ptr, Ptr
        Div, // Ptr, Ptr
        Mul, // Ptr, Ptr
        LeftShift, // Ptr
        RightShift, // Ptr
        And, // Ptr, Ptr
        Or, // Ptr, Ptr
        Label, // StringPtr
        /// To make use of ternary operator.
        Conditional, // Ptr, Ptr, Ptr
        Dot,
    };

    type: Type,
    value: defines.EitherPtr(Ptr, u32),
};

pub const Builder = struct {
    pub const StringPtr = defines.Offset;

    constants: std.MultiArrayList(Constant),
    functions: MultiArrayList(Function),
    nodes: Node.List,
    data: std.ArrayList(u32),
    allocator: Allocator,
    strings: InternTable,

    pub fn init(allocator: Allocator, counts: common.CompilerContext.Counts) Error!Builder {
        var strings = InternTable.empty;
        strings.ensureTotalCapacity(allocator, counts.string + counts.types * 4 + counts.functions)
            catch return Error.AllocatorFailure;

        return .{
            .nodes = try Node.List.init(allocator, counts.statements + counts.expressions),
            .data = std.ArrayList(u32).initCapacity(allocator, (counts.statements + counts.expressions) / 2)
                catch return Error.AllocatorFailure,
            .constants = std.MultiArrayList(Constant).initCapacity(allocator, counts.bool + counts.float + counts.integer + counts.string)
                catch return Error.AllocatorFailure,
            .functions = try MultiArrayList(Function).init(allocator, counts.functions),
            .strings = strings,
            .allocator = allocator,
        };
    }

    pub fn build(self: *const Builder, allocator: Allocator, types: Typechecker.TypeTable.Slice) Error!JIR {
        return collections.deepCopy(JIR{
            .types = types,
            .constants = self.constants.slice(),
            .functions = self.functions.slice(),
            .nodes = self.nodes.slice(),
            .data = self.data.items,
        }, allocator);
    }

    pub fn internString(self: *Builder, str: []const u8) Error!defines.StringPtr {
        const res = self.strings.getOrPutValue(self.allocator, str, {})
            catch return Error.AllocatorFailure;
        return @intCast(res.index);
    }

    pub fn getInternedString(self: *const Builder, index: defines.StringPtr)  []const u8 {
        return self.strings.keys()[index];
    }

    pub fn typeDef(self: *Builder, typeID: TypeID) Error!void {
        return self.nodes.append(self.allocator, .{
            .type = .TypeDef,
            .value = typeID,
        });
    }

    pub fn functionDef(self: *Builder, function: Function.Ptr) Error!void {
        return self.nodes.append(self.allocator, .{
            .type = .FunctionDef,
            .value = function,
        });
    }

    pub fn variableDef(self: *Builder, typeID: TypeID, initializer: ?Ptr) Error!void {
        const start: u32 = @intCast(self.data.items.len);
        self.data.append(self.allocator, typeID) catch return Error.AllocatorFailure;
        self.data.append(self.allocator, @intFromBool(initializer != null)) catch return Error.AllocatorFailure;
        if (initializer) |i| {
            self.data.append(self.allocator, i) catch return Error.AllocatorFailure;
        }
        return self.nodes.append(self.allocator, .{
            .type = .VariableDef,
            .value = start,
        });
    }

    pub fn assignment(self: *Builder, decl: StringPtr, expr: Ptr) Error!void {
        const start: u32 = @intCast(self.data.items.len);
        self.data.append(self.allocator, decl) catch return Error.AllocatorFailure;
        self.data.append(self.allocator, expr) catch return Error.AllocatorFailure;
        return self.nodes.append(self.allocator, .{
            .type = .Assignment,
            .value = start,
        });
    }

    pub fn store(self: *Builder, decl: Ptr, expr: Ptr) Error!void {
        const start: u32 = @intCast(self.data.items.len);
        self.data.append(self.allocator, decl) catch return Error.AllocatorFailure;
        self.data.append(self.allocator, expr) catch return Error.AllocatorFailure;
        return self.nodes.append(self.allocator, .{
            .type = .Store,
            .value = start,
        });
    }

    pub fn reference(self: *Builder, decl: StringPtr) Error!void {
        return self.nodes.append(self.allocator, .{
            .type = .Reference,
            .value = decl,
        });
    }

    pub fn dereference(self: *Builder, expr: Ptr) Error!void {
        return self.nodes.append(self.allocator, .{
            .type = .Dereference,
            .value = expr,
        });
    }

    pub fn call(self: *Builder, expr: Ptr, args: []const Ptr) Error!void {
        const start: u32 = @intCast(self.data.items.len);
        self.data.append(self.allocator, expr) catch return Error.AllocatorFailure;
        // arg count can be found from the resulting type of expr.
        self.data.appendSlice(self.allocator, args) catch return Error.AllocatorFailure;
        return self.nodes.append(self.allocator, .{
            .type = .Call,
            .value = start,
        });
    }

    pub fn literal(self: *Builder, constant: Constant.Ptr) Error!void {
        return self.nodes.append(self.allocator, .{
            .type = .Literal,
            .value = constant,
        });
    }
};
 
pub const Constant = union(enum) {
    pub const Ptr = defines.Offset;

    Integer: union(enum) {
        i32: i32,
        u32: u32,
        i8: i8,
        u8: u8,
    },
    Float: f32,
    Aggregate: struct {
        type: TypeID,
        data: []const Constant, // @Note we can refer with slice directly because
                                // indices won't change unlike the JIR nodes.
    }, 
    Array: struct {
        type: TypeID,
        data: []const Constant,
    },
    Undefined: TypeID,
    Function: Function.Ptr,
};

pub const Function = struct {
    pub const Ptr = defines.Offset;

    signature: TypeID,
    body: []const Function.Ptr,
};

const JIR = @This();

types: Typechecker.TypeTable.Slice,
constants: std.MultiArrayList(Constant).Slice,
functions: MultiArrayList(Function).Slice,
nodes: Node.List.Slice,
data: []const u32,
