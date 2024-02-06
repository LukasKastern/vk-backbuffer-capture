const std = @import("std");
const vulkan = @import("vk.zig");

const frag_shader = @embedFile("shaders/fs_swapchain_fullscreen.spv");
const vert_shader = @embedFile("shaders/vs_swapchain_fullscreen.spv");

pub const SwapchainPipeline = struct {
    vk_set_layout: vulkan.VkDescriptorSetLayout,
    vk_pipeline_layout: vulkan.VkPipelineLayout,
    vk_pipeline: vulkan.VkPipeline,
};

pub fn createSwapchainPipeline(device: vulkan.VkDevice, color_format: vulkan.VkFormat) !SwapchainPipeline {
    var vk_fs_module: vulkan.VkShaderModule = blk: {
        var create_info = std.mem.zeroInit(vulkan.VkShaderModuleCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .flags = 0,
            .codeSize = frag_shader.len,
            .pCode = @as([*c]const u32, @alignCast(@ptrCast(frag_shader.ptr))),
        });

        var module: vulkan.VkShaderModule = undefined;
        try vulkan.vkCall(vulkan.vkCreateShaderModule, .{ device, &create_info, null, &module });

        break :blk module;
    };

    var vk_vs_module: vulkan.VkShaderModule = blk: {
        var create_info = std.mem.zeroInit(vulkan.VkShaderModuleCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .flags = 0,
            .codeSize = vert_shader.len,
            .pCode = @as([*c]const u32, @alignCast(@ptrCast(vert_shader.ptr))),
        });

        var module: vulkan.VkShaderModule = undefined;
        try vulkan.vkCall(vulkan.vkCreateShaderModule, .{ device, &create_info, null, &module });

        break :blk module;
    };

    var set_layout = set_layout: {
        var vk_sampler = blk: {
            var vk_sampler_desc = std.mem.zeroInit(vulkan.VkSamplerCreateInfo, .{
                .sType = vulkan.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                .flags = 0,
                .addressModeU = vulkan.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                .addressModeV = vulkan.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                .addressModeW = vulkan.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                .magFilter = vulkan.VK_FILTER_NEAREST,
                .minFilter = vulkan.VK_FILTER_NEAREST,
                .mipmapMode = vulkan.VK_SAMPLER_MIPMAP_MODE_NEAREST,
                .borderColor = vulkan.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
            });

            var sampler: vulkan.VkSampler = undefined;
            try vulkan.vkCall(vulkan.vkCreateSampler, .{ device, &vk_sampler_desc, null, &sampler });
            break :blk sampler;
        };

        var descriptor_set_layout_binding = std.mem.zeroInit(vulkan.VkDescriptorSetLayoutBinding, .{
            .binding = 0,
            .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vulkan.VK_SHADER_STAGE_ALL,
            .pImmutableSamplers = &vk_sampler,
        });

        var descriptor_set_layout_create_info = std.mem.zeroInit(vulkan.VkDescriptorSetLayoutCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .flags = vulkan.VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR,
            .bindingCount = 1,
            .pBindings = &descriptor_set_layout_binding,
        });

        var set_layout: vulkan.VkDescriptorSetLayout = undefined;
        try vulkan.vkCall(vulkan.vkCreateDescriptorSetLayout, .{ device, &descriptor_set_layout_create_info, null, &set_layout });
        break :set_layout set_layout;
    };

    var pipeline_layout = layout: {
        var create_pipeline_layout_info = std.mem.zeroInit(vulkan.VkPipelineLayoutCreateInfo, .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &set_layout,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        });

        var vk_layout: vulkan.VkPipelineLayout = undefined;
        try vulkan.vkCall(vulkan.vkCreatePipelineLayout, .{ device, &create_pipeline_layout_info, null, &vk_layout });
        break :layout vk_layout;
    };

    var vi_state = std.mem.zeroInit(vulkan.VkPipelineVertexInputStateCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    });

    var ia_state = std.mem.zeroInit(vulkan.VkPipelineInputAssemblyStateCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vulkan.VK_FALSE,
    });

    var vp_state = std.mem.zeroInit(vulkan.VkPipelineViewportStateCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null,
        .scissorCount = 1,
        .pScissors = null,
    });

    var rs_state = std.mem.zeroInit(vulkan.VkPipelineRasterizationStateCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthClampEnable = vulkan.VK_TRUE,
        .rasterizerDiscardEnable = vulkan.VK_FALSE,
        .polygonMode = vulkan.VK_POLYGON_MODE_FILL,
        .cullMode = vulkan.VK_CULL_MODE_NONE,
        .frontFace = vulkan.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = vulkan.VK_FALSE,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
        .lineWidth = 1,
    });

    var sample_mask = @as(u32, 0xFFFFFFFF);

    var ms_state = std.mem.zeroInit(vulkan.VkPipelineMultisampleStateCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = 1,
        .sampleShadingEnable = vulkan.VK_FALSE,
        .minSampleShading = 1.0,
        .pSampleMask = &sample_mask,
        .alphaToCoverageEnable = vulkan.VK_FALSE,
        .alphaToOneEnable = vulkan.VK_FALSE,
    });

    var common_dynamic_states = [_]vulkan.VkDynamicState{
        vulkan.VK_DYNAMIC_STATE_VIEWPORT,
        vulkan.VK_DYNAMIC_STATE_SCISSOR,
    };

    var dyn_state = std.mem.zeroInit(vulkan.VkPipelineDynamicStateCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = common_dynamic_states.len,
        .pDynamicStates = &common_dynamic_states,
    });

    var rendering_info = std.mem.zeroInit(vulkan.VkPipelineRenderingCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &color_format,
        .depthAttachmentFormat = vulkan.VK_FORMAT_UNDEFINED,
        .stencilAttachmentFormat = vulkan.VK_FORMAT_UNDEFINED,
    });

    var blend_attachment = std.mem.zeroInit(vulkan.VkPipelineColorBlendAttachmentState, .{
        .blendEnable = vulkan.VK_FALSE,
        .colorWriteMask = vulkan.VK_COLOR_COMPONENT_R_BIT | vulkan.VK_COLOR_COMPONENT_G_BIT |
            vulkan.VK_COLOR_COMPONENT_B_BIT | vulkan.VK_COLOR_COMPONENT_A_BIT,
    });

    var cb_state = std.mem.zeroInit(vulkan.VkPipelineColorBlendStateCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vulkan.VK_FALSE,
        .logicOp = vulkan.VK_LOGIC_OP_NO_OP,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    });

    var shader_stages: [2]vulkan.VkPipelineShaderStageCreateInfo = undefined;
    shader_stages[0] = std.mem.zeroInit(vulkan.VkPipelineShaderStageCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .flags = 0,
        .stage = vulkan.VK_SHADER_STAGE_VERTEX_BIT,
        .module = vk_vs_module,
        .pName = "main",
    });
    shader_stages[1] = std.mem.zeroInit(vulkan.VkPipelineShaderStageCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .flags = 0,
        .stage = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = vk_fs_module,
        .pName = "main",
    });

    var pipeline_info = std.mem.zeroInit(vulkan.VkGraphicsPipelineCreateInfo, .{
        .sType = vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
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

    var vk_pipeline: vulkan.VkPipeline = undefined;
    try vulkan.vkCall(
        vulkan.vkCreateGraphicsPipelines,
        .{ device, null, 1, &pipeline_info, null, &vk_pipeline },
    );

    return .{
        .vk_pipeline = vk_pipeline,
        .vk_pipeline_layout = pipeline_layout,
        .vk_set_layout = set_layout,
    };
}
