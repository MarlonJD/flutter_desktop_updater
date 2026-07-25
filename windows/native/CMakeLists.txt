# The Flutter Windows toolchain supports CMake 3.14 or later. Keep the native
# helper target on the same floor so Flutter plugin clients build unchanged.
cmake_minimum_required(VERSION 3.14)

project(desktop_updater_native LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

option(
  DESKTOP_UPDATER_NATIVE_BUILD_TESTS
  "Build desktop_updater native tests"
  OFF
)

add_library(desktop_updater_native STATIC
  "src/desktop_updater_native.cpp"
  "src/desktop_updater_native_c.cpp"
)

target_compile_features(desktop_updater_native PUBLIC cxx_std_17)
target_compile_definitions(desktop_updater_native PUBLIC
  DESKTOP_UPDATER_NATIVE_STATIC
)
target_include_directories(desktop_updater_native PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(desktop_updater_native PRIVATE bcrypt shell32 version)

if(DESKTOP_UPDATER_NATIVE_BUILD_TESTS)
  enable_testing()

  include(FetchContent)
  FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/archive/release-1.11.0.zip
  )
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
  set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)
  FetchContent_MakeAvailable(googletest)

  add_executable(desktop_updater_native_test
    "test/desktop_updater_native_test.cpp"
  )
  target_link_libraries(desktop_updater_native_test PRIVATE
    desktop_updater_native
    gtest_main
    gmock
  )

  include(GoogleTest)
  gtest_discover_tests(desktop_updater_native_test)
endif()
