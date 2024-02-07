// This application initializes a vk-backbuffer-capture instance using the supplied pid.
// Once hooked we create a opengl / x11 driven window that displays the content of the target app.

const std = @import("std");

const c = @cImport({
    @cInclude("GL/glx.h");
    @cInclude("X11/X.h");
    @cInclude("X11/Xlib.h");
});

pub fn main() !void {
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
    var win = c.XCreateWindow(display, c.RootWindow(display, visual_info.*.screen), 0, 0, 500, 500, 0, visual_info.*.depth, c.InputOutput, visual_info.*.visual, swa_mask, &window_attributes);

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

    while (true) {
        while (c.XPending(display) != 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(display, &event);
        }

        c.glClear(c.GL_COLOR_BUFFER_BIT);

        c.glFlush();
    }
}
