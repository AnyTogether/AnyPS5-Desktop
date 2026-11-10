cmake_minimum_required(VERSION 3.18)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "layer_overlay.cc"
  "retro_core_host_linux.cc"
  "retro_linux_audio.cc"
  "retro_linux_video.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
pkg_check_modules(RETRO_RENDER REQUIRED IMPORTED_TARGET egl epoxy)
pkg_check_modules(RETRO_AUDIO REQUIRED IMPORTED_TARGET libpulse)
set(ANYPS5_RETRO_VULKAN ON)
add_subdirectory("${CMAKE_SOURCE_DIR}/../native/retro" "${CMAKE_CURRENT_BINARY_DIR}/retro")
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK PkgConfig::RETRO_RENDER PkgConfig::RETRO_AUDIO anyps5_retro_vulkan)
# dlopen for gtk-layer-shell (layer_overlay.cc), which is loaded at run time, never linked.
target_link_libraries(${BINARY_NAME} PRIVATE ${CMAKE_DL_LIBS})

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
