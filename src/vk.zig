const vulkan = struct {
    pub usingnamespace @cImport({
        @cInclude("vulkan/vulkan_core.h");
        @cInclude("vulkan/vk_layer.h");
    });
};

pub usingnamespace vulkan;

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
