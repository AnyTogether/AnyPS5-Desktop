cmake_minimum_required(VERSION 3.13)
project(anyps5_retro_test LANGUAGES CXX)

enable_testing()
add_subdirectory(.. retro)

add_library(retro_fake_core SHARED fake_core.cpp)
add_executable(retro_native_test retro_native_test.cpp)
target_link_libraries(retro_native_test PRIVATE anyps5_retro)
add_test(NAME retro_native COMMAND retro_native_test "$<TARGET_FILE:retro_fake_core>")
