const std = @import("std");
const common = @import("../../../core/common.zig");
const collections = @import("../../../util/collections.zig");
const defines = @import("../../../core/defines.zig");

const Comptime = @import("../../../typechecker/comptime.zig");
const Allocator = std.mem.Allocator;
const Error = common.CompilerError;
const TypeID = @import("../../../typechecker/type.zig").TypeID;
const TypeInfo = @import("../../../typechecker/type.zig").TypeInfo;
const Typechecker = @import("../../../typechecker/typechecker.zig");

const JIR = @import("../../backend.zig").C.JIR;
const JAIR = @import("../jair.zig");

pub const TypeTable = std.MultiArrayList(JAIR.Type);

const Builder = @This();

jir: JIR.Base,
renamedStringMap: std.bit_set.Dynamic,
nodes: JAIR.Node.List,
typeTable: TypeTable,
typeMap: collections.HashMap(TypeID, TypeID),
keyNodes: std.ArrayList(JAIR.Ptr),
data: std.ArrayList(u32),
allocator: Allocator,
typechecker: *Typechecker,

pub fn fromJIR(jir: JIR.Base, allocator: Allocator, typechecker: *Typechecker) Error!Builder {
    var typeMap = collections.HashMap(TypeID, TypeID).empty;
    typeMap.ensureTotalCapacity(allocator, @intCast(jir.types.len)) catch return Error.AllocatorFailure;

    return .{
        .jir = jir,
        .nodes = try JAIR.Node.List.init(allocator, jir.nodes.len),
        .keyNodes = std.ArrayList(JAIR.Ptr).initCapacity(allocator, jir.keyNodes.len)
            catch return Error.AllocatorFailure,
        .data = std.ArrayList(u32).initCapacity(allocator, jir.data.len)
            catch return Error.AllocatorFailure,
        .typeTable = TypeTable.initCapacity(allocator, jir.types.len)
            catch return Error.AllocatorFailure,
        .typeMap = typeMap,
        .renamedStringMap = std.bit_set.Dynamic.initEmpty(allocator, jir.strings.len)
            catch return Error.AllocatorFailure,
        .allocator = allocator,
        .typechecker = typechecker,
    };
}

pub fn build(self: *Builder) Error!JAIR {
    for (self.jir.strings) |str| {
        _ = std.mem.replace(u8, str, "::", "__", @constCast(str));
    }

    for (0..self.jir.types.len) |id| {
        _ = try self.typeName(@intCast(id));
        _ = try self.convertType(@intCast(id));
    }

    for (self.jir.keyNodes) |nodePtr| {
        const node = self.jir.nodes.get(nodePtr);

        // @TODO Continue from here.
        _ = try self.createJAIR(node);
    }

    return JAIR{
        .typeTable = self.typeTable.toOwnedSlice(),
        .data = self.data.items,
        .strings = self.jir.strings,
        .nodes = self.nodes.toOwnedSlice(),
        .keyNodes = self.keyNodes.toOwnedSlice(self.allocator) catch return Error.AllocatorFailure,
        .typeNames = self.jir.typeNames,
    };
}

fn functionDef(self: *Builder, fptr: JIR.Ptr) Error!JAIR.Ptr {
    const function = self.jir.functions.get(self.jir.data[self.jir.nodes.get(fptr).value + 1]);
    const signature = self.jir.types.get(function.signature).Function;

    const start: u32 = @intCast(self.data.items.len);
    self.data.append(self.allocator, if (self.jir.hasMetadata(fptr, "@export")) 1 else 0) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, function.name) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, try self.convertType(signature.returnType)) catch return Error.AllocatorFailure;
    self.data.append(self.allocator, @intCast(signature.argTypes.len)) catch return Error.AllocatorFailure;
    for (signature.argTypes, function.args) |argType, argName| {
        self.data.append(self.allocator, try self.convertType(argType)) catch return Error.AllocatorFailure;
        self.data.append(self.allocator, argName) catch return Error.AllocatorFailure;
    }

    const nodePtr = try self.nodes.addOne(self.allocator);
    self.nodes.set(nodePtr, .{
        .type = .FunctionDef,
        .value = start,
    });
    self.keyNodes.append(self.allocator, nodePtr) catch return Error.AllocatorFailure;
    return nodePtr;
}

fn typeName(self: *Builder, id: TypeID) Error!defines.StringPtr {
    const name = self.jir.typeNames.get(id).?;

    if (self.renamedStringMap.isSet(name)) {
        return name;
    }

    const newName = newName: switch (self.jir.types.get(id)) {
        .Noreturn, .Any, .Type, .EnumLiteral, .ComptimeInt, .ComptimeFloat => "",
        .Void => |mut| if (mut) "mut_void" else "void",
        .Bool => |mut| if (mut) "mut_bool" else "bool",
        .CChar => |mut| if (mut) "mut_c_char" else "c_char",
        .CUChar => |mut| if (mut) "mut_c_uchar" else "c_uchar",
        .CDouble => |mut| if (mut) "mut_c_double" else "c_double",
        .CInt => |mut| if (mut) "mut_c_int" else "c_int",
        .CLong => |mut| if (mut) "mut_c_long" else "c_long",
        .CShort => |mut| if (mut) "mut_c_short" else "c_short",
        .CSize => |mut| if (mut) "mut_c_size" else "c_size",
        .CUInt => |mut| if (mut) "mut_c_uint" else "c_uint",
        .CULong => |mut| if (mut) "mut_c_ulong" else "c_ulong",
        .CUShort => |mut| if (mut) "mut_c_ushort" else "c_ushort",
        .Float => |mut| if (mut) "mut_float" else "float",
        .Integer => |int| switch (int.size) {
            64 =>
                if (int.signed and int.mutable) "mut_isize"
                else if (int.signed) "isize"
                else if (int.mutable) "mut_usize"
                else "usize",
            32 =>
                if (int.signed and int.mutable) "mut_i32"
                else if (int.signed) "i32"
                else if (int.mutable) "mut_u32"
                else "u32",
            16 =>
                if (int.signed and int.mutable) "mut_i16"
                else if (int.signed) "i16"
                else if (int.mutable) "mut_u16"
                else "u16",
            8 =>
                if (int.signed and int.mutable) "mut_i8"
                else if (int.signed) "i8"
                else if (int.mutable) "mut_u8"
                else "u8",
            else => return common.debug.ShouldBeImpossible(undefined, @src()),
        },
        .Enum => |enm| if (enm.mutable) std.fmt.allocPrint(self.allocator, "mut_{s}", .{self.jir.strings[enm.name]}) catch return Error.AllocatorFailure else self.jir.strings[enm.name],
        .Union => |uni| if (uni.mutable) std.fmt.allocPrint(self.allocator, "mut_{s}", .{self.jir.strings[uni.name]}) catch return Error.AllocatorFailure else self.jir.strings[uni.name],
        .Struct => |str| if (str.mutable) std.fmt.allocPrint(self.allocator, "mut_{s}", .{self.jir.strings[str.name]}) catch return Error.AllocatorFailure else self.jir.strings[str.name],
        .Array => |arr| std.fmt.allocPrint(self.allocator, "{s}Array_{d}_{s}", .{if (arr.mutable) "mut_" else "", arr.len, self.jir.strings[try self.typeName(arr.child)]}) catch return Error.AllocatorFailure,
        .Function => |func| {
            var len: u32 = 7;
            for (func.argTypes) |argt| {
                len += @intCast(self.jir.strings[try self.typeName(argt)].len + 2);
            }
            len += @intCast(self.jir.strings[try self.typeName(func.returnType)].len);

            const newName = self.allocator.alloc(u8, len) catch return Error.AllocatorFailure;
            std.mem.copyForwards(u8, newName[0..5], "func_");

            var index: u32 = 5;
            for (func.argTypes) |argt| {
                const argName = self.jir.strings[self.jir.typeNames.get(argt).?];
                std.mem.copyForwards(u8, newName[index..], argName);
                index += @intCast(argName.len + 1);
                newName[index - 1] = '_';
            }

            index += 2;
            newName[index - 2] = '_';
            newName[index - 1] = '_';

            std.mem.copyForwards(u8, newName[index..], self.jir.strings[self.jir.typeNames.get(func.returnType).?]);

            break :newName newName;
        },
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => std.fmt.allocPrint(self.allocator, "{s}Slice_{s}", .{
                if (ptr.mutable) "mut_" else "",
                self.jir.strings[try self.typeName(ptr.child)],
            }) catch return Error.AllocatorFailure,
            else => |size| std.fmt.allocPrint(self.allocator, "{s}{s}ptr_{s}", .{
                if (ptr.mutable) "mut_" else "",
                if (size == .C) "c_" else "",
                self.jir.strings[try self.typeName(ptr.child)],
            }) catch return Error.AllocatorFailure,
        },
    };

    self.jir.strings[name] = newName;
    self.renamedStringMap.set(name);
    return name;
}

fn convertType(self: *Builder, id: TypeID) Error!TypeID {
    if (self.typeMap.get(id)) |res| {
        return res;
    }

    const converted: JAIR.Type = switch (self.jir.types.get(id)) {
        .Type, .Any, .EnumLiteral => .{ .Void = {} },
        .Void, .Noreturn => .{ .Void = {} },
        .Bool, .CChar, .CUChar => .{ .Byte = {} },
        .ComptimeFloat, .CDouble => .{ .Double = {} },
        .Float => .{ .Single = {} },
        .Enum, .CInt, .CUInt => .{ .Word = {} },
        .Function, .CLong, .ComptimeInt, .CSize, .CULong => .{ .Long = {} },
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => JAIR.Type{
                .Custom = .{
                    .Aggregate = .{
                        .name = try self.typeName(id),
                        .size = try self.typechecker.sizeOf(id),
                        .alignment = try self.typechecker.alignOf(id),
                        .fields = &.{
                            try self.convertType(ptr.child),
                            try self.convertType(comptime Comptime.Folder.Builtin.Type("u32")),
                        },
                    },
                },
            },
            else => .{ .Long = {} },
        },
        .CShort, .CUShort => .{ .Half = {} },
        .Integer => |int| switch (int.size) {
            64 => .{ .Long = {} },
            32 => .{ .Word = {} },
            16 => .{ .Half = {} },
            8 => .{ .Byte = {} },
            else => unreachable,
        },
        .Array => |arr| .{
            .Array = .{
                .size = arr.len * try self.typechecker.alignOf(arr.child),
                .alignment = try self.typechecker.alignOf(arr.child),
            },
        },
        .Union => |uni| .{
            .Custom = .{
                .Union = .{
                    .name = try self.typeName(uni.name),
                    .alignment = try self.typechecker.alignOf(id),
                    .size = try self.typechecker.sizeOf(id),
                    .fields = fields: {
                        var fieldLen: u32 = 0;
                        for (uni.fields) |field| {
                            if (try self.typechecker.sizeOf(field.valueType) == 0) {
                                continue;
                            }

                            fieldLen += 1;
                        }

                        const fields = self.allocator.alloc(TypeID, fieldLen)
                            catch return Error.AllocatorFailure;

                        for (uni.fields, 0..) |field, i| {
                            fields[i] = try self.convertType(field.valueType);
                        }

                        break :fields fields;
                    },
                }
            }
        },
        .Struct => |str| .{
            .Custom = .{
                .Aggregate = .{
                    .name = try self.typeName(str.name),
                    .alignment = try self.typechecker.alignOf(id),
                    .size = try self.typechecker.sizeOf(id),
                    .fields = fields: {
                        var fieldLen: u32 = 0;
                        for (str.fields) |field| {
                            if (try self.typechecker.sizeOf(field.valueType) == 0) {
                                continue;
                            }

                            fieldLen += 1;
                        }

                        const fields = self.allocator.alloc(TypeID, fieldLen)
                            catch return Error.AllocatorFailure;

                        for (str.fields, 0..) |field, i| {
                            fields[i] = try self.convertType(field.valueType);
                        }

                        break :fields fields;
                    },
                }
            }
        }
    };

    const res: u32 = @intCast(self.typeTable.addOneAssumeCapacity());
    self.typeTable.set(res, converted);
    self.typeMap.putAssumeCapacityNoClobber(id, res);
    return res;
}
