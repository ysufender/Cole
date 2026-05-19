const defines = @import("../../core/defines.zig");
const types = @import("../../typechecker/type.zig");

const MultiArray = @import("../../util/arraylist.zig").MultiArrayList;
const Typechecker = @import("../../typechecker/typechecker.zig");
const TypeID = types.TypeID;
const TypeTable = Typechecker.TypeTable;
const FunctionPtr = defines.Offset;
const JIRPtr = defines.Offset;

pub const JIRNode = union(enum) {
    TypeDef: TypeID,
    FunctionDef: FunctionPtr,
    VariableDef: struct {
        type: TypeID,
        initializer: ?JIRPtr,
    },
    Assignment: struct {
        assignThis: defines.DeclPtr,
        toThat: JIRPtr,
    },
};

pub const Constant = union(enum) {
    pub const Size = u64;

    Integer: union(enum) {
        i32: i32,
        u32: u32,
        i8: i8,
        u8: u8,
    },
    Float: f32,
    Aggregate: struct {
        type: TypeID,
        data: []const Constant,
    }, 
    Array: struct {
        type: TypeID,
        data: []const Constant,
    },
    Undefined: TypeID,
    Function: FunctionPtr,
};

pub const Function = struct {
    signature: TypeID,
    body: []const JIRPtr,
};
