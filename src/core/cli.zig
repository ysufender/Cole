const std = @import("std");
const common = @import("common.zig");
const hashmap = @import("../util/hashmap.zig");
const collections = @import("../util/collections.zig");

const Backend = @import("../codegen/backend.zig").Backend;
const Error = common.CompilerError;

const Flag = enum {
    Help,
    Version,
    Working,
    MaxErr,
    None,
    Include,
    Backend,
    Link,
    LinkPath,
    Flag,
    Output,
    Optimize,
    Target,
};

const flags = std.StaticStringMap(Flag).initComptime(&(.{
    .{ "--help", .Help },
    .{ "-h", .Help },

    .{ "--debug", .Flag },
    .{ "-D", .Flag },

    .{ "--output", .Output },
    .{ "-o", .Output },

    .{ "--version", .Version },
    .{ "-v", .Version },

    .{ "--working", .Working },
    .{ "-w", .Working },

    .{ "--max-err", .MaxErr },
    .{ "-m", .MaxErr },

    .{ "--include", .Include },
    .{ "-I", .Include },

    // .{ "--backend", .Backend },
    .{ "--optimize", .Optimize },
    .{ "-O", .Optimize },

    .{ "--link", .Link },
    .{ "-l", .Link },
    
    .{ "--link-dir", .LinkPath },
    .{ "-L", .LinkPath },

    .{ "--parse-only", .Flag },

    .{ "--typecheck-only", .Flag },

    .{ "--resolve-only", .Flag },

    .{ "--supress-warnings", .Flag },
    .{ "-s", .Flag },

} ++ if (common.debug.isDebug) .{

    .{ "--print-ast", .Flag },
    .{ "--print-ast-full", .Flag },

    .{ "--dump-memory", .Flag },

    .{ "--dump-stats", .Flag },

    .{ "--dump-jir", .Flag },
} else .{}));

const helpText =
    @embedFile("../res/help.txt")
    ++ if (common.debug.isDebug) @embedFile("../res/help-debug.txt") else "";

pub fn parseCLI(allocator: std.mem.Allocator, _args: std.process.Args, io: std.Io) common.CompilerError!common.CompilerSettings {
    const NMap = std.StringHashMapUnmanaged(void);

    var args = _args.iterateAllocator(allocator) catch return Error.AllocatorFailure;

    _ = args.skip();

    var maybeFile: ?[]const u8 = null;
    var maybeOut: ?[]const u8 = null;
    var workingDir: []const u8 = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch return Error.AllocatorFailure;
    var includeDirs = NMap.empty;
    var libraries = NMap.empty;
    var linkDirs = NMap.empty;
    var maxErr: u32 = 5;
    var targetBackend = Backend.C;
    var optimize: ?[]const u8 = null;
    var cliFlags = common.CompilerSettings.FlagSet.empty;

    cliFlags.ensureTotalCapacity(allocator, 128) catch return Error.AllocatorFailure;

    includeDirs.ensureTotalCapacity(allocator, 512) catch return Error.AllocatorFailure;

    while (args.next()) |flag| {
        switch (hash(flag)) {
            .Help => return printHelp(),
            .Version => return printHeader(),
            .Optimize => {
                if (args.next()) |arg| {
                    if (
                        std.mem.eql(u8, arg, "g")
                        or std.mem.eql(u8, arg, "0")
                        or std.mem.eql(u8, arg, "1")
                        or std.mem.eql(u8, arg, "2")
                        or std.mem.eql(u8, arg, "3")
                    ) {
                        optimize = arg;
                        continue;
                    }

                    common.log.err("Unknown optimization level '{s}'.", .{arg});
                    return Error.UnknownFlag;
                }
                else {
                    common.log.err("Expected an optimization level after optimize option.", .{});
                    return Error.MissingFlag;
                }
            },
            .Link => {
                if (args.next()) |arg| {
                    libraries.put(allocator, arg, {}) catch return Error.AllocatorFailure;
                }
                else {
                    common.log.err("Expected a library after link flag.", .{});
                    return Error.MissingFlag;
                }
            },
            .LinkPath => {
                if (args.next()) |arg| {
                    const path = std.Io.Dir.cwd().realPathFileAlloc(io, arg, allocator) catch |err| switch (err) {
                        error.OutOfMemory => return Error.AllocatorFailure,
                        else => {
                            common.log.info("Given path '{s}' couldn't be resolved.", .{arg});
                            return Error.IOError;
                        }
                    };

                    includeDirs.put(allocator, path, {}) catch return Error.AllocatorFailure;
                }
                else {
                    common.log.err("Expected a path after link directory flag.", .{});
                    return Error.MissingFlag;
                }
            },
            .Backend => {
                const backend = args.next() orelse return Error.MissingFlag;
                targetBackend = std.meta.stringToEnum(Backend, backend) orelse {
                    common.log.err("{s} is not a supported backend.", .{backend});
                    return Error.UnknownFlag;
                };
            },
            .Working => {
                const dir = args.next() orelse return Error.MissingFlag;

                std.process.setCurrentPath(io, dir) catch |err| {
                    common.log.err("Failed to set working directory to '{s}',\n\tProvided information: {s}", .{dir, @errorName(err)});
                    return Error.IOError;
                };

                workingDir = std.process.currentPathAlloc(io, allocator) catch return Error.AllocatorFailure;
            },
            .MaxErr => {
                const max = if (args.next()) |next| next else {
                    common.log.err("Expected an integer value, received nothing.", .{});
                    return Error.MissingFlag;
                };

                maxErr = std.fmt.parseInt(u32, max, 10) catch {
                    common.log.err("Expected an integer value, received '{s}'", .{max});

                    return Error.UnknownFlag;
                };
            },
            .Include => {
                if (args.next()) |arg| {
                    const path = std.Io.Dir.cwd().realPathFileAlloc(io, arg, allocator) catch |err| switch (err) {
                        error.OutOfMemory => return Error.AllocatorFailure,
                        else => {
                            common.log.info("Given path '{s}' couldn't be resolved.", .{arg});
                            return Error.IOError;
                        }
                    };

                    includeDirs.put(allocator, path, {}) catch return Error.AllocatorFailure;
                }
                else {
                    common.log.err("Expected a path after include flag.", .{});
                }
            },
            .Output =>
                if (maybeOut) |_| {
                    common.log.err("Multiple output file overrides.", .{});
                    return Error.MultipleCLIOptions;
                }
                else {
                    maybeOut = args.next();
                },

            .Flag => cliFlags.put(allocator, flag, {}) catch return Error.AllocatorFailure,

            else =>
                if (maybeFile != null) {
                    common.log.err("Unexpected commandline option {s}", .{flag});
                    return Error.UnknownFlag;
                }
                else {
                    maybeFile = flag;
                }
        }
    }

    const collect = struct {
        pub fn collect(count: u32, _it: NMap.KeyIterator, _allocator: std.mem.Allocator) ![][]const u8 {
            var it = _it;
            const ret = _allocator.alloc([]const u8, count) catch return Error.AllocatorFailure;
            var i: u32 = 0;
            while (it.next()) |n| : (i += 1) {
                ret[i] = n.*;
            }
            return ret;
        }
    }.collect;

    return blk: {
        if (maybeFile) |file| break :blk common.CompilerSettings{
            .inputFile = file,
            .outputFile = maybeOut orelse "out",
            .workingDir = workingDir,
            .includeDirs = try collect(
                includeDirs.count(),
                includeDirs.keyIterator(),
                allocator
            ),
            .linkDirs = try collect(
                linkDirs.count(),
                linkDirs.keyIterator(),
                allocator
            ),
            .libraries = try collect(
                libraries.count(),
                libraries.keyIterator(),
                allocator
            ),
            .buildInfo = .{
                .backend = targetBackend,
                .isDebug = cliFlags.contains("--debug"),
                .optimization = @enumFromInt(
                    if (cliFlags.contains("--debug")) 0
                    else if (std.mem.eql(u8, optimize orelse "1", "g")) 0
                    else std.fmt.parseInt(u3, optimize orelse "1", 10) catch unreachable,
                ),
                .platform = switch (@import("builtin").os.tag) {
                    .windows => .Windows,
                    .freebsd, .netbsd, .openbsd,
                    .macos, .linux, .dragonfly,
                    .illumos, .haiku => .Unix,
                    else => |platform| {
                        common.log.err("Unsupported target platform '{s}' detected.", .{@tagName(platform)});
                        return Error.UnsupportedTarget;
                    },
                },
            },
            .maxErr = maxErr,
            .flags = cliFlags,
        }
        else {
            common.log.err("cole expects an input file.", .{});
            return Error.NoSourceFile;
        }
    };
}

fn printHeader() common.CompilerError {
    common.log.info(
        "The Cole Compiler:" ++
        "\n\tVersion: " ++ common.COLE_VERSION,
        .{}
    );

    return Error.Terminate; 
}

fn printHelp() common.CompilerError {
    printHeader() catch { };
    common.log.info(helpText, .{});
    return Error.Terminate; 
}  

fn hash(str: []const u8) Flag {
    if (flags.get(str)) |flag| {
        return flag;
    }

    return .None;
}
