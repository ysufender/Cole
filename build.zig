const std = @import("std");


const resourcePath = "res/";

var targets = [_]std.Target.Query{
    .{},
    .{ .os_tag = .windows, .cpu_arch = .x86_64, .abi = .gnu },
    .{ .os_tag = .linux,   .cpu_arch = .x86_64, .abi = .gnu },
};

const version = std.SemanticVersion{
    .major = 0,
    .minor = 0,
    .patch = 1,
};

var config: struct {
    native: std.Build.ResolvedTarget = undefined,
    tools: struct {
        compiler_debugger: bool = false,
    } = .{ },
} = .{};

pub fn build(b: *std.Build) void {
    _ = configureBuild(b);
    buildCompiler(b);
    addDebugTarget(b);
    addTestStep(b);
}

fn addTestStep(b: *std.Build) void {
    const opts = b.addOptions();
    opts.addOption(bool, "isDebug", true);
    opts.addOption([]const u8, "version", "test");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = config.native,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    tests.root_module.addEmbedPath(b.path(resourcePath));
    tests.root_module.addOptions("config", opts);

    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Run unit tests reachable from src/main.zig");
    step.dependOn(&run.step);
}

fn buildCompiler(b: *std.Build) void {
    addTargets(b, .Debug);
    addTargets(b, .ReleaseFast);
    addTargets(b, .ReleaseSafe);
    addTargets(b, .ReleaseSmall);
}

fn addTargets(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    var seen = std.StringHashMap(void).init(b.allocator);
    defer seen.deinit();

    const toLower = std.ascii.allocLowerString;
    const print = std.fmt.allocPrint;

    for (targets) |query| {
        const target   = b.resolveTargetQuery(query);

        const targetName = print(b.allocator, "{s}-{s}-{s}", .{
            toLower(b.allocator, @tagName(optimize)) catch unreachable,
            @tagName(target.result.os.tag),
            @tagName(target.result.cpu.arch),
        }) catch unreachable;

        if (seen.contains(targetName)) continue;
        seen.putNoClobber(targetName, {}) catch unreachable;

        const versionString = print(b.allocator, "v{d}.{d}.{d}", .{
            version.major,
            version.minor,
            version.patch,
        }) catch unreachable;

        const opts = b.addOptions();
        opts.addOption(bool, "isDebug", optimize == .Debug);
        opts.addOption([]const u8, "version", versionString);

        const exe = b.addExecutable(.{
            .name = "jaslc",
            .version = version,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .strip = true,
                .code_model = .small,
                .link_libc = true,
                .error_tracing = optimize != .Debug,
                .omit_frame_pointer = optimize != .Debug,
            }),
        });

        exe.root_module.addEmbedPath(b.path(resourcePath));
        exe.root_module.addOptions("config", opts);

        if (target.result.os.tag == .linux) {
            exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/lib/" });
            exe.root_module.addEmbedPath(.{ .cwd_relative = "/usr/include/" });
            exe.root_module.linkSystemLibrary("tcc", .{ .preferred_link_mode = .static });
            // exe.root_module.linkSystemLibrary("mimalloc", .{ .preferred_link_mode = .static });
        }

        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{
                targetName,
                versionString,
            }) } }
        });

        const step = b.step(targetName, print(
            b.allocator,
            "Build for {s}",
            .{targetName},
        ) catch unreachable);

        step.dependOn(&install.step);
        step.dependOn(b.getInstallStep());
    }
}

fn addDebugTarget(b: *std.Build) void {
    const targetName = "debug";

    const opts = b.addOptions();
    opts.addOption(bool, "isDebug", true);
    opts.addOption([]const u8, "version", "debug");

    const exe = b.addExecutable(.{
        .name = "jaslc-debug",
        .version = version,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = config.native,
            .optimize = .Debug,
            .link_libc  = true,
            .error_tracing = true,
            .omit_frame_pointer = false,
        }),
        .use_llvm = true,
    });
    exe.root_module.addEmbedPath(b.path(resourcePath));
    exe.root_module.addOptions("config", opts);
    const install = b.addInstallArtifact(exe, .{});

    const step = b.step(targetName, "Build for debug on native platform");
    step.dependOn(&install.step);
    step.dependOn(b.getInstallStep());
}

fn configureBuild(b: *std.Build) void {
    config = .{
        .native = b.standardTargetOptions(.{}),
        .tools = .{
            .compiler_debugger = b.option(bool, "compiler-debugger", "Build the compiler debugger, not to be confused with program debugger.") orelse false,
        },
    };
}
