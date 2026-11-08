#ifndef ANYPS5_RETRO_VULKAN_VIDEO_H_
#define ANYPS5_RETRO_VULKAN_VIDEO_H_

#include <windows.h>
#include <vulkan/vulkan_core.h>

#include <cstdint>
#include <mutex>

constexpr int kVulkan = 6;

struct RetroVulkanContext {
  VkPhysicalDevice gpu;
  VkDevice device;
  VkQueue queue;
  uint32_t queue_family;
  VkQueue present_queue;
  uint32_t present_queue_family;
};

struct RetroVulkanNegotiation {
  int type;
  unsigned version;
  const VkApplicationInfo* (*application_info)();
  bool (*create_device)(RetroVulkanContext*, VkInstance, VkPhysicalDevice, VkSurfaceKHR,
                        PFN_vkGetInstanceProcAddr, const char**, unsigned, const char**,
                        unsigned, const VkPhysicalDeviceFeatures*);
  void (*destroy_device)();
};

struct RetroVulkanImage {
  VkImageView view;
  VkImageLayout layout;
  VkImageViewCreateInfo info;
};

struct RetroVulkanInterface {
  int type;
  unsigned version;
  void* handle;
  VkInstance instance;
  VkPhysicalDevice gpu;
  VkDevice device;
  PFN_vkGetDeviceProcAddr device_proc;
  PFN_vkGetInstanceProcAddr instance_proc;
  VkQueue queue;
  unsigned queue_family;
  void (*set_image)(void*, const RetroVulkanImage*, uint32_t, const VkSemaphore*, uint32_t);
  uint32_t (*sync_index)(void*);
  uint32_t (*sync_mask)(void*);
  void (*set_command_buffers)(void*, uint32_t, const VkCommandBuffer*);
  void (*wait_sync)(void*);
  void (*lock_queue)(void*);
  void (*unlock_queue)(void*);
  void (*set_signal)(void*, VkSemaphore);
};

class RetroVulkanVideo {
 public:
  ~RetroVulkanVideo();
  bool Load();
  bool SetNegotiation(const RetroVulkanNegotiation& negotiation);
  bool Open();
  void Close();
  bool negotiated() const { return negotiated_; }
  bool unsupported_sync() const { return unsupported_sync_; }
  const RetroVulkanInterface& render_interface() const { return interface_; }
  bool Read(uint8_t* pixels, unsigned width, unsigned height);

 private:
  bool PrepareBuffer(VkDeviceSize bytes);
  void ClearBuffer();
  bool CopyImage(const RetroVulkanImage& image, unsigned width, unsigned height);

  template <typename T>
  T InstanceProc(const char* name) const {
    return reinterpret_cast<T>(interface_.instance_proc(interface_.instance, name));
  }

  template <typename T>
  T DeviceProc(const char* name) const {
    return reinterpret_cast<T>(interface_.device_proc(interface_.device, name));
  }

  HMODULE loader_ = nullptr;
  RetroVulkanNegotiation negotiation_{};
  RetroVulkanInterface interface_{};
  bool negotiated_ = false;
  bool unsupported_sync_ = false;
  VkCommandPool pool_ = VK_NULL_HANDLE;
  VkCommandBuffer command_ = VK_NULL_HANDLE;
  VkFence fence_ = VK_NULL_HANDLE;
  VkBuffer buffer_ = VK_NULL_HANDLE;
  VkDeviceMemory memory_ = VK_NULL_HANDLE;
  VkDeviceSize capacity_ = 0;
  const uint8_t* mapped_ = nullptr;
  RetroVulkanImage image_{};
  std::mutex queue_mutex_;
};

#endif
