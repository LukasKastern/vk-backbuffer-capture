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

    _ = b.run(&.{
        "glslc",
        "src/shaders/vs_swapchain_fullscreen.vert",
        "-o",
        "src/shaders/vs_swapchain_fullscreen.spv",
    });
    _ = b.run(&.{
        "glslc",
        "src/shaders/fs_swapchain_fullscreen.frag",
        "-o",
        "src/shaders/fs_swapchain_fullscreen.spv",
    });

    const hook = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "backbuffer-capture",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/layer.zig"),
            .link_libc = true,
        }),
    });

    const sdk = b.addLibrary(.{
        .name = "backbuffer-api",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/sdk/api.zig"),
            .link_libc = true,
        }),
    });

    sdk.bundle_compiler_rt = true;

    const shared_module = b.addModule("shared", .{
        .root_source_file = b.path("src/shared.zig"),
    });

    sdk.root_module.addImport("shared", shared_module);
    hook.root_module.addImport("shared", shared_module);

    sdk.root_module.addIncludePath(b.path("src/sdk/"));
    sdk.installHeadersDirectory(b.path("src/sdk/backbuffer-capture/"), "backbuffer-capture/", .{});

    const c_api_example = b.addExecutable(.{
        .name = "c_api-example",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        }),
    });
    c_api_example.root_module.addCSourceFile(.{
        .file = b.path("src/examples/c_api/main.c"),
        .language = .c,
    });

    c_api_example.root_module.linkLibrary(sdk);
    c_api_example.root_module.addIncludePath(b.path("zig-out/include"));

    const window = b.addExecutable(.{
        .name = "window-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/window/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const window_c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/examples/window/c.h"),
    });

    const shared_c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/shared.c"),
    });
    shared_module.addImport("shared_c", shared_c.createModule());

    // Import opengl-headers
    const dep_opengl_header = b.dependency("gl", .{});

    // Import x11
    const dep_x11_headers = b.dependency("x11", .{});

    const dep_vk_header = b.dependency("vulkan_headers", .{});

    window_c.addIncludePath(dep_opengl_header.path(""));
    window_c.addIncludePath(dep_vk_header.path("include"));
    window_c.addIncludePath(dep_x11_headers.path(""));

    @import("x11").addIncludePaths(dep_x11_headers.builder, window.root_module);

    window.root_module.addImport("c", window_c.createModule());

    window.root_module.linkLibrary(sdk);

    window.root_module.addImport("backbuffer-capture", sdk.root_module);
    window.root_module.addIncludePath(b.path("src/sdk"));

    // Import opengl-headers
    @import("vulkan_headers").addIncludePaths(dep_vk_header.builder, hook.root_module);
    @import("vulkan_headers").addIncludePaths(dep_vk_header.builder, sdk.root_module);
    @import("vulkan_headers").addIncludePaths(dep_vk_header.builder, shared_module);
    @import("vulkan_headers").addIncludePaths(dep_vk_header.builder, c_api_example.root_module);

    b.installArtifact(window);
    b.installArtifact(hook);
    b.installArtifact(sdk);
    b.installArtifact(c_api_example);
}
