cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# What a media player on this computer plays (now_playing.cpp, Windows' system media transport
# controls). C++/WinRT needs exceptions and C++20's coroutine header, and the standard settings
# above turn exceptions off in the standard library (_HAS_EXCEPTIONS=0), so it is a library of
# its own with a plain C header.
add_library(now_playing STATIC "now_playing.cpp")
target_compile_features(now_playing PRIVATE cxx_std_20)
target_compile_options(now_playing PRIVATE /W3 /EHsc)
target_compile_definitions(now_playing PRIVATE "NOMINMAX" "UNICODE" "_UNICODE" "WIN32_LEAN_AND_MEAN")
target_link_libraries(now_playing PRIVATE windowsapp)

# Delete game: a game's files into the Recycle Bin (recycle.cpp, the shell's IFileOperation) on
# a thread of its own. A library with a plain C header for the same reason: the thread it starts
# needs exceptions.
add_library(recycle STATIC "recycle.cpp")
target_compile_features(recycle PRIVATE cxx_std_17)
target_compile_options(recycle PRIVATE /W3 /EHsc)
target_compile_definitions(recycle PRIVATE "NOMINMAX" "UNICODE" "_UNICODE")
target_link_libraries(recycle PRIVATE shell32 ole32)

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE now_playing)
target_link_libraries(${BINARY_NAME} PRIVATE recycle)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
