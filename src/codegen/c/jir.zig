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

pub const Ptr = defines.Offset;

const Node = struct {
    pub const List = MultiArrayList(Node);

    pub const Type = enum {
        TypeDef,
        FunctionDef,
        VariableDef,
        Identifier,
        Assignment, // Direct assignment to a variable.
        Store, // Assignment through pointer
        Return,
        Scope,
        Exit,
        Reference,
        Dereference,
        Call,
        Literal,
        Add,
        Sub,
        Div,
        Mul,
        LeftShift,
        RightShift,
        And,
        Or,
        Label,
        Dot,
        Grouping,
        Jump,
        JumpIf,
        Lesser,
        LesserEqual,
        Greater,
        GreaterEqual,
        Equal,
        NotEqual,
        Invert,
        Xor,
        BitwiseOr,
        BitwiseAnd,
        Not,
        Negation,
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

    pub fn addFunction(self: *Builder, function: Function) Error!Function.Ptr {
        const res = try self.functions.addOne(self.allocator);
        self.functions.set(res, function);
        return res;
    }

    pub fn addConstant(self: *Builder, constant: Constant) Error!Constant.Ptr {
        const res = self.constants.addOne(self.allocator) catch return Error.AllocatorFailure;
        self.constants.set(res, constant);
        return @intCast(res);
    }

    pub fn internString(self: *Builder, str: []const u8) Error!defines.StringPtr {
        const res = self.strings.getOrPutValue(self.allocator, str, {})
            catch return Error.AllocatorFailure;
        return @intCast(res.index);
    }

    pub inline fn getInternedString(self: *const Builder, index: defines.StringPtr)  []const u8 {
        return self.strings.keys()[index];
    }

    pub fn variableDef(self: *Builder, typeID: TypeID, initializer: Ptr) Error!void {
        const start: u32 = @intCast(self.data.items.len);
        self.data.append(self.allocator, typeID) catch return Error.AllocatorFailure;
        const initializerExpression = self.nodes.get(initializer).value;
        const isUndefined = self.constants.get(initializerExpression) == .Undefined;
        self.data.append(self.allocator, @intFromBool(isUndefined)) catch return Error.AllocatorFailure;

        if (!isUndefined) {
            self.data.append(self.allocator, initializer) catch return Error.AllocatorFailure;
        }

        return self.nodes.append(self.allocator, .{
            .type = .VariableDef,
            .value = start,
        });
    }

    pub inline fn functionDef(self: *Builder, function: Function.Ptr) Error!void { _ = try self.commonSingle(.FunctionDef, function); }
    pub inline fn typeDef(self: *Builder, typeID: TypeID) Error!void { _ = try self.commonSingle(.TypeDef, typeID); }

    pub inline fn jump(self: *Builder, lbl: StringPtr) Error!Ptr { return self.commonSingle(.Jump, lbl); }
    pub inline fn cjump(self: *Builder, lbl: StringPtr) Error!Ptr { return self.commonSingle(.JumpIf, lbl); }
    pub inline fn exit(self: *Builder) Error!Ptr { return self.commonSingle(.Scope, 0); }
    pub inline fn scope(self: *Builder, name: StringPtr) Error!Ptr { return self.commonSingle(.Scope, name); }
    pub inline fn @"return"(self: *Builder, expr: Ptr) Error!Ptr { return self.commonSingle(.Return, expr); }
    pub inline fn identifier(self: *Builder, decl: StringPtr) Error!Ptr { return self.commonSingle(.Identifier, decl); }
    pub inline fn assignment(self: *Builder, decl: StringPtr, expr: Ptr) Error!Ptr { return self.commonBinary(.Assignment, decl, expr); }
    pub inline fn store(self: *Builder, decl: Ptr, expr: Ptr) Error!Ptr { return self.commonBinary(.Store, decl, expr); }
    pub inline fn reference(self: *Builder, decl: StringPtr) Error!Ptr { return self.commonSingle(.Reference, decl); }
    pub inline fn dereference(self: *Builder, expr: Ptr) Error!Ptr { return self.commonSingle(.Dereference, expr); }
    pub inline fn call(self: *Builder, expr: Ptr, args: []const Ptr) Error!Ptr { return self.commonBinary(.Call, expr, args); }
    pub inline fn literal(self: *Builder, constant: Constant.Ptr) Error!Ptr { return self.commonSingle(.Literal, constant); }
    pub inline fn add(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.Add, lhs, rhs); }
    pub inline fn sub(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.Sub, lhs, rhs); }
    pub inline fn div(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.Div, lhs, rhs); }
    pub inline fn mul(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.Mul, lhs, rhs); }
    pub inline fn lshift(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.LeftShift, lhs, rhs); }
    pub inline fn rshift(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.RightShift, lhs, rhs); }
    pub inline fn @"and"(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.And, lhs, rhs); }
    pub inline fn @"or"(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.Or, lhs, rhs); }
    pub inline fn label(self: *Builder, name: StringPtr) Error!Ptr { return self.commonSingle(.Label, name); }
    pub inline fn dot(self: *Builder, object: Ptr, field: StringPtr) Error!Ptr { return self.commonBinary(.Dot, object, field); }
    pub inline fn grouping(self: *Builder, expr: Ptr) Error!Ptr { return self.commonSingle(.Grouping, expr); }
    pub inline fn lesser(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.Lesser, lhs, rhs); }
    pub inline fn lesserEqual(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.LesserEqual, lhs, rhs); }
    pub inline fn greater(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.Greater, lhs, rhs); }
    pub inline fn greaterEqual(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.GreaterEqual, lhs, rhs); }
    pub inline fn equal(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.Equal, lhs, rhs); }
    pub inline fn notEqual(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.NotEqual, lhs, rhs); }
    pub inline fn invert(self: *Builder, expr: Ptr) Error!Ptr { return self.commonSingle(.Invert, expr); }
    pub inline fn xor(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.Xor, lhs, rhs); }
    pub inline fn bitwiseOr(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.BitwiseOr, lhs, rhs); }
    pub inline fn bitwiseAnd(self: *Builder, lhs: Ptr, rhs: Ptr) Error!Ptr { return self.commonBinary(.BitwiseAnd, lhs, rhs); }
    pub inline fn not(self: *Builder, rhs: Ptr) Error!Ptr { return self.commonSingle(.Not, rhs); }
    pub inline fn negate(self: *Builder, rhs: Ptr) Error!Ptr { return self.commonSingle(.Negation, rhs); }

    inline fn commonSingle(
        self: *Builder,
        comptime nodeType: Node.Type,
        expr: Ptr,
    ) Error!Ptr {
        const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
        self.nodes.set(res, .{
            .type = nodeType,
            .value = expr,
        });
        return res;
    }

    inline fn commonBinary(
        self: *Builder,
        comptime nodeType: Node.Type,
        lhs: Ptr,
        rhs: Ptr
    ) Error!Ptr {
        const start: u32 = @intCast(self.data.items.len);
        self.data.append(self.allocator, lhs) catch return Error.AllocatorFailure;
        self.data.append(self.allocator, rhs) catch return Error.AllocatorFailure;

        const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
        self.nodes.set(res, .{
            .type = nodeType,
            .value = start,
        });
        return res;
    }
};
 
pub const Constant = union(enum) {
    pub const Ptr = defines.Offset;
    pub const List = std.MultiArrayList(Constant).Slice;

    const ConstantArray = struct {
        type: TypeID,
        data: defines.Range,
    };

    Integer: union(enum) {
        i32: i32,
        u32: u32,
        i8: i8,
        u8: u8,
    },
    Float: f32,
    Aggregate: ConstantArray, 
    Array: ConstantArray,
    Pointer: Constant.Ptr,
    Undefined: TypeID,
    Function: Function.Ptr,
};

pub const Function = struct {
    pub const Ptr = defines.Offset;
    pub const List = MultiArrayList(Function).Slice;

    signature: TypeID,
    body: defines.Range,
};

const JIR = @This();

types: Typechecker.TypeTable.Slice,
constants: Constant.List,
functions: Function.List,
nodes: Node.List.Slice,
data: []const u32,

pub fn dump(self: *const JIR) void {
    common.log.debug("Registered types:", .{});
    for (0..self.types.len) |index| {
        common.log.debug("    {d}", .{ index });
    }

    common.log.debug("Lowered IR:", .{});
    var iterator = self.nodes.iterator();
    while (iterator.next()) |node| {
        common.log.debug("{s}", .{@tagName(node.type)});
    }
}
