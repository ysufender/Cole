const std = @import("std");

const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const prepass = @import("parser/prepass.zig");
const dependency = @import("parser/dependency.zig");

const resolver = @import("typechecker/resolver.zig");
const typechecker = @import("typechecker/typechecker.zig");
const comptimeMod = @import("typechecker/comptime.zig");
const lowerer = @import("typechecker/lowerer.zig");
const typeMod = @import("typechecker/type.zig");

const arraylist = @import("util/arraylist.zig");
const collections = @import("util/collections.zig");
const functional = @import("util/functional.zig");
const hashmap = @import("util/hashmap.zig");
const stack = @import("util/stack.zig");

const common = @import("core/common.zig");
const context = @import("core/context.zig");
const cli = @import("core/cli.zig");
const settings = @import("core/settings.zig");

const lexerTests = @import("lexer/unverified_lexer_test.zig");

test "test harness wiring" {
    try std.testing.expect(true);
}
