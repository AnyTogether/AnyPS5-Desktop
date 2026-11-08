find_package(Threads REQUIRED)
add_library(anyps5_retro STATIC retro_frame.cpp retro_library.cpp retro_session.cpp)
target_compile_features(anyps5_retro PUBLIC cxx_std_17)
target_include_directories(anyps5_retro PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(anyps5_retro PRIVATE ${CMAKE_DL_LIBS} Threads::Threads)
if(WIN32)
  target_compile_definitions(anyps5_retro PRIVATE NOMINMAX)
endif()

if(ANYPS5_RETRO_VULKAN)
  include(FetchContent)
  if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
  endif()
  FetchContent_Declare(vulkan_headers
    URL https://codeload.github.com/KhronosGroup/Vulkan-Headers/tar.gz/2fa203425eb4af9dfc6b03f97ef72b0b5bcb8350
    URL_HASH SHA256=66e0dc7932203def85d94bf65a4fa3a3b29e61366713404f0465cdeb02e6ffd3
    SOURCE_SUBDIR include
  )
  FetchContent_MakeAvailable(vulkan_headers)

  add_library(anyps5_retro_vulkan STATIC retro_vulkan_video.cpp)
  if(COMMAND apply_standard_settings)
    apply_standard_settings(anyps5_retro_vulkan)
  endif()
  target_include_directories(anyps5_retro_vulkan PRIVATE "${vulkan_headers_SOURCE_DIR}/include")
  target_link_libraries(anyps5_retro_vulkan PUBLIC anyps5_retro PRIVATE ${CMAKE_DL_LIBS})
  if(WIN32)
    target_compile_definitions(anyps5_retro_vulkan PRIVATE NOMINMAX)
  endif()
endif()
