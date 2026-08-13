cmake_minimum_required(VERSION 3.14)

project(desktop_updater_windows_consumer LANGUAGES CXX)

find_package(desktop_updater_native 3.1.5 EXACT CONFIG REQUIRED)

add_executable(consumer main.cpp)
target_compile_features(consumer PRIVATE cxx_std_17)
target_link_libraries(consumer PRIVATE desktop_updater::native)

add_custom_command(TARGET consumer POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    $<TARGET_FILE:desktop_updater::native>
    $<TARGET_FILE_DIR:consumer>)

enable_testing()
add_test(NAME desktop_updater_windows_installed_consumer COMMAND consumer)
