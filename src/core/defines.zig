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

    pub fn len(self: Range) u32 {
        assert(self.end >= self.start);
        return self.end - self.start;
    }

    pub fn at(self: Range, index: u32) u32 {
        assert(self.start + index < self.end);
        return self.start + index;
    }

    pub fn into(self: Range, from: anytype) @TypeOf(from) {
        return from[self.start..self.end];
    }

    pub fn get(self: Range, from: anytype, index: u32) @typeInfo(@TypeOf(from)).pointer.child {
        return from[self.at(index)];
    }

    pub fn subRange(self: Range, from: u32) Range {
        const start = self.start + from;
        return .{
            .start = start,
            .end = start + self.len() - from,
        };
    }

    pub fn subRangeN(self: Range, from: u32, count: u32) Range {
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

pub const rehashLimit = 512;
pub const stackLimit = 16;
pub const subscopeMax = 512;
