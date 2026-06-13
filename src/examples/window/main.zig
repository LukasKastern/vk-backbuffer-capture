// This application initializes a vk-backbuffer-capture instance using the supplied pid.
// Once hooked we create a opengl / x11 driven window that displays the content of the target app.

const std = @import("std");

const backbuffer_capture = @import("backbuffer-capture");

const c = @import("c");

var x11: X11Lib = undefined;

const X11Lib = struct {
    handle: std.DynLib,

    XOpenDisplay: *const fn ([*c]const u8) callconv(.c) ?*c.Display,
    XCloseDisplay: *const fn (?*c.Display) callconv(.c) c_int,
    XSynchronize: *const fn (?*c.Display, c_int) callconv(.c) ?*const fn (?*c.Display) callconv(.c) c_int,

    XCreateColormap: *const fn (?*c.Display, c.Window, [*c]c.Visual, c_int) callconv(.c) c.Colormap,
    XCreateWindow: *const fn (?*c.Display, c.Window, c_int, c_int, c_uint, c_uint, c_uint, c_int, c_uint, [*c]c.Visual, c_ulong, [*c]c.XSetWindowAttributes) callconv(.c) c.Window,
    XDestroyWindow: *const fn (?*c.Display, c.Window) callconv(.c) c_int,

    XMapWindow: *const fn (?*c.Display, c.Window) callconv(.c) c_int,
    XUnmapWindow: *const fn (?*c.Display, c.Window) callconv(.c) c_int,

    XFlush: *const fn (?*c.Display) callconv(.c) c_int,

    XStoreName: *const fn (?*c.Display, c.Window, [*c]const u8) callconv(.c) c_int,

    XGetWindowAttributes: *const fn (?*c.Display, c.Window, [*c]c.XWindowAttributes) callconv(.c) c_int,
    XPending: *const fn (?*c.Display) callconv(.c) c_int,
    XNextEvent: *const fn (?*c.Display, [*c]c.XEvent) callconv(.c) c_int,

    pub fn load() !void {
        x11.handle = std.DynLib.open("libX11.so") catch return error.FailedToLoadX11;
        inline for (@typeInfo(X11Lib).@"struct".fields[1..]) |field| {
            const name = std.fmt.comptimePrint("{s}\x00", .{field.name});
            const name_z: [:0]const u8 = @ptrCast(name[0 .. name.len - 1]);
            @field(x11, field.name) = x11.handle.lookup(field.type, name_z) orelse {
                std.log.err("Failed to find symbol: {s}", .{name});
                return error.SymbolLookup;
            };
        }
    }
};

var glx: GLXLib = undefined;

const GLXLib = struct {
    const GLXChooseFBConfig = *const fn (dpy: ?*c.Display, screen: c_int, attribList: [*c]const c_int, nitems: [*c]c_int) callconv(.c) [*c]c.GLXFBConfig;
    const XLGetVisualFromFBConfig = *const fn (dpy: ?*c.Display, config: c.GLXFBConfig) callconv(.c) [*c]c.XVisualInfo;
    const GLXMakeContextCurrent = *const fn (dpy: ?*c.Display, draw: c.GLXDrawable, read: c.GLXDrawable, ctx: c.GLXContext) callconv(.c) c_int;
    const GLXCreateWindow = *const fn (dpy: ?*c.Display, config: c.GLXFBConfig, win: c.Window, attribList: [*c]const c_int) callconv(.c) c.GLXWindow;
    const GLXCreateNewContext = *const fn (dpy: ?*c.Display, config: c.GLXFBConfig, renderType: c_int, shareList: c.GLXContext, direct: c_int) callconv(.c) c.GLXContext;
    const GLXDestroyContext = *const fn (dpy: ?*c.Display, ctx: c.GLXContext) callconv(.c) void;
    const GLXDestroyWindow = *const fn (dpy: ?*c.Display, window: c.GLXWindow) callconv(.c) void;

    handle: std.DynLib,

    glXChooseFBConfig: GLXChooseFBConfig,
    glXGetVisualFromFBConfig: XLGetVisualFromFBConfig,

    glXMakeContextCurrent: GLXMakeContextCurrent,
    glXCreateWindow: GLXCreateWindow,

    glXCreateNewContext: GLXCreateNewContext,
    glXDestroyContext: GLXDestroyContext,

    glXDestroyWindow: GLXDestroyWindow,

    pub fn load() !void {
        glx.handle = std.DynLib.open("libGLX.so") catch return error.FailedToLoadGLX;
        inline for (@typeInfo(GLXLib).@"struct".fields[1..]) |field| {
            const name = std.fmt.comptimePrint("{s}\x00", .{field.name});
            const name_z: [:0]const u8 = @ptrCast(name[0 .. name.len - 1]);
            @field(glx, field.name) = glx.handle.lookup(field.type, name_z) orelse {
                std.log.err("Failed to find symbol: {s}", .{name});
                return error.SymbolLookup;
            };
        }
    }
};

var gl: glLib = undefined;

const glLib = struct {
    handle: std.DynLib,

    glMatrixMode: *const fn (mode: c.GLenum) callconv(.c) void,
    glLoadIdentity: *const fn () callconv(.c) void,

    glTranslatef: *const fn (x: c.GLfloat, y: c.GLfloat, z: c.GLfloat) callconv(.c) void,
    glScalef: *const fn (x: c.GLfloat, y: c.GLfloat, z: c.GLfloat) callconv(.c) void,
    glViewport: *const fn (x: c.GLint, y: c.GLint, width: c.GLsizei, height: c.GLsizei) callconv(.c) void,

    glClear: *const fn (mask: c.GLbitfield) callconv(.c) void,
    glBindTexture: *const fn (target: c.GLenum, texture: c.GLuint) callconv(.c) void,
    glEnable: *const fn (cap: c.GLenum) callconv(.c) void,
    glBegin: *const fn (mode: c.GLenum) callconv(.c) void,
    glTexCoord2f: *const fn (s: c.GLfloat, t: c.GLfloat) callconv(.c) void,
    glVertex2i: *const fn (x: c.GLint, y: c.GLint) callconv(.c) void,
    glEnd: *const fn () callconv(.c) void,
    glDisable: *const fn (cap: c.GLenum) callconv(.c) void,
    glFlush: *const fn () callconv(.c) void,
    glTexParameteri: *const fn (target: c.GLenum, pname: c.GLenum, param: c.GLint) callconv(.c) void,
    glGenTextures: *const fn (n: c.GLsizei, textures: [*c]c.GLuint) callconv(.c) void,

    pub fn load() !void {
        gl.handle = std.DynLib.open("libGL.so") catch return error.FailedToLoadLibGL;
        inline for (@typeInfo(glLib).@"struct".fields[1..]) |field| {
            const name = std.fmt.comptimePrint("{s}\x00", .{field.name});
            const name_z: [:0]const u8 = @ptrCast(name[0 .. name.len - 1]);
            @field(gl, field.name) = gl.handle.lookup(field.type, name_z) orelse {
                std.log.err("Failed to find symbol: {s}", .{name});
                return error.SymbolLookup;
            };
        }
    }
};

const allocator = std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    try GLXLib.load();
    try X11Lib.load();
    try glLib.load();

    var iterator = try init.minimal.args.iterateAllocator(allocator);
    _ = iterator.next();

    const pid_as_str = iterator.next() orelse {
        std.log.err("Specify the pid that has the backbuffer capture preloaded as the first arg", .{});
        return error.ArgParseFailed;
    };

    const pid = std.fmt.parseInt(c_int, pid_as_str, 10) catch |e| {
        switch (e) {
            else => {
                std.log.err("Failed to parse first arg into a pid", .{});
                return error.ArgParseFailed;
            },
        }
    };

    var options = backbuffer_capture.api.VKBackbufferInitializeOptions{
        .target_app_id = pid,
    };
    var state: backbuffer_capture.api.VKBackbufferCaptureState = null;
    try backbuffer_capture.capture_init(&options, &state);
    defer backbuffer_capture.capture_deinit(state);

    var init_backbuffer_frame: backbuffer_capture.api.VKBackbufferFrame = undefined;
    try backbuffer_capture.capture_try_get_next_frame(state, std.time.ns_per_s * 2, &init_backbuffer_frame);
    try backbuffer_capture.capture_return_frame(state, &init_backbuffer_frame);

    const display = x11.XOpenDisplay("");
    if (display == null) {
        return error.FailedToOpenDisplay;
    }
    _ = x11.XSynchronize(display, 1);

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
    const fb_configs = glx.glXChooseFBConfig(display, c.DefaultScreen(display), &single_buffer_attributes, &num_fb_configs);

    if (num_fb_configs == 0) {
        return error.NoFbConfigFound;
    }

    const visual_info = glx.glXGetVisualFromFBConfig(display, fb_configs[0]);
    var window_attributes = std.mem.zeroInit(c.XSetWindowAttributes, .{
        .border_pixel = 0,
        .event_mask = c.StructureNotifyMask,
        .colormap = x11.XCreateColormap(display, c.RootWindow(display, visual_info.*.screen), visual_info.*.visual, c.AllocNone),
    });

    const ratio = @as(f32, @floatFromInt(init_backbuffer_frame.width)) / @as(f32, @floatFromInt(init_backbuffer_frame.height));

    const swa_mask: c_ulong = @intCast(c.CWBorderPixel | c.CWColormap | c.CWEventMask | c.CWOverrideRedirect);
    const win = x11.XCreateWindow(display, c.RootWindow(display, visual_info.*.screen), 0, 0, @intFromFloat(500 * ratio), 500, 0, visual_info.*.depth, c.InputOutput, visual_info.*.visual, swa_mask, &window_attributes);

    std.log.info("{}x{}", .{ init_backbuffer_frame.width, init_backbuffer_frame.height });

    _ = x11.XStoreName(display, win, "Example Window");

    const context = glx.glXCreateNewContext(display, fb_configs[0], c.GLX_RGBA_TYPE, null, 1);
    if (context == null) {
        return error.FailedToCreateContext;
    }

    const glx_win = glx.glXCreateWindow(display, fb_configs[0], win, null);
    if (glx_win == 0) {
        return error.FailedToCreateGlxWin;
    }

    _ = x11.XMapWindow(display, win);
    _ = x11.XFlush(display);

    _ = glx.glXMakeContextCurrent(display, glx_win, glx_win, context);

    var handle_to_gl_tex: std.array_hash_map.Auto(c_int, u32) = .empty;

    gl.glMatrixMode(c.GL_PROJECTION);
    gl.glLoadIdentity();

    gl.glMatrixMode(c.GL_MODELVIEW);
    gl.glLoadIdentity();

    gl.glTranslatef(0, 0, 0);
    gl.glScalef(1.0, -1.0, 1.0);

    while (true) {
        var atts: c.XWindowAttributes = undefined;
        _ = x11.XGetWindowAttributes(display, win, &atts);

        while (x11.XPending(display) != 0) {
            var event: c.XEvent = undefined;
            _ = x11.XNextEvent(display, &event);

            gl.glViewport(0, 0, event.xconfigure.width, event.xconfigure.height);
        }

        var backbuffer_frame: backbuffer_capture.api.VKBackbufferFrame = undefined;
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

        const gl_handle = blk: {
            if (handle_to_gl_tex.get(backbuffer_frame.frame_fd_opaque)) |gl_tex| {
                break :blk gl_tex;
            } else {
                var texture: u32 = 0;
                _ = gl.glGenTextures(1, &texture);

                switch (backbuffer_frame.format) {
                    c.VK_FORMAT_B8G8R8A8_UNORM...c.VK_FORMAT_B8G8R8A8_SRGB => {
                        gl.glBindTexture(c.GL_TEXTURE_2D, texture);
                        gl.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_SWIZZLE_B, c.GL_RED);
                        gl.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_SWIZZLE_R, c.GL_BLUE);
                        gl.glBindTexture(c.GL_TEXTURE_2D, 0);
                    },
                    else => {},
                }

                try backbuffer_capture.capture_import_opengl_texture(state, &backbuffer_frame, texture);
                try handle_to_gl_tex.put(allocator, backbuffer_frame.frame_fd_opaque, texture);

                break :blk texture;
            }
        };

        gl.glClear(c.GL_COLOR_BUFFER_BIT);
        gl.glBindTexture(c.GL_TEXTURE_2D, gl_handle);
        gl.glEnable(c.GL_TEXTURE_2D);
        gl.glBegin(c.GL_QUADS);
        gl.glTexCoord2f(0, 0);
        gl.glVertex2i(-1, -1);
        gl.glTexCoord2f(0, 1);
        gl.glVertex2i(-1, 1);
        gl.glTexCoord2f(1, 1);
        gl.glVertex2i(1, 1);
        gl.glTexCoord2f(1, 0);
        gl.glVertex2i(1, -1);
        gl.glEnd();
        gl.glDisable(c.GL_TEXTURE_2D);
        gl.glBindTexture(c.GL_TEXTURE_2D, 0);
        gl.glFlush();

        try backbuffer_capture.capture_return_frame(state, &backbuffer_frame);
    }
}
