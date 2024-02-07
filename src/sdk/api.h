#include <stdint.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_core.h>

struct VKBackbufferFrame {
    VkFormat frame_format;
    int frame_handle;
};

typedef void* VKBackbufferCaptureState;

struct VKBackbufferInitializeOptions {
  uint64_t target_app_id;
};

int vk_backbuffer_capture_init(const struct VKBackbufferInitializeOptions *options, VKBackbufferCaptureState* out_state);

int vk_backbuffer_capture_deinit(VKBackbufferCaptureState state);

int vk_backbuffer_capture_next_frame(VKBackbufferCaptureState out_state, struct VKBackbufferFrame *out_frame);
