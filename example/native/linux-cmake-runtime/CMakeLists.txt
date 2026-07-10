cmake_minimum_required(VERSION 3.14)

project(desktop_updater_linux_runtime_compile LANGUAGES CXX)

find_package(desktop_updater_native 2.7.0 EXACT CONFIG REQUIRED)

add_executable(runtime_compile main.cpp)
target_compile_features(runtime_compile PRIVATE cxx_std_14)
target_link_libraries(runtime_compile
  PRIVATE desktop_updater::runtime desktop_updater::native)

enable_testing()
add_test(NAME desktop_updater_linux_runtime_compile COMMAND runtime_compile)
