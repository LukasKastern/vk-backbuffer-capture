// This application initializes a vk-backbuffer-capture instance using the supplied pid.
// Once hooked we create a opengl / x11 driven window that displays the content of the target app.

const std = @import("std");

const c = @cImport({
    @cInclude("GL/glx.h");
    @cInclude("X11/X.h");
    @cInclude("X11/Xlib.h");
    @cInclude("vulkan/vulkan_core.h");
});

var x11: X11Lib = undefined;

const X11Lib = struct {
    handle: std.DynLib,

    XOpenDisplay: *const @TypeOf(c.XOpenDisplay),
    XCloseDisplay: *const @TypeOf(c.XCloseDisplay),
    XSynchronize: *const @TypeOf(c.XSynchronize),

    XCreateColormap: *const @TypeOf(c.XCreateColormap),
    XCreateWindow: *const @TypeOf(c.XCreateWindow),
    XDestroyWindow: *const @TypeOf(c.XDestroyWindow),

    XMapWindow: *const @TypeOf(c.XMapWindow),
    XUnmapWindow: *const @TypeOf(c.XUnmapWindow),

    XFlush: *const @TypeOf(c.XFlush),

    XStoreName: *const @TypeOf(c.XStoreName),

    XGetWindowAttributes: *const @TypeOf(c.XGetWindowAttributes),
    XPending: *const @TypeOf(c.XPending),
    XNextEvent: *const @TypeOf(c.XNextEvent),

    pub fn load() !void {
        x11.handle = std.DynLib.open("libX11.so") catch return error.FailedToLoadX11;
        inline for (@typeInfo(X11Lib).Struct.fields[1..]) |field| {
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
    handle: std.DynLib,

    glXChooseFBConfig: *const @TypeOf(c.glXChooseFBConfig),
    glXGetVisualFromFBConfig: *const @TypeOf(c.glXGetVisualFromFBConfig),

    glXMakeContextCurrent: *const @TypeOf(c.glXMakeContextCurrent),
    glXCreateWindow: *const @TypeOf(c.glXCreateWindow),

    glXCreateNewContext: *const @TypeOf(c.glXCreateNewContext),
    glXDestroyContext: *const @TypeOf(c.glXDestroyContext),

    glXDestroyWindow: *const @TypeOf(c.glXDestroyWindow),

    pub fn load() !void {
        glx.handle = std.DynLib.open("libGLX.so") catch return error.FailedToLoadGLX;
        inline for (@typeInfo(GLXLib).Struct.fields[1..]) |field| {
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

    glMatrixMode: *const @TypeOf(c.glMatrixMode),
    glLoadIdentity: *const @TypeOf(c.glLoadIdentity),

    glTranslatef: *const @TypeOf(c.glTranslatef),
    glScalef: *const @TypeOf(c.glScalef),
    glViewport: *const @TypeOf(c.glViewport),

    glClear: *const @TypeOf(c.glClear),
    glBindTexture: *const @TypeOf(c.glBindTexture),
    glEnable: *const @TypeOf(c.glEnable),
    glBegin: *const @TypeOf(c.glBegin),
    glTexCoord2f: *const @TypeOf(c.glTexCoord2f),
    glVertex2i: *const @TypeOf(c.glVertex2i),
    glEnd: *const @TypeOf(c.glEnd),
    glDisable: *const @TypeOf(c.glDisable),
    glFlush: *const @TypeOf(c.glFlush),

    glTexParameteri: *const @TypeOf(c.glTexParameteri),

    glGenTextures: *const @TypeOf(c.glGenTextures),

    pub fn load() !void {
        gl.handle = std.DynLib.open("libGL.so") catch return error.FailedToLoadGLX;
        inline for (@typeInfo(glLib).Struct.fields[1..]) |field| {
            const name = std.fmt.comptimePrint("{s}\x00", .{field.name});
            const name_z: [:0]const u8 = @ptrCast(name[0 .. name.len - 1]);
            @field(gl, field.name) = gl.handle.lookup(field.type, name_z) orelse {
                std.log.err("Failed to find symbol: {s}", .{name});
                return error.SymbolLookup;
            };
        }
    }
};

const backbuffer_capture = @import("backbuffer-capture");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

pub fn main() !void {
    try GLXLib.load();
    try X11Lib.load();
    try glLib.load();

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

    var display = x11.XOpenDisplay("");
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
    var fb_configs = glx.glXChooseFBConfig(display, c.DefaultScreen(display), &single_buffer_attributes, &num_fb_configs);

    if (num_fb_configs == 0) {
        return error.NoFbConfigFound;
    }

    var visual_info = glx.glXGetVisualFromFBConfig(display, fb_configs[0]);
    var window_attributes = std.mem.zeroInit(c.XSetWindowAttributes, .{
        .border_pixel = 0,
        .event_mask = c.StructureNotifyMask,
        .colormap = x11.XCreateColormap(display, c.RootWindow(display, visual_info.*.screen), visual_info.*.visual, c.AllocNone),
    });

    var ratio = @as(f32, @floatFromInt(init_backbuffer_frame.width)) / @as(f32, @floatFromInt(init_backbuffer_frame.height));

    var swa_mask: c_ulong = @intCast(c.CWBorderPixel | c.CWColormap | c.CWEventMask | c.CWOverrideRedirect);
    var win = x11.XCreateWindow(display, c.RootWindow(display, visual_info.*.screen), 0, 0, @intFromFloat(500 * ratio), 500, 0, visual_info.*.depth, c.InputOutput, visual_info.*.visual, swa_mask, &window_attributes);

    std.log.info("{}x{}", .{ init_backbuffer_frame.width, init_backbuffer_frame.height });

    _ = x11.XStoreName(display, win, "Example Window");

    var context = glx.glXCreateNewContext(display, fb_configs[0], c.GLX_RGBA_TYPE, null, 1);
    if (context == null) {
        return error.FailedToCreateContext;
    }

    var glx_win = glx.glXCreateWindow(display, fb_configs[0], win, null);
    if (glx_win == 0) {
        return error.FailedToCreateGlxWin;
    }

    _ = x11.XMapWindow(display, win);
    _ = x11.XFlush(display);

    _ = glx.glXMakeContextCurrent(display, glx_win, glx_win, context);

    var handle_to_gl_tex = std.AutoArrayHashMap(c_int, u32).init(allocator);

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
                try handle_to_gl_tex.put(backbuffer_frame.frame_fd_opaque, texture);

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
