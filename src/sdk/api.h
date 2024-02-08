#include <stdint.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_core.h>

struct VKBackbufferFrame {
    VkFormat format;
    uint32_t width;
    uint32_t height;
    int frame_fd_opaque;
};

typedef void* VKBackbufferCaptureState;

struct VKBackbufferInitializeOptions {
  int32_t target_app_id;
};

typedef enum {
  VkBackbufferCaptureResult_Success,
  VkBackbufferCaptureResult_RemoteNotFound = -1,
  VkBackbufferCaptureResult_VersionMismatch = -2,
  VkBackbufferCaptureResult_OutOfMemory = -3,
  VkBackbufferCaptureResult_NoSpaceLeft = -4,
  VkBackbufferCaptureResult_ApiError = -5,
} vk_backbuffer_capture_result;

vk_backbuffer_capture_result vk_backbuffer_capture_init(const struct VKBackbufferInitializeOptions *options, VKBackbufferCaptureState* out_state);

vk_backbuffer_capture_result vk_backbuffer_capture_deinit(VKBackbufferCaptureState state);

vk_backbuffer_capture_result vk_backbuffer_capture_next_frame(VKBackbufferCaptureState out_state, struct VKBackbufferFrame *out_frame);

/** When done with a frame call this method to return it back to the application. */
vk_backbuffer_capture_result vk_backbuffer_return_frame(VKBackbufferCaptureState out_state, struct VKBackbufferFrame *out_frame);

/** Utility method to acquire an opengl texture from an opaque file handle. */
vk_backbuffer_capture_result vk_backbuffer_import_opengl_texture(VKBackbufferCaptureState out_state, const struct VkBackbufferFrame *frame, uint32_t *out_texture);
