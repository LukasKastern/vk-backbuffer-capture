const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const compile_vert = b.addSystemCommand(&.{ "glslc", "src/shaders/vs_swapchain_fullscreen.vert", "-o", "src/shaders/vs_swapchain_fullscreen.spv" });
    const compile_frag = b.addSystemCommand(&.{ "glslc", "src/shaders/fs_swapchain_fullscreen.frag", "-o", "src/shaders/fs_swapchain_fullscreen.spv" });

    const vulkan_dep = b.dependency("vulkan_headers", .{ .target = target, .optimize = optimize });

    const x11_dep = b.dependency("x11", .{
        .target = target,
        .optimize = optimize,
    });

    const gl_dep = b.dependency("gl", .{
        .target = target,
        .optimize = optimize,
    });

    const dependencies = &[_]*std.Build.Step.Compile{
        vulkan_dep.artifact("vulkan-headers"),
        x11_dep.artifact("x11-headers"),
        gl_dep.artifact("opengl-headers"),
    };

    const hook = b.addSharedLibrary(.{
        .name = "backbuffer-capture",
        .root_source_file = .{ .path = "src/layer.zig" },
        .target = target,
        .optimize = optimize,
    });

    hook.step.dependOn(&compile_frag.step);
    hook.step.dependOn(&compile_vert.step);

    hook.linkLibC();

    const sdk = b.addStaticLibrary(.{
        .name = "backbuffer-api",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/sdk/api.zig" },
    });

    sdk.linkLibC();
    sdk.bundle_compiler_rt = true;

    var shared_module = b.addModule("shared", .{
        .source_file = .{ .path = "src/shared.zig" },
    });

    sdk.addModule("shared", shared_module);

    sdk.addIncludePath(.{ .path = "src/sdk/" });
    sdk.installHeadersDirectory("src/sdk/backbuffer-capture/", "backbuffer-capture/");

    const c_api_example = b.addExecutable(.{
        .name = "c_api-example",
        .root_source_file = .{ .path = "src/examples/c_api/main.c" },
        .target = target,
        .optimize = optimize,
    });

    c_api_example.linkLibrary(sdk);
    // c_api_example.step.dependOn(&install_sdk_api.step);
    c_api_example.addIncludePath(.{ .path = "zig-out/include" });

    const window = b.addExecutable(.{
        .name = "window-example",
        .root_source_file = .{ .path = "src/examples/window/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    window.linkLibrary(sdk);

    var sdk_module = b.addModule(
        "backbuffer-capture",
        .{
            .source_file = .{ .path = "src/sdk/api.zig" },
            .dependencies = &.{
                .{ .name = "shared", .module = shared_module },
            },
        },
    );

    window.addModule("backbuffer-capture", sdk_module);
    window.addIncludePath(.{ .path = "src/sdk" });

    for (dependencies) |dep| {
        hook.linkLibrary(dep);
        sdk.linkLibrary(dep);
        c_api_example.linkLibrary(dep);
        window.linkLibrary(dep);
    }

    b.installArtifact(window);
    b.installArtifact(hook);
    b.installArtifact(sdk);
    b.installArtifact(c_api_example);
}
