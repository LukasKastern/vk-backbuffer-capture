const std = @import("std");
const api = @cImport(@cInclude("api.h"));
pub usingnamespace api;

const shared = @import("shared");
const c = shared.c;

const BackbufferCaptureState = struct {
    shared_data: *shared.HookSharedData,

    texture_handles: []c_int,

    opengl_import_api: ?struct {
        gl_get_error: *const fn () callconv(.C) c_int,
        gl_gen_textures: *const fn (n: i32, textures: [*c]u32) callconv(.C) void,
        gl_bind_texture: *const fn (target: i32, texture: u32) callconv(.C) void,
        gl_tex_parameter: *const fn (target: c_int, name: c_int, value: c_int) callconv(.C) void,

        create_memory_objects_ext: *const fn (n: c_int, memory_objects: *c_uint) callconv(.C) void,
        import_memory_fd_ext: *const fn (memory: u32, size: u64, handle_type: i32, fd: i32) callconv(.C) void,
        is_memory_object_ext: *const fn (memory_object: u32) callconv(.C) c_int,
        tex_storage_mem_2d_ext: *const fn (target: i32, levels: i32, internal_format: i32, width: i32, height: i32, memory: u32, offset: u64) callconv(.C) void,
    },
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const VkBackbufferErrors = error{
    RemoteNotFound,
    OutOfMemory,
    NoSpaceLeft,
    VersionMismatch,
    Timeout,
    ApiError,
};

pub fn capture_init(options: *const api.VKBackbufferInitializeOptions, out_state: *api.VKBackbufferCaptureState) VkBackbufferErrors!void {
    var shm_section_name = try shared.formatSectionName(options.target_app_id);

    std.log.info("Open shm section: {s}", .{shm_section_name});
    var shm_handle = c.shm_open(shm_section_name, c.O_RDWR, 0);

    if (shm_handle == -1) {
        return VkBackbufferErrors.RemoteNotFound;
    }

    defer _ = c.close(shm_handle);

    var shm_buf: *shared.HookSharedData = @alignCast(
        @ptrCast(c.mmap(@as(*anyopaque, @ptrFromInt(@as(usize, @intCast(shm_handle)))), @sizeOf(shared.HookSharedData), c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, shm_handle, 0)),
    );

    if (@intFromPtr(shm_buf) == @intFromPtr(c.MAP_FAILED)) {
        return error.RemoteNotFound;
    }

    errdefer _ = c.munmap(shm_buf, @sizeOf(shared.HookSharedData));

    if (shm_buf.version != shared.HookSharedData.HookVersion) {
        return error.VersionMismatch;
    }

    if (c.ptrace(c.PTRACE_ATTACH, options.target_app_id, @as(c_int, 0), @as(c_int, 0)) == -1) {
        return error.RemoteNotFound;
    }

    defer {
        var res: c_long = -1;
        var retries: usize = 0;
        while (res != 0 and retries < 3) {
            retries += 1;
            res = c.ptrace(c.PTRACE_DETACH, options.target_app_id, @as(c_int, 0), @as(c_int, 0));

            if (res != 0) {
                std.time.sleep(std.time.ns_per_ms * 15);
            }
        }
    }

    if (c.pthread_mutex_trylock(&shm_buf.remote_process_alive_lock) != 0) {
        // Somebody is already hooked into the process..
        return error.RemoteNotFound;
    }

    errdefer _ = c.pthread_mutex_unlock(&shm_buf.remote_process_alive_lock);

    _ = c.pthread_mutex_lock(&shm_buf.lock);
    defer _ = c.pthread_mutex_unlock(&shm_buf.lock);

    {
        var res = c.pthread_mutex_trylock(&shm_buf.hook_process_alive_lock);
        if (res == 0 or res == @intFromEnum(std.os.linux.E.OWNERDEAD)) {
            // Process is not alive anymore..

            if (res == @intFromEnum(std.os.linux.E.OWNERDEAD)) {
                _ = c.pthread_mutex_consistent(&shm_buf.hook_process_alive_lock);
            }

            _ = c.pthread_mutex_unlock(&shm_buf.hook_process_alive_lock);
            return error.RemoteNotFound;
        }
    }

    var pid = c.syscall(c.SYS_pidfd_open, options.target_app_id, @as(c_int, 0));

    var handles = try allocator.alloc(c_int, shm_buf.num_textures);
    errdefer allocator.free(handles);

    for (shm_buf.texture_handles[0..shm_buf.num_textures], handles) |texture_handle, *handle| {
        var out_handle = c.syscall(c.SYS_pidfd_getfd, pid, texture_handle, @as(c_int, 0));
        handle.* = @intCast(out_handle);
    }

    var backbuffer_capture_state = try allocator.create(BackbufferCaptureState);
    backbuffer_capture_state.shared_data = shm_buf;
    backbuffer_capture_state.opengl_import_api = null;
    backbuffer_capture_state.texture_handles = handles;

    std.log.info("Hooked to {s} ({})", .{ shm_section_name, shm_buf.sequence });

    out_state.* = @ptrCast(backbuffer_capture_state);
}

pub fn capture_deinit(state: api.VKBackbufferCaptureState) void {
    allocator.destroy(@as(*BackbufferCaptureState, @ptrCast(@alignCast(state))));
}

pub fn capture_try_get_next_frame(state: api.VKBackbufferCaptureState, wait_time_ns: u32, out_frame: *api.VKBackbufferFrame) VkBackbufferErrors!void {
    var backbuffer_capture_state = @as(*BackbufferCaptureState, @ptrCast(@alignCast(state)));

    var lck_res = c.pthread_mutex_trylock(&backbuffer_capture_state.shared_data.hook_process_alive_lock);

    if (lck_res == 0 or lck_res == @intFromEnum(std.os.linux.E.OWNERDEAD)) {
        if (lck_res == @intFromEnum(std.os.linux.E.OWNERDEAD)) {
            _ = c.pthread_mutex_consistent(&backbuffer_capture_state.shared_data.hook_process_alive_lock);
        }

        // Process is not alive anymore..
        _ = c.pthread_mutex_unlock(&backbuffer_capture_state.shared_data.hook_process_alive_lock);
        return VkBackbufferErrors.RemoteNotFound;
    }

    var time: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &time);

    time.tv_nsec += wait_time_ns;
    time.tv_sec += @divFloor(time.tv_nsec, std.time.ns_per_s);
    time.tv_nsec = @mod(time.tv_nsec, std.time.ns_per_s);

    if (c.sem_timedwait(&backbuffer_capture_state.shared_data.new_texture_signal, &time) == -1) {
        return error.Timeout;
    }

    if (c.pthread_mutex_timedlock(&backbuffer_capture_state.shared_data.lock, &time) == -1) {
        return error.Timeout;
    }

    defer _ = c.pthread_mutex_unlock(&backbuffer_capture_state.shared_data.lock);

    _ = c.pthread_mutex_trylock(&backbuffer_capture_state.shared_data.texture_locks[@intCast(backbuffer_capture_state.shared_data.latest_texture)]);

    out_frame.format = backbuffer_capture_state.shared_data.format;
    out_frame.width = backbuffer_capture_state.shared_data.width;
    out_frame.height = backbuffer_capture_state.shared_data.height;
    out_frame.frame_fd_opaque = backbuffer_capture_state.texture_handles[@intCast(backbuffer_capture_state.shared_data.latest_texture)];

    backbuffer_capture_state.shared_data.latest_texture = -1;
}

pub fn capture_return_frame(state: api.VKBackbufferCaptureState, frame: *const api.VKBackbufferFrame) VkBackbufferErrors!void {
    var backbuffer_capture_state = @as(*BackbufferCaptureState, @ptrCast(@alignCast(state)));

    _ = c.pthread_mutex_lock(&backbuffer_capture_state.shared_data.lock);
    defer _ = c.pthread_mutex_unlock(&backbuffer_capture_state.shared_data.lock);

    var frame_idx = blk: {
        for (backbuffer_capture_state.texture_handles, 0..) |handle, idx| {
            if (handle == frame.frame_fd_opaque) {
                break :blk idx;
            }
        }

        return;
    };

    if (c.pthread_mutex_unlock(&backbuffer_capture_state.shared_data.texture_locks[frame_idx]) == -1) {
        std.log.err("Failed to unlock mutex", .{});
        return;
    }
}

fn dlsymLoadOrError(dl: ?*anyopaque, sym: [:0]const u8) VkBackbufferErrors!*anyopaque {
    var symbol = c.dlsym(dl, sym);
    if (symbol == null) {
        return error.ApiError;
    }

    return symbol.?;
}

pub fn capture_import_opengl_texture(state: api.VKBackbufferCaptureState, frame: *const api.VKBackbufferFrame, gl_tex: u32) VkBackbufferErrors!void {
    var backbuffer_capture_state = @as(*BackbufferCaptureState, @ptrCast(@alignCast(state)));

    if (backbuffer_capture_state.opengl_import_api == null) {
        backbuffer_capture_state.opengl_import_api = blk: {
            var glx = c.dlopen("libGLX.so", c.RTLD_NOW);
            if (glx == null) {
                return error.ApiError;
            }

            var gl = c.dlopen("libGL.so", c.RTLD_NOW);
            if (gl == null) {
                return error.ApiError;
            }

            var glx_load: *const fn (name: [*c]const u8) callconv(.C) ?*anyopaque =
                @ptrCast(try dlsymLoadOrError(gl, "glXGetProcAddress"));

            break :blk .{
                .gl_get_error = @ptrCast(try dlsymLoadOrError(gl, "glGetError")),
                .gl_gen_textures = @ptrCast(try dlsymLoadOrError(gl, "glGenTextures")),
                .gl_bind_texture = @ptrCast(try dlsymLoadOrError(gl, "glBindTexture")),
                .gl_tex_parameter = @ptrCast(try dlsymLoadOrError(gl, "glTexParameteri")),

                .create_memory_objects_ext = @ptrCast(glx_load("glCreateMemoryObjectsEXT") orelse return error.ApiError),
                .import_memory_fd_ext = @ptrCast(glx_load("glImportMemoryFdEXT") orelse return error.ApiError),
                .is_memory_object_ext = @ptrCast(glx_load("glIsMemoryObjectEXT") orelse return error.ApiError),
                .tex_storage_mem_2d_ext = @ptrCast(glx_load("glTexStorageMem2DEXT") orelse return error.ApiError),
            };
        };
    }

    const gl_api = &backbuffer_capture_state.opengl_import_api.?;

    var mem_obj: c_uint = 0;

    gl_api.create_memory_objects_ext(1, &mem_obj);
    if (gl_api.gl_get_error() != 0) {
        return error.ApiError;
    }

    const GL_HANDLE_TYPE_OPAQUE_FD_EXT = 38278;
    gl_api.import_memory_fd_ext(mem_obj, backbuffer_capture_state.shared_data.size, GL_HANDLE_TYPE_OPAQUE_FD_EXT, frame.frame_fd_opaque);
    if (gl_api.gl_get_error() != 0) {
        return error.ApiError;
    }

    if (gl_api.is_memory_object_ext(mem_obj) == 0) {
        return error.ApiError;
    }

    const GL_TEXTURE_2D = @as(c_int, 0x0DE1);
    gl_api.gl_bind_texture(GL_TEXTURE_2D, gl_tex);
    defer gl_api.gl_bind_texture(GL_TEXTURE_2D, 0);

    // Ehhh. We shouldn't do this here lol.
    const GL_RGBA8 = @import("std").zig.c_translation.promoteIntLiteral(c_int, 0x8058, .hexadecimal);
    const GL_TEXTURE_TILING_EXT = @import("std").zig.c_translation.promoteIntLiteral(c_int, 0x9580, .hexadecimal);
    const GL_OPTIMAL_TILING_EXT = @import("std").zig.c_translation.promoteIntLiteral(c_int, 0x9584, .hexadecimal);

    gl_api.gl_tex_parameter(GL_TEXTURE_2D, GL_TEXTURE_TILING_EXT, GL_OPTIMAL_TILING_EXT);

    if (gl_api.gl_get_error() != 0) {
        return error.ApiError;
    }

    gl_api.tex_storage_mem_2d_ext(
        GL_TEXTURE_2D,
        1,
        GL_RGBA8,
        @intCast(backbuffer_capture_state.shared_data.width),
        @intCast(backbuffer_capture_state.shared_data.height),
        mem_obj,
        0,
    );

    if (gl_api.gl_get_error() != 0) {
        return error.ApiError;
    }
}

fn vk_backbuffer_error_to_result(err: VkBackbufferErrors!void) api.vk_backbuffer_capture_result {
    err catch |e| {
        switch (e) {
            error.RemoteNotFound => {
                return api.VkBackbufferCaptureResult_RemoteNotFound;
            },
            error.OutOfMemory => {
                return api.VkBackbufferCaptureResult_OutOfMemory;
            },
            error.VersionMismatch => {
                return api.VkBackbufferCaptureResult_VersionMismatch;
            },
            error.NoSpaceLeft => {
                return api.VkBackbufferCaptureResult_NoSpaceLeft;
            },
            error.ApiError => {
                return api.VkBackbufferCaptureResult_ApiError;
            },
            error.Timeout => {
                return api.VkBackbufferCaptureResult_Timeout;
            },
        }
    };

    return api.VkBackbufferCaptureResult_Success;
}

pub export fn vk_backbuffer_capture_init(options: *const api.VKBackbufferInitializeOptions, out_state: *api.VKBackbufferCaptureState) callconv(.C) api.vk_backbuffer_capture_result {
    return vk_backbuffer_error_to_result(capture_init(options, out_state));
}

pub export fn vk_backbuffer_capture_deinit(state: api.VKBackbufferCaptureState) callconv(.C) void {
    capture_deinit(state);
}

pub export fn vk_backbuffer_capture_next_frame(state: api.VKBackbufferCaptureState, wait_time: u32, frame: *api.VKBackbufferFrame) callconv(.C) api.vk_backbuffer_capture_result {
    return vk_backbuffer_error_to_result(capture_try_get_next_frame(state, wait_time, frame));
}

pub export fn vk_backbuffer_capture_return_frame(state: api.VKBackbufferCaptureState, frame: *api.VKBackbufferFrame) callconv(.C) api.vk_backbuffer_capture_result {
    return vk_backbuffer_error_to_result(capture_return_frame(state, frame));
}

pub export fn vk_backbuffer_capture_import_opengl_texture(state: api.VKBackbufferCaptureState, frame: *const api.VKBackbufferFrame, gl_tex: u32) callconv(.C) api.vk_backbuffer_capture_result {
    return vk_backbuffer_error_to_result(capture_import_opengl_texture(state, frame, gl_tex));
}
