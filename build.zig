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

    const hook = b.addSharedLibrary(.{
        .name = "backbuffer-capture",
        .root_source_file = .{ .path = "src/hook.zig" },
        .target = target,
        .optimize = optimize,
    });

    hook.linkSystemLibraryName("png");

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
    sdk.linkSystemLibraryName("X11");
    sdk.linkSystemLibraryName("GLX");
    sdk.linkSystemLibraryName("GL");

    sdk.addIncludePath(.{ .path = "src/sdk/" });

    const window = b.addExecutable(.{
        .name = "window-example",
        .root_source_file = .{ .path = "src/examples/window/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    window.linkLibrary(sdk);

    b.installArtifact(window);
    b.installArtifact(hook);
    b.installArtifact(sdk);
}
