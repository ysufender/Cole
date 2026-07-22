const std = @import("std");
const common = @import("common.zig");
const hashmap = @import("../util/hashmap.zig");
const collections = @import("../util/collections.zig");

const Backend = @import("../codegen/backend.zig").Backend;
const Error = common.CompilerError;

const Flags = enum {
    Help,
    Version,
    Working,
    MaxErr,
    None,
    Include,
    Backend,
    BackendOptions,
    Flag,
    Output,
};

const flags = std.StaticStringMap(Flags).initComptime(&(.{
    .{ "--help", .Help },
    .{ "-h", .Help },

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

    .{ "--backend", .Backend },

    .{ "--backend-options", .BackendOptions },
    .{ "-B", .BackendOptions },

    .{ "--parse-only", .Flag },

    .{ "--typecheck-only", .Flag },

    .{ "--resolve-only", .Flag },

    .{ "--allow-recursion", .Flag },

    .{ "--supress-warnings", .Flag },
    .{ "-s", .Flag },

} ++ if (common.debug.isDebug) .{

    .{ "--print-ast", .Flag },
    .{ "--print-ast-full", .Flag },

    .{ "--dump-memory", .Flag },

    .{ "--dump-stats", .Flag },

    .{ "--dump-jir", .Flag },
}));

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
    var maxErr: u32 = 5;
    var targetBackend = Backend.C;
    var backendOptions: []const u8 = "";
    var cliFlags = common.CompilerSettings.FlagSet.empty;

    cliFlags.ensureTotalCapacity(allocator, 128) catch return Error.AllocatorFailure;

    includeDirs.ensureTotalCapacity(allocator, 512) catch return Error.AllocatorFailure;

    while (args.next()) |flag| {
        switch (hash(flag)) {
            .Help => return printHelp(),
            .Version => return printHeader(),
            .Backend => {
                const backend = args.next() orelse return Error.MissingFlag;
                targetBackend = std.meta.stringToEnum(Backend, backend) orelse {
                    common.log.err("{s} is not a supported backend.", .{backend});
                    return Error.UnknownFlag;
                };
            },
            .BackendOptions => {
                const opts = args.next() orelse return Error.MissingFlag;
                backendOptions = opts;
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
            .maxErr = maxErr,
            .flags = cliFlags,
            .backend = targetBackend,
            .backendFlags = backendOptions,
        }
        else {
            common.log.err("jaslc expects an input file.", .{});
            return Error.NoSourceFile;
        }
    };
}

fn printHeader() common.CompilerError {
    common.log.info(
        "The JASL Compiler:" ++
        "\n\tVersion: " ++ common.JASL_VERSION,
        .{}
    );

    return Error.Terminate; 
}

fn printHelp() common.CompilerError {
    printHeader() catch { };
    common.log.info(helpText, .{});
    return Error.Terminate; 
}  

fn hash(str: []const u8) Flags {
    if (flags.get(str)) |flag| {
        return flag;
    }

    return .None;
}
