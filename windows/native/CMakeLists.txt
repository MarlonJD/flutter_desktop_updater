cmake_minimum_required(VERSION 3.14)

project(desktop_updater_native VERSION 2.7.0 LANGUAGES CXX)

option(DESKTOP_UPDATER_NATIVE_BUILD_TESTS
  "Build desktop_updater native tests" OFF)
option(DESKTOP_UPDATER_NATIVE_RUNTIME
  "Build the preview non-Flutter update runtime" OFF)

set(NATIVE_SOURCES
  src/desktop_updater_native.cpp
  src/desktop_updater_native_c.cpp
)

add_library(desktop_updater_native_objects OBJECT ${NATIVE_SOURCES})
target_compile_features(desktop_updater_native_objects PUBLIC cxx_std_17)
target_include_directories(desktop_updater_native_objects
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)
set_target_properties(desktop_updater_native_objects PROPERTIES
  POSITION_INDEPENDENT_CODE ON)

add_library(desktop_updater_native_static STATIC
  $<TARGET_OBJECTS:desktop_updater_native_objects>)
target_include_directories(desktop_updater_native_static
  PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_link_libraries(desktop_updater_native_static
  PUBLIC Bcrypt Shell32)

add_library(desktop_updater_native SHARED
  $<TARGET_OBJECTS:desktop_updater_native_objects>)
add_library(desktop_updater::native ALIAS desktop_updater_native)
target_include_directories(desktop_updater_native
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)
target_compile_definitions(desktop_updater_native
  PRIVATE DESKTOP_UPDATER_NATIVE_BUILDING_DLL)
target_compile_definitions(desktop_updater_native
  INTERFACE DESKTOP_UPDATER_NATIVE_USING_DLL)
target_link_libraries(desktop_updater_native
  PRIVATE Bcrypt Shell32)
set_target_properties(desktop_updater_native PROPERTIES
  EXPORT_NAME native
  WINDOWS_EXPORT_ALL_SYMBOLS ON
  OUTPUT_NAME desktop_updater_native)

if(DESKTOP_UPDATER_NATIVE_RUNTIME)
  enable_language(C)
  set(DESKTOP_UPDATER_RUNTIME_COMMON_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}/../../native_runtime/cpp)
  set(DESKTOP_UPDATER_MONOCYPHER_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/monocypher/src)
  add_library(desktop_updater_runtime SHARED
    src/runtime/desktop_updater_runtime_c.cpp
    src/runtime/sha256_bcrypt.cpp
    src/runtime/update_transport_winhttp.cpp
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/json_value.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/release_contract.cc
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/monocypher.c
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional/monocypher-ed25519.c)
  add_library(desktop_updater::runtime ALIAS desktop_updater_runtime)
  target_compile_features(desktop_updater_runtime PUBLIC cxx_std_17)
  target_include_directories(desktop_updater_runtime
    PUBLIC
      $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
      $<INSTALL_INTERFACE:include>
    PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional)
  target_compile_definitions(desktop_updater_runtime
    PRIVATE DESKTOP_UPDATER_RUNTIME_BUILDING_DLL)
  target_compile_definitions(desktop_updater_runtime
    INTERFACE DESKTOP_UPDATER_RUNTIME_USING_DLL)
  set_target_properties(desktop_updater_runtime PROPERTIES
    EXPORT_NAME runtime
    OUTPUT_NAME desktop_updater_runtime)
  target_link_libraries(desktop_updater_runtime PRIVATE Bcrypt Winhttp)
endif()

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  include(GNUInstallDirs)
  include(CMakePackageConfigHelpers)
  install(TARGETS desktop_updater_native
    EXPORT desktop_updater_nativeTargets
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
  if(DESKTOP_UPDATER_NATIVE_RUNTIME)
    install(TARGETS desktop_updater_runtime
      EXPORT desktop_updater_nativeTargets
      RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
      LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
      ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
  endif()
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
  write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfigVersion.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion)
  install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfig.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfigVersion.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/desktop_updater_native)
endif()

if(DESKTOP_UPDATER_NATIVE_BUILD_TESTS)
  enable_testing()
  find_package(GTest 1.16.0 EXACT CONFIG QUIET)
  if(NOT GTest_FOUND)
    include(FetchContent)
    FetchContent_Declare(
      googletest
      URL https://github.com/google/googletest/archive/refs/tags/v1.16.0.zip
      URL_HASH SHA256=a9607c9215866bd425a725610c5e0f739eeb50887a57903df48891446ce6fb3c
    )
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)
  endif()

  add_executable(desktop_updater_native_test
    test/desktop_updater_native_c_test.cpp)
  target_compile_features(desktop_updater_native_test PRIVATE cxx_std_17)
  target_include_directories(desktop_updater_native_test
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_link_libraries(desktop_updater_native_test
    PRIVATE desktop_updater_native_static GTest::gtest_main)

  include(GoogleTest)
  gtest_discover_tests(desktop_updater_native_test)

  if(DESKTOP_UPDATER_NATIVE_RUNTIME)
    add_executable(desktop_updater_runtime_api_compile_test
      test/runtime/runtime_c_api_compile_test.cpp)
    target_compile_features(desktop_updater_runtime_api_compile_test
      PRIVATE cxx_std_17)
    target_link_libraries(desktop_updater_runtime_api_compile_test
      PRIVATE desktop_updater_runtime)
    add_test(NAME desktop_updater_runtime_api_compile
      COMMAND desktop_updater_runtime_api_compile_test)

    add_executable(desktop_updater_runtime_contract_test
      test/runtime/contract_conformance_test.cpp
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/contract_fixture_tests.cc)
    target_compile_features(desktop_updater_runtime_contract_test
      PRIVATE cxx_std_17)
    target_include_directories(desktop_updater_runtime_contract_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
    target_link_libraries(desktop_updater_runtime_contract_test
      PRIVATE desktop_updater_runtime Bcrypt)
    add_test(NAME desktop_updater_runtime_contract
      COMMAND desktop_updater_runtime_contract_test
        ${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-contract)

    add_executable(desktop_updater_runtime_transport_test
      test/runtime/transport_fixture_test.cpp
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/transport_fixture_tests.cc)
    target_compile_features(desktop_updater_runtime_transport_test
      PRIVATE cxx_std_17)
    target_include_directories(desktop_updater_runtime_transport_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
    target_link_libraries(desktop_updater_runtime_transport_test
      PRIVATE desktop_updater_runtime Bcrypt Winhttp)
    add_test(NAME desktop_updater_runtime_transport
      COMMAND desktop_updater_runtime_transport_test)
  endif()
endif()
