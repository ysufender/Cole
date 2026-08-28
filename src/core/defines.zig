const std = @import("std"); 
const common = @import("common.zig");
const builtin = @import("builtin");

pub const Debug = builtin.mode == .Debug;

const assert = std.debug.assert;

const Settings = common.CompilerSettings;

pub const FilePtr = u32;
pub const TokenListPtr = u32;
pub const ASTPtr = u32;
pub const OpaquePtr = u32;
pub const Offset = u32;

pub const Range = struct {
    start: u32,
    end: u32,

    pub inline fn len(self: Range) u32 {
        assert(self.end >= self.start);
        return self.end - self.start;
    }

    pub inline fn at(self: Range, index: u32) u32 {
        assert(self.start + index < self.end);
        return self.start + index;
    }

    pub inline fn subRange(self: Range, from: u32) Range {
        return self.subRangeN(from, self.len() - from);
    }

    pub inline fn subRangeN(self: Range, from: u32, count: u32) Range {
        assert(from < self.len() and from + count <= self.len());
        const start = self.start + from;
        return .{
            .start = start,
            .end = start + count,
        };
    }
};

pub const ExpressionPtr = u32;
pub const StatementPtr = u32;
pub const TokenPtr = u32;
pub const SignaturePtr = u32;

pub const SymbolPtr = u32;
pub const ModulePtr = u32;

pub const ScopePtr = u32;
pub const DeclPtr = u32;

pub fn EitherPtr(_: type, _: type) type {
    return OpaquePtr;
}

pub fn EitherType(This: type, That: type) type {
    return union(enum) {
        This: This,
        That: That,
    };
}

pub const StringPtr = u32;

pub const rehashLimit = 512;
pub const callstackLimit = 16;
pub const subscopeMax = 512;
pub const comptimeStackLimit = 512;
