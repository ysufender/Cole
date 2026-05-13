const std = @import("std");

const resourcePath = "res/";

const targets = [_]std.Target.Query{
    .{},
    .{ .os_tag = .windows, .cpu_arch = .x86_64 },
    .{ .os_tag = .linux,   .cpu_arch = .x86_64 },
};

const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

pub fn build(b: *std.Build) void {
    configureBuild(b);
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
            .root_module = b.createModule(
                if (optimize == .Debug) .{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc  = target.result.os.tag == .windows,
                    .error_tracing = true,
                    .omit_frame_pointer = false,
                }
                else .{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc  = target.result.os.tag == .windows,
                    .strip = true,
                }
            ),
        });
        exe.root_module.addEmbedPath(b.path(resourcePath));
        exe.root_module.addOptions("config", opts);
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

fn configureBuild(b: *std.Build) void {
    _ = b;
}
