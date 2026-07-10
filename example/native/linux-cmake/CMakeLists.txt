cmake_minimum_required(VERSION 3.14)

project(desktop_updater_linux_consumer LANGUAGES CXX)

find_package(desktop_updater_native CONFIG REQUIRED)

add_executable(consumer main.cpp)
target_compile_features(consumer PRIVATE cxx_std_14)
target_link_libraries(consumer PRIVATE desktop_updater::native)

enable_testing()
add_test(NAME desktop_updater_linux_installed_consumer COMMAND consumer)
