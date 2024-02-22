const std = @import("std");
const vulkan = @import("vk.zig");
const pipeline = @import("pipeline.zig");

const c = @import("shared.zig").c;
const HookSharedData = @import("shared.zig").HookSharedData;
const formatSectionName = @import("shared.zig").formatSectionName;

const RTLD = struct {
    pub const NEXT = @as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));
};

const InstanceApi = vulkan.InstanceApi;
const DeviceApi = vulkan.DeviceApi;

var sequence: u32 = 0;

fn notifyWorker(capture_instance: *ActiveCaptureInstance) void {

    // This will be overwritten by future capture instances. Cache this so we can clean it up later.
    var original_shm_buf = capture_instance.shm_buf.*;

    while (capture_instance.shutdown == null) {
        capture_instance.notify.sem.wait();

        if (capture_instance.shutdown != null) {
            break;
        }

        capture_instance.notify.lock.lock();
        var buffer_to_wait_on = capture_instance.notify.pending_buffers.orderedRemove(0);
        capture_instance.notify.lock.unlock();

        var hook_image = capture_instance.hook_images[buffer_to_wait_on];

        vulkan.vkCall(capture_instance.device.api.vkWaitForFences.?, .{
            capture_instance.device.vk_device,
            1,
            &hook_image.vk_fence,
            vulkan.VK_TRUE,
            vulkan.UINT64_MAX,
        }) catch break;

        vulkan.vkCall(capture_instance.device.api.vkResetFences.?, .{
            capture_instance.device.vk_device,
            1,
            &hook_image.vk_fence,
        }) catch break;

        var post_sem = false;
        {
            _ = c.pthread_mutex_lock(&capture_instance.shm_buf.lock);
            capture_instance.shm_buf.latest_texture = @intCast(buffer_to_wait_on);

            var prev_val: c_int = 0;
            _ = c.sem_getvalue(&capture_instance.shm_buf.new_texture_signal, &prev_val);

            if (prev_val == 0) {
                post_sem = true;
            }

            _ = c.pthread_mutex_unlock(&capture_instance.shm_buf.lock);
        }

        _ = c.pthread_mutex_unlock(&capture_instance.shm_buf.texture_locks[buffer_to_wait_on]);

        if (post_sem) {
            _ = c.sem_post(&capture_instance.shm_buf.new_texture_signal);
        }
    }

    // Wait until all images are made available..
    std.log.info("Deallocating shm_buf ({})", .{original_shm_buf.sequence});

    if (capture_instance.shutdown.? != .RemoteDied) {
        //TODO: Fix deadlock when remote dies while we are shutting down ;)

        std.log.debug("Going into shmbuf lock", .{});

        // Tell remote that we are shutting down.
        _ = c.pthread_mutex_lock(&original_shm_buf.lock);
        capture_instance.shm_buf.shutdown = true;
        _ = c.pthread_mutex_unlock(&original_shm_buf.lock);

        std.log.debug("Left shmbuf lock", .{});

        _ = c.sem_post(&original_shm_buf.new_texture_signal);

        std.log.debug("Entering Lock Texture Loop: {}", .{capture_instance.hook_images.len});
        for (0..capture_instance.hook_images.len) |idx| {
            std.log.debug("Locking Texture: {}", .{idx});
            _ = c.pthread_mutex_lock(&original_shm_buf.texture_locks[idx]);
            std.log.debug("Locked Texture: {}", .{idx});
        }

        std.log.debug("Entering process lock again", .{});
        _ = c.pthread_mutex_lock(&original_shm_buf.lock);
        std.log.debug("Process shutdown sequence completed", .{});
    }

    std.log.debug("Destroying hook process alive lock", .{});
    _ = c.pthread_mutex_destroy(&original_shm_buf.hook_process_alive_lock);

    std.log.debug("Destroying remote process alive lock", .{});
    _ = c.pthread_mutex_destroy(&original_shm_buf.remote_process_alive_lock);

    std.log.debug("Destroying shmbuf lock", .{});
    _ = c.pthread_mutex_destroy(&original_shm_buf.lock);

    std.log.debug("Destroying texture signal", .{});
    _ = c.sem_destroy(&original_shm_buf.new_texture_signal);

    for (capture_instance.hook_images, 0..) |image, idx| {
        std.log.debug("Destroying hook image mutex {}", .{idx});
        _ = c.pthread_mutex_destroy(&original_shm_buf.texture_locks[idx]);
        _ = image;
    }

    std.log.info("Successfully deallocated shm_buf ({})", .{original_shm_buf.sequence});
    allocator.destroy(capture_instance);
}

fn copyIntoHookTexture(device_data: *VkDeviceData, queue: vulkan.VkQueue, present_info: *vulkan.VkPresentInfoKHR) !void {
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
                break :blk present_info.pImageIndices[idx];
            }
        }

        return error.SwapchainNotFound;
    };

    var image_and_lock = blk: {
        _ = c.pthread_mutex_lock(&capture_instance.shm_buf.lock);
        defer _ = c.pthread_mutex_unlock(&capture_instance.shm_buf.lock);

        for (capture_instance.hook_images, capture_instance.shm_buf.texture_locks[0..capture_instance.hook_images.len], 0..) |*hook_image, *lock, idx| {
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

    var hook_image = image_and_lock.hook_image;
    var lock = image_and_lock.lock;
    _ = lock; // autofix

    if (queue_data.vk_command_pool == null) {
        var create_info = std.mem.zeroInit(vulkan.VkCommandPoolCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queue_data.family_index,
            .flags = vulkan.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT | vulkan.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        });

        try vulkan.vkCall(device_data.api.vkCreateCommandPool.?, .{
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

            try vulkan.vkCall(device_data.api.vkAllocateCommandBuffers.?, .{ device_data.vk_device, &allocate_info, cmd_buffer });
        }
    }

    if (queue_data.pipeline == null) {
        queue_data.pipeline = try pipeline.createSwapchainPipeline(device_data.api, device_data.vk_device, swapchain_data.format);
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

    try vulkan.vkCall(device_data.api.vkResetCommandBuffer.?, .{ cmd_buffer, 0 });

    const begin_info = std.mem.zeroInit(vulkan.VkCommandBufferBeginInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = vulkan.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });

    try vulkan.vkCall(device_data.api.vkBeginCommandBuffer.?, .{ cmd_buffer, &begin_info });

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

        try vulkan.vkCall(device_data.api.vkCmdPipelineBarrier2.?, .{ cmd_buffer, &dep_info });
    }

    try vulkan.vkCall(device_data.api.vkCmdBeginRendering.?, .{ cmd_buffer, &rendering_info });
    {
        var viewport = std.mem.zeroInit(vulkan.VkViewport, .{
            .maxDepth = @as(f32, 1),
            .width = @as(f32, @floatFromInt(swapchain_data.width)),
            .height = @as(f32, @floatFromInt(swapchain_data.height)),
        });

        try vulkan.vkCall(device_data.api.vkCmdSetViewport.?, .{ cmd_buffer, 0, 1, &viewport });

        var scissors = std.mem.zeroInit(
            vulkan.VkRect2D,
            .{
                .extent = .{
                    .width = @as(u32, @intCast(swapchain_data.width)),
                    .height = @as(u32, @intCast(swapchain_data.height)),
                },
            },
        );

        try vulkan.vkCall(device_data.api.vkCmdSetScissor.?, .{ cmd_buffer, 0, 1, &scissors });

        try vulkan.vkCall(device_data.api.vkCmdBindPipeline.?, .{ cmd_buffer, vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS, queue_data.pipeline.?.vk_pipeline });

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

        try vulkan.vkCall(device_data.api.vkCmdPushDescriptorSetKHR.?, .{ cmd_buffer, vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS, queue_data.pipeline.?.vk_pipeline_layout, 0, 1, &write_info });

        try vulkan.vkCall(device_data.api.vkCmdDraw.?, .{ cmd_buffer, 3, 1, 0, 0 });
    }

    try vulkan.vkCall(device_data.api.vkCmdEndRendering.?, .{cmd_buffer});

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

        try vulkan.vkCall(device_data.api.vkCmdPipelineBarrier2.?, .{ cmd_buffer, &dep_info });
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

        try vulkan.vkCall(device_data.api.vkCmdPipelineBarrier2.?, .{ cmd_buffer, &dep_info });
    }

    try vulkan.vkCall(device_data.api.vkEndCommandBuffer.?, .{cmd_buffer});

    const submit_info = std.mem.zeroInit(vulkan.VkSubmitInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pCommandBuffers = &cmd_buffer,
        .commandBufferCount = 1,
        .pWaitSemaphores = present_info.pWaitSemaphores,
        .waitSemaphoreCount = present_info.waitSemaphoreCount,
        .pSignalSemaphores = &hook_image.vk_sem,
        .signalSemaphoreCount = 1,
    });

    present_info.waitSemaphoreCount = 1;
    present_info.pWaitSemaphores = &hook_image.vk_sem;

    try vulkan.vkCall(device_data.api.vkQueueSubmit.?, .{
        queue,
        1,
        &submit_info,
        hook_image.vk_fence,
    });

    {
        capture_instance.notify.lock.lock();
        defer capture_instance.notify.lock.unlock();
        try capture_instance.notify.pending_buffers.append(image_and_lock.idx);
    }

    capture_instance.notify.sem.post();
}

const ActiveCaptureInstanceTimeoutNs = std.time.ns_per_s * 2;

fn allocateHookImages(device_data: *VkDeviceData, swapchain_data: SwapchainData) ![]HookImageData {
    var hook_images = allocator.alloc(HookImageData, 4) catch unreachable;
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

        if (device_data.api.vkCreateImage.?(device_data.vk_device, &image_info, null, &hook_image.vk_image) != vulkan.VK_SUCCESS) {
            return error.VkCreateImageFailed;
        }

        var memory_requirements: vulkan.VkMemoryRequirements = undefined;
        try vulkan.vkCall(device_data.api.vkGetImageMemoryRequirements.?, .{ device_data.vk_device, hook_image.vk_image, &memory_requirements });

        hook_image.size = memory_requirements.size;

        // Allocate texture memory
        {
            const memory_type_index = mem_type: {
                var mem_props: vulkan.VkPhysicalDeviceMemoryProperties = undefined;
                try vulkan.vkCall(device_data.instance_data.api.vkGetPhysicalDeviceMemoryProperties.?, .{ device_data.vk_phy_device, &mem_props });

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
            try vulkan.vkCall(device_data.api.vkAllocateMemory.?, .{ device_data.vk_device, &memory_allocate_info, null, &mem });

            var bind_info = std.mem.zeroInit(vulkan.VkBindImageMemoryInfo, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO,
                .pNext = null,
                .image = hook_image.vk_image,
                .memory = mem,
                .memoryOffset = 0,
            });

            try vulkan.vkCall(device_data.api.vkBindImageMemory2.?, .{ device_data.vk_device, 1, &bind_info });

            var get_memory_fd_info = std.mem.zeroInit(vulkan.VkMemoryGetFdInfoKHR, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
                .memory = mem,
                .handleType = vulkan.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
            });

            try vulkan.vkCall(device_data.api.vkGetMemoryFdKHR.?, .{ device_data.vk_device, &get_memory_fd_info, &hook_image.image_handle });
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

        if (device_data.api.vkCreateImageView.?(device_data.vk_device, &info, null, &hook_image.vk_view) != vulkan.VK_SUCCESS) {
            return error.FailedToCreateImageView;
        }

        var fence_create_info = std.mem.zeroInit(vulkan.VkFenceCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        });

        try vulkan.vkCall(device_data.api.vkCreateFence.?, .{
            device_data.vk_device, &fence_create_info, null, &hook_image.vk_fence,
        });

        var sem_create_info = std.mem.zeroInit(vulkan.VkSemaphoreCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        });
        try vulkan.vkCall(device_data.api.vkCreateSemaphore.?, .{ device_data.vk_device, &sem_create_info, null, &hook_image.vk_sem });
    }

    return hook_images;
}

fn deinitCaptureInstance(reason: ActiveCaptureInstance.ShutdownReason) void {
    var capture_instance = active_capture_instance.?;
    _ = c.pthread_mutex_unlock(&capture_instance.shm_buf.hook_process_alive_lock);

    {
        capture_instance.notify.lock.lock();
        defer capture_instance.notify.lock.unlock();
        _ = c.pthread_mutex_unlock(&capture_instance.shm_buf.hook_process_alive_lock);
        capture_instance.shutdown = reason;
    }

    capture_instance.notify.sem.post();

    capture_instance.notify.worker.join();

    active_capture_instance = null;
}

fn isOrTrySetSwapchainActive(device_data: *VkDeviceData, swapchains: []const vulkan.VkSwapchainKHR) !bool {
    active_capture_instance_lck.lock();
    defer active_capture_instance_lck.unlock();

    if (active_capture_instance) |capture_instance| {
        var lock_result = c.pthread_mutex_trylock(&capture_instance.shm_buf.remote_process_alive_lock);
        var is_remote_process_alive = lock_result ==
            @intFromEnum(std.os.linux.E.BUSY);

        var remote_died = capture_instance.was_remote_process_alive and !is_remote_process_alive;
        if (lock_result == @intFromEnum(std.os.linux.E.OWNERDEAD)) {
            remote_died = true;
        }

        if (lock_result == 0) {
            _ = c.pthread_mutex_unlock(&capture_instance.shm_buf.remote_process_alive_lock);
        }

        if (remote_died) {
            // Remote process died, reallocate the swapchain data.
            std.log.info("Remote process died", .{});
            deinitCaptureInstance(.RemoteDied);
            return false;
        } else {
            capture_instance.was_remote_process_alive = is_remote_process_alive;
        }

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

                    // Wait for the chain to have received a few frames.
                    if (chain_data.submission_count < 30) {
                        continue;
                    }

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
        if (active_capture_instance != null) {
            deinitCaptureInstance(.Other);
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

        {
            var att = std.mem.zeroes(c.pthread_mutexattr_t);
            _ = c.pthread_mutexattr_init(&att);
            _ = c.pthread_mutexattr_setpshared(&att, c.PTHREAD_PROCESS_SHARED);

            if (c.pthread_mutex_init(&shm_buf.lock, &att) == -1) {
                return error.FailedToInitializeMutex;
            }
        }

        _ = c.pthread_mutex_lock(&shm_buf.lock);
        defer _ = c.pthread_mutex_unlock(&shm_buf.lock);

        @memset(@as([*c]u8, @ptrCast(shm_buf))[0..@sizeOf(HookSharedData)], 0);

        var hook_images = try allocateHookImages(device_data, best_swapchain);
        std.debug.assert(hook_images.len <= HookSharedData.MaxTextures);

        for (hook_images, 0..) |image, idx| {
            var att = std.mem.zeroes(c.pthread_mutexattr_t);
            _ = c.pthread_mutexattr_init(&att);
            _ = c.pthread_mutexattr_setpshared(&att, c.PTHREAD_PROCESS_SHARED);

            if (c.pthread_mutex_init(&shm_buf.texture_locks[idx], &att) == -1) {
                return error.FailedToInitializeMutex;
            }

            shm_buf.texture_handles[idx] = image.image_handle;
        }

        if (c.sem_init(&shm_buf.new_texture_signal, 1, 0) == -1) {
            return error.FailedToInitSem;
        }

        {
            var att = std.mem.zeroes(c.pthread_mutexattr_t);
            _ = c.pthread_mutexattr_init(&att);
            _ = c.pthread_mutexattr_setpshared(&att, c.PTHREAD_PROCESS_SHARED);

            if (c.pthread_mutex_init(&shm_buf.lock, &att) == -1) {
                return error.FailedToInitializeMutex;
            }
        }

        {
            var att = std.mem.zeroes(c.pthread_mutexattr_t);
            _ = c.pthread_mutexattr_init(&att);
            _ = c.pthread_mutexattr_setpshared(&att, c.PTHREAD_PROCESS_SHARED);
            _ = c.pthread_mutexattr_setrobust(&att, c.PTHREAD_MUTEX_ROBUST);

            if (c.pthread_mutex_init(&shm_buf.hook_process_alive_lock, &att) == -1) {
                return error.FailedToInitializeMutex;
            }
        }

        {
            var att = std.mem.zeroes(c.pthread_mutexattr_t);
            _ = c.pthread_mutexattr_init(&att);
            _ = c.pthread_mutexattr_setpshared(&att, c.PTHREAD_PROCESS_SHARED);
            _ = c.pthread_mutexattr_setrobust(&att, c.PTHREAD_MUTEX_ROBUST);

            if (c.pthread_mutex_init(&shm_buf.remote_process_alive_lock, &att) == -1) {
                return error.FailedToInitializeMutex;
            }
        }

        shm_buf.num_textures = hook_images.len;
        shm_buf.latest_texture = -1;
        shm_buf.version = HookSharedData.HookVersion;
        shm_buf.format = best_swapchain.format;
        shm_buf.width = @intCast(best_swapchain.width);
        shm_buf.height = @intCast(best_swapchain.height);
        shm_buf.size = @intCast(hook_images[0].size);
        shm_buf.sequence = next_active_capture_instance_seq;

        active_capture_instance = try allocator.create(ActiveCaptureInstance);

        active_capture_instance.?.* = .{
            .device = device_data,
            .swapchain = best_swapchain.vk_swapchain,
            .last_render_time = std.time.nanoTimestamp(),
            .hook_images = hook_images,
            .shm_buf = shm_buf,
            .was_remote_process_alive = false,
            .notify = .{
                .lock = .{},
                .pending_buffers = std.ArrayList(usize).init(allocator),
                .worker = undefined,
                .sem = .{},
            },
            .shutdown = null,
        };

        active_capture_instance.?.notify.worker = try std.Thread.spawn(.{}, notifyWorker, .{active_capture_instance.?});

        next_active_capture_instance_seq += 1;

        _ = c.pthread_mutex_lock(&shm_buf.hook_process_alive_lock);

        std.log.info("Set new swapchain active {} ({})", .{ @intFromPtr(best_swapchain.vk_swapchain), shm_buf.sequence });

        return true;
    }

    return false;
}

var vk_device_proc_addr_original: ?*const fn (device: vulkan.VkDevice, name: [*c]const u8) *const anyopaque = null;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const HookImageData = struct {
    vk_image: vulkan.VkImage,
    vk_view: vulkan.VkImageView,
    vk_fence: vulkan.VkFence,
    image_handle: c_int,
    size: u64,
    vk_sem: vulkan.VkSemaphore,
};

const QueueData = struct {
    vk_queue: vulkan.VkQueue,
    family_index: u32,
    vk_command_pool: vulkan.VkCommandPool = null,
    vk_command_buffers: ?[]vulkan.VkCommandBuffer = null,
    pipeline: ?pipeline.SwapchainPipeline = null,
};

const ActiveCaptureInstance = struct {
    const ShutdownReason = enum { RemoteDied, Other };

    device: *VkDeviceData,

    swapchain: vulkan.VkSwapchainKHR,

    last_render_time: i128,

    hook_images: []HookImageData,

    shm_buf: *HookSharedData,

    was_remote_process_alive: bool,

    notify: struct {
        lock: std.Thread.Mutex,
        pending_buffers: std.ArrayList(usize),
        worker: std.Thread,
        sem: std.Thread.Semaphore,
    },

    shutdown: ?ShutdownReason,
};

var active_capture_instance: ?*ActiveCaptureInstance = null;
var next_active_capture_instance_seq: usize = 1;
var active_capture_instance_lck: std.Thread.Mutex = .{};

const SwapchainData = struct {
    vk_swapchain: vulkan.VkSwapchainKHR = null,

    backbuffer_image_views: []vulkan.VkImageView,
    backbuffer_images: []vulkan.VkImage,

    width: usize,
    height: usize,
    format: vulkan.VkFormat,

    submission_count: usize,
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
    api: InstanceApi,
    physical_devices: std.ArrayList(vulkan.VkPhysicalDevice),
    devices: std.ArrayList(*VkDeviceData),
};

var vk_instances = std.ArrayList(*VkInstanceData).init(allocator);
var vk_instances_lock = std.Thread.Mutex{};

var vk_device_to_device_data = std.AutoArrayHashMap(vulkan.VkDevice, *VkDeviceData).init(allocator);
var vk_device_to_instance_lock = std.Thread.Mutex{};

var vk_queue_to_device_data = std.AutoArrayHashMap(vulkan.VkQueue, *VkDeviceData).init(allocator);
var vk_queue_to_device_lock = std.Thread.Mutex{};

pub fn vkQueuePresentKHR(queue: vulkan.VkQueue, present_info: *const vulkan.VkPresentInfoKHR) callconv(.C) vulkan.VkResult {
    if (getVulkanDeviceDataFromVkQueue(queue)) |device_data| {
        var present = present_info.*;
        if (!device_data.had_error) {
            for (device_data.swapchains.items) |*swapchain| {
                for (present_info.pSwapchains[0..present_info.swapchainCount]) |in_swapchain| {
                    if (in_swapchain == swapchain.vk_swapchain) {
                        swapchain.submission_count += 1;
                    }
                }
            }

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
                copyIntoHookTexture(device_data, queue, &present) catch |e| {
                    switch (e) {
                        else => {
                            std.log.err("Error occured during copyIntoHookTexture invocation. Error: {s}", .{@errorName(e)});
                            device_data.had_error = true;
                        },
                    }
                };
            }
        }
        return device_data.api.vkQueuePresentKHR.?(queue, &present);
    } else {
        // std.log.err("vkQueuePresentKHR failed! We have no device data.", .{});
        return vulkan.VK_SUCCESS;
    }
}

fn rememberSwapchain(device_data: *VkDeviceData, swapchain: vulkan.VkSwapchainKHR, create_info: *const vulkan.VkSwapchainCreateInfoKHR) !void {
    var swapchain_data = blk: {
        var count: c_uint = 0;

        if (device_data.api.vkGetSwapchainImagesKHR.?(device_data.vk_device, swapchain, &count, null) != vulkan.VK_SUCCESS) {
            std.log.warn("Failed to get swapchain images from chain {}", .{@intFromPtr(swapchain)});
            return error.FailedToGetSwapchainimages;
        }

        var images = try allocator.alloc(vulkan.VkImage, count);
        var image_views = try allocator.alloc(vulkan.VkImageView, count);

        if (device_data.api.vkGetSwapchainImagesKHR.?(device_data.vk_device, swapchain, &count, images.ptr) != vulkan.VK_SUCCESS) {
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

            if (device_data.api.vkCreateImageView.?(device_data.vk_device, &info, null, view) != vulkan.VK_SUCCESS) {
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
            .submission_count = 0,
        };
    };

    try device_data.swapchains.append(swapchain_data);

    std.log.info(
        "Create swapchain {}x{} ({})",
        .{ create_info.imageExtent.width, create_info.imageExtent.height, create_info.imageFormat },
    );
}

pub fn vkCreateSwapchainKHR(device: vulkan.VkDevice, pCreateInfo: *const vulkan.VkSwapchainCreateInfoKHR, pAllocator: *const vulkan.VkAllocationCallbacks, pSwapchain: *vulkan.VkSwapchainKHR) vulkan.VkResult {
    if (getVulkanDeviceDataFromVkDevice(device)) |device_data| {
        var create_info = pCreateInfo.*;
        create_info.imageUsage |= vulkan.VK_IMAGE_USAGE_SAMPLED_BIT;
        var swapchain_res = device_data.api.vkCreateSwapchainKHR.?(device, &create_info, pAllocator, pSwapchain);

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
        std.log.err("vkCreateSwapchainKHR failed, we have no device data", .{});
        return vulkan.VK_ERROR_UNKNOWN;
    }
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

pub fn vkGetDeviceQueue(device: vulkan.VkDevice, queue_family_index: c_uint, queue_index: c_uint, queue: *vulkan.VkQueue) callconv(.C) void {
    if (getVulkanDeviceDataFromVkDevice(device)) |device_data| {
        device_data.api.vkGetDeviceQueue.?(device, queue_family_index, queue_index, queue);
        rememberQueue(device_data, queue_family_index, queue.*);
    } else {
        std.log.err("vkGetDeviceQueue called but we have no device data", .{});
    }
}

fn rememberPhysicalDevices(instance_data: *VkInstanceData, phys_devices: []vulkan.VkPhysicalDevice) !void {
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
}

pub fn vkEnumeratePhysicalDevices(instance: vulkan.VkInstance, pPhysicalDeviceCount: [*c]u32, pPhysicalDevices: [*c]vulkan.VkPhysicalDevice) callconv(.C) vulkan.VkResult {
    var instance_data_maybe: ?*VkInstanceData = blk: {
        vk_instances_lock.lock();
        defer vk_instances_lock.unlock();

        for (vk_instances.items) |item| {
            if (item.instance == instance) {
                break :blk item;
            }
        }

        break :blk null;
    };

    if (instance_data_maybe) |instance_data| {
        var result = instance_data.api.vkEnumeratePhysicalDevices.?(instance, pPhysicalDeviceCount, pPhysicalDevices);
        if (result == vulkan.VK_SUCCESS) {
            if (pPhysicalDevices != null) {
                rememberPhysicalDevices(instance_data, pPhysicalDevices[0..@intCast(pPhysicalDeviceCount.*)]) catch |e| {
                    switch (e) {
                        else => {
                            std.log.err("Failed to rememberPhysicalDevices. Error: {s}", .{@errorName(e)});
                            return vulkan.VK_ERROR_UNKNOWN;
                        },
                    }
                };
            }
        }

        return result;
    } else {
        std.log.err("Enumerate Physical Devices called but we have no instance data", .{});
        return vulkan.VK_ERROR_UNKNOWN;
    }
}

fn injectDeviceFeatures(create_info: *vulkan.VkDeviceCreateInfo) void {
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

        if (create_info.ppEnabledExtensionNames != null) {
            for (create_info.ppEnabledExtensionNames[0..create_info.enabledExtensionCount], 0..) |extension, idx| {
                all_extensions[idx] = extension;
            }
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

    // This does leak ;)
    var synch2_feature_khr = gpa.allocator().create(vulkan.VkPhysicalDeviceSynchronization2FeaturesKHR) catch unreachable;
    var dynamic_rendering = gpa.allocator().create(vulkan.VkPhysicalDeviceDynamicRenderingFeaturesKHR) catch unreachable;

    var create_info_as_in_struct = @as(*const vulkan.VkBaseInStructure, @ptrCast(@alignCast(create_info)));
    if (!vulkan.vkStructureHasNext(create_info_as_in_struct, vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES_KHR)) {
        synch2_feature_khr.* = std.mem.zeroInit(vulkan.VkPhysicalDeviceSynchronization2FeaturesKHR, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES_KHR,
            .pNext = null,
            .synchronization2 = vulkan.VK_TRUE,
        });

        var next = create_info.pNext;
        synch2_feature_khr.pNext = @ptrCast(@constCast(next));
        create_info.pNext = synch2_feature_khr;
    }

    if (!vulkan.vkStructureHasNext(create_info_as_in_struct, vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR)) {
        dynamic_rendering.* = std.mem.zeroInit(vulkan.VkPhysicalDeviceDynamicRenderingFeaturesKHR, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
            .pNext = null,
            .dynamicRendering = vulkan.VK_TRUE,
        });

        var next = create_info.pNext;
        dynamic_rendering.pNext = @ptrCast(@constCast(next));
        create_info.pNext = dynamic_rendering;
    }
}

fn rememberNewDevice(instance_data: *VkInstanceData, physical_device: vulkan.VkPhysicalDevice, device: vulkan.VkDevice, get_proc_addr: vulkan.PFN_vkGetDeviceProcAddr) !void {
    var device_data = try allocator.create(VkDeviceData);

    var api: DeviceApi = undefined;
    inline for (std.meta.fields(DeviceApi)) |field| {
        comptime var name_buffer: [field.name.len + 1:0]u8 = undefined;
        comptime {
            std.mem.copy(u8, name_buffer[0..field.name.len], field.name);
            name_buffer[field.name.len] = 0;
        }

        @field(api, field.name) = @ptrCast(get_proc_addr.?(device, &name_buffer));

        if (@field(api, field.name) == null) {
            std.log.err("Couldn't find function {s}", .{field.name});
            return error.FunctionNotFound;
        }
    }

    device_data.* = .{
        .vk_device = device,
        .vk_phy_device = physical_device,
        .api = api,
        .instance_data = instance_data,
        .queues = std.ArrayList(QueueData).initCapacity(allocator, 8) catch unreachable,
        .swapchains = std.ArrayList(SwapchainData).initCapacity(allocator, 8) catch unreachable,
    };

    try instance_data.devices.append(device_data);

    //
    {
        vk_device_to_instance_lock.lock();
        defer vk_device_to_instance_lock.unlock();

        try vk_device_to_device_data.put(device, device_data);
    }

    std.log.info("Instance {} found device {}", .{ @intFromPtr(instance_data), @intFromPtr(device) });
}

pub fn vkCreateDevice(physicalDevice: vulkan.VkPhysicalDevice, pCreateInfo: [*c]const vulkan.VkDeviceCreateInfo, pAllocator: [*c]const vulkan.VkAllocationCallbacks, pDevice: [*c]vulkan.VkDevice) vulkan.VkResult {
    var create_info = pCreateInfo.*;

    injectDeviceFeatures(&create_info);

    var instance_data_maybe: ?*VkInstanceData = blk: {
        vk_instances_lock.lock();
        defer vk_instances_lock.unlock();

        for (vk_instances.items) |item| {
            for (item.physical_devices.items) |phys_dev| {
                if (phys_dev == physicalDevice) {
                    break :blk item;
                }
            }
        }

        break :blk null;
    };

    if (instance_data_maybe == null) {
        std.log.err("Couldn't find instance associated with physical device {}", .{@intFromPtr(physicalDevice)});
        return vulkan.VK_ERROR_INITIALIZATION_FAILED;
    }

    var layer_create_info: ?*vulkan.VkLayerDeviceCreateInfo = @constCast(@alignCast(@ptrCast(create_info.pNext)));
    while (layer_create_info != null and (layer_create_info.?.sType != vulkan.VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO or layer_create_info.?.function != vulkan.VK_LAYER_LINK_INFO)) {
        layer_create_info = @constCast(@alignCast(@ptrCast(layer_create_info.?.pNext)));
    }

    if (layer_create_info == null) {
        return vulkan.VK_ERROR_INITIALIZATION_FAILED;
    }

    var get_instance_proc_addr = layer_create_info.?.u.pLayerInfo.*.pfnNextGetInstanceProcAddr;
    var get_device_proc_addr = layer_create_info.?.u.pLayerInfo.*.pfnNextGetDeviceProcAddr;

    var create_device: vulkan.PFN_vkCreateDevice = @ptrCast(get_instance_proc_addr.?(null, "vkCreateDevice"));

    layer_create_info.?.u.pLayerInfo = layer_create_info.?.u.pLayerInfo.*.pNext;

    var result = create_device.?(physicalDevice, &create_info, pAllocator, pDevice);

    if (result == vulkan.VK_SUCCESS) {
        // std.log.info("Crete dev", .{});
        rememberNewDevice(instance_data_maybe.?, physicalDevice, pDevice.*, get_device_proc_addr) catch |e| {
            switch (e) {
                else => {
                    std.log.err("Failed to rememberNewDevice. Error: {s}", .{@errorName(e)});
                },
            }
        };
    }

    return result;
}

fn injectInstanceFeatures(create_info: *vulkan.VkInstanceCreateInfo) void {

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
}

fn vkAllocateInstanceData(instance: vulkan.VkInstance, get_proc_addr: vulkan.PFN_vkGetInstanceProcAddr) !void {
    vk_instances_lock.lock();
    defer vk_instances_lock.unlock();

    var api: InstanceApi = undefined;
    inline for (std.meta.fields(InstanceApi)) |field| {
        comptime var name_buffer: [field.name.len + 1:0]u8 = undefined;
        comptime {
            std.mem.copy(u8, name_buffer[0..field.name.len], field.name);
            name_buffer[field.name.len] = 0;
        }

        @field(api, field.name) = @ptrCast(get_proc_addr.?(instance, &name_buffer));

        if (@field(api, field.name) == null) {
            std.log.err("Couldn't find function {s}", .{field.name});
            return error.FunctionNotFound;
        }
    }

    var instance_data = try allocator.create(VkInstanceData);
    instance_data.* = .{
        .api = api,
        .instance = instance,
        .physical_devices = std.ArrayList(vulkan.VkPhysicalDevice).init(allocator),
        .devices = std.ArrayList(*VkDeviceData).init(allocator),
    };

    try vk_instances.append(instance_data);
    std.log.info("Allocated instance data {} for {}", .{ @intFromPtr(instance_data), @intFromPtr(instance) });
}

pub fn vkCreateInstance(pCreateInfo: *const vulkan.VkInstanceCreateInfo, pAllocator: *const vulkan.VkAllocationCallbacks, pInstance: *vulkan.VkInstance) callconv(.C) vulkan.VkResult {
    var layer_create_info: ?*vulkan.VkLayerInstanceCreateInfo = @constCast(@alignCast(@ptrCast(pCreateInfo.pNext)));
    while (layer_create_info != null and (layer_create_info.?.sType != vulkan.VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO or layer_create_info.?.function != vulkan.VK_LAYER_LINK_INFO)) {
        layer_create_info = @constCast(@alignCast(@ptrCast(layer_create_info.?.pNext)));
    }

    if (layer_create_info == null) {
        return vulkan.VK_ERROR_INITIALIZATION_FAILED;
    }

    var get_instance_proc_addr = layer_create_info.?.u.pLayerInfo.*.pfnNextGetInstanceProcAddr;
    layer_create_info.?.u.pLayerInfo = layer_create_info.?.u.pLayerInfo.*.pNext;

    var info = pCreateInfo.*;
    injectInstanceFeatures(&info);

    var create_func: vulkan.PFN_vkCreateInstance = @ptrCast(get_instance_proc_addr.?(null, "vkCreateInstance"));
    var res = create_func.?(&info, pAllocator, pInstance);

    if (res == vulkan.VK_SUCCESS) {
        std.log.info("Creating instace", .{});

        vkAllocateInstanceData(pInstance.*, get_instance_proc_addr) catch |e| {
            switch (e) {
                else => {
                    std.log.err("Failed to allocate instance data. Error: {s}", .{@errorName(e)});
                    return vulkan.VK_ERROR_INITIALIZATION_FAILED;
                },
            }
        };
    }

    return res;
}

pub export fn vkBackbufferCapture_vkGetInstanceProcAddr(instance: vulkan.VkInstance, pName: [*c]const u8) callconv(.C) ?*const anyopaque {
    const OverridenFunctions = &.{
        .{ &vkBackbufferCapture_vkGetInstanceProcAddr, "vkGetInstanceProcAddr" },
        .{ &vkCreateInstance, "vkCreateInstance" },
        .{ &vkCreateDevice, "vkCreateDevice" },
        .{ &vkEnumeratePhysicalDevices, "vkEnumeratePhysicalDevices" },
        .{ &vkBackbufferCapture_vkGetDeviceProcAddr, "vkGetDeviceProcAddr" },
    };

    std.log.debug("Looking for instance func: {s}", .{std.mem.span(pName)});

    inline for (OverridenFunctions) |function| {
        if (std.mem.eql(u8, std.mem.span(pName), function[1])) {
            return function[0];
        }
    }

    vk_instances_lock.lock();
    defer vk_instances_lock.unlock();
    for (vk_instances.items) |known_instance| {
        if (instance == known_instance.instance) {
            return known_instance.api.vkGetInstanceProcAddr.?(instance, pName);
        }
    }

    return null;
}

pub export fn vkBackbufferCapture_vkGetDeviceProcAddr(device: vulkan.VkDevice, name: [*c]const u8) callconv(.C) ?*const anyopaque {
    var name_as_span = std.mem.span(name);

    std.log.debug("Looking for device funcc: {s}", .{name_as_span});

    const OverridenFunctions = &.{
        .{ &vkCreateDevice, "vkCreateDevice" },
        .{ &vkGetDeviceQueue, "vkGetDeviceQueue" },
        .{ &vkCreateSwapchainKHR, "vkCreateSwapchainKHR" },
        .{ &vkQueuePresentKHR, "vkQueuePresentKHR" },
        .{ &vkBackbufferCapture_vkGetDeviceProcAddr, "vkGetDeviceProcAddr" },
    };

    // std.log.info("Looking for func: {s}", .{name_as_span});

    inline for (OverridenFunctions) |function| {
        if (std.mem.eql(u8, name_as_span, function[1])) {
            return function[0];
        }
    }

    // Only redirect API calls if we have a valid mapping for the vk_device.
    if (getVulkanDeviceDataFromVkDevice(device)) |device_data| {
        return device_data.api.vkGetDeviceProcAddr.?(device, name);
    }

    return null;
}

pub export fn vkBackbufferCapture_vkNegotiateLoaderLayerInterfaceVersion(negoatiate_interface: *vulkan.VkNegotiateLayerInterface) callconv(.C) vulkan.VkResult {
    if (negoatiate_interface.sType != vulkan.LAYER_NEGOTIATE_INTERFACE_STRUCT) {
        return vulkan.VK_ERROR_INITIALIZATION_FAILED;
    }

    negoatiate_interface.pNext = null;

    if (negoatiate_interface.loaderLayerInterfaceVersion >= 2) {
        negoatiate_interface.pfnGetInstanceProcAddr = @ptrCast(&vkBackbufferCapture_vkGetInstanceProcAddr);
        negoatiate_interface.pfnGetDeviceProcAddr = @ptrCast(&vkBackbufferCapture_vkGetDeviceProcAddr);
        negoatiate_interface.pfnGetPhysicalDeviceProcAddr = null;
    }

    return vulkan.VK_SUCCESS;
}
