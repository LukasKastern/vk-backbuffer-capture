# What is vk-backbuffer-capture?

vk-backbuffer-capture is a vulkan layer that provides applications with low-latency access to swapchain images.

## Prequisites
[Zig (0.11)](https://ziglang.org/download/).

## Build the project

```console
git clone https://github.com/LukasKastern/vk-backbuffer-capture.git
cd vk-backbuffer-capture
zig build -Doptimize=ReleaseFast
```

## Usage

After compiling the project you can start capturing an application by setting the following env vars:
- ```VK_LOADER_LAYERS_ENABLE=VK_LAYER_BACKBUFFER_CAPTURE_default```
- ```VK_LAYER_PATH=/PATH/TO/THIS/REPOSITORY```

For example:
```console
export VK_LOADER_LAYERS_ENABLE=VK_LAYER_BACKBUFFER_CAPTURE_default 
export VK_LAYER_PATH=/home/yourname/backbuffer-capture/
vkcube
```

Validate that capturing is working by running the window-example with the PID of the just started app.


## Note

The current way of transfering the textures requires ptrace permission.
 
```console
sudo setcap 'cap_sys_ptrace=ep' /home/yourname/Projects/backbuffer-capture/zig-out/bin/window-example
```

To enable debug messages set the env var BACKBUFFER_CAPTURE_DEBUG to the desired output level.

```console
BACKBUFFER_CAPTURE_DEBUG=info
````
