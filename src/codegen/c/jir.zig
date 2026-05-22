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
        Reference, // ok
        Dereference, // ok
        Call, // ok
        Literal, // ok
        Add, // ok
        Sub, // ok
        Div, // ok
        Mul, // ok
        LeftShift, // ok
        RightShift, // ok
        And, // ok
        Or, // ok
        Label, // ok
        Dot, // ok
        Grouping, // ok
        Goto, // ok
        Lesser, // ok
        LesserEqual, // ok
        Greater, // ok
        GreaterEqual, // ok
        Equal, // ok
        NotEqual, // ok
        Invert, // ok
        Xor, // ok
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

    pub inline fn getInternedString(self: *const Builder, index: defines.StringPtr)  []const u8 { return self.strings.keys()[index]; }
    pub inline fn typeDef(self: *Builder, typeID: TypeID) Error!void { return self.commonSingle(.TypeDef, typeID); }
    pub inline fn functionDef(self: *Builder, function: Function.Ptr) Error!void { return self.commonSingle(.FunctionDef, function); }
    pub inline fn assignment(self: *Builder, decl: StringPtr, expr: Ptr) Error!void { return self.commonBinary(.Assignment, decl, expr); }
    pub inline fn store(self: *Builder, decl: Ptr, expr: Ptr) Error!void { return self.commonBinary(.Store, decl, expr); }
    pub inline fn reference(self: *Builder, decl: StringPtr) Error!void { return self.commonSingle(.Reference, decl); }
    pub inline fn dereference(self: *Builder, expr: Ptr) Error!void { return self.commonSingle(.Dereference, expr); }
    pub inline fn call(self: *Builder, expr: Ptr, args: []const Ptr) Error!void { return self.commonBinary(.Call, expr, args); }
    pub inline fn literal(self: *Builder, constant: Constant.Ptr) Error!void { return self.commonSingle(.Literal, constant); }
    pub inline fn add(self: *Builder, lhs: Ptr, rhs: Ptr) Error!void { return self.commonBinary(.Add, lhs, rhs); }
    pub inline fn sub(self: *Builder, lhs: Ptr, rhs: Ptr) Error!void { return self.commonBinary(.Sub, lhs, rhs); }
    pub inline fn div(self: *Builder, lhs: Ptr, rhs: Ptr) Error!void { return self.commonBinary(.Div, lhs, rhs); }
    pub inline fn mul(self: *Builder, lhs: Ptr, rhs: Ptr) Error!void { return self.commonBinary(.Mul, lhs, rhs); }
    pub inline fn lshift(self: *Builder, lhs: Ptr, rhs: Ptr) Error!void { return self.commonBinary(.LeftShift, lhs, rhs); }
    pub inline fn rshift(self: *Builder, lhs: Ptr, rhs: Ptr) Error!void { return self.commonBinary(.RightShift, lhs, rhs); }
    pub inline fn @"and"(self: *Builder, lhs: Ptr, rhs: Ptr) Error!void { return self.commonBinary(.And, lhs, rhs); }
    pub inline fn @"or"(self: *Builder, lhs: Ptr, rhs: Ptr) Error!void { return self.commonBinary(.Or, lhs, rhs); }
    pub inline fn label(self: *Builder, name: StringPtr) Error!void { return self.commonSingle(.Label, name); }
    pub inline fn dot(self: *Builder, object: Ptr, field: StringPtr) Error!void { return self.commonBinary(.Dot, object, field); }
    pub inline fn grouping(self: *Builder, expr: Ptr) Error!void { return self.commonSingle(.Grouping, expr); }
    pub inline fn lesser(self: *Builder, lhs: Ptr, rhs: StringPtr) Error!void { return self.commonBinary(.Dot, lhs, rhs); }
    pub inline fn lesserEqual(self: *Builder, lhs: Ptr, rhs: StringPtr) Error!void { return self.commonBinary(.Dot, lhs, rhs); }
    pub inline fn greater(self: *Builder, lhs: Ptr, rhs: StringPtr) Error!void { return self.commonBinary(.Dot, lhs, rhs); }
    pub inline fn greaterEqual(self: *Builder, lhs: Ptr, rhs: StringPtr) Error!void { return self.commonBinary(.Dot, lhs, rhs); }
    pub inline fn equal(self: *Builder, lhs: Ptr, rhs: StringPtr) Error!void { return self.commonBinary(.Dot, lhs, rhs); }
    pub inline fn notEqual(self: *Builder, lhs: Ptr, rhs: StringPtr) Error!void { return self.commonBinary(.Dot, lhs, rhs); }
    pub inline fn invert(self: *Builder, expr: Ptr) Error!void { return self.commonSingle(.Grouping, expr); }
    pub inline fn xor(self: *Builder, lhs: Ptr, rhs: StringPtr) Error!void { return self.commonBinary(.Dot, lhs, rhs); }

    inline fn commonSingle(
        self: *Builder,
        comptime nodeType: Node.Type,
        expr: Ptr,
    ) Error!void {
        return self.nodes.append(self.allocator, .{
            .type = nodeType,
            .value = expr,
        });
    }

    inline fn commonBinary(
        self: *Builder,
        comptime nodeType: Node.Type,
        lhs: Ptr,
        rhs: Ptr
    ) Error!void {
        const start: u32 = @intCast(self.data.items.len);
        self.data.append(self.allocator, lhs) catch return Error.AllocatorFailure;
        self.data.append(self.allocator, rhs) catch return Error.AllocatorFailure;
        return self.nodes.append(self.allocator, .{
            .type = nodeType,
            .value = start,
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
