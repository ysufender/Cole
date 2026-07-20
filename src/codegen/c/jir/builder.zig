const std = @import("std");
const common = @import("../../../core/common.zig");
const defines = @import("../../../core/defines.zig");
const Types = @import("../../../typechecker/type.zig");
const collections = @import("../../../util/collections.zig");

const JIR = @import("../jir.zig");
const Typechecker = @import("../../../typechecker/typechecker.zig");
const MultiArrayList = @import("../../../util/collections.zig").MultiArrayList;
const Allocator = std.mem.Allocator;
pub const InternTable = std.array_hash_map.String(void);
const Error = common.CompilerError;
const TypeID = Types.TypeID;
const Declaration = @import("../../../typechecker/resolver.zig").Declaration;

pub const StringPtr = defines.Offset;

const Builder = @This();

constants: std.MultiArrayList(JIR.Constant),
functions: MultiArrayList(JIR.Function),
nodes: JIR.Node.List,
data: std.ArrayList(u32),
allocator: Allocator,
keyNodes: std.ArrayList(JIR.Ptr),
strings: InternTable,

pub fn init(allocator: Allocator, counts: common.CompilerContext.Counts) Error!Builder {
    var strings = InternTable.empty;
    strings.ensureTotalCapacity(allocator, counts.string + counts.types * 4 + counts.functions)
        catch return Error.AllocatorFailure;

    return .{
        .nodes = try JIR.Node.List.init(allocator, counts.statements + counts.expressions),
        .keyNodes = std.ArrayList(JIR.Ptr).initCapacity(allocator, counts.statements + counts.expressions)
            catch return Error.AllocatorFailure,
        .data = std.ArrayList(u32).initCapacity(allocator, (counts.statements + counts.expressions) / 2)
            catch return Error.AllocatorFailure,
        .constants = std.MultiArrayList(JIR.Constant).initCapacity(allocator, counts.bool + counts.float + counts.integer + counts.string)
            catch return Error.AllocatorFailure,
        .functions = try MultiArrayList(JIR.Function).init(allocator, counts.functions),
        .strings = strings,
        .allocator = allocator,
    };
}

pub fn build(self: *const Builder, allocator: Allocator, typechecker: *const Typechecker) Error!JIR {
    return .{
        .types = try collections.deepCopy(typechecker.typeTable.slice(), allocator),
        .typeNames = try collections.deepCopy(typechecker.typenameMap, allocator),
        .strings = try collections.deepCopy(self.strings.keys(), allocator),
        .constants = try collections.deepCopy(self.constants.slice(), allocator),
        .functions = try collections.deepCopy(self.functions.slice(), allocator),
        .nodes = try collections.deepCopy(self.nodes.slice(), allocator),
        .keyNodes = try collections.deepCopy(self.keyNodes.items, allocator),
        .data = try collections.deepCopy(self.data.items, allocator),
        .context = typechecker.context,
    };
}

pub fn addFunction(self: *Builder, function: JIR.Function) Error!JIR.Function.Ptr {
    const res = try self.functions.addOne(self.allocator);
    self.functions.set(res, function);
    return res;
}

pub fn addConstant(self: *Builder, constant: JIR.Constant) Error!JIR.Constant.Ptr {
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

pub fn addKeyNode(self: *Builder, node: JIR.Ptr) Error!void {
    return self.keyNodes.append(self.allocator, node);
}

pub fn variableDef(
    self: *Builder,
    topLevel: bool,
    typeID: TypeID,
    decl: *const Declaration,
    initializer: JIR.Ptr,
    typechecker: *Typechecker,
) Error!JIR.Ptr {
    const isUndefined =
        if (typechecker.executer.attemptEval(decl.node, typeID)) |v|
            typechecker.executer.getValue(v) == .Undefined
        else false;

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, @intFromBool(topLevel)) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, typeID) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, decl.name) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intFromBool(isUndefined)) catch return Error.AllocatorFailure;
    if (!isUndefined) {
        self.data.append(self.allocator, initializer) catch return Error.AllocatorFailure;
    }

    const res = try self.nodes.addOne(self.allocator);
    self.nodes.set(res, .{
        .type = .VariableDef,
        .value = start,
    });
    try self.addKeyNode(res);
    return res;
}

pub inline fn functionDef(self: *Builder, name: defines.StringPtr, function: JIR.Function.Ptr) Error!void {
    const node = try self.commonBinary(.FunctionDef, name, function);
    return self.addKeyNode(node);
}

pub inline fn typeDef(self: *Builder, typeID: TypeID) Error!JIR.Ptr {
    const res = try self.commonSingle(.TypeDef, typeID);
    try self.addKeyNode(res);
    return res;
}

pub inline fn @"return"(self: *Builder, expr: JIR.Ptr) Error!JIR.Ptr {
    const res = try self.commonSingle(.Return, expr);
    return res;
}

pub inline fn assignment(self: *Builder, decl: JIR.Ptr, expr: JIR.Ptr) Error!JIR.Ptr {
    const res = try self.commonBinary(.Assignment, decl, expr);
    return res;
}

pub inline fn jump(self: *Builder, lbl: StringPtr) Error!JIR.Ptr { return self.commonSingle(.Jump, lbl); }
pub inline fn cjump(self: *Builder, lbl: StringPtr, cnd: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.JumpIf, lbl, cnd); }
pub inline fn exit(self: *Builder) Error!JIR.Ptr { return self.commonSingle(.Exit, 0); }
pub inline fn scope(self: *Builder, name: StringPtr) Error!JIR.Ptr { return self.commonSingle(.Scope, name); }

pub inline fn construct(self: *Builder, typeID: TypeID, start: JIR.Ptr, end: JIR.Ptr) Error!JIR.Ptr { return self.commonTernary(.Construction, typeID, start, end); }

pub inline fn identifier(self: *Builder, decl: defines.StringPtr) Error!JIR.Ptr { return self.commonSingle(.Identifier, decl); }

pub inline fn reference(self: *Builder, decl: StringPtr) Error!JIR.Ptr { return self.commonSingle(.Reference, decl); }
pub inline fn dereference(self: *Builder, expr: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Dereference, expr); }
pub inline fn literal(self: *Builder, constant: JIR.Constant.Ptr) Error!JIR.Ptr { return self.commonSingle(.Literal, constant); }
pub inline fn add(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Add, lhs, rhs); }
pub inline fn sub(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Sub, lhs, rhs); }
pub inline fn div(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Div, lhs, rhs); }
pub inline fn mul(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Mul, lhs, rhs); }
pub inline fn lshift(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.LeftShift, lhs, rhs); }
pub inline fn rshift(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.RightShift, lhs, rhs); }
pub inline fn @"and"(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.And, lhs, rhs); }
pub inline fn @"or"(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Or, lhs, rhs); }
pub inline fn label(self: *Builder, name: StringPtr) Error!JIR.Ptr { return self.commonSingle(.Label, name); }
pub inline fn dot(self: *Builder, object: JIR.Ptr, field: StringPtr) Error!JIR.Ptr { return self.commonBinary(.Dot, object, field); }
pub inline fn lesser(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Lesser, lhs, rhs); }
pub inline fn lesserEqual(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.LesserEqual, lhs, rhs); }
pub inline fn greater(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Greater, lhs, rhs); }
pub inline fn greaterEqual(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.GreaterEqual, lhs, rhs); }
pub inline fn equal(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Equal, lhs, rhs); }
pub inline fn notEqual(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.NotEqual, lhs, rhs); }
pub inline fn invert(self: *Builder, expr: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Invert, expr); }
pub inline fn xor(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Xor, lhs, rhs); }
pub inline fn bitwiseOr(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.BitwiseOr, lhs, rhs); }
pub inline fn bitwiseAnd(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.BitwiseAnd, lhs, rhs); }
pub inline fn not(self: *Builder, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Not, rhs); }
pub inline fn negate(self: *Builder, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Negation, rhs); }
pub inline fn grouping(self: *Builder, exprStart: JIR.Ptr, exprEnd: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Grouping, exprStart, exprEnd); }

pub inline fn ternary(self: *Builder, cnd: JIR.Ptr, then: JIR.Ptr, otherwise: JIR.Ptr) Error!JIR.Ptr { return self.commonTernary(.Ternary, cnd, then, otherwise); }
pub inline fn call(self: *Builder, expr: JIR.Ptr, args: defines.Range) Error!JIR.Ptr { return self.commonTernary(.Call, expr, args.start, args.end); }

inline fn commonTernary(
    self: *Builder,
    comptime nodeType: JIR.Node.Type,
    first: JIR.Ptr,
    second: JIR.Ptr,
    third: JIR.Ptr,
) Error!JIR.Ptr {
    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, first) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, second) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, third) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = nodeType,
        .value = start,
    });
    return res;
}

inline fn commonSingle(
    self: *Builder,
    comptime nodeType: JIR.Node.Type,
    expr: JIR.Ptr,
) Error!JIR.Ptr {
    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = nodeType,
        .value = expr,
    });
    return res;
}

inline fn commonBinary(
    self: *Builder,
    comptime nodeType: JIR.Node.Type,
    lhs: JIR.Ptr,
    rhs: JIR.Ptr
) Error!JIR.Ptr {
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
