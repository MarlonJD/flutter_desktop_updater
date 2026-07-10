cmake_minimum_required(VERSION 3.10)

project(desktop_updater_native LANGUAGES CXX)

option(DESKTOP_UPDATER_NATIVE_BUILD_TESTS
  "Build desktop_updater native tests" OFF)

add_library(desktop_updater_native STATIC
  src/desktop_updater_native.cc)
add_library(desktop_updater::native ALIAS desktop_updater_native)
target_compile_features(desktop_updater_native PUBLIC cxx_std_14)
target_include_directories(desktop_updater_native
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)
set_target_properties(desktop_updater_native PROPERTIES
  EXPORT_NAME native
  POSITION_INDEPENDENT_CODE ON)

include(GNUInstallDirs)
install(TARGETS desktop_updater_native
  EXPORT desktop_updater_nativeTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/
  DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT desktop_updater_nativeTargets
  FILE desktop_updater_nativeTargets.cmake
  NAMESPACE desktop_updater::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/desktop_updater_native)
configure_file(
  cmake/desktop_updater_nativeConfig.cmake.in
  ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfig.cmake
  @ONLY)
configure_file(
  cmake/desktop_updater_native.pc.in
  ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_native.pc
  @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_native.pc
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)
install(FILES
  ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfig.cmake
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/desktop_updater_native)

if(DESKTOP_UPDATER_NATIVE_BUILD_TESTS)
  if(CMAKE_VERSION VERSION_LESS "3.14")
    message(FATAL_ERROR "Native tests require CMake 3.14 or later")
  endif()
  enable_testing()
  find_package(GTest 1.16.0 EXACT CONFIG QUIET)
  if(NOT GTest_FOUND)
    include(FetchContent)
    FetchContent_Declare(
      googletest
      URL https://github.com/google/googletest/archive/refs/tags/v1.16.0.zip
      URL_HASH SHA256=a9607c9215866bd425a725610c5e0f739eeb50887a57903df48891446ce6fb3c
    )
    set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)
  endif()

  add_executable(desktop_updater_native_test
    test/desktop_updater_native_test.cc)
  target_compile_features(desktop_updater_native_test PRIVATE cxx_std_17)
  target_include_directories(desktop_updater_native_test
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_link_libraries(desktop_updater_native_test
    PRIVATE desktop_updater_native GTest::gtest_main)

  include(GoogleTest)
  gtest_discover_tests(desktop_updater_native_test)
endif()
