// This application initializes a vk-backbuffer-capture instance using the supplied pid.
// Once hooked we create a opengl / x11 driven window that displays the content of the target app.

const std = @import("std");

const c = @cImport({
    @cInclude("GL/glx.h");
    @cInclude("X11/X.h");
    @cInclude("X11/Xlib.h");
});

const backbuffer_capture = @import("backbuffer-capture");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

pub fn main() !void {
    var iterator = std.process.ArgIterator.init();
    _ = iterator.next();

    var pid_as_str = iterator.next() orelse {
        std.log.err("Specify the pid that has the backbuffer capture preloaded as the first arg", .{});
        return error.ArgParseFailed;
    };

    var pid = std.fmt.parseInt(c_int, pid_as_str, 10) catch |e| {
        switch (e) {
            else => {
                std.log.err("Failed to parse first arg into a pid", .{});
                return error.ArgParseFailed;
            },
        }
    };

    var options = backbuffer_capture.VKBackbufferInitializeOptions{
        .target_app_id = pid,
    };
    var state: backbuffer_capture.VKBackbufferCaptureState = null;
    try backbuffer_capture.capture_init(&options, &state);
    defer backbuffer_capture.capture_deinit(state);

    var init_backbuffer_frame: backbuffer_capture.VKBackbufferFrame = undefined;
    try backbuffer_capture.capture_try_get_next_frame(state, std.time.ns_per_s * 2, &init_backbuffer_frame);
    try backbuffer_capture.capture_return_frame(state, &init_backbuffer_frame);

    var display = c.XOpenDisplay("");
    _ = c.XSynchronize(display, 1);

    var single_buffer_attributes = [_]c_int{
        c.GLX_DRAWABLE_TYPE,
        c.GLX_WINDOW_BIT,
        c.GLX_RENDER_TYPE,
        c.GLX_RGBA_BIT,
        c.GLX_RED_SIZE,
        8,
        c.GLX_GREEN_SIZE,
        8,
        c.GLX_BLUE_SIZE,
        8,
        c.None,
    };

    var num_fb_configs: c_int = 0;
    var fb_configs = c.glXChooseFBConfig(display, c.DefaultScreen(display), &single_buffer_attributes, &num_fb_configs);

    if (num_fb_configs == 0) {
        return error.NoFbConfigFound;
    }

    var visual_info = c.glXGetVisualFromFBConfig(display, fb_configs[0]);
    var window_attributes = std.mem.zeroInit(c.XSetWindowAttributes, .{
        .border_pixel = 0,
        .event_mask = 0,
        .colormap = c.XCreateColormap(display, c.RootWindow(display, visual_info.*.screen), visual_info.*.visual, c.AllocNone),
    });

    var swa_mask: c_ulong = @intCast(c.CWBorderPixel | c.CWColormap | c.CWEventMask | c.CWOverrideRedirect);
    var win = c.XCreateWindow(display, c.RootWindow(display, visual_info.*.screen), 0, 0, init_backbuffer_frame.width, init_backbuffer_frame.height, 0, visual_info.*.depth, c.InputOutput, visual_info.*.visual, swa_mask, &window_attributes);

    _ = c.XStoreName(display, win, "Example Window");

    var context = c.glXCreateNewContext(display, fb_configs[0], c.GLX_RGBA_TYPE, null, 1);
    if (context == null) {
        return error.FailedToCreateContext;
    }

    var glx_win = c.glXCreateWindow(display, fb_configs[0], win, null);
    if (glx_win == 0) {
        return error.FailedToCreateGlxWin;
    }

    _ = c.XMapWindow(display, win);
    _ = c.XFlush(display);

    _ = c.glXMakeContextCurrent(display, glx_win, glx_win, context);

    var handle_to_gl_tex = std.AutoArrayHashMap(c_int, u32).init(allocator);

    c.glMatrixMode(c.GL_PROJECTION);
    c.glOrtho(0, @floatFromInt(init_backbuffer_frame.width), @floatFromInt(init_backbuffer_frame.height), 0, -1, 1);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glLoadIdentity();

    while (true) {
        while (c.XPending(display) != 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(display, &event);
        }

        var backbuffer_frame: backbuffer_capture.VKBackbufferFrame = undefined;
        backbuffer_capture.capture_try_get_next_frame(state, std.time.ns_per_ms * 30, &backbuffer_frame) catch |e| {
            switch (e) {
                error.Timeout => {
                    std.log.info("Timeout", .{});
                    continue;
                },
                else => {
                    return error.FailedToGetNextFrame;
                },
            }
        };

        var gl_handle = blk: {
            if (handle_to_gl_tex.get(backbuffer_frame.frame_fd_opaque)) |gl| {
                break :blk gl;
            } else {
                var handle: u32 = 0;
                try backbuffer_capture.capture_import_opengl_texture(state, &backbuffer_frame, &handle);
                try handle_to_gl_tex.put(backbuffer_frame.frame_fd_opaque, handle);

                break :blk handle;
            }
        };

        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glBindTexture(c.GL_TEXTURE_2D, gl_handle);
        c.glEnable(c.GL_TEXTURE_2D);
        c.glBegin(c.GL_QUADS);
        c.glTexCoord2i(0, 0);
        c.glVertex2i(0, 0);
        c.glTexCoord2i(0, 1);
        c.glVertex2i(0, @intCast(init_backbuffer_frame.width));
        c.glTexCoord2i(1, 1);
        c.glVertex2i(@intCast(init_backbuffer_frame.width), @intCast(init_backbuffer_frame.height));
        c.glTexCoord2i(1, 0);
        c.glVertex2i(@intCast(init_backbuffer_frame.width), 0);
        c.glEnd();
        c.glDisable(c.GL_TEXTURE_2D);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glFlush();

        try backbuffer_capture.capture_return_frame(state, &backbuffer_frame);
    }
}
