cmake_minimum_required(VERSION 3.22)
project(desktop_updater_v3_removed_api_windows_consumer LANGUAGES C CXX)

if(NOT DEFINED DESKTOP_UPDATER_SOURCE_ROOT)
  message(FATAL_ERROR "DESKTOP_UPDATER_SOURCE_ROOT is required")
endif()

add_library(
  legacy_windows_c
  OBJECT
  "${CMAKE_CURRENT_LIST_DIR}/../../windows-c/legacy_schedule_install.c"
)
set_target_properties(legacy_windows_c PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED YES)
target_include_directories(
  legacy_windows_c
  PRIVATE "${DESKTOP_UPDATER_SOURCE_ROOT}/windows/native/include"
)

add_library(
  legacy_windows_cpp
  OBJECT
  "${CMAKE_CURRENT_LIST_DIR}/../../windows-cpp/legacy_schedule_install.cc"
)
set_target_properties(
  legacy_windows_cpp
  PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED YES
)
target_include_directories(
  legacy_windows_cpp
  PRIVATE "${DESKTOP_UPDATER_SOURCE_ROOT}/windows/native/include"
)
