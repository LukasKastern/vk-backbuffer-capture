const std = @import("std");
const vulkan = @import("vk.zig");
const pipeline = @import("pipeline.zig");
const png = @cImport(@cInclude("png.h"));

const c = @import("shared.zig").c;
const HookSharedData = @import("shared.zig").HookSharedData;
const formatSectionName = @import("shared.zig").formatSectionName;

var submission_count: u32 = 0;

var vk_queue_submit_original: ?*const fn (queue: vulkan.VkQueue, submitCount: c_uint, pSubmits: *const vulkan.VkSubmitInfo, fence: vulkan.VkFence) callconv(.C) vulkan.VkResult = null;
var vk_queue_submit_2_original: ?*const fn (queue: vulkan.VkQueue, submitCount: c_uint, pSubmits: *const vulkan.VkSubmitInfo2, fence: vulkan.VkFence) callconv(.C) vulkan.VkResult = null;
var vk_create_swapchain_original: ?*const fn (device: vulkan.VkDevice, pCreateInfo: *const vulkan.VkSwapchainCreateInfoKHR, pAllocator: *const vulkan.VkAllocationCallbacks, pSwapchain: *vulkan.VkSwapchainKHR) callconv(.C) vulkan.VkResult = null;

const RTLD = struct {
    pub const NEXT = @as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));
};

pub export fn vkQueueSubmit2(queue: vulkan.VkQueue, submitCount: c_uint, pSubmits: *const vulkan.VkSubmitInfo2, fence: vulkan.VkFence) callconv(.C) vulkan.VkResult {
    submission_count += 1;

    if (vk_queue_submit_2_original == null) {
        vk_queue_submit_2_original = @ptrCast(std.c.dlsym(RTLD.NEXT, "vkQueueSubmit2"));
    }

    return vk_queue_submit_2_original.?(queue, submitCount, pSubmits, fence);
}

pub export fn vkQueueSubmit(queue: vulkan.VkQueue, submitCount: c_uint, pSubmits: *const vulkan.VkSubmitInfo, fence: vulkan.VkFence) callconv(.C) vulkan.VkResult {
    submission_count += 1;

    if (vk_queue_submit_original == null) {
        vk_queue_submit_original = @ptrCast(std.c.dlsym(RTLD.NEXT, "vkQueueSubmit"));
    }

    return vk_queue_submit_original.?(queue, submitCount, pSubmits, fence);
}

var sequence: u32 = 0;

fn copyIntoHookTexture(device_data: *VkDeviceData, queue: vulkan.VkQueue, present_info: *const vulkan.VkPresentInfoKHR) !void {
    var capture_instance = active_capture_instance.?;

    var queue_data = blk: {
        for (device_data.queues.items) |*device_queue| {
            if (device_queue.vk_queue == queue) {
                break :blk device_queue;
            }
        }

        return error.QueueNotFound;
    };

    var buffer_idx = blk: {
        for (present_info.pSwapchains[0..present_info.swapchainCount], 0..) |swapchain, idx| {
            if (swapchain == capture_instance.swapchain) {
                break :blk idx;
            }
        }

        return error.SwapchainNotFound;
    };

    var image_and_lock = blk: {
        _ = c.pthread_mutex_lock(&capture_instance.shm_buf.lock);
        defer _ = c.pthread_mutex_unlock(&capture_instance.shm_buf.lock);

        for (capture_instance.hook_images, capture_instance.shm_buf.texture_locks[0..capture_instance.hook_images.len], 0..) |hook_image, *lock, idx| {
            if (idx == capture_instance.shm_buf.latest_texture) {
                continue;
            }

            if (c.pthread_mutex_trylock(lock) == 0) {
                break :blk .{
                    .hook_image = hook_image,
                    .lock = lock,
                    .idx = idx,
                };
            }
        }

        // No image available..
        return;
    };

    std.log.info("Capturing into tex {}", .{image_and_lock.idx});

    var hook_image = image_and_lock.hook_image;
    var lock = image_and_lock.lock;

    if (queue_data.vk_command_pool == null) {
        var create_info = std.mem.zeroInit(vulkan.VkCommandPoolCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queue_data.family_index,
            .flags = vulkan.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT | vulkan.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        });

        try vulkan.vkCall(vulkan.vkCreateCommandPool, .{
            device_data.vk_device,
            &create_info,
            null,
            @as([*c]vulkan.VkCommandPool, @ptrCast(&queue_data.vk_command_pool)),
        });
    }

    var swapchain_data = blk: {
        for (capture_instance.device.swapchains.items) |swapchain| {
            if (swapchain.vk_swapchain == capture_instance.swapchain) {
                break :blk swapchain;
            }
        }

        return error.SwapchainDataNotFound;
    };

    if (queue_data.vk_command_buffers == null) {
        queue_data.vk_command_buffers = try allocator.alloc(vulkan.VkCommandBuffer, capture_instance.hook_images.len);

        for (queue_data.vk_command_buffers.?) |*cmd_buffer| {
            var allocate_info = std.mem.zeroInit(vulkan.VkCommandBufferAllocateInfo, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .commandBufferCount = 1,
                .commandPool = queue_data.vk_command_pool.?,
                .level = vulkan.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            });

            var allocate = @as(
                *const fn (device: vulkan.VkDevice, pAllocateInfo: [*c]const vulkan.VkCommandBufferAllocateInfo, pCommandBuffers: [*c]vulkan.VkCommandBuffer) vulkan.VkResult,
                @ptrCast(vkGetDeviceProcAddr(device_data.vk_device, "vkAllocateCommandBuffers")),
            );

            try vulkan.vkCall(allocate, .{ device_data.vk_device, &allocate_info, cmd_buffer });
        }
    }

    if (queue_data.pipeline == null) {
        queue_data.pipeline = try pipeline.createSwapchainPipeline(device_data.vk_device, swapchain_data.format);
    }

    var cmd_buffer = queue_data.vk_command_buffers.?[buffer_idx];

    const attachment_info = std.mem.zeroInit(vulkan.VkRenderingAttachmentInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR,
        .imageView = hook_image.vk_view,
        .imageLayout = vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .storeOp = vulkan.VK_ATTACHMENT_STORE_OP_STORE,
    });

    const rendering_info = std.mem.zeroInit(vulkan.VkRenderingInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_RENDERING_INFO_KHR,
        .renderArea = .{
            .extent = .{
                .width = @as(u32, @intCast(swapchain_data.width)),
                .height = @as(u32, @intCast(swapchain_data.height)),
            },
        },
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment_info,
    });

    try vulkan.vkCall(vulkan.vkResetCommandBuffer, .{ cmd_buffer, 0 });

    const begin_info = std.mem.zeroInit(vulkan.VkCommandBufferBeginInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = vulkan.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });

    try vulkan.vkCall(vulkan.vkBeginCommandBuffer, .{ cmd_buffer, &begin_info });

    {
        const image_barrier = std.mem.zeroInit(vulkan.VkImageMemoryBarrier2, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .dstStageMask = vulkan.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = vulkan.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .newLayout = vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .image = swapchain_data.backbuffer_images[buffer_idx],
            .subresourceRange = .{
                .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                .levelCount = 1,
                .layerCount = 1,
            },
        });

        const dep_info = std.mem.zeroInit(vulkan.VkDependencyInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &image_barrier,
        });

        try vulkan.vkCall(device_data.api.vk_cmd_pipeline_barrier, .{ cmd_buffer, &dep_info });
    }

    try vulkan.vkCall(device_data.api.vk_cmd_begin_rendering, .{ cmd_buffer, &rendering_info });
    {
        var viewport = std.mem.zeroInit(vulkan.VkViewport, .{
            .maxDepth = @as(f32, 1),
            .width = @as(f32, @floatFromInt(swapchain_data.width)),
            .height = @as(f32, @floatFromInt(swapchain_data.height)),
        });

        try vulkan.vkCall(vulkan.vkCmdSetViewport, .{ cmd_buffer, 0, 1, &viewport });

        var scissors = std.mem.zeroInit(
            vulkan.VkRect2D,
            .{
                .extent = .{
                    .width = @as(u32, @intCast(swapchain_data.width)),
                    .height = @as(u32, @intCast(swapchain_data.height)),
                },
            },
        );

        try vulkan.vkCall(vulkan.vkCmdSetScissor, .{ cmd_buffer, 0, 1, &scissors });

        try vulkan.vkCall(vulkan.vkCmdBindPipeline, .{ cmd_buffer, vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS, queue_data.pipeline.?.vk_pipeline });

        var image_info = std.mem.zeroInit(vulkan.VkDescriptorImageInfo, .{
            .imageView = swapchain_data.backbuffer_image_views[buffer_idx],

            .imageLayout = vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .sampler = null,
        });

        var write_info = std.mem.zeroInit(vulkan.VkWriteDescriptorSet, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pBufferInfo = null,
            .dstSet = null,
            .pTexelBufferView = null,
            .pImageInfo = &image_info,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
        });

        try vulkan.vkCall(device_data.api.vk_cmd_push_descriptor_set, .{ cmd_buffer, vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS, queue_data.pipeline.?.vk_pipeline_layout, 0, 1, &write_info });

        try vulkan.vkCall(vulkan.vkCmdDraw, .{ cmd_buffer, 3, 1, 0, 0 });
    }

    try vulkan.vkCall(device_data.api.vk_cmd_end_rendering, .{cmd_buffer});

    {
        const image_barrier = std.mem.zeroInit(vulkan.VkImageMemoryBarrier2, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .dstStageMask = vulkan.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = vulkan.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .newLayout = vulkan.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .oldLayout = vulkan.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .image = swapchain_data.backbuffer_images[buffer_idx],
            .subresourceRange = .{
                .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                .levelCount = 1,
                .layerCount = 1,
            },
        });

        const dep_info = std.mem.zeroInit(vulkan.VkDependencyInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &image_barrier,
        });

        try vulkan.vkCall(device_data.api.vk_cmd_pipeline_barrier, .{ cmd_buffer, &dep_info });
    }

    {
        const image_barrier = std.mem.zeroInit(vulkan.VkImageMemoryBarrier2, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .dstStageMask = vulkan.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = vulkan.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .newLayout = vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .image = hook_image.vk_image,
            .subresourceRange = .{
                .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                .levelCount = 1,
                .layerCount = 1,
            },
        });

        const dep_info = std.mem.zeroInit(vulkan.VkDependencyInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &image_barrier,
        });

        try vulkan.vkCall(device_data.api.vk_cmd_pipeline_barrier, .{ cmd_buffer, &dep_info });
    }

    var region = std.mem.zeroInit(vulkan.VkBufferImageCopy, .{
        .bufferOffset = 0,
        .bufferRowLength = @as(u32, @intCast(swapchain_data.width)),
        .bufferImageHeight = @as(u32, @intCast(swapchain_data.height)),
        .imageSubresource = .{
            .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageExtent = .{
            .width = @as(u32, @intCast(swapchain_data.width)),
            .height = @as(u32, @intCast(swapchain_data.height)),
            .depth = 1,
        },
    });

    try vulkan.vkCall(vulkan.vkCmdCopyImageToBuffer, .{
        cmd_buffer,
        hook_image.vk_image,
        vulkan.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        hook_image.vk_buffer,
        1,
        &region,
    });

    try vulkan.vkCall(vulkan.vkEndCommandBuffer, .{cmd_buffer});

    const submit_info = std.mem.zeroInit(vulkan.VkSubmitInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pCommandBuffers = &cmd_buffer,
        .commandBufferCount = 1,
    });

    try vulkan.vkCall(vulkan.vkQueueSubmit, .{
        queue,
        1,
        &submit_info,
        hook_image.vk_fence,
    });

    try vulkan.vkCall(vulkan.vkWaitForFences, .{
        device_data.vk_device,
        1,
        &hook_image.vk_fence,
        vulkan.VK_TRUE,
        vulkan.UINT64_MAX,
    });

    try vulkan.vkCall(vulkan.vkResetFences, .{
        device_data.vk_device,
        1,
        &hook_image.vk_fence,
    });

    var post_sem = false;
    {
        _ = c.pthread_mutex_lock(&capture_instance.shm_buf.lock);
        capture_instance.shm_buf.latest_texture = @intCast(image_and_lock.idx);

        var prev_val: c_int = 0;
        _ = c.sem_getvalue(&capture_instance.shm_buf.new_texture_signal, &prev_val);

        if (prev_val == 0) {
            post_sem = true;
        }

        _ = c.pthread_mutex_unlock(&capture_instance.shm_buf.lock);
    }

    _ = c.pthread_mutex_unlock(lock);

    if (post_sem) {
        _ = c.sem_post(&capture_instance.shm_buf.new_texture_signal);
    }

    // {
    //     var buff: [128]u8 = undefined;
    //     var name = try std.fmt.bufPrintZ(&buff, "Somepng_{}.png", .{sequence});
    //     sequence += 1;
    //     var file = png.fopen(name, "wb");

    //     var write_struct = png.png_create_write_struct(png.PNG_LIBPNG_VER_STRING, null, null, null);
    //     png.png_init_io(write_struct, file);

    //     var info = png.png_create_info_struct(write_struct);
    //     png.png_set_IHDR(
    //         write_struct,
    //         info,
    //         @intCast(swapchain_data.width),
    //         @intCast(swapchain_data.height),
    //         8,
    //         png.PNG_COLOR_TYPE_RGB_ALPHA,
    //         png.PNG_INTERLACE_NONE,
    //         png.PNG_COMPRESSION_TYPE_DEFAULT,
    //         png.PNG_FILTER_TYPE_DEFAULT,
    //     );

    //     var rows = allocator.alloc([*c]u8, swapchain_data.height) catch unreachable;
    //     defer allocator.free(rows);
    //     for (rows, 0..) |*row, idx| {
    //         row.* = &@as([*c]u8, @ptrCast(capture_instance.hook_images[buffer_idx].memory))[idx * swapchain_data.width * 4];
    //     }

    //     png.png_set_rows(write_struct, info, @ptrCast(rows));

    //     png.png_write_png(write_struct, info, png.PNG_TRANSFORM_BGR, null);

    //     _ = png.fclose(file);
    // }
}

const ActiveCaptureInstanceTimeoutNs = std.time.ns_per_s * 2;

fn allocateHookImages(device_data: *VkDeviceData, swapchain_data: SwapchainData) ![]HookImageData {
    var hook_images = allocator.alloc(HookImageData, 3) catch unreachable;
    for (hook_images) |*hook_image| {
        var image_ext_create_info = std.mem.zeroInit(vulkan.VkExternalMemoryImageCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext = null,
            .handleTypes = vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
        });

        const image_info = std.mem.zeroInit(vulkan.VkImageCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &image_ext_create_info,
            .imageType = vulkan.VK_IMAGE_TYPE_2D,
            .format = swapchain_data.format,
            .extent = .{
                .width = @as(u32, @intCast(swapchain_data.width)),
                .height = @as(u32, @intCast(swapchain_data.height)),
                .depth = 1,
            },
            .arrayLayers = 1,
            .mipLevels = 1,
            .samples = vulkan.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vulkan.VK_IMAGE_TILING_OPTIMAL,
            .usage = vulkan.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                vulkan.VK_IMAGE_USAGE_STORAGE_BIT | vulkan.VK_IMAGE_USAGE_SAMPLED_BIT,
            .flags = 0,
            .sharingMode = vulkan.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
        });

        if (vulkan.vkCreateImage(device_data.vk_device, &image_info, null, &hook_image.vk_image) != vulkan.VK_SUCCESS) {
            return error.VkCreateImageFailed;
        }

        var memory_requirements: vulkan.VkMemoryRequirements = undefined;
        try vulkan.vkCall(vulkan.vkGetImageMemoryRequirements, .{ device_data.vk_device, hook_image.vk_image, &memory_requirements });

        hook_image.size = memory_requirements.size;

        // Allocate texture memory
        {
            const memory_type_index = mem_type: {
                var mem_props: vulkan.VkPhysicalDeviceMemoryProperties = undefined;
                try vulkan.vkCall(vulkan.vkGetPhysicalDeviceMemoryProperties, .{ device_data.vk_phy_device, &mem_props });

                for (mem_props.memoryTypes[0..mem_props.memoryTypeCount], 0..) |prop, idx| {
                    if (memory_requirements.memoryTypeBits & (@as(u32, 1) << @intCast(idx)) == 0) {
                        continue;
                    }

                    var flags = vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

                    if ((@as(c_int, @intCast(prop.propertyFlags)) & (flags)) == flags) {
                        break :mem_type @as(u32, @intCast(idx));
                    }
                }

                return error.MemTypeNotFound;
            };

            var export_info = std.mem.zeroInit(vulkan.VkExportMemoryAllocateInfo, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
                .pNext = null,
                .handleTypes = vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
            });

            var memory_allocate_info = std.mem.zeroInit(vulkan.VkMemoryAllocateInfo, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .pNext = &export_info,
                .allocationSize = memory_requirements.size,
                .memoryTypeIndex = memory_type_index,
            });

            var mem: vulkan.VkDeviceMemory = undefined;
            try vulkan.vkCall(vulkan.vkAllocateMemory, .{ device_data.vk_device, &memory_allocate_info, null, &mem });

            var bind_info = std.mem.zeroInit(vulkan.VkBindImageMemoryInfo, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO,
                .pNext = null,
                .image = hook_image.vk_image,
                .memory = mem,
                .memoryOffset = 0,
            });

            try vulkan.vkCall(device_data.api.vk_bind_image_memory, .{ device_data.vk_device, 1, &bind_info });

            var get_memory_fd_info = std.mem.zeroInit(vulkan.VkMemoryGetFdInfoKHR, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
                .memory = mem,
                .handleType = vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
            });

            try vulkan.vkCall(device_data.api.vk_get_memory_fd, .{ device_data.vk_device, &get_memory_fd_info, &hook_image.image_handle });
        }

        // Allocate buffer info
        {
            var buffer_create_info = std.mem.zeroInit(vulkan.VkBufferCreateInfo, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = memory_requirements.size,
                .queueFamilyIndexCount = 0,
                .pQueueFamilyIndices = null,
                .usage = vulkan.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            });

            var buffer: vulkan.VkBuffer = undefined;
            try vulkan.vkCall(vulkan.vkCreateBuffer, .{
                device_data.vk_device,
                &buffer_create_info,
                null,
                &buffer,
            });

            hook_image.vk_buffer = buffer;

            var requirements: vulkan.VkMemoryRequirements = undefined;
            try vulkan.vkCall(vulkan.vkGetBufferMemoryRequirements, .{
                device_data.vk_device,
                buffer,
                &requirements,
            });

            const memory_type_index = mem_type: {
                var mem_props: vulkan.VkPhysicalDeviceMemoryProperties = undefined;
                try vulkan.vkCall(vulkan.vkGetPhysicalDeviceMemoryProperties, .{ device_data.vk_phy_device, &mem_props });

                for (mem_props.memoryTypes[0..mem_props.memoryTypeCount], 0..) |prop, idx| {
                    if (requirements.memoryTypeBits & (@as(u32, 1) << @intCast(idx)) == 0) {
                        continue;
                    }

                    var flags = vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;

                    if ((@as(c_int, @intCast(prop.propertyFlags)) & (flags)) == flags) {
                        break :mem_type @as(u32, @intCast(idx));
                    }
                }

                return error.MemTypeNotFound;
            };

            var memory_allocate_info = std.mem.zeroInit(vulkan.VkMemoryAllocateInfo, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .pNext = null,
                .allocationSize = memory_requirements.size,
                .memoryTypeIndex = memory_type_index,
            });

            var mem: vulkan.VkDeviceMemory = undefined;
            try vulkan.vkCall(vulkan.vkAllocateMemory, .{ device_data.vk_device, &memory_allocate_info, null, &mem });

            try vulkan.vkCall(vulkan.vkBindBufferMemory, .{ device_data.vk_device, buffer, mem, 0 });

            try vulkan.vkCall(vulkan.vkMapMemory, .{
                device_data.vk_device,
                mem,
                0,
                memory_requirements.size,
                0,
                &hook_image.memory,
            });
        }

        var info = std.mem.zeroInit(vulkan.VkImageViewCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .format = swapchain_data.format,
            .viewType = vulkan.VK_IMAGE_VIEW_TYPE_2D,
            .subresourceRange = .{
                .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                .layerCount = 1,
                .levelCount = 1,
            },
            .image = hook_image.vk_image,
        });

        if (vulkan.vkCreateImageView(device_data.vk_device, &info, null, &hook_image.vk_view) != vulkan.VK_SUCCESS) {
            return error.FailedToCreateImageView;
        }

        var fence_create_info = std.mem.zeroInit(vulkan.VkFenceCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        });

        try vulkan.vkCall(vulkan.vkCreateFence, .{
            device_data.vk_device, &fence_create_info, null, &hook_image.vk_fence,
        });
    }

    return hook_images;
}

fn isOrTrySetSwapchainActive(device_data: *VkDeviceData, swapchains: []const vulkan.VkSwapchainKHR) !bool {
    active_capture_instance_lck.lock();
    defer active_capture_instance_lck.unlock();

    if (active_capture_instance) |capture_instance| {
        if (capture_instance.device == device_data) {
            for (swapchains) |in_swapchain| {
                if (capture_instance.swapchain == in_swapchain) {
                    return true;
                }
            }
        }

        if (std.time.nanoTimestamp() - capture_instance.last_render_time < ActiveCaptureInstanceTimeoutNs) {
            return false;
        }
    }

    var best_swapchain_data: ?SwapchainData = null;

    for (swapchains) |swapchain| {
        var swapchain_data = blk: {
            for (device_data.swapchains.items) |chain_data| {
                if (chain_data.vk_swapchain == swapchain) {
                    break :blk chain_data;
                }
            }

            continue;
        };

        if (best_swapchain_data) |best_swapchain| {
            // Prefer swapchain with largest surface area.
            if (best_swapchain.width * best_swapchain.height < swapchain_data.width * swapchain_data.height) {
                best_swapchain_data = swapchain_data;
            }
        } else {
            best_swapchain_data = swapchain_data;
        }
    }

    if (best_swapchain_data) |best_swapchain| {
        if (active_capture_instance) |active_capture| {
            _ = active_capture; // autofix

            // TODO: queue deallocation when it's safe to do
            active_capture_instance = null;
        }

        var shm_section_name = try formatSectionName(c.getpid());
        std.log.info("Open shm section: {s}", .{shm_section_name});

        _ = c.shm_unlink(shm_section_name);

        var shm_handle = c.shm_open(shm_section_name, c.O_CREAT | c.O_RDWR, c.S_IRUSR | c.S_IWUSR | c.S_IXUSR);
        if (shm_handle == -1) {
            return error.FailedToOpenBackbufferHook;
        }

        if (c.ftruncate(shm_handle, @sizeOf(HookSharedData)) == 1) {
            return error.FailedToResizeShmMem;
        }

        var shm_buf: *HookSharedData = @ptrCast(@alignCast(c.mmap(null, @sizeOf(HookSharedData), c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, shm_handle, 0)));
        if (@intFromPtr(shm_buf) == @intFromPtr(c.MAP_FAILED)) {
            return error.MapFailed;
        }

        @memset(@as([*c]u8, @ptrCast(shm_buf))[0..@sizeOf(HookSharedData)], 0);

        var hook_images = try allocateHookImages(device_data, best_swapchain);
        std.debug.assert(hook_images.len <= HookSharedData.MaxTextures);

        for (hook_images, 0..) |image, idx| {
            var att = std.mem.zeroes(c.pthread_mutexattr_t);
            _ = c.pthread_mutexattr_init(&att);
            _ = c.pthread_mutexattr_setpshared(&att, c.PTHREAD_PROCESS_SHARED);

            // Ideally we would set these to be robust. So that when this app or the receiving app crashes we do not deadlock.
            // But our current approach requires locks to be transfered inbetween threads - a robust mutex would prevent us from doing so.
            // pthread_mutexattr_setrobust(&att, PTHREAD_MUTEX_ROBUST);

            if (c.pthread_mutex_init(&shm_buf.texture_locks[idx], &att) == -1) {
                return error.FailedToInitializeMutex;
            }

            shm_buf.texture_handles[idx] = image.image_handle;
        }

        {
            var att = std.mem.zeroes(c.pthread_mutexattr_t);
            _ = c.pthread_mutexattr_init(&att);
            _ = c.pthread_mutexattr_setpshared(&att, c.PTHREAD_PROCESS_SHARED);

            if (c.pthread_mutex_init(&shm_buf.lock, &att) == -1) {
                return error.FailedToInitializeMutex;
            }
        }

        if (c.sem_init(&shm_buf.new_texture_signal, 1, 0) == -1) {
            return error.FailedToInitSem;
        }

        shm_buf.num_textures = hook_images.len;
        shm_buf.latest_texture = -1;
        shm_buf.version = HookSharedData.HookVersion;
        shm_buf.format = best_swapchain.format;
        shm_buf.width = @intCast(best_swapchain.width);
        shm_buf.height = @intCast(best_swapchain.height);
        shm_buf.size = @intCast(hook_images[0].size);

        active_capture_instance = .{
            .device = device_data,
            .swapchain = best_swapchain.vk_swapchain,
            .last_render_time = std.time.nanoTimestamp(),
            .hook_images = hook_images,
            .shm_buf = shm_buf,
        };

        std.log.info("Set new swapchain active {}", .{@intFromPtr(best_swapchain.vk_swapchain)});

        return true;
    }

    return false;
}

pub export fn vkQueuePresentKHR(queue: vulkan.VkQueue, present_info: *const vulkan.VkPresentInfoKHR) callconv(.C) vulkan.VkResult {
    if (getVulkanDeviceDataFromVkQueue(queue)) |device_data| {
        if (!device_data.had_error) {
            var is_active = blk: {
                break :blk isOrTrySetSwapchainActive(device_data, present_info.pSwapchains[0..present_info.swapchainCount]) catch |e| {
                    switch (e) {
                        else => {
                            std.log.err("Error occured during isOrTrySetSwapchainActive invocation. Error: {s}", .{@errorName(e)});
                            device_data.had_error = true;
                            break :blk false;
                        },
                    }
                };
            };

            if (is_active) {
                copyIntoHookTexture(device_data, queue, present_info) catch |e| {
                    switch (e) {
                        else => {
                            std.log.err("Error occured during copyIntoHookTexture invocation. Error: {s}", .{@errorName(e)});
                            device_data.had_error = true;
                        },
                    }
                };
            }
        }
        return device_data.api.vk_queue_present_khr(queue, present_info);
    } else {
        return getApi().vk_queue_present_khr(queue, present_info);
    }
}

fn rememberSwapchain(device_data: *VkDeviceData, swapchain: vulkan.VkSwapchainKHR, create_info: *const vulkan.VkSwapchainCreateInfoKHR) !void {
    var swapchain_data = blk: {
        var count: c_uint = 0;

        if (vulkan.vkGetSwapchainImagesKHR(device_data.vk_device, swapchain, &count, null) != vulkan.VK_SUCCESS) {
            std.log.warn("Failed to get swapchain images from chain {}", .{@intFromPtr(swapchain)});
            return error.FailedToGetSwapchainimages;
        }

        var images = try allocator.alloc(vulkan.VkImage, count);
        var image_views = try allocator.alloc(vulkan.VkImageView, count);

        if (vulkan.vkGetSwapchainImagesKHR(device_data.vk_device, swapchain, &count, images.ptr) != vulkan.VK_SUCCESS) {
            std.log.warn("Failed to get swapchain images from chain {}", .{@intFromPtr(swapchain)});
            return error.FailedToGetSwapchainimages;
        }

        for (image_views, images[0..count]) |*view, image| {
            var info = std.mem.zeroInit(vulkan.VkImageViewCreateInfo, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .format = create_info.imageFormat,
                .viewType = vulkan.VK_IMAGE_VIEW_TYPE_2D,
                .subresourceRange = .{
                    .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                    .layerCount = 1,
                    .levelCount = 1,
                },
                .image = image,
            });

            if (vulkan.vkCreateImageView(device_data.vk_device, &info, null, view) != vulkan.VK_SUCCESS) {
                return error.CreateImageViewFailed;
            }

            std.log.info("Created view for swapchain {} and image {}", .{ @intFromPtr(swapchain), @intFromPtr(image) });
        }

        break :blk .{
            .vk_swapchain = swapchain,
            .backbuffer_image_views = image_views,
            .backbuffer_images = images,
            .width = create_info.imageExtent.width,
            .height = create_info.imageExtent.height,
            .format = create_info.imageFormat,
        };
    };

    try device_data.swapchains.append(swapchain_data);

    std.log.info(
        "Create swapchain {}x{} ({})",
        .{ create_info.imageExtent.width, create_info.imageExtent.height, create_info.imageFormat },
    );
}

pub export fn vkCreateSwapchainKHR(device: vulkan.VkDevice, pCreateInfo: *const vulkan.VkSwapchainCreateInfoKHR, pAllocator: *const vulkan.VkAllocationCallbacks, pSwapchain: *vulkan.VkSwapchainKHR) vulkan.VkResult {
    if (getVulkanDeviceDataFromVkDevice(device)) |device_data| {
        var create_info = pCreateInfo.*;
        create_info.imageUsage |= vulkan.VK_IMAGE_USAGE_SAMPLED_BIT;
        var swapchain_res = device_data.api.vk_create_swapchain_khr(device, &create_info, pAllocator, pSwapchain);

        if (swapchain_res == vulkan.VK_SUCCESS) {
            rememberSwapchain(device_data, pSwapchain.*, pCreateInfo) catch |e| {
                switch (e) {
                    else => {
                        std.log.err("Failed to remember swapchain. Error: {s}", .{@errorName(e)});
                        device_data.had_error = true;
                    },
                }
            };
        }

        return swapchain_res;
    } else {
        //TODO: We should fallback to the default vkCreateSwapchainKhr
        @panic("Create Swapchain Khr called but we do not have a valid mapping to the device");
    }
}

var vk_device_proc_addr_original: ?*const fn (device: vulkan.VkDevice, name: [*c]const u8) *const anyopaque = null;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const OriginalVulkanApi = struct {
    vk_create_instance: *const fn (pCreateInfo: *const vulkan.VkInstanceCreateInfo, pAllocator: *const vulkan.VkAllocationCallbacks, pInstance: *vulkan.VkInstance) vulkan.VkResult,
    vk_enumerate_physical_devices: *const fn (instance: vulkan.VkInstance, pPhysicalDeviceCount: [*c]u32, pPhysicalDevices: [*c]vulkan.VkPhysicalDevice) vulkan.VkResult,
    vk_create_device: *const fn (physicalDevice: vulkan.VkPhysicalDevice, pCreateInfo: [*c]const vulkan.VkDeviceCreateInfo, pAllocator: [*c]const vulkan.VkAllocationCallbacks, pDevice: [*c]vulkan.VkDevice) vulkan.VkResult,
    vk_get_instance_proc_addr: *const fn (instance: vulkan.VkInstance, pName: [*c]const u8) *const anyopaque,
    vk_get_device_proc_addr: *const fn (device: vulkan.VkDevice, pName: [*c]const u8) *const anyopaque,
    vk_get_device_queue: *const fn (device: vulkan.VkDevice, queue_family_index: c_uint, queue_index: c_uint, queue: *vulkan.VkQueue) callconv(.C) void,
    vk_queue_present_khr: *const fn (queue: vulkan.VkQueue, present_info: *const vulkan.VkPresentInfoKHR) callconv(.C) vulkan.VkResult,
};

const DeviceApi = struct {
    vk_create_swapchain_khr: *const fn (device: vulkan.VkDevice, pCreateInfo: *const vulkan.VkSwapchainCreateInfoKHR, pAllocator: *const vulkan.VkAllocationCallbacks, pSwapchain: *vulkan.VkSwapchainKHR) vulkan.VkResult,
    vk_queue_present_khr: *const fn (queue: vulkan.VkQueue, present_info: *const vulkan.VkPresentInfoKHR) callconv(.C) vulkan.VkResult,
    vk_get_device_queue: *const fn (device: vulkan.VkDevice, queue_family_index: c_uint, queue_index: c_uint, queue: *vulkan.VkQueue) callconv(.C) void,
    vk_bind_image_memory: *const fn (device: vulkan.VkDevice, bindInfoCount: u32, pBindInfos: [*c]const vulkan.VkBindImageMemoryInfo) vulkan.VkResult,
    vk_cmd_pipeline_barrier: *const fn (cmd_buffer: vulkan.VkCommandBuffer, dep_info: [*c]const vulkan.VkDependencyInfo) callconv(.C) void,
    vk_cmd_begin_rendering: *const fn (cmd_buffer: vulkan.VkCommandBuffer, rendering_info: [*c]const vulkan.VkRenderingInfo) callconv(.C) void,
    vk_cmd_end_rendering: *const fn (cmd_buffer: vulkan.VkCommandBuffer) callconv(.C) void,
    vk_cmd_push_descriptor_set: *const fn (commandBuffer: vulkan.VkCommandBuffer, pipelineBindPoint: vulkan.VkPipelineBindPoint, layout: vulkan.VkPipelineLayout, set: u32, descriptorWriteCount: u32, pDescriptorWrites: [*c]const vulkan.VkWriteDescriptorSet) callconv(.C) void,
    vk_get_memory_fd: *const fn (device: vulkan.VkDevice, info: [*c]const vulkan.VkMemoryGetFdInfoKHR, [*c]c_int) callconv(.C) vulkan.VkResult,
};

const HookImageData = struct {
    vk_image: vulkan.VkImage,
    vk_view: vulkan.VkImageView,
    vk_fence: vulkan.VkFence,
    vk_buffer: vulkan.VkBuffer,
    memory: ?*anyopaque,
    image_handle: c_int,
    size: u64,
};

const QueueData = struct {
    vk_queue: vulkan.VkQueue,
    family_index: u32,
    vk_command_pool: vulkan.VkCommandPool = null,
    vk_command_buffers: ?[]vulkan.VkCommandBuffer = null,
    pipeline: ?pipeline.SwapchainPipeline = null,
};

const ActiveCaptureInstance = struct {
    device: *VkDeviceData,

    swapchain: vulkan.VkSwapchainKHR,

    last_render_time: i128,

    hook_images: []HookImageData,

    shm_buf: *HookSharedData,
};

var active_capture_instance: ?ActiveCaptureInstance = null;
var active_capture_instance_lck: std.Thread.Mutex = .{};

const SwapchainData = struct {
    vk_swapchain: vulkan.VkSwapchainKHR = null,

    backbuffer_image_views: []vulkan.VkImageView,
    backbuffer_images: []vulkan.VkImage,

    width: usize,
    height: usize,
    format: vulkan.VkFormat,
};

const VkDeviceData = struct {
    instance_data: *VkInstanceData,

    had_error: bool = false,

    api: DeviceApi,
    vk_device: vulkan.VkDevice,
    vk_phy_device: vulkan.VkPhysicalDevice,
    queues: std.ArrayList(QueueData),
    swapchains: std.ArrayList(SwapchainData),
};

fn getVulkanDeviceDataFromVkDevice(device: vulkan.VkDevice) ?*VkDeviceData {
    vk_device_to_instance_lock.lock();
    defer vk_device_to_instance_lock.unlock();

    return vk_device_to_device_data.get(device);
}

fn getVulkanDeviceDataFromVkQueue(queue: vulkan.VkQueue) ?*VkDeviceData {
    vk_queue_to_device_lock.lock();
    defer vk_queue_to_device_lock.unlock();

    return vk_queue_to_device_data.get(queue);
}

const VkInstanceData = struct {
    instance: vulkan.VkInstance,
    physical_devices: std.ArrayList(vulkan.VkPhysicalDevice),
    devices: std.ArrayList(*VkDeviceData),
};

var vk_instances = std.ArrayList(*VkInstanceData).init(allocator);
var vk_instances_lock = std.Thread.Mutex{};

var vk_device_to_device_data = std.AutoArrayHashMap(vulkan.VkDevice, *VkDeviceData).init(allocator);
var vk_device_to_instance_lock = std.Thread.Mutex{};

var vk_queue_to_device_data = std.AutoArrayHashMap(vulkan.VkQueue, *VkDeviceData).init(allocator);
var vk_queue_to_device_lock = std.Thread.Mutex{};

fn getApi() *const OriginalVulkanApi {
    const lazily_loaded_api = struct {
        var initialized: bool = false;
        var api_data: OriginalVulkanApi = undefined;
    };

    if (!lazily_loaded_api.initialized) {
        lazily_loaded_api.initialized = true;
        lazily_loaded_api.api_data = .{
            .vk_create_instance = @ptrCast(std.c.dlsym(RTLD.NEXT, "vkCreateInstance")),
            .vk_enumerate_physical_devices = @ptrCast(std.c.dlsym(RTLD.NEXT, "vkEnumeratePhysicalDevices")),
            .vk_create_device = @ptrCast(std.c.dlsym(RTLD.NEXT, "vkCreateDevice")),
            .vk_get_instance_proc_addr = @ptrCast(std.c.dlsym(RTLD.NEXT, "vkGetInstanceProcAddr")),
            .vk_get_device_proc_addr = @ptrCast(std.c.dlsym(RTLD.NEXT, "vkGetDeviceProcAddr")),
            .vk_get_device_queue = @ptrCast(std.c.dlsym(RTLD.NEXT, "vkGetDeviceQueue")),
            .vk_queue_present_khr = @ptrCast(std.c.dlsym(RTLD.NEXT, "vkQueuePresentKHR")),
        };
    }

    return &lazily_loaded_api.api_data;
}

fn vkAllocateInstanceData(instance: vulkan.VkInstance) !void {
    vk_instances_lock.lock();
    defer vk_instances_lock.unlock();

    var instance_data = try allocator.create(VkInstanceData);
    instance_data.* = .{
        .instance = instance,
        .physical_devices = std.ArrayList(vulkan.VkPhysicalDevice).init(allocator),
        .devices = std.ArrayList(*VkDeviceData).init(allocator),
    };

    try vk_instances.append(instance_data);
    std.log.info("Allocated instance data {} for {}", .{ @intFromPtr(instance_data), @intFromPtr(instance) });
}

pub export fn vkCreateInstance(pCreateInfo: *const vulkan.VkInstanceCreateInfo, pAllocator: *const vulkan.VkAllocationCallbacks, pInstance: *vulkan.VkInstance) vulkan.VkResult {
    var layer_count: c_uint = 0;
    _ = vulkan.vkEnumerateInstanceLayerProperties(&layer_count, null);
    var layers = allocator.alloc(vulkan.VkLayerProperties, layer_count) catch unreachable;
    _ = vulkan.vkEnumerateInstanceLayerProperties(&layer_count, layers.ptr);

    var create_info = pCreateInfo.*;

    // Inject our extensions
    {
        const our_extensions = [_][*:0]const u8{
            vulkan.VK_KHR_EXTERNAL_MEMORY_CAPABILITIES_EXTENSION_NAME,
        };

        var all_extensions = allocator.alloc([*:0]const u8, our_extensions.len + create_info.enabledExtensionCount) catch unreachable;

        for (create_info.ppEnabledExtensionNames[0..create_info.enabledExtensionCount], 0..) |extension, idx| {
            all_extensions[idx] = extension;
        }

        for (our_extensions) |our_extension| {
            var has_extension = blk: {
                for (all_extensions[0..create_info.enabledExtensionCount]) |extension| {
                    if (std.mem.eql(u8, std.mem.span(our_extension), std.mem.span(extension))) {
                        break :blk true;
                    }
                }

                break :blk false;
            };

            if (!has_extension) {
                all_extensions[create_info.enabledExtensionCount] = our_extension;
                create_info.enabledExtensionCount += 1;
            }
        }

        create_info.ppEnabledExtensionNames = @ptrCast(all_extensions);
    }

    var result = getApi().vk_create_instance(&create_info, pAllocator, pInstance);
    if (result == vulkan.VK_SUCCESS) {
        std.log.info("Creating instace", .{});
        vkAllocateInstanceData(pInstance.*) catch |e| {
            switch (e) {
                else => {
                    std.log.err("Failed to allocate instance data. Error: {s}", .{@errorName(e)});
                },
            }
        };
    }

    return result;
}

fn rememberPhysicalDevices(instance: vulkan.VkInstance, phys_devices: []vulkan.VkPhysicalDevice) !void {
    vk_instances_lock.lock();
    defer vk_instances_lock.unlock();

    var instance_data_maybe: ?*VkInstanceData = null;

    for (vk_instances.items) |item| {
        if (item.instance == instance) {
            instance_data_maybe = item;
        }
    }

    if (instance_data_maybe) |instance_data| {
        try instance_data.physical_devices.ensureUnusedCapacity(phys_devices.len);

        for (phys_devices) |physical_device| {
            var is_device_known = blk: {
                for (instance_data.physical_devices.items) |known_device| {
                    if (physical_device == known_device) {
                        break :blk true;
                    }
                }

                break :blk false;
            };

            if (!is_device_known) {
                try instance_data.physical_devices.append(physical_device);
                std.log.info("Instance {} found physical device {}", .{ @intFromPtr(instance_data), @intFromPtr(physical_device) });
            }
        }
    } else {
        std.log.warn("Couldn't find instance data for vkInstance: {}", .{@intFromPtr(instance)});
    }
}

pub export fn vkEnumeratePhysicalDevices(instance: vulkan.VkInstance, pPhysicalDeviceCount: [*c]u32, pPhysicalDevices: [*c]vulkan.VkPhysicalDevice) vulkan.VkResult {
    var result = getApi().vk_enumerate_physical_devices(instance, pPhysicalDeviceCount, pPhysicalDevices);
    if (result == vulkan.VK_SUCCESS) {
        if (pPhysicalDevices != null) {
            rememberPhysicalDevices(instance, pPhysicalDevices[0..@intCast(pPhysicalDeviceCount.*)]) catch |e| {
                switch (e) {
                    else => {
                        std.log.err("Failed to rememberPhysicalDevices. Error: {s}", .{@errorName(e)});
                    },
                }
            };
        }
    }

    return result;
}

fn rememberQueue(device_data: *VkDeviceData, family_index: u32, queue: vulkan.VkQueue) void {
    for (device_data.queues.items) |known_queue| {
        if (queue == known_queue.vk_queue) {
            return;
        }
    }

    vk_queue_to_device_lock.lock();
    defer vk_queue_to_device_lock.unlock();

    std.log.info("Found new queue: {}", .{@intFromPtr(queue)});

    vk_queue_to_device_data.put(queue, device_data) catch unreachable;
    device_data.queues.append(.{
        .vk_queue = queue,
        .family_index = family_index,
    }) catch unreachable;
}

pub export fn vkGetDeviceQueue(device: vulkan.VkDevice, queue_family_index: c_uint, queue_index: c_uint, queue: *vulkan.VkQueue) callconv(.C) void {
    if (getVulkanDeviceDataFromVkDevice(device)) |device_data| {
        device_data.api.vk_get_device_queue(device, queue_family_index, queue_index, queue);
        rememberQueue(device_data, queue_family_index, queue.*);
    } else {
        getApi().vk_get_device_queue(device, queue_family_index, queue_index, queue);
    }
}

fn rememberNewDevice(physical_device: vulkan.VkPhysicalDevice, device: [*c]vulkan.VkDevice) !void {
    vk_instances_lock.lock();
    defer vk_instances_lock.unlock();

    var instance_data_maybe: ?*VkInstanceData = null;

    main_loop: for (vk_instances.items) |item| {
        for (item.physical_devices.items) |phy| {
            if (phy == physical_device) {
                // Found the matching instance.
                instance_data_maybe = item;
                break :main_loop;
            }
        }
    }

    if (instance_data_maybe) |instance_data| {
        var api = getApi();

        var device_data = try allocator.create(VkDeviceData);
        device_data.* = .{
            .vk_device = device.*,
            .vk_phy_device = physical_device,
            .api = .{
                .vk_create_swapchain_khr = @ptrCast(api.vk_get_device_proc_addr(device.*, "vkCreateSwapchainKHR")),
                .vk_queue_present_khr = @ptrCast(api.vk_get_device_proc_addr(device.*, "vkQueuePresentKHR")),
                .vk_get_device_queue = @ptrCast(api.vk_get_device_proc_addr(device.*, "vkGetDeviceQueue")),
                .vk_bind_image_memory = @ptrCast(api.vk_get_device_proc_addr(device.*, "vkBindImageMemory2KHR")),
                .vk_cmd_pipeline_barrier = @ptrCast(api.vk_get_device_proc_addr(device.*, "vkCmdPipelineBarrier2KHR")),
                .vk_cmd_begin_rendering = @ptrCast(api.vk_get_device_proc_addr(device.*, "vkCmdBeginRenderingKHR")),
                .vk_cmd_end_rendering = @ptrCast(api.vk_get_device_proc_addr(device.*, "vkCmdEndRenderingKHR")),
                .vk_cmd_push_descriptor_set = @ptrCast(api.vk_get_device_proc_addr(device.*, "vkCmdPushDescriptorSetKHR")),
                .vk_get_memory_fd = @ptrCast(api.vk_get_device_proc_addr(device.*, "vkGetMemoryFdKHR")),
            },

            .instance_data = instance_data,
            .queues = std.ArrayList(QueueData).initCapacity(allocator, 8) catch unreachable,
            .swapchains = std.ArrayList(SwapchainData).initCapacity(allocator, 8) catch unreachable,
        };

        try instance_data.devices.append(device_data);

        //
        {
            vk_device_to_instance_lock.lock();
            defer vk_device_to_instance_lock.unlock();

            try vk_device_to_device_data.put(device.*, device_data);
        }

        std.log.info("Instance {} found device {}", .{ @intFromPtr(instance_data), @intFromPtr(device.*) });
    } else {
        std.log.warn("Couldn't find vkInstance for physicalDevice {}. Will ignore vkDevice: {}", .{ @intFromPtr(physical_device), @intFromPtr(device.*) });
    }
}

pub export fn vkCreateDevice(physicalDevice: vulkan.VkPhysicalDevice, pCreateInfo: [*c]const vulkan.VkDeviceCreateInfo, pAllocator: [*c]const vulkan.VkAllocationCallbacks, pDevice: [*c]vulkan.VkDevice) vulkan.VkResult {
    var create_info = pCreateInfo.*;

    // Inject our extensions
    {
        const our_extensions = [_][*:0]const u8{
            vulkan.VK_KHR_BIND_MEMORY_2_EXTENSION_NAME,
            vulkan.VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
            vulkan.VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
            vulkan.VK_KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME,
            vulkan.VK_KHR_CREATE_RENDERPASS_2_EXTENSION_NAME,
            vulkan.VK_KHR_MAINTENANCE_2_EXTENSION_NAME,
            vulkan.VK_KHR_MULTIVIEW_EXTENSION_NAME,
            vulkan.VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME,
            vulkan.VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
            vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
        };

        var all_extensions = allocator.alloc([*:0]const u8, our_extensions.len + create_info.enabledExtensionCount) catch unreachable;

        for (create_info.ppEnabledExtensionNames[0..create_info.enabledExtensionCount], 0..) |extension, idx| {
            all_extensions[idx] = extension;
        }

        for (our_extensions) |our_extension| {
            var has_extension = blk: {
                for (all_extensions[0..create_info.enabledExtensionCount]) |extension| {
                    if (std.mem.eql(u8, std.mem.span(our_extension), std.mem.span(extension))) {
                        break :blk true;
                    }
                }

                break :blk false;
            };

            if (!has_extension) {
                all_extensions[create_info.enabledExtensionCount] = our_extension;
                create_info.enabledExtensionCount += 1;
            }
        }

        create_info.ppEnabledExtensionNames = @ptrCast(all_extensions);
    }

    var enabled_features = if (create_info.pEnabledFeatures != null) create_info.pEnabledFeatures.* else std.mem.zeroes(vulkan.VkPhysicalDeviceFeatures);
    enabled_features.depthClamp = vulkan.VK_TRUE;
    create_info.pEnabledFeatures = &enabled_features;

    var synch2_feature_khr: vulkan.VkPhysicalDeviceSynchronization2FeaturesKHR = undefined;
    var dynamic_rendering: vulkan.VkPhysicalDeviceDynamicRenderingFeaturesKHR = undefined;

    var create_info_as_in_struct = @as(*const vulkan.VkBaseInStructure, @ptrCast(@alignCast(&create_info)));
    if (!vulkan.vkStructureHasNext(create_info_as_in_struct, vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES_KHR)) {
        synch2_feature_khr = std.mem.zeroInit(vulkan.VkPhysicalDeviceSynchronization2FeaturesKHR, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES_KHR,
            .pNext = null,
            .synchronization2 = vulkan.VK_TRUE,
        });

        var next = create_info.pNext;
        synch2_feature_khr.pNext = @ptrCast(@constCast(next));
        create_info.pNext = &synch2_feature_khr;
    }

    if (!vulkan.vkStructureHasNext(create_info_as_in_struct, vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR)) {
        dynamic_rendering = std.mem.zeroInit(vulkan.VkPhysicalDeviceDynamicRenderingFeaturesKHR, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
            .pNext = null,
            .dynamicRendering = vulkan.VK_TRUE,
        });

        var next = create_info.pNext;
        dynamic_rendering.pNext = @ptrCast(@constCast(next));
        create_info.pNext = &dynamic_rendering;
    }

    var result = getApi().vk_create_device(physicalDevice, &create_info, pAllocator, pDevice);
    std.log.info("res: {}", .{result});
    if (result == vulkan.VK_SUCCESS) {
        rememberNewDevice(physicalDevice, pDevice) catch |e| {
            switch (e) {
                else => {
                    std.log.err("Failed to rememberNewDevice. Error: {s}", .{@errorName(e)});
                },
            }
        };
    }

    return result;
}

pub export fn vkGetInstanceProcAddr(instance: vulkan.VkInstance, pName: [*c]const u8) *const anyopaque {
    if (std.mem.eql(u8, std.mem.span(pName), "vkGetDeviceProcAddr")) {
        return @ptrCast(&vkGetDeviceProcAddr);
    }

    return getApi().vk_get_instance_proc_addr(instance, pName);
}

pub export fn vkGetDeviceProcAddr(device: vulkan.VkDevice, name: [*c]const u8) *const anyopaque {
    var name_as_span = std.mem.span(name);

    // Only redirect API calls if we have a valid mapping for the vk_device.
    if (getVulkanDeviceDataFromVkDevice(device) != null) {
        if (std.mem.eql(u8, name_as_span, "vkCreateSwapchainKHR")) {
            return @ptrCast(&vkCreateSwapchainKHR);
        }
        if (std.mem.eql(u8, name_as_span, "vkQueuePresentKHR")) {
            return @ptrCast(&vkQueuePresentKHR);
        }
        if (std.mem.eql(u8, name_as_span, "vkGetDeviceQueue")) {
            return @ptrCast(&vkGetDeviceQueue);
        }
    }

    return @ptrCast(getApi().vk_get_device_proc_addr(device, name));
}
