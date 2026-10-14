const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .small });

    // Kindle 3: Freescale i.MX35 (ARM1136JF-S), Linux 2.6.26, armel.
    // Statically linked against musl so it doesn't care about the Kindle's
    // ancient glibc.
    const kindle_target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1136jf_s },
    });

    // Installs a ready-to-copy KUAL extension:
    //   zig-out/extensions/weather/{config.xml,menu.json,weather.conf,bin/}
    const kindle = b.addExecutable(.{
        .name = "k3-weather",
        .root_module = appModule(b, kindle_target, optimize),
        .linkage = .static,
    });
    b.getInstallStep().dependOn(&b.addInstallArtifact(kindle, .{
        .dest_dir = .{ .override = .{ .custom = "extensions/weather/bin" } },
    }).step);
    b.installDirectory(.{
        .source_dir = b.path("kindle/extensions/weather"),
        .install_dir = .prefix,
        .install_subdir = "extensions/weather",
    });

    // Host build for previewing: `zig build preview -- --png out.png`
    const host = b.addExecutable(.{
        .name = "k3-weather-host",
        .root_module = appModule(b, b.graph.host, .debug),
    });
    const run = b.addRunArtifact(host);
    run.addPassthruArgs();
    b.step("preview", "Run the host build (use --png FILE)").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = appModule(b, b.graph.host, .debug) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

fn appModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
    });
    mod.addIncludePath(b.path("vendor"));
    mod.addCSourceFile(.{ .file = b.path("src/ttf.c"), .flags = &.{"-O2"} });
    mod.addAnonymousImport("DejaVuSans.ttf", .{ .root_source_file = b.path("assets/DejaVuSans.ttf") });
    mod.addAnonymousImport("DejaVuSans-Bold.ttf", .{ .root_source_file = b.path("assets/DejaVuSans-Bold.ttf") });
    mod.addAnonymousImport("mbta-roots.pem", .{ .root_source_file = b.path("assets/mbta-roots.pem") });
    return mod;
}
