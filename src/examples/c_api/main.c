#include <backbuffer-capture/api.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
  if(argc < 2) {
    printf("Pass the pid of the target process as the first arg.\n");
    return -1;
  }

  int pid = atoi(argv[1]);
  if(pid == 0) {
    printf("Pass the pid of the target process as the first arg.\n");
    return -2;
  }  

  struct VKBackbufferInitializeOptions options = {
    .target_app_id = pid,
  };

  VKBackbufferCaptureState state;

  printf("Initializing Now\n");

  vk_backbuffer_capture_result result;
  if((result = vk_backbuffer_capture_init(&options, &state)) != VkBackbufferCaptureResult_Success) {
    return result;
  }

  printf("Attempting to acquire first frame\n");

  struct VKBackbufferFrame frame;
  if((result = vk_backbuffer_capture_next_frame(state, 1000 * 1000 * 100, &frame)) != VkBackbufferCaptureResult_Success) {
     return result; 
  }

  printf("Deinitializing\n");

  if((result = vk_backbuffer_capture_return_frame(state, &frame)) != VkBackbufferCaptureResult_Success) {
    return result;
  }

  vk_backbuffer_capture_deinit(state);

  printf("Success\n");
 
  return 0;
}
