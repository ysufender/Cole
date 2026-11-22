const std = @import("std");
const common = @import("../../../core/common.zig");
const defines = @import("../../../core/defines.zig");
const Types = @import("../../../typechecker/type.zig");
const collections = @import("../../../util/collections.zig");

const JIR = @import("../jir.zig");
const Typechecker = @import("../../../typechecker/typechecker.zig");
const MultiArrayList = @import("../../../util/collections.zig").MultiArrayList;
const Allocator = std.mem.Allocator;
const Error = common.CompilerError;
const TypeID = Types.TypeID;
const Declaration = @import("../../../typechecker/resolver.zig").Declaration;
const Comptime = @import("../../../typechecker/comptime.zig");

pub const InternTable = std.hash_map.StringHashMapUnmanaged(u32);
pub const InternArray = std.ArrayList([]const u8);
pub const StringPtr = defines.Offset;
pub const MetadataMap = collections.HashMap(JIR.Ptr, []const JIR.Constant.Ptr);

const Builder = @This();

constants: std.MultiArrayList(JIR.Constant),
typeToJirMap: collections.HashMap(TypeID, JIR.Ptr),
functions: MultiArrayList(JIR.Function),
functionCache: collections.HashMap(JIR.Ptr, JIR.Function.Ptr),
functionDefCache: collections.HashMap(JIR.Function.Ptr, void),
loweredBodies: collections.HashMap(defines.ScopePtr, void),
metadata: MetadataMap,
nodes: JIR.Node.List,
data: std.ArrayList(u32),
allocator: Allocator,
keyNodes: std.ArrayList(JIR.Ptr),
strings: InternTable,
stringList: InternArray,
topLevelAsms: std.ArrayList(defines.StringPtr),
typechecker: *Typechecker,

pub fn init(allocator: Allocator, counts: common.CompilerContext.Counts, typechecker: *Typechecker) Error!Builder {
    var strings = InternTable.empty;
    strings.ensureTotalCapacity(allocator, counts.string + counts.types * 4 + counts.functions)
        catch return Error.AllocatorFailure;

    var funcCache = collections.HashMap(JIR.Ptr, JIR.Function.Ptr).empty;
    funcCache.ensureTotalCapacity(allocator, counts.functions)
        catch return Error.AllocatorFailure;

    var functionDefCache = collections.HashMap(JIR.Function.Ptr, void).empty;
    functionDefCache.ensureTotalCapacity(allocator, counts.functions)
        catch return Error.AllocatorFailure;

    var loweredBodies = collections.HashMap(JIR.Function.Ptr, void).empty;
    loweredBodies.ensureTotalCapacity(allocator, counts.functions)
        catch return Error.AllocatorFailure;

    var metadata = MetadataMap.empty;
    metadata.ensureTotalCapacity(allocator, counts.meta * 3) catch return Error.AllocatorFailure;

    var typeToJirMap = collections.HashMap(TypeID, JIR.Ptr).empty;
    typeToJirMap.ensureTotalCapacity(allocator, counts.types) catch return Error.AllocatorFailure;

    return .{
        .nodes = try JIR.Node.List.init(allocator, counts.statements + counts.expressions),
        .keyNodes = std.ArrayList(JIR.Ptr).initCapacity(allocator, counts.statements + counts.expressions)
            catch return Error.AllocatorFailure,
        .data = std.ArrayList(u32).initCapacity(allocator, (counts.statements + counts.expressions) / 2)
            catch return Error.AllocatorFailure,
        .constants = std.MultiArrayList(JIR.Constant).initCapacity(allocator, counts.bool + counts.float + counts.integer + counts.string)
            catch return Error.AllocatorFailure,
        .functions = try MultiArrayList(JIR.Function).init(allocator, counts.functions),
        .topLevelAsms = try std.ArrayList(defines.StringPtr).initCapacity(allocator, 128),
        .functionCache = funcCache,
        .functionDefCache = functionDefCache,
        .loweredBodies = loweredBodies,
        .strings = strings,
        .allocator = allocator,
        .typechecker = typechecker,
        .typeToJirMap = typeToJirMap,
        .stringList = InternArray.initCapacity(allocator, counts.string + counts.types * 4 + counts.functions)
            catch return Error.AllocatorFailure,
        .metadata = metadata,
    };
}

pub fn build(self: *const Builder, allocator: Allocator) Error!JIR {
    return .{
        .types = try collections.deepCopy(self.typechecker.typeTable.slice(), allocator),
        .typeNames = try collections.deepCopy(self.typechecker.typenameMap, allocator),
        .strings = try collections.deepCopy(self.stringList.items, allocator),
        .constants = try collections.deepCopy(self.constants.slice(), allocator),
        .functions = try collections.deepCopy(self.functions.slice(), allocator),
        .nodes = try collections.deepCopy(self.nodes.slice(), allocator),
        .keyNodes = try collections.deepCopy(self.keyNodes.items, allocator),
        .data = try collections.deepCopy(self.data.items, allocator),
        .topLevelAsms = try collections.deepCopy(self.topLevelAsms.items, allocator),
        .context = self.typechecker.context,
        .metadata = self.metadata.clone(allocator) catch return Error.AllocatorFailure,
        .typeToJirMap = self.typeToJirMap.clone(allocator) catch return Error.AllocatorFailure,
    };
}

pub fn addFunction(self: *Builder, function: JIR.Function) Error!JIR.Function.Ptr {
    const ptr =
        if (self.functionCache.get(function.body)) |ptr| ptr 
        else try self.functions.addOne(self.allocator);

    self.functions.set(ptr, function);
    self.functionCache.put(self.allocator, function.body, ptr)
        catch return Error.AllocatorFailure;
    return ptr;
}

pub fn addConstant(self: *Builder, constant: JIR.Constant) Error!JIR.Constant.Ptr {
    const res = self.constants.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.constants.set(res, constant);
    return @intCast(res);
}

pub fn modifyInternedString(self: *Builder, strPtr: defines.StringPtr, new: []const u8) Error!void {
    _ = self.strings.remove(self.stringList.items[strPtr]);
    self.stringList.items[strPtr] = new;
    const gop = self.strings.getOrPut(self.allocator, new) catch return Error.AllocatorFailure;
    if (!gop.found_existing) gop.value_ptr.* = strPtr;
}

pub fn internString(self: *Builder, str: []const u8) Error!defines.StringPtr {
    const res = self.strings.getOrPut(self.allocator, str)
        catch return Error.AllocatorFailure;

    if (res.found_existing) {
        return res.value_ptr.*;
    }
    else {
        res.value_ptr.* = @intCast(self.stringList.items.len);
        self.stringList.append(self.allocator, str)
            catch return Error.AllocatorFailure;
        return @intCast(res.value_ptr.*);
    }
}

pub fn getInternedString(self: *const Builder, index: defines.StringPtr)  []const u8 {
    return self.stringList.items[index];
}

pub fn addMetadata(self: *Builder, node: JIR.Ptr, metadata: []const JIR.Constant.Ptr) Error!void {
    return self.metadata.put(self.allocator, node, metadata);
}

pub fn addKeyNode(self: *Builder, node: JIR.Ptr) Error!void {
    return self.keyNodes.append(self.allocator, node);
}

pub fn variableDef(
    self: *Builder,
    topLevel: bool,
    typeID: TypeID,
    name: defines.StringPtr,
    isUndefined: bool,
    initializer: JIR.Ptr,
    initExpr: ?defines.ExpressionPtr,
) Error!JIR.Ptr {
    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, @intFromBool(topLevel)) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, typeID) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, name) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intFromBool(isUndefined)) catch return Error.AllocatorFailure;
    if (!isUndefined) {
        self.data.append(self.allocator, initializer) catch return Error.AllocatorFailure;
    }

    const res = try self.nodes.addOne(self.allocator);

    if (initExpr) |expr| {
        try self.typechecker.lowerer.addMetadata(res, expr);
    }

    self.nodes.set(res, .{
        .type = .VariableDef,
        .value = start,
    });
    try self.addKeyNode(res);

    return res;
}

pub fn functionDef(self: *Builder, name: defines.StringPtr, function: JIR.Function.Ptr) Error!void {
    if (self.functionDefCache.contains(function)) {
        return;
    }

    self.functionDefCache.putNoClobber(self.allocator, function, {})
        catch return Error.AllocatorFailure;
    self.loweredBodies.putNoClobber(self.allocator, self.functions.get(function).scope, {})
        catch return Error.AllocatorFailure;
    const node = try self.commonBinary(.FunctionDef, name, function);
    try self.typechecker.lowerer.addMetadata(node, self.functions.get(function).expr);
    return self.addKeyNode(node);
}

pub fn typeDef(self: *Builder, typeID: TypeID) Error!JIR.Ptr {
    const typeInfo = self.typechecker.typeTable.get(typeID);

    const res = try self.commonSingle(.TypeDef, typeID);
    try self.addKeyNode(res);

    const typeExpr: ?defines.ExpressionPtr = switch (typeInfo) {
        .Struct => |str| str.expr,
        .Union => |uni| uni.expr,
        .Enum => |enm| enm.expr,
        else => null,
    };

    if (typeExpr) |expr| {
        try self.typechecker.lowerer.addMetadata(res, expr);
    }

    if (!self.typeToJirMap.contains(typeID)) {
        self.typeToJirMap.put(self.allocator, typeID, res)
            catch return Error.AllocatorFailure;
        const mutableType = try self.typechecker.registerType(self.typechecker.makeMutable(self.typechecker.typeTable.get(typeID)));
        self.typeToJirMap.put(self.allocator, mutableType, res)
            catch return Error.AllocatorFailure;
    }

    return res;
}

pub fn @"return"(self: *Builder, withRet: bool, expr: JIR.Ptr) Error!JIR.Ptr {
    const res = try self.commonBinary(.Return, @intFromBool(withRet), expr);
    return res;
}

pub fn assignment(self: *Builder, decl: JIR.Ptr, expr: JIR.Ptr) Error!JIR.Ptr {
    const res = try self.commonBinary(.Assignment, decl, expr);
    return res;
}

pub fn jump(self: *Builder, lbl: StringPtr) Error!JIR.Ptr { return self.commonSingle(.Jump, lbl); }
pub fn cjump(self: *Builder, lbl: StringPtr, cnd: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.JumpIf, lbl, cnd); }
pub fn exit(self: *Builder) Error!JIR.Ptr { return self.commonSingle(.Exit, 0); }

pub fn stmtExpr(self: *Builder, expr: JIR.Ptr, stmts: []const JIR.Ptr) Error!JIR.Ptr {
    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, expr) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intCast(stmts.len)) catch return Error.AllocatorFailure;
    self.data.appendSlice(self.allocator, stmts) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = .StatementExpr,
        .value = start,
    });
    return res;
}

pub fn scope(self: *Builder, name: defines.StringPtr, args: []const JIR.Ptr) Error!JIR.Ptr {
    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, name) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intCast(args.len)) catch return Error.AllocatorFailure;
    self.data.appendSlice(self.allocator, args) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = .Scope,
        .value = start,
    });
    return res;
}

pub fn construct(self: *Builder, typeID: TypeID, args: []const JIR.Ptr) Error!JIR.Ptr {
    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, typeID) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intCast(args.len)) catch return Error.AllocatorFailure;
    self.data.appendSlice(self.allocator, args) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = .Construction,
        .value = start,
    });
    return res;
}

pub fn identifier(self: *Builder, decl: defines.StringPtr, topLevelAndIsParam: u8, valueType: TypeID) Error!JIR.Ptr { return self.commonTernary(.Identifier, decl, topLevelAndIsParam, valueType); }
pub fn inlineCode(self: *Builder, code: defines.StringPtr) Error!JIR.Ptr { return self.commonSingle(.Code, code); }

pub fn discard(self: *Builder, expr: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Discard, expr); }

pub fn reference(self: *Builder, decl: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Reference, decl); }
pub fn literal(self: *Builder, constant: JIR.Constant.Ptr) Error!JIR.Ptr { return self.commonSingle(.Literal, constant); }
pub fn add(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Add, lhs, rhs); }
pub fn sub(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Sub, lhs, rhs); }
pub fn div(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Div, lhs, rhs); }
pub fn mul(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Mul, lhs, rhs); }
pub fn mod(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Mod, lhs, rhs); }
pub fn lshift(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.LeftShift, lhs, rhs); }
pub fn rshift(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.RightShift, lhs, rhs); }
pub fn @"and"(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.And, lhs, rhs); }
pub fn @"or"(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Or, lhs, rhs); }
pub fn label(self: *Builder, name: StringPtr) Error!JIR.Ptr { return self.commonSingle(.Label, name); }
pub fn lesser(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Lesser, lhs, rhs); }
pub fn lesserEqual(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.LesserEqual, lhs, rhs); }
pub fn greater(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Greater, lhs, rhs); }
pub fn greaterEqual(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.GreaterEqual, lhs, rhs); }
pub fn equal(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Equal, lhs, rhs); }
pub fn notEqual(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.NotEqual, lhs, rhs); }
pub fn invert(self: *Builder, expr: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Invert, expr); }
pub fn xor(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Xor, lhs, rhs); }
pub fn bitwiseOr(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.BitwiseOr, lhs, rhs); }
pub fn bitwiseAnd(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.BitwiseAnd, lhs, rhs); }
pub fn not(self: *Builder, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Not, rhs); }
pub fn negate(self: *Builder, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Negation, rhs); }

pub fn dot(self: *Builder, object: JIR.Ptr, field: StringPtr, objType: TypeID) Error!JIR.Ptr {
    if (self.typechecker.getFlag(.LValue) or self.nodes.get(object).type == .Identifier) {
        return self.commonBinary(.Dot,
            switch (self.typechecker.typeTable.get(objType)) {
                .Pointer => |ptr| switch (ptr.size) {
                    .Slice => object,
                    else => try self.dereference(object, objType),
                },
                else => object,
            },
            field
        );
    }

    const objName = try self.typechecker.folder.generateRandomName(.Obj);
    const objDef = try self.variableDef(false, objType, objName, false, object, null);
    const objIdent = try switch (self.typechecker.typeTable.get(objType)) {
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => self.identifier(objName, 0, objType),
            else => self.dereference(try self.identifier(objName, 0, objType), objType)
        },
        else => self.identifier(objName, 0, objType),
    };

    const access = try self.commonBinary(.Dot, objIdent, field);

    return switch (self.typechecker.typeTable.get(objType)) {
        .Union => self.stmtExpr(access, &.{objDef}),
        else => self.stmtExpr(access, &.{objDef}),
    };
}

pub fn dereference(self: *Builder, expr: JIR.Ptr, typeID: TypeID) Error!JIR.Ptr {
    return self.commonBinary(.Dereference, expr, typeID);
}

pub fn grouping(self: *Builder, args: []const JIR.Ptr) Error!JIR.Ptr {
    std.debug.assert(args.len <= 1);

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, @intCast(args.len)) catch return Error.AllocatorFailure;
    self.data.appendSlice(self.allocator, args) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = .Grouping,
        .value = start,
    });
    return res;
}

pub fn ternary(self: *Builder, cnd: JIR.Ptr, then: JIR.Ptr, otherwise: JIR.Ptr) Error!JIR.Ptr { return self.commonTernary(.Ternary, cnd, then, otherwise); }

pub fn call(self: *Builder, returnType: TypeID, stmt: bool, expr: JIR.Ptr, args: []const JIR.Ptr) Error!JIR.Ptr {
    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, returnType) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intFromBool(stmt)) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, expr) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intCast(args.len)) catch return Error.AllocatorFailure;
    self.data.appendSlice(self.allocator, args) catch return Error.AllocatorFailure;

    const res = self.nodes.addOne(self.allocator) catch return Error.AllocatorFailure;
    self.nodes.set(res, .{
        .type = .Call,
        .value = start,
    });
    return res;
}

fn commonTernary(
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

fn commonSingle(
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

fn commonBinary(
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
