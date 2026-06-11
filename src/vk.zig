pub const C = @cImport({
    @cInclude("vulkan/vulkan_core.h");
    @cInclude("vulkan/vk_layer.h");
});

pub const InstanceApi = struct {
    vkCreateInstance: C.PFN_vkCreateInstance,
    vkEnumeratePhysicalDevices: C.PFN_vkEnumeratePhysicalDevices,
    vkGetInstanceProcAddr: C.PFN_vkGetInstanceProcAddr,
    vkGetPhysicalDeviceMemoryProperties: C.PFN_vkGetPhysicalDeviceMemoryProperties,
};

pub const DeviceApi = struct {
    vkGetDeviceProcAddr: C.PFN_vkGetDeviceProcAddr,
    vkCreateSwapchainKHR: C.PFN_vkCreateSwapchainKHR,
    vkQueuePresentKHR: C.PFN_vkQueuePresentKHR,
    vkGetDeviceQueue: C.PFN_vkGetDeviceQueue,
    vkBindImageMemory2KHR: C.PFN_vkBindImageMemory2KHR,
    vkCmdPipelineBarrier2KHR: C.PFN_vkCmdPipelineBarrier2KHR,
    vkCmdBeginRenderingKHR: C.PFN_vkCmdBeginRenderingKHR,
    vkCmdEndRenderingKHR: C.PFN_vkCmdEndRenderingKHR,
    vkCmdPushDescriptorSetKHR: C.PFN_vkCmdPushDescriptorSetKHR,
    vkGetMemoryFdKHR: C.PFN_vkGetMemoryFdKHR,
    vkGetSwapchainImagesKHR: C.PFN_vkGetSwapchainImagesKHR,
    vkCreateImageView: C.PFN_vkCreateImageView,
    vkCreateFence: C.PFN_vkCreateFence,
    vkCreateSemaphore: C.PFN_vkCreateSemaphore,
    vkAllocateMemory: C.PFN_vkAllocateMemory,
    vkCreateImage: C.PFN_vkCreateImage,
    vkGetImageMemoryRequirements: C.PFN_vkGetImageMemoryRequirements,
    vkWaitForFences: C.PFN_vkWaitForFences,
    vkResetFences: C.PFN_vkResetFences,
    vkCreateCommandPool: C.PFN_vkCreateCommandPool,
    vkAllocateCommandBuffers: C.PFN_vkAllocateCommandBuffers,
    vkResetCommandBuffer: C.PFN_vkResetCommandBuffer,
    vkBeginCommandBuffer: C.PFN_vkBeginCommandBuffer,
    vkCmdSetViewport: C.PFN_vkCmdSetViewport,
    vkCmdSetScissor: C.PFN_vkCmdSetScissor,
    vkCmdBindPipeline: C.PFN_vkCmdBindPipeline,
    vkCmdDraw: C.PFN_vkCmdDraw,
    vkEndCommandBuffer: C.PFN_vkEndCommandBuffer,
    vkQueueSubmit: C.PFN_vkQueueSubmit,
    vkCreateShaderModule: C.PFN_vkCreateShaderModule,
    vkCreateSampler: C.PFN_vkCreateSampler,
    vkCreateDescriptorSetLayout: C.PFN_vkCreateDescriptorSetLayout,
    vkCreatePipelineLayout: C.PFN_vkCreatePipelineLayout,
    vkCreateGraphicsPipelines: C.PFN_vkCreateGraphicsPipelines,
    vkDestroySwapchainKHR: C.PFN_vkDestroySwapchainKHR,
};

pub fn vkCall(func: anytype, args: anytype) !void {
    const fn_type = @TypeOf(func);

    switch (@typeInfo(fn_type)) {
        .@"fn" => |fun| {
            if (fun.return_type == c_int) {
                const res = @call(.auto, func, args);
                if (res != C.VK_SUCCESS) {
                    return error.VkError;
                }
            } else {
                @call(.auto, func, args);
            }
        },
        .pointer => |pointer| {
            switch (@typeInfo(pointer.child)) {
                .@"fn" => |fun| {
                    if (fun.return_type == c_int) {
                        const res = @call(.auto, func, args);
                        if (res != C.VK_SUCCESS) {
                            return error.VkError;
                        }
                    } else {
                        @call(.auto, func, args);
                    }
                },
                else => {
                    @compileError("Non func passed to vkCall. Check vkCall invocations");
                },
            }
        },
        else => {
            @compileError("Non func passed to vkCall. Check vkCall invocations");
        },
    }
}

pub fn vkStructureHasNext(root: *const C.VkBaseInStructure, structure_type: c_int) bool {
    var next = @as(?*const C.VkBaseInStructure, root);
    while (next != null) {
        if (next.?.sType == structure_type) {
            return true;
        }

        next = @ptrCast(@alignCast(next.?.pNext));
    }

    return false;
}
