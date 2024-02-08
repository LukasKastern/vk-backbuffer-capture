#ifdef __cplusplus
extern "C" {
#endif


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
  VkBackbufferCaptureResult_Timeout = -6,
} vk_backbuffer_capture_result;

vk_backbuffer_capture_result vk_backbuffer_capture_init(const struct VKBackbufferInitializeOptions *options, VKBackbufferCaptureState* out_state);

void vk_backbuffer_capture_deinit(VKBackbufferCaptureState state);

vk_backbuffer_capture_result vk_backbuffer_capture_next_frame(VKBackbufferCaptureState out_state, uint32_t wait_time_ns, struct VKBackbufferFrame *out_frame);

/** When done with a frame call this method to return it back to the application. */
vk_backbuffer_capture_result vk_backbuffer_capture_return_frame(VKBackbufferCaptureState out_state, struct VKBackbufferFrame *frame);

/** Utility method to acquire an opengl texture from an opaque file handle. */
vk_backbuffer_capture_result vk_backbuffer_capture_import_opengl_texture(VKBackbufferCaptureState out_state, const struct VkBackbufferFrame *frame, uint32_t gl_texture);

#ifdef __cplusplus
}
#endif
