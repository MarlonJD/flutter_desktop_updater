cmake_minimum_required(VERSION 3.10)

project(desktop_updater_native VERSION 2.7.0 LANGUAGES CXX)

option(DESKTOP_UPDATER_NATIVE_BUILD_TESTS
  "Build desktop_updater native tests" OFF)
option(DESKTOP_UPDATER_NATIVE_RUNTIME
  "Build the preview non-Flutter update runtime" OFF)

set(DESKTOP_UPDATER_RUNTIME_COMMON_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/../../native_runtime/cpp)
add_library(desktop_updater_native STATIC
  src/desktop_updater_native.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/json_value.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/stage_provenance.cc)
add_library(desktop_updater::native ALIAS desktop_updater_native)
target_compile_features(desktop_updater_native PUBLIC cxx_std_14)
target_include_directories(desktop_updater_native
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
  PRIVATE
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
set_target_properties(desktop_updater_native PROPERTIES
  EXPORT_NAME native
  POSITION_INDEPENDENT_CODE ON)

if(DESKTOP_UPDATER_NATIVE_RUNTIME)
  enable_language(C)
  find_package(CURL REQUIRED)
  find_package(OpenSSL REQUIRED COMPONENTS Crypto)
  find_package(Threads REQUIRED)
  set(DESKTOP_UPDATER_MONOCYPHER_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/monocypher/src)
  set(DESKTOP_UPDATER_MINIZ_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/miniz)
  set_source_files_properties(${DESKTOP_UPDATER_MINIZ_DIR}/miniz.c PROPERTIES
    COMPILE_DEFINITIONS "MINIZ_NO_ZLIB_APIS;_LARGEFILE64_SOURCE=1")
  add_library(desktop_updater_runtime STATIC
    src/runtime/artifact_stager_linux.cc
    src/runtime/runtime_configuration.cc
    src/runtime/sha256_openssl.cc
    src/runtime/update_client_linux.cc
    src/runtime/update_transport_curl.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/diagnostics.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/release_contract.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/update_client_core.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/artifact_stager.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/client_lifecycle.cc
    ${DESKTOP_UPDATER_MINIZ_DIR}/miniz.c
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/monocypher.c
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional/monocypher-ed25519.c)
  add_library(desktop_updater::runtime ALIAS desktop_updater_runtime)
  target_compile_features(desktop_updater_runtime PUBLIC cxx_std_14)
  target_include_directories(desktop_updater_runtime
    PUBLIC
      $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
      $<INSTALL_INTERFACE:include>
    PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MINIZ_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional)
  set_target_properties(desktop_updater_runtime PROPERTIES
    EXPORT_NAME runtime
    POSITION_INDEPENDENT_CODE ON)
  target_link_libraries(desktop_updater_runtime
    PUBLIC CURL::libcurl OpenSSL::Crypto
    PRIVATE desktop_updater_native Threads::Threads)
endif()

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  include(GNUInstallDirs)
  include(CMakePackageConfigHelpers)
  install(TARGETS desktop_updater_native
    EXPORT desktop_updater_nativeTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
  if(DESKTOP_UPDATER_NATIVE_RUNTIME)
    install(TARGETS desktop_updater_runtime
      EXPORT desktop_updater_nativeTargets
      ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
  endif()
  install(DIRECTORY include/
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
  install(EXPORT desktop_updater_nativeTargets
    FILE desktop_updater_nativeTargets.cmake
    NAMESPACE desktop_updater::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/desktop_updater_native)
  set(DESKTOP_UPDATER_NATIVE_RUNTIME_BUILT
    ${DESKTOP_UPDATER_NATIVE_RUNTIME})
  configure_file(
    cmake/desktop_updater_nativeConfig.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfig.cmake
    @ONLY)
  write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfigVersion.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion)
  configure_file(
    cmake/desktop_updater_native.pc.in
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_native.pc
    @ONLY)
  install(FILES ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_native.pc
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)
  install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfig.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfigVersion.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/desktop_updater_native)
endif()

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

  if(DESKTOP_UPDATER_NATIVE_RUNTIME)
    add_executable(desktop_updater_runtime_lifecycle_test
      test/runtime/client_lifecycle_test.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/client_lifecycle.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/client_lifecycle_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/json_value.cc)
    target_compile_features(desktop_updater_runtime_lifecycle_test
      PRIVATE cxx_std_14)
    target_include_directories(desktop_updater_runtime_lifecycle_test PRIVATE
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
    target_link_libraries(desktop_updater_runtime_lifecycle_test
      PRIVATE Threads::Threads)
    add_test(NAME desktop_updater_runtime_lifecycle
      COMMAND desktop_updater_runtime_lifecycle_test)

    add_executable(desktop_updater_runtime_contract_test
      test/runtime/contract_conformance_test.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/archive_fixture_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/contract_fixture_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/diagnostics_fixture_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/update_client_core_fixture_tests.cc)
    target_compile_features(desktop_updater_runtime_contract_test
      PRIVATE cxx_std_14)
    target_include_directories(desktop_updater_runtime_contract_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MINIZ_DIR})
    target_link_libraries(desktop_updater_runtime_contract_test
      PRIVATE desktop_updater_runtime OpenSSL::Crypto)
    add_test(NAME desktop_updater_runtime_contract
      COMMAND desktop_updater_runtime_contract_test
        ${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-contract)

    add_executable(desktop_updater_runtime_artifact_test
      test/runtime/artifact_stager_test.cc)
    target_compile_features(desktop_updater_runtime_artifact_test
      PRIVATE cxx_std_14)
    target_include_directories(desktop_updater_runtime_artifact_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MINIZ_DIR})
    target_link_libraries(desktop_updater_runtime_artifact_test
      PRIVATE desktop_updater_runtime)
    add_test(NAME desktop_updater_runtime_artifact
      COMMAND desktop_updater_runtime_artifact_test
        ${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-contract)

    add_executable(desktop_updater_runtime_transport_test
      test/runtime/transport_fixture_test.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/transport_fixture_tests.cc)
    target_compile_features(desktop_updater_runtime_transport_test
      PRIVATE cxx_std_14)
    target_include_directories(desktop_updater_runtime_transport_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
    target_link_libraries(desktop_updater_runtime_transport_test
      PRIVATE desktop_updater_runtime CURL::libcurl OpenSSL::Crypto)
    add_test(NAME desktop_updater_runtime_transport
      COMMAND desktop_updater_runtime_transport_test)
  endif()
endif()
