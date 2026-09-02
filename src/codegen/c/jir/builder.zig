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

pub const InternTable = std.array_hash_map.String(void);
pub const StringPtr = defines.Offset;
pub const MetadataMap = collections.HashMap(JIR.Ptr, []const JIR.Constant.Ptr);

const Builder = @This();

constants: std.MultiArrayList(JIR.Constant),
functions: MultiArrayList(JIR.Function),
functionCache: collections.HashMap(JIR.Ptr, JIR.Function.Ptr),
functionDefCache: collections.HashMap(JIR.Function.Ptr, void),
metadata: MetadataMap,
nodes: JIR.Node.List,
data: std.ArrayList(u32),
allocator: Allocator,
keyNodes: std.ArrayList(JIR.Ptr),
strings: InternTable,
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

    var metadata = MetadataMap.empty;
    metadata.ensureTotalCapacity(allocator, counts.meta * 3) catch return Error.AllocatorFailure;

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
        .strings = strings,
        .allocator = allocator,
        .typechecker = typechecker,
        .metadata = metadata,
    };
}

pub fn build(self: *const Builder, allocator: Allocator) Error!JIR {
    return .{
        .types = try collections.deepCopy(self.typechecker.typeTable.slice(), allocator),
        .typeNames = try collections.deepCopy(self.typechecker.typenameMap, allocator),
        .strings = try collections.deepCopy(self.strings.keys(), allocator),
        .constants = try collections.deepCopy(self.constants.slice(), allocator),
        .functions = try collections.deepCopy(self.functions.slice(), allocator),
        .nodes = try collections.deepCopy(self.nodes.slice(), allocator),
        .keyNodes = try collections.deepCopy(self.keyNodes.items, allocator),
        .data = try collections.deepCopy(self.data.items, allocator),
        .topLevelAsms = try collections.deepCopy(self.topLevelAsms.items, allocator),
        .context = self.typechecker.context,
        .metadata = self.metadata.clone(allocator) catch return Error.AllocatorFailure,
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

pub fn modifyInternedString(self: *Builder, strPtr: defines.StringPtr, new: []const u8) void {
    self.strings.keys()[strPtr] = new;
}

pub fn internString(self: *Builder, str: []const u8) Error!defines.StringPtr {
    const res = self.strings.getOrPutValue(self.allocator, str, {})
        catch return Error.AllocatorFailure;
    return @intCast(res.index);
}

pub inline fn getInternedString(self: *const Builder, index: defines.StringPtr)  []const u8 {
    return self.strings.keys()[index];
}

pub inline fn addMetadata(self: *Builder, node: JIR.Ptr, metadata: []const JIR.Constant.Ptr) Error!void {
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

pub inline fn functionDef(self: *Builder, name: defines.StringPtr, function: JIR.Function.Ptr) Error!void {
    if (self.functionDefCache.contains(function)) {
        return;
    }

    self.functionDefCache.putNoClobber(self.allocator, function, {})
        catch return Error.AllocatorFailure;
    const node = try self.commonBinary(.FunctionDef, name, function);
    try self.typechecker.lowerer.addMetadata(node, self.functions.get(function).expr);
    return self.addKeyNode(node);
}

pub inline fn typeDef(self: *Builder, typeID: TypeID) Error!JIR.Ptr {
    const typeInfo = self.typechecker.typeTable.get(typeID);

    const res = try self.commonSingle(.TypeDef, typeID);
    try self.addKeyNode(res);

    const _expr: ?*defines.ExpressionPtr = switch (typeInfo) {
        .Struct => &self.typechecker.typeTable.items(.data)[typeID].Struct.expr,
        .Union => &self.typechecker.typeTable.items(.data)[typeID].Union.expr,
        .Enum => &self.typechecker.typeTable.items(.data)[typeID].Enum.expr,
        else => null,
    };

    if (_expr) |expr| {
        try self.typechecker.lowerer.addMetadata(res, expr.*);
        expr.* = res;
    }

    return res;
}

pub inline fn @"return"(self: *Builder, withRet: bool, expr: JIR.Ptr) Error!JIR.Ptr {
    const res = try self.commonBinary(.Return, @intFromBool(withRet), expr);
    return res;
}

pub inline fn assignment(self: *Builder, decl: JIR.Ptr, expr: JIR.Ptr) Error!JIR.Ptr {
    const res = try self.commonBinary(.Assignment, decl, expr);
    return res;
}

pub inline fn jump(self: *Builder, lbl: StringPtr) Error!JIR.Ptr { return self.commonSingle(.Jump, lbl); }
pub inline fn cjump(self: *Builder, lbl: StringPtr, cnd: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.JumpIf, lbl, cnd); }
pub inline fn exit(self: *Builder) Error!JIR.Ptr { return self.commonSingle(.Exit, 0); }

pub inline fn stmtExpr(self: *Builder, expr: JIR.Ptr, stmts: []const JIR.Ptr) Error!JIR.Ptr {
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

pub inline fn scope(self: *Builder, name: defines.StringPtr, args: []const JIR.Ptr) Error!JIR.Ptr {
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

pub inline fn construct(self: *Builder, typeID: TypeID, args: []const JIR.Ptr) Error!JIR.Ptr {
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

pub inline fn identifier(self: *Builder, decl: defines.StringPtr) Error!JIR.Ptr { return self.commonSingle(.Identifier, decl); }
pub inline fn inlineC(self: *Builder, code: defines.StringPtr) Error!JIR.Ptr { return self.commonSingle(.Code, code); }

pub inline fn discard(self: *Builder, expr: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Discard, expr); }

pub inline fn reference(self: *Builder, decl: JIR.Ptr) Error!JIR.Ptr { return self.commonSingle(.Reference, decl); }
pub inline fn literal(self: *Builder, constant: JIR.Constant.Ptr) Error!JIR.Ptr { return self.commonSingle(.Literal, constant); }
pub inline fn add(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Add, lhs, rhs); }
pub inline fn sub(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Sub, lhs, rhs); }
pub inline fn div(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Div, lhs, rhs); }
pub inline fn mul(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Mul, lhs, rhs); }
pub inline fn mod(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Mod, lhs, rhs); }
pub inline fn lshift(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.LeftShift, lhs, rhs); }
pub inline fn rshift(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.RightShift, lhs, rhs); }
pub inline fn @"and"(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.And, lhs, rhs); }
pub inline fn @"or"(self: *Builder, lhs: JIR.Ptr, rhs: JIR.Ptr) Error!JIR.Ptr { return self.commonBinary(.Or, lhs, rhs); }
pub inline fn label(self: *Builder, name: StringPtr) Error!JIR.Ptr { return self.commonSingle(.Label, name); }
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

pub fn dot(self: *Builder, object: JIR.Ptr, field: StringPtr, objType: TypeID) Error!JIR.Ptr {
    const objName = try self.typechecker.folder.generateRandomName(.Obj);
    const objDef = try self.variableDef(false, objType, objName, false, object, null);
    const objIdent = try self.identifier(objName);

    const access = try self.commonBinary(.Dot, objIdent, field);

    return switch (self.typechecker.typeTable.get(objType)) {
        .Union => |uni|
            if (self.typechecker.context.settings.buildInfo.isDebug and field != try self.internString("tag")) {
                const fieldIndex = try self.typechecker.fieldIndex(objType, field);
                const tagVal = try self.addConstant(.{ .Integer = .{ .u32 = fieldIndex } });
                const tag = try self.dot(objIdent, try self.internString("tag"), objType);
                const okLabelName = try self.typechecker.folder.generateRandomName(.UnionSafety);
                const cnd = try self.equal(tag, try self.literal(try self.addConstant(.{
                    .Aggregate = .{
                        .type = uni.tag,
                        .data = .{
                            .start = tagVal,
                            .end = tagVal + 1,
                        },
                    }
                })));
                const safetyCheck = try self.cjump(okLabelName, cnd);
                const segfault = try self.typechecker.builder.inlineC(
                    try self.internString(
                        std.fmt.allocPrint(self.allocator, "__union_access__: __union_access((long)&&__union_access__, \"{s}\");", .{
                            self.getInternedString(uni.fields[fieldIndex].name),
                        }) catch return Error.AllocatorFailure,
                    ),
                );
                const okLabel = try self.label(okLabelName);

                return self.stmtExpr(access, &.{
                    objDef,
                    safetyCheck,
                    segfault,
                    okLabel,
                });
            }
            else self.stmtExpr(access, &.{objDef}),
        else => self.stmtExpr(access, &.{objDef}),
    };
}

pub inline fn dereference(self: *Builder, expr: JIR.Ptr, exprType: TypeID) Error!JIR.Ptr {
    if (self.typechecker.context.settings.buildInfo.isDebug) {
        const ptrName = try self.typechecker.folder.generateRandomName(.Ptr);
        const ptrDef = try self.variableDef(false, exprType, ptrName, false, expr, null);
        const ptrIdent = try self.identifier(ptrName);

        const nullPtr = try self.literal(try self.addConstant(.{ .Undefined = exprType, }));

        const safeLabelName = try self.typechecker.folder.generateRandomName(.Safe);
        const cnd = try self.notEqual(ptrIdent, nullPtr);
        const safetyCheck = try self.cjump(safeLabelName, cnd);

        const segfault = try self.typechecker.lowerer.handler("__null_deref");

        const safeLabel = try self.label(safeLabelName);

        const deref = try self.commonSingle(.Dereference, ptrIdent);

        return self.stmtExpr(deref, &.{
            ptrDef,
            safetyCheck,
            segfault,
            safeLabel
        });
    }
    else {
        return self.commonSingle(.Dereference, expr);
    }
}

pub inline fn grouping(self: *Builder, args: []const JIR.Ptr) Error!JIR.Ptr {
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

pub inline fn ternary(self: *Builder, cnd: JIR.Ptr, then: JIR.Ptr, otherwise: JIR.Ptr) Error!JIR.Ptr { return self.commonTernary(.Ternary, cnd, then, otherwise); }

pub inline fn call(self: *Builder, stmt: bool, expr: JIR.Ptr, args: []const JIR.Ptr) Error!JIR.Ptr {
    const start: u32 = @intCast(self.data.items.len);
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
