const vulkan = struct {
    pub usingnamespace @cImport({
        @cInclude("vulkan/vulkan_core.h");
        @cInclude("vulkan/vk_layer.h");
    });
};

pub usingnamespace vulkan;

pub const InstanceApi = struct {
    vkCreateInstance: vulkan.PFN_vkCreateInstance,
    vkEnumeratePhysicalDevices: vulkan.PFN_vkEnumeratePhysicalDevices,
    vkGetInstanceProcAddr: vulkan.PFN_vkGetInstanceProcAddr,
    vkGetPhysicalDeviceMemoryProperties: vulkan.PFN_vkGetPhysicalDeviceMemoryProperties,
};

pub const DeviceApi = struct {
    vkGetDeviceProcAddr: vulkan.PFN_vkGetDeviceProcAddr,
    vkCreateSwapchainKHR: vulkan.PFN_vkCreateSwapchainKHR,
    vkQueuePresentKHR: vulkan.PFN_vkQueuePresentKHR,
    vkGetDeviceQueue: vulkan.PFN_vkGetDeviceQueue,
    vkBindImageMemory2KHR: vulkan.PFN_vkBindImageMemory2KHR,
    vkCmdPipelineBarrier2KHR: vulkan.PFN_vkCmdPipelineBarrier2KHR,
    vkCmdBeginRenderingKHR: vulkan.PFN_vkCmdBeginRenderingKHR,
    vkCmdEndRenderingKHR: vulkan.PFN_vkCmdEndRenderingKHR,
    vkCmdPushDescriptorSetKHR: vulkan.PFN_vkCmdPushDescriptorSetKHR,
    vkGetMemoryFdKHR: vulkan.PFN_vkGetMemoryFdKHR,
    vkGetSwapchainImagesKHR: vulkan.PFN_vkGetSwapchainImagesKHR,
    vkCreateImageView: vulkan.PFN_vkCreateImageView,
    vkCreateFence: vulkan.PFN_vkCreateFence,
    vkCreateSemaphore: vulkan.PFN_vkCreateSemaphore,
    vkAllocateMemory: vulkan.PFN_vkAllocateMemory,
    vkCreateImage: vulkan.PFN_vkCreateImage,
    vkGetImageMemoryRequirements: vulkan.PFN_vkGetImageMemoryRequirements,
    vkWaitForFences: vulkan.PFN_vkWaitForFences,
    vkResetFences: vulkan.PFN_vkResetFences,
    vkCreateCommandPool: vulkan.PFN_vkCreateCommandPool,
    vkAllocateCommandBuffers: vulkan.PFN_vkAllocateCommandBuffers,
    vkResetCommandBuffer: vulkan.PFN_vkResetCommandBuffer,
    vkBeginCommandBuffer: vulkan.PFN_vkBeginCommandBuffer,
    vkCmdSetViewport: vulkan.PFN_vkCmdSetViewport,
    vkCmdSetScissor: vulkan.PFN_vkCmdSetScissor,
    vkCmdBindPipeline: vulkan.PFN_vkCmdBindPipeline,
    vkCmdDraw: vulkan.PFN_vkCmdDraw,
    vkEndCommandBuffer: vulkan.PFN_vkEndCommandBuffer,
    vkQueueSubmit: vulkan.PFN_vkQueueSubmit,
    vkCreateShaderModule: vulkan.PFN_vkCreateShaderModule,
    vkCreateSampler: vulkan.PFN_vkCreateSampler,
    vkCreateDescriptorSetLayout: vulkan.PFN_vkCreateDescriptorSetLayout,
    vkCreatePipelineLayout: vulkan.PFN_vkCreatePipelineLayout,
    vkCreateGraphicsPipelines: vulkan.PFN_vkCreateGraphicsPipelines,
    vkDestroySwapchainKHR: vulkan.PFN_vkDestroySwapchainKHR,
};

pub fn vkCall(func: anytype, args: anytype) !void {
    const fn_type = @TypeOf(func);

    switch (@typeInfo(fn_type)) {
        .Fn => |fun| {
            if (fun.return_type == c_int) {
                var res = @call(.auto, func, args);
                if (res != vulkan.VK_SUCCESS) {
                    return error.VkError;
                }
            } else {
                @call(.auto, func, args);
            }
        },
        .Pointer => |pointer| {
            switch (@typeInfo(pointer.child)) {
                .Fn => |fun| {
                    if (fun.return_type == c_int) {
                        var res = @call(.auto, func, args);
                        if (res != vulkan.VK_SUCCESS) {
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

pub fn vkStructureHasNext(root: *const vulkan.VkBaseInStructure, structure_type: c_int) bool {
    var next = @as(?*const vulkan.VkBaseInStructure, root);
    while (next != null) {
        if (next.?.sType == structure_type) {
            return true;
        }

        next = @ptrCast(@alignCast(next.?.pNext));
    }

    return false;
}
