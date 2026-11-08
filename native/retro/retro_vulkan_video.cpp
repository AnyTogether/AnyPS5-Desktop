#include "retro_vulkan_video.h"

#include <vulkan/vulkan_core.h>

#include <algorithm>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <utility>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace anyps5::retro {
namespace {

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

  void* loader_ = nullptr;
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

RetroVulkanVideo::~RetroVulkanVideo() {
  Close();
  if (!loader_) return;
#if defined(_WIN32)
  FreeLibrary(static_cast<HMODULE>(loader_));
#else
  dlclose(loader_);
#endif
}

bool RetroVulkanVideo::Load() {
#if defined(_WIN32)
  if (!loader_) loader_ = LoadLibraryExW(L"vulkan-1.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!loader_) return false;
  const auto address = GetProcAddress(static_cast<HMODULE>(loader_), "vkGetInstanceProcAddr");
#else
  if (!loader_) loader_ = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
  if (!loader_) return false;
  const auto address = dlsym(loader_, "vkGetInstanceProcAddr");
#endif
  if (!address) return false;
  static_assert(sizeof(address) == sizeof(interface_.instance_proc));
  std::memcpy(&interface_.instance_proc, &address, sizeof(address));
  return true;
}

bool RetroVulkanVideo::SetNegotiation(const RetroVulkanNegotiation& negotiation) {
  if (negotiation.type != 0 || negotiation.version != 1 || !negotiation.create_device)
    return false;
  negotiation_ = negotiation;
  return true;
}

bool RetroVulkanVideo::Open() {
  if (!interface_.instance_proc || !negotiation_.create_device) return false;
  const auto create_instance = InstanceProc<PFN_vkCreateInstance>("vkCreateInstance");
  if (!create_instance) return false;
  VkApplicationInfo fallback{};
  fallback.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
  fallback.pApplicationName = "AnyPS5 Desktop";
  fallback.apiVersion = VK_API_VERSION_1_2;
  const auto* app = negotiation_.application_info ? negotiation_.application_info() : nullptr;
  VkInstanceCreateInfo instance_info{};
  instance_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  instance_info.pApplicationInfo = app ? app : &fallback;
  if (create_instance(&instance_info, nullptr, &interface_.instance) != VK_SUCCESS)
    return false;
  interface_.device_proc = InstanceProc<PFN_vkGetDeviceProcAddr>("vkGetDeviceProcAddr");
  if (!interface_.device_proc) return false;
  RetroVulkanContext context{};
  VkPhysicalDeviceFeatures features{};
  if (!negotiation_.create_device(&context, interface_.instance, VK_NULL_HANDLE,
                                  VK_NULL_HANDLE, interface_.instance_proc, nullptr, 0,
                                  nullptr, 0, &features))
    return false;
  negotiated_ = true;
  interface_.gpu = context.gpu;
  interface_.device = context.device;
  interface_.queue = context.queue;
  interface_.queue_family = context.queue_family;
  VkCommandPoolCreateInfo pool_info{};
  pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
  pool_info.queueFamilyIndex = context.queue_family;
  if (DeviceProc<PFN_vkCreateCommandPool>("vkCreateCommandPool")(
          context.device, &pool_info, nullptr, &pool_) != VK_SUCCESS)
    return false;
  VkCommandBufferAllocateInfo command_info{};
  command_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
  command_info.commandPool = pool_;
  command_info.commandBufferCount = 1;
  if (DeviceProc<PFN_vkAllocateCommandBuffers>("vkAllocateCommandBuffers")(
          context.device, &command_info, &command_) != VK_SUCCESS)
    return false;
  VkFenceCreateInfo fence_info{};
  fence_info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
  if (DeviceProc<PFN_vkCreateFence>("vkCreateFence")(
          context.device, &fence_info, nullptr, &fence_) != VK_SUCCESS)
    return false;
  interface_.type = 0;
  interface_.version = 5;
  interface_.handle = this;
  interface_.set_image = [](void* handle, const RetroVulkanImage* image, uint32_t waits,
                            const VkSemaphore*, uint32_t family) {
    auto& video = *static_cast<RetroVulkanVideo*>(handle);
    if (waits != 0 || (family != VK_QUEUE_FAMILY_IGNORED &&
                       family != video.interface_.queue_family)) {
      video.unsupported_sync_ = true;
      return;
    }
    video.image_ = image ? *image : RetroVulkanImage{};
  };
  interface_.sync_index = [](void*) -> uint32_t { return 0; };
  interface_.sync_mask = [](void*) -> uint32_t { return 1; };
  interface_.set_command_buffers = [](void* handle, uint32_t count, const VkCommandBuffer*) {
    if (count != 0) static_cast<RetroVulkanVideo*>(handle)->unsupported_sync_ = true;
  };
  interface_.wait_sync = [](void*) {};
  interface_.lock_queue = [](void* handle) {
    static_cast<RetroVulkanVideo*>(handle)->queue_mutex_.lock();
  };
  interface_.unlock_queue = [](void* handle) {
    static_cast<RetroVulkanVideo*>(handle)->queue_mutex_.unlock();
  };
  interface_.set_signal = [](void* handle, VkSemaphore signal) {
    if (signal) static_cast<RetroVulkanVideo*>(handle)->unsupported_sync_ = true;
  };
  return true;
}

void RetroVulkanVideo::Close() {
  const auto device = interface_.device;
  if (device) {
    DeviceProc<PFN_vkDeviceWaitIdle>("vkDeviceWaitIdle")(device);
    ClearBuffer();
    if (fence_) DeviceProc<PFN_vkDestroyFence>("vkDestroyFence")(device, fence_, nullptr);
    if (pool_) DeviceProc<PFN_vkDestroyCommandPool>("vkDestroyCommandPool")(device, pool_, nullptr);
    if (negotiated_ && negotiation_.destroy_device) negotiation_.destroy_device();
    DeviceProc<PFN_vkDestroyDevice>("vkDestroyDevice")(device, nullptr);
  }
  if (interface_.instance)
    InstanceProc<PFN_vkDestroyInstance>("vkDestroyInstance")(interface_.instance, nullptr);
  interface_ = {};
  negotiated_ = false;
}

void RetroVulkanVideo::ClearBuffer() {
  const auto device = interface_.device;
  if (mapped_) DeviceProc<PFN_vkUnmapMemory>("vkUnmapMemory")(device, memory_);
  if (buffer_) DeviceProc<PFN_vkDestroyBuffer>("vkDestroyBuffer")(device, buffer_, nullptr);
  if (memory_) DeviceProc<PFN_vkFreeMemory>("vkFreeMemory")(device, memory_, nullptr);
  mapped_ = nullptr;
  buffer_ = VK_NULL_HANDLE;
  memory_ = VK_NULL_HANDLE;
  capacity_ = 0;
}

bool RetroVulkanVideo::PrepareBuffer(VkDeviceSize bytes) {
  if (capacity_ >= bytes) return true;
  ClearBuffer();
  const auto device = interface_.device;
  VkBufferCreateInfo buffer_info{};
  buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  buffer_info.size = bytes;
  buffer_info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
  if (DeviceProc<PFN_vkCreateBuffer>("vkCreateBuffer")(device, &buffer_info, nullptr, &buffer_) !=
      VK_SUCCESS)
    return false;
  VkMemoryRequirements requirements{};
  DeviceProc<PFN_vkGetBufferMemoryRequirements>("vkGetBufferMemoryRequirements")(
      device, buffer_, &requirements);
  VkPhysicalDeviceMemoryProperties properties{};
  InstanceProc<PFN_vkGetPhysicalDeviceMemoryProperties>("vkGetPhysicalDeviceMemoryProperties")(
      interface_.gpu, &properties);
  const auto visible = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
  uint32_t memory_type = 0;
  for (; memory_type < properties.memoryTypeCount; ++memory_type) {
    if ((requirements.memoryTypeBits & (1u << memory_type)) &&
        (properties.memoryTypes[memory_type].propertyFlags & visible) == visible)
      break;
  }
  if (memory_type == properties.memoryTypeCount) return false;
  VkMemoryAllocateInfo allocation{};
  allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  allocation.allocationSize = requirements.size;
  allocation.memoryTypeIndex = memory_type;
  if (DeviceProc<PFN_vkAllocateMemory>("vkAllocateMemory")(device, &allocation, nullptr, &memory_) !=
          VK_SUCCESS ||
      DeviceProc<PFN_vkBindBufferMemory>("vkBindBufferMemory")(device, buffer_, memory_, 0) !=
          VK_SUCCESS)
    return false;
  void* mapped = nullptr;
  if (DeviceProc<PFN_vkMapMemory>("vkMapMemory")(device, memory_, 0, bytes, 0, &mapped) != VK_SUCCESS)
    return false;
  mapped_ = static_cast<const uint8_t*>(mapped);
  capacity_ = bytes;
  return true;
}

bool RetroVulkanVideo::CopyImage(const RetroVulkanImage& image, unsigned width, unsigned height) {
  const auto device = interface_.device;
  if (DeviceProc<PFN_vkResetCommandPool>("vkResetCommandPool")(device, pool_, 0) != VK_SUCCESS ||
      DeviceProc<PFN_vkResetFences>("vkResetFences")(device, 1, &fence_) != VK_SUCCESS)
    return false;
  VkCommandBufferBeginInfo begin{};
  begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  if (DeviceProc<PFN_vkBeginCommandBuffer>("vkBeginCommandBuffer")(command_, &begin) != VK_SUCCESS)
    return false;
  const auto barrier = DeviceProc<PFN_vkCmdPipelineBarrier>("vkCmdPipelineBarrier");
  VkImageMemoryBarrier source{};
  source.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
  source.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
  source.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
  source.oldLayout = image.layout;
  source.newLayout = VK_IMAGE_LAYOUT_GENERAL;
  source.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  source.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  source.image = image.info.image;
  source.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
  barrier(command_, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
          0, nullptr, 0, nullptr, 1, &source);
  VkBufferImageCopy region{};
  region.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
  region.imageExtent = {width, height, 1};
  DeviceProc<PFN_vkCmdCopyImageToBuffer>("vkCmdCopyImageToBuffer")(
      command_, source.image, VK_IMAGE_LAYOUT_GENERAL, buffer_, 1, &region);
  VkBufferMemoryBarrier destination{};
  destination.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
  destination.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
  destination.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
  destination.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  destination.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  destination.buffer = buffer_;
  destination.size = VK_WHOLE_SIZE;
  barrier(command_, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0,
          0, nullptr, 1, &destination, 0, nullptr);
  if (DeviceProc<PFN_vkEndCommandBuffer>("vkEndCommandBuffer")(command_) != VK_SUCCESS)
    return false;
  VkSubmitInfo submit{};
  submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
  submit.commandBufferCount = 1;
  submit.pCommandBuffers = &command_;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (DeviceProc<PFN_vkQueueSubmit>("vkQueueSubmit")(interface_.queue, 1, &submit, fence_) !=
        VK_SUCCESS)
      return false;
  }
  constexpr uint64_t kFrameTimeout = 5'000'000'000;
  return DeviceProc<PFN_vkWaitForFences>("vkWaitForFences")(device, 1, &fence_, VK_TRUE,
                                                          kFrameTimeout) == VK_SUCCESS;
}

bool RetroVulkanVideo::Read(uint8_t* pixels, unsigned width, unsigned height) {
  const auto image = std::exchange(image_, RetroVulkanImage{});
  const bool bgra = image.info.format == VK_FORMAT_B8G8R8A8_UNORM ||
                    image.info.format == VK_FORMAT_B8G8R8A8_SRGB;
  if (unsupported_sync_ || !image.info.image || image.layout != VK_IMAGE_LAYOUT_GENERAL ||
      (!bgra && image.info.format != VK_FORMAT_R8G8B8A8_UNORM &&
       image.info.format != VK_FORMAT_R8G8B8A8_SRGB))
    return false;
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  if (!PrepareBuffer(bytes) || !CopyImage(image, width, height)) return false;
  std::memcpy(pixels, mapped_, bytes);
  for (size_t index = 0; index < bytes; index += 4) {
    if (bgra) std::swap(pixels[index], pixels[index + 2]);
    pixels[index + 3] = 255;
  }
  return true;
}

class VulkanVideo final : public Video {
 public:
  bool Open() override { return video_.Load(); }
  int PreferredContext() const override { return kVulkan; }
  std::string_view PreferredRenderer() const override { return "vulkan"; }

  bool Bind(HardwareCallbacks& callbacks) override {
    if (callbacks.context_type != kVulkan) return false;
    callbacks.framebuffer = []() -> uintptr_t { return 0; };
    callbacks.proc_address = [](const char*) -> void (*)() { return nullptr; };
    return true;
  }

  bool Environment(unsigned command, void* data, int context) override {
    if (command == kHardwareNegotiation)
      return video_.SetNegotiation(*static_cast<const RetroVulkanNegotiation*>(data));
    if (command != kHardwareInterface || context != kVulkan) return false;
    *static_cast<const RetroVulkanInterface**>(data) = &video_.render_interface();
    return true;
  }

  void Reset(const HardwareCallbacks& callbacks) override {
    if (!video_.Open()) throw std::runtime_error("The PS3 Vulkan device could not be initialized.");
    callbacks.reset();
  }

  void Clear() override {}

  void BeforeCoreDeinit(const HardwareCallbacks& callbacks) override {
    if (video_.negotiated() && callbacks.destroy) callbacks.destroy();
    video_.Close();
  }

  void Close() override {}

  std::shared_ptr<Frame> Read(unsigned width, unsigned height, const HardwareCallbacks&) override {
    auto frame = std::make_shared<Frame>();
    frame->width = width;
    frame->height = height;
    frame->pixels.resize(static_cast<size_t>(width) * height * 4);
    if (!video_.Read(frame->pixels.data(), width, height))
      throw std::runtime_error("The PS3 Vulkan frame could not be read.");
    return frame;
  }

  bool UnsupportedSync() const override { return video_.unsupported_sync(); }

 private:
  RetroVulkanVideo video_;
};
}  // namespace

std::unique_ptr<Video> CreateVulkanVideo() { return std::make_unique<VulkanVideo>(); }

}  // namespace anyps5::retro
