const std = @import("std");
const common = @import("../../../core/common.zig");
const collections = @import("../../../util/collections.zig");

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
        .allocator = allocator,
        .typechecker = typechecker,
    };
}

pub fn build(self: *Builder) Error!JAIR {
    for (self.jir.strings) |str| {
        _ = std.mem.replace(u8, str, "::", "__", @constCast(str));
    }

    for (self.jir.keyNodes) |nodePtr| {
        const node = self.jir.nodes.get(nodePtr);

        if (node.type == .FunctionDef) {
            _ = try self.functionDef(nodePtr);
        }
    }

    return JAIR{
        .typeTable = self.typeTable.toOwnedSlice(),
        .data = self.data.items,
        .strings = self.jir.strings,
        .nodes = self.nodes.toOwnedSlice(),
        .keyNodes = self.keyNodes.toOwnedSlice(self.allocator) catch return Error.AllocatorFailure,
    };
}

fn convertType(self: *Builder, id: TypeID) Error!TypeID {
    if (self.typeMap.get(id)) |res| {
        return res;
    }

    const converted: JAIR.Type = switch (self.jir.types.get(id)) {
        .Type, .Any, .EnumLiteral => unreachable,
        .Void, .Noreturn => .{ .Void = {} },
        .Bool, .CChar, .CUChar => .{ .Byte = {} },
        .ComptimeFloat, .CDouble => .{ .Double = {} },
        .Float => .{ .Single = {} },
        .Enum, .CInt, .CUInt => .{ .Word = {} },
        .Function, .CLong, .ComptimeInt, .CSize, .CULong, .Pointer => .{ .Long = {} },
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
                    .name = uni.name,
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
                    .name = str.name,
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
