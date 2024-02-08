const std = @import("std");
const vulkan = @import("vk.zig");

pub const c = @cImport({
    @cInclude("semaphore.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("pthread.h");
    @cInclude("fcntl.h");
    @cInclude("dlfcn.h");
    @cInclude("sys/ptrace.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
    @cInclude("sys/wait.h");
});

var shm_section_name_buffer: [128]u8 = undefined;

pub const HookSharedData = extern struct {
    pub const MaxTextures = 8;
    pub const HookVersion = 13;

    version: usize,

    sequence: usize,

    num_textures: usize,

    texture_handles: [MaxTextures]c_int,

    texture_locks: [MaxTextures]c.pthread_mutex_t,

    format: vulkan.VkFormat,

    width: u32,

    height: u32,

    size: u32,

    new_texture_signal: c.sem_t,
    latest_texture: c_int,

    lock: c.pthread_mutex_t,

    // These are "robust" mutexes used to detect whether the hook and the "remote" process are still alive.
    hook_process_alive_lock: c.pthread_mutex_t,
    remote_process_alive_lock: c.pthread_mutex_t,
};

pub fn formatSectionName(process_id: c_int) ![:0]const u8 {
    var shm_section_name = try std.fmt.bufPrintZ(&shm_section_name_buffer, "vk-backbuffer-hook-{}", .{process_id});
    return shm_section_name;
}
