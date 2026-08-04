cmake_minimum_required(VERSION 3.22)
project(desktop_updater_v3_removed_api LANGUAGES CXX)

if(NOT DEFINED DESKTOP_UPDATER_SOURCE_ROOT)
  message(FATAL_ERROR "DESKTOP_UPDATER_SOURCE_ROOT is required")
endif()

add_library(legacy_linux_scheduler STATIC main.cpp)
target_compile_features(legacy_linux_scheduler PRIVATE cxx_std_17)
target_include_directories(
  legacy_linux_scheduler
  PRIVATE "${DESKTOP_UPDATER_SOURCE_ROOT}/linux/native/include"
)
