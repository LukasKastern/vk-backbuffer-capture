const std = @import("std");
const vulkan = @import("vk.zig");

const frag_shader = @embedFile("shaders/fs_swapchain_fullscreen.spv");
const vert_shader = @embedFile("shaders/vs_swapchain_fullscreen.spv");

pub const SwapchainPipeline = struct {
    vk_set_layout: vulkan.C.VkDescriptorSetLayout,
    vk_pipeline_layout: vulkan.C.VkPipelineLayout,
    vk_pipeline: vulkan.C.VkPipeline,
};

pub fn createSwapchainPipeline(device_api: vulkan.DeviceApi, device: vulkan.C.VkDevice, color_format: vulkan.C.VkFormat) !SwapchainPipeline {
    const vk_fs_module: vulkan.C.VkShaderModule = blk: {
        var create_info = std.mem.zeroInit(vulkan.C.VkShaderModuleCreateInfo, .{
            .sType = vulkan.C.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .flags = 0,
            .codeSize = frag_shader.len,
            .pCode = @as([*c]const u32, @ptrCast(@alignCast(frag_shader.ptr))),
        });

        var module: vulkan.C.VkShaderModule = undefined;
        try vulkan.vkCall(device_api.vkCreateShaderModule.?, .{ device, &create_info, null, &module });

        break :blk module;
    };

    const vk_vs_module: vulkan.C.VkShaderModule = blk: {
        var create_info = std.mem.zeroInit(vulkan.C.VkShaderModuleCreateInfo, .{
            .sType = vulkan.C.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .flags = 0,
            .codeSize = vert_shader.len,
            .pCode = @as([*c]const u32, @ptrCast(@alignCast(vert_shader.ptr))),
        });

        var module: vulkan.C.VkShaderModule = undefined;
        try vulkan.vkCall(device_api.vkCreateShaderModule.?, .{ device, &create_info, null, &module });

        break :blk module;
    };

    var set_layout = set_layout: {
        var vk_sampler = blk: {
            var vk_sampler_desc = std.mem.zeroInit(vulkan.C.VkSamplerCreateInfo, .{
                .sType = vulkan.C.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                .flags = 0,
                .addressModeU = vulkan.C.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                .addressModeV = vulkan.C.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                .addressModeW = vulkan.C.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                .magFilter = vulkan.C.VK_FILTER_NEAREST,
                .minFilter = vulkan.C.VK_FILTER_NEAREST,
                .mipmapMode = vulkan.C.VK_SAMPLER_MIPMAP_MODE_NEAREST,
                .borderColor = vulkan.C.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
            });

            var sampler: vulkan.C.VkSampler = undefined;
            try vulkan.vkCall(device_api.vkCreateSampler.?, .{ device, &vk_sampler_desc, null, &sampler });
            break :blk sampler;
        };

        var descriptor_set_layout_binding = std.mem.zeroInit(vulkan.C.VkDescriptorSetLayoutBinding, .{
            .binding = 0,
            .descriptorType = vulkan.C.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vulkan.C.VK_SHADER_STAGE_ALL,
            .pImmutableSamplers = &vk_sampler,
        });

        var descriptor_set_layout_create_info = std.mem.zeroInit(vulkan.C.VkDescriptorSetLayoutCreateInfo, .{
            .sType = vulkan.C.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .flags = vulkan.C.VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR,
            .bindingCount = 1,
            .pBindings = &descriptor_set_layout_binding,
        });

        var set_layout: vulkan.C.VkDescriptorSetLayout = undefined;
        try vulkan.vkCall(device_api.vkCreateDescriptorSetLayout.?, .{ device, &descriptor_set_layout_create_info, null, &set_layout });
        break :set_layout set_layout;
    };

    const pipeline_layout = layout: {
        var create_pipeline_layout_info = std.mem.zeroInit(vulkan.C.VkPipelineLayoutCreateInfo, .{
            .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &set_layout,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        });

        var vk_layout: vulkan.C.VkPipelineLayout = undefined;
        try vulkan.vkCall(device_api.vkCreatePipelineLayout.?, .{ device, &create_pipeline_layout_info, null, &vk_layout });
        break :layout vk_layout;
    };

    var vi_state = std.mem.zeroInit(vulkan.C.VkPipelineVertexInputStateCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    });

    var ia_state = std.mem.zeroInit(vulkan.C.VkPipelineInputAssemblyStateCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = vulkan.C.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vulkan.C.VK_FALSE,
    });

    var vp_state = std.mem.zeroInit(vulkan.C.VkPipelineViewportStateCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null,
        .scissorCount = 1,
        .pScissors = null,
    });

    var rs_state = std.mem.zeroInit(vulkan.C.VkPipelineRasterizationStateCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthClampEnable = vulkan.C.VK_TRUE,
        .rasterizerDiscardEnable = vulkan.C.VK_FALSE,
        .polygonMode = vulkan.C.VK_POLYGON_MODE_FILL,
        .cullMode = vulkan.C.VK_CULL_MODE_NONE,
        .frontFace = vulkan.C.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = vulkan.C.VK_FALSE,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
        .lineWidth = 1,
    });

    var sample_mask = @as(u32, 0xFFFFFFFF);

    var ms_state = std.mem.zeroInit(vulkan.C.VkPipelineMultisampleStateCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = 1,
        .sampleShadingEnable = vulkan.C.VK_FALSE,
        .minSampleShading = 1.0,
        .pSampleMask = &sample_mask,
        .alphaToCoverageEnable = vulkan.C.VK_FALSE,
        .alphaToOneEnable = vulkan.C.VK_FALSE,
    });

    var common_dynamic_states = [_]vulkan.C.VkDynamicState{
        vulkan.C.VK_DYNAMIC_STATE_VIEWPORT,
        vulkan.C.VK_DYNAMIC_STATE_SCISSOR,
    };

    var dyn_state = std.mem.zeroInit(vulkan.C.VkPipelineDynamicStateCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = common_dynamic_states.len,
        .pDynamicStates = &common_dynamic_states,
    });

    var rendering_info = std.mem.zeroInit(vulkan.C.VkPipelineRenderingCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &color_format,
        .depthAttachmentFormat = vulkan.C.VK_FORMAT_UNDEFINED,
        .stencilAttachmentFormat = vulkan.C.VK_FORMAT_UNDEFINED,
    });

    var blend_attachment = std.mem.zeroInit(vulkan.C.VkPipelineColorBlendAttachmentState, .{
        .blendEnable = vulkan.C.VK_FALSE,
        .colorWriteMask = vulkan.C.VK_COLOR_COMPONENT_R_BIT | vulkan.C.VK_COLOR_COMPONENT_G_BIT |
            vulkan.C.VK_COLOR_COMPONENT_B_BIT | vulkan.C.VK_COLOR_COMPONENT_A_BIT,
    });

    var cb_state = std.mem.zeroInit(vulkan.C.VkPipelineColorBlendStateCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vulkan.C.VK_FALSE,
        .logicOp = vulkan.C.VK_LOGIC_OP_NO_OP,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    });

    var shader_stages: [2]vulkan.C.VkPipelineShaderStageCreateInfo = undefined;
    shader_stages[0] = std.mem.zeroInit(vulkan.C.VkPipelineShaderStageCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .flags = 0,
        .stage = vulkan.C.VK_SHADER_STAGE_VERTEX_BIT,
        .module = vk_vs_module,
        .pName = "main",
    });
    shader_stages[1] = std.mem.zeroInit(vulkan.C.VkPipelineShaderStageCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .flags = 0,
        .stage = vulkan.C.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = vk_fs_module,
        .pName = "main",
    });

    var pipeline_info = std.mem.zeroInit(vulkan.C.VkGraphicsPipelineCreateInfo, .{
        .sType = vulkan.C.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &rendering_info,
        .flags = 0,
        .stageCount = 2,
        .pStages = shader_stages[0..2].ptr,
        .pVertexInputState = &vi_state,
        .pInputAssemblyState = &ia_state,
        .pTessellationState = null,
        .pViewportState = &vp_state,
        .pRasterizationState = &rs_state,
        .pMultisampleState = &ms_state,
        .pDepthStencilState = null,
        .pColorBlendState = &cb_state,
        .pDynamicState = &dyn_state,
        .layout = pipeline_layout,
        .renderPass = null,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    });

    var vk_pipeline: vulkan.C.VkPipeline = undefined;
    try vulkan.vkCall(
        device_api.vkCreateGraphicsPipelines.?,
        .{ device, null, 1, &pipeline_info, null, &vk_pipeline },
    );

    return .{
        .vk_pipeline = vk_pipeline,
        .vk_pipeline_layout = pipeline_layout,
        .vk_set_layout = set_layout,
    };
}
