cmake_minimum_required(VERSION 3.14)

if(POLICY CMP0091)
  cmake_policy(SET CMP0091 NEW)
endif()
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")

project(desktop_updater_native VERSION 2.7.0 LANGUAGES C CXX)

option(DESKTOP_UPDATER_NATIVE_BUILD_TESTS
  "Build desktop_updater native tests" OFF)
option(DESKTOP_UPDATER_NATIVE_RUNTIME
  "Build the preview non-Flutter update runtime" OFF)
# A portable helper policy is consumer-specific: it seals the hashes of the
# final signed application and helper. Keep the provider opt-in so ordinary
# development builds do not accidentally ship an unbound policy.
option(DESKTOP_UPDATER_PORTABLE_PROVIDER
  "Bundle the signed same-user Windows helper provider" OFF)
set(DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH "" CACHE FILEPATH
  "Absolute path to the consumer-specific portable helper policy")
set(DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR "" CACHE PATH
  "Absolute installer-protected directory for an elevated helper copy")
if(DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR)
  string(REPLACE "\\" "/"
    DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR_NORMALIZED
    "${DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR}")
  if(NOT IS_ABSOLUTE "${DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR}" AND
     NOT DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR_NORMALIZED MATCHES
       "^[A-Za-z]:/")
    message(FATAL_ERROR
      "DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR must be absolute")
  endif()
  if(NOT DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR_NORMALIZED MATCHES
       "^[A-Za-z]:/Program Files/DesktopUpdaterHelperGenerationV1--[A-Za-z0-9][A-Za-z0-9._+-]*--[A-Za-z0-9][A-Za-z0-9._+-]*$")
    message(FATAL_ERROR
      "DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR must use the dedicated "
      "<drive>:/Program Files/DesktopUpdaterHelperGenerationV1--"
      "<package-id>--<release> "
      "layout")
  endif()
endif()

if(DESKTOP_UPDATER_PORTABLE_PROVIDER)
  if(NOT DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH)
    message(FATAL_ERROR
      "DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH is required when "
      "DESKTOP_UPDATER_PORTABLE_PROVIDER is enabled")
  endif()
  string(REPLACE "\\" "/"
    DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH_NORMALIZED
    "${DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH}")
  if(NOT IS_ABSOLUTE "${DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH}" AND
     NOT DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH_NORMALIZED MATCHES
       "^[A-Za-z]:/")
    message(FATAL_ERROR
      "DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH must be absolute")
  endif()
  if(NOT EXISTS "${DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH}" OR
     IS_DIRECTORY "${DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH}")
    message(FATAL_ERROR
      "DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH does not name a file")
  endif()
  set(DESKTOP_UPDATER_PORTABLE_POLICY_OUTPUT
    "${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_helper_policy.json")
  configure_file(
    "${DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH}"
    "${DESKTOP_UPDATER_PORTABLE_POLICY_OUTPUT}"
    COPYONLY)
  if(NOT CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(DESKTOP_UPDATER_PORTABLE_POLICY_OUTPUT
      "${DESKTOP_UPDATER_PORTABLE_POLICY_OUTPUT}" PARENT_SCOPE)
  endif()
endif()

set(DESKTOP_UPDATER_RUNTIME_COMMON_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/../../native_runtime/cpp)
set(DESKTOP_UPDATER_MONOCYPHER_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/monocypher/src)
set(DESKTOP_UPDATER_MINIZ_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/miniz)
set_source_files_properties(${DESKTOP_UPDATER_MINIZ_DIR}/miniz.c PROPERTIES
  COMPILE_DEFINITIONS MINIZ_NO_ZLIB_APIS)
set(NATIVE_SOURCES
  src/desktop_updater_native.cpp
  src/desktop_updater_native_c.cpp
  src/helper/helper_authenticode.cpp
  src/helper/helper_policy_windows.cpp
  src/helper/named_pipe_transport.cpp
  src/helper/windows_helper_diagnostics.cpp
  src/helper/windows_protected_helper_locator.cpp
  src/helper/windows_recovery_transport.cpp
  src/helper/windows_one_shot_transport.cpp
  src/helper/windows_portable_transaction_index.cpp
  src/helper/windows_portable_user_storage.cpp
  src/helper/windows_transaction_journal.cpp
  src/helper/windows_uninstall_record_proof.cpp
  src/runtime/sha256_bcrypt.cpp
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/install_helper_contract.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/install_helper_policy.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_request.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_service_runtime.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_session.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_wire.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/stage_provenance.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/windows_native_install_request_builder.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/json_value.cc
)

add_library(desktop_updater_native_objects OBJECT ${NATIVE_SOURCES})
target_compile_features(desktop_updater_native_objects PUBLIC cxx_std_17)
target_include_directories(desktop_updater_native_objects
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/helper
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
)
target_compile_definitions(desktop_updater_native_objects
  PRIVATE
    UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
    _WIN32_WINNT=0x0A00
    DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR="${DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR}")
if(MSVC)
  target_compile_options(desktop_updater_native_objects PRIVATE /utf-8)
endif()
set_target_properties(desktop_updater_native_objects PROPERTIES
  POSITION_INDEPENDENT_CODE ON)

add_library(desktop_updater_native_static STATIC
  $<TARGET_OBJECTS:desktop_updater_native_objects>)
target_include_directories(desktop_updater_native_static
  PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_link_libraries(desktop_updater_native_static
  PUBLIC advapi32 bcrypt crypt32 ole32 shell32 wintrust)

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
  PRIVATE advapi32 bcrypt crypt32 ole32 shell32 wintrust)
set_target_properties(desktop_updater_native PROPERTIES
  EXPORT_NAME native
  WINDOWS_EXPORT_ALL_SYMBOLS ON
  OUTPUT_NAME desktop_updater_native)

set(DESKTOP_UPDATER_INSTALL_HELPER_SOURCES
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_authorization.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_service_runtime.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/release_contract.cc
  ${DESKTOP_UPDATER_MONOCYPHER_DIR}/monocypher.c
  ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional/monocypher-ed25519.c
  src/helper/install_strategy.cpp
  src/helper/helper_policy_windows.cpp
  src/helper/helper_authenticode.cpp
  src/helper/named_pipe_transport.cpp
  src/helper/windows_helper_diagnostics.cpp
  src/helper/windows_helper_bootstrap.cpp
  src/helper/windows_archive_restage.cpp
  src/helper/windows_install_authorizer.cpp
  src/helper/windows_one_shot_transport.cpp
  src/helper/windows_reservation.cpp
  src/helper/windows_transaction_journal.cpp
  src/helper/windows_uninstall_record_proof.cpp
  src/helper/windows_file_transaction.cpp
  src/helper/windows_recovery_service.cpp
  src/helper/windows_persistent_recovery.cpp
  src/helper/windows_portable_recovery_host.cpp
  src/helper/windows_portable_transaction_index.cpp
  src/helper/windows_portable_user_storage.cpp
  src/helper/windows_protected_helper_locator.cpp
  src/helper/windows_recovery_host.cpp
  src/helper/windows_recovery_pipe_server.cpp
  src/helper/windows_recovery_transport.cpp
  src/helper/windows_relaunch_service.cpp
  src/helper/verified_installer_handoff.cpp
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/install_helper_policy.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_request.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_session.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_wire.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/json_value.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/stage_provenance.cc
  ${DESKTOP_UPDATER_MINIZ_DIR}/miniz.c)
add_library(desktop_updater_install_helper_support STATIC
  ${DESKTOP_UPDATER_INSTALL_HELPER_SOURCES})
target_compile_features(desktop_updater_install_helper_support
  PUBLIC cxx_std_17)
target_compile_definitions(desktop_updater_install_helper_support
  PRIVATE
    UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
    _WIN32_WINNT=0x0A00 MINIZ_NO_ZLIB_APIS)
if(MSVC)
  target_compile_options(desktop_updater_install_helper_support PRIVATE /utf-8)
endif()
target_include_directories(desktop_updater_install_helper_support
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src/helper
    $<BUILD_INTERFACE:${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}>
  PRIVATE
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional
    ${DESKTOP_UPDATER_MINIZ_DIR})
target_link_libraries(desktop_updater_install_helper_support
  PUBLIC wintrust crypt32 advapi32 shell32 bcrypt ole32 oleaut32 taskschd
    userenv)

add_executable(desktop_updater_install_helper WIN32
  src/helper/main.cpp)
target_compile_features(desktop_updater_install_helper PRIVATE cxx_std_17)
target_compile_definitions(desktop_updater_install_helper
  PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(desktop_updater_install_helper
  PRIVATE desktop_updater_install_helper_support)
if(MINGW)
  target_link_options(desktop_updater_install_helper PRIVATE -municode)
endif()
set_target_properties(desktop_updater_install_helper PROPERTIES
  OUTPUT_NAME desktop_updater_install_helper)

if(DESKTOP_UPDATER_NATIVE_RUNTIME)
  enable_language(C)
  set(DESKTOP_UPDATER_RUNTIME_SOURCES
    src/runtime/artifact_stager_windows.cpp
    src/runtime/desktop_updater_runtime_c.cpp
    src/runtime/sha256_bcrypt.cpp
    src/runtime/update_transport_winhttp.cpp
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/diagnostics.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/release_contract.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/redirect_url.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/stage_provenance.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/update_client_core.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/artifact_stager.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/client_lifecycle.cc
    ${DESKTOP_UPDATER_MINIZ_DIR}/miniz.c
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/monocypher.c
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional/monocypher-ed25519.c)
  add_library(desktop_updater_runtime_objects OBJECT
    ${DESKTOP_UPDATER_RUNTIME_SOURCES})
  target_compile_features(desktop_updater_runtime_objects PUBLIC cxx_std_17)
  target_include_directories(desktop_updater_runtime_objects
    PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/include
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MINIZ_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional)
  target_compile_definitions(desktop_updater_runtime_objects
    PRIVATE DESKTOP_UPDATER_RUNTIME_BUILDING_DLL)
  set_target_properties(desktop_updater_runtime_objects PROPERTIES
    POSITION_INDEPENDENT_CODE ON)

  add_library(desktop_updater_runtime SHARED
    $<TARGET_OBJECTS:desktop_updater_runtime_objects>)
  add_library(desktop_updater::runtime ALIAS desktop_updater_runtime)
  target_compile_features(desktop_updater_runtime PUBLIC cxx_std_17)
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
  target_compile_definitions(desktop_updater_runtime
    INTERFACE DESKTOP_UPDATER_RUNTIME_USING_DLL)
  set_target_properties(desktop_updater_runtime PROPERTIES
    EXPORT_NAME runtime
    OUTPUT_NAME desktop_updater_runtime)
  target_link_libraries(desktop_updater_runtime
    PRIVATE
      desktop_updater_native_static
      bcrypt crypt32 winhttp wintrust)
endif()

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  include(GNUInstallDirs)
  include(CMakePackageConfigHelpers)
  install(TARGETS desktop_updater_native
    EXPORT desktop_updater_nativeTargets
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
  install(TARGETS desktop_updater_install_helper
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
  if(DESKTOP_UPDATER_PORTABLE_PROVIDER)
    install(FILES "${DESKTOP_UPDATER_PORTABLE_POLICY_OUTPUT}"
      DESTINATION ${CMAKE_INSTALL_BINDIR})
  endif()
  if(DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR)
    install(TARGETS desktop_updater_install_helper
      RUNTIME DESTINATION
        "${DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR}")
  endif()
  if(DESKTOP_UPDATER_NATIVE_RUNTIME)
    install(TARGETS desktop_updater_runtime
      EXPORT desktop_updater_nativeTargets
      RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
      LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
      ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
  endif()
  install(DIRECTORY include/
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
  install(FILES THIRD_PARTY_NOTICES.md
    DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/doc/desktop_updater_native)
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
    test/desktop_updater_native_c_test.cpp
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/install_helper_contract_fixture_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_request_fixture_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_authorization.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_authorization_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_service_runtime.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_service_runtime_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_session_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_wire_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/windows_native_install_request_builder_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/install_helper_policy_fixture_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/release_contract.cc
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/monocypher.c
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional/monocypher-ed25519.c)
  add_executable(windows_restart_caller_fixture
    test/windows_restart_caller_fixture.cpp)
  target_compile_features(windows_restart_caller_fixture PRIVATE cxx_std_17)
  target_compile_definitions(windows_restart_caller_fixture
    PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
  if(MINGW)
    target_link_options(windows_restart_caller_fixture PRIVATE -municode)
  endif()
  target_link_libraries(windows_restart_caller_fixture
    PRIVATE desktop_updater_native_static)
  add_dependencies(desktop_updater_native_test
    windows_restart_caller_fixture)
  target_compile_features(desktop_updater_native_test PRIVATE cxx_std_17)
  target_include_directories(desktop_updater_native_test
    PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional)
  target_compile_definitions(desktop_updater_native_test PRIVATE
    DESKTOP_UPDATER_JOURNAL_FIXTURE_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-install-helper/v1/journal-transitions.json\"
    DESKTOP_UPDATER_VALID_REQUEST_FIXTURE_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-install-helper/v1/valid-requests.json\"
    DESKTOP_UPDATER_SIGNATURE_FIXTURE_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-contract/canonical-signature-cases.json\"
    DESKTOP_UPDATER_POLICY_FIXTURE_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-install-helper/v1/policy-cases.json\")
  target_link_libraries(desktop_updater_native_test
    PRIVATE desktop_updater_native_static GTest::gtest_main)

  include(GoogleTest)
  gtest_discover_tests(desktop_updater_native_test)

  add_executable(windows_helper_auth
    test/helper/windows_helper_auth_test.cpp)
  target_compile_features(windows_helper_auth PRIVATE cxx_std_17)
  target_compile_definitions(windows_helper_auth
    PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(windows_helper_auth
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_helper_auth)

  add_executable(windows_helper_reservation
    test/helper/windows_helper_reservation_test.cpp)
  target_compile_features(windows_helper_reservation PRIVATE cxx_std_17)
  target_compile_definitions(windows_helper_reservation
    PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(windows_helper_reservation
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_helper_reservation)

  add_executable(windows_helper_diagnostics
    test/helper/windows_helper_diagnostics_test.cpp)
  target_compile_features(windows_helper_diagnostics PRIVATE cxx_std_17)
  target_compile_definitions(windows_helper_diagnostics
    PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(windows_helper_diagnostics
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_helper_diagnostics)

  add_executable(windows_one_shot_transport
    test/helper/windows_one_shot_transport_test.cpp)
  target_compile_features(windows_one_shot_transport PRIVATE cxx_std_17)
  target_compile_definitions(windows_one_shot_transport
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_one_shot_transport PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_one_shot_transport
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_one_shot_transport)

  add_executable(windows_persistent_recovery
    test/helper/windows_persistent_recovery_test.cpp)
  target_compile_features(windows_persistent_recovery PRIVATE cxx_std_17)
  target_compile_definitions(windows_persistent_recovery
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_persistent_recovery PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_persistent_recovery
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_persistent_recovery)

  add_executable(windows_portable_recovery_host
    test/helper/windows_portable_recovery_host_test.cpp)
  target_compile_features(windows_portable_recovery_host PRIVATE cxx_std_17)
  target_compile_definitions(windows_portable_recovery_host
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_portable_recovery_host PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_portable_recovery_host
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_portable_recovery_host
    DISCOVERY_MODE PRE_TEST)

  add_executable(windows_portable_transaction_index
    test/helper/windows_portable_transaction_index_test.cpp)
  target_compile_features(windows_portable_transaction_index PRIVATE
    cxx_std_17)
  target_compile_definitions(windows_portable_transaction_index
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_portable_transaction_index PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_portable_transaction_index
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_portable_transaction_index
    DISCOVERY_MODE PRE_TEST)

  add_executable(windows_protected_helper_locator
    test/helper/windows_protected_helper_locator_test.cpp)
  target_compile_features(windows_protected_helper_locator PRIVATE cxx_std_17)
  target_compile_definitions(windows_protected_helper_locator
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_protected_helper_locator PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_protected_helper_locator
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_protected_helper_locator)

  add_executable(windows_recovery_host
    test/helper/windows_recovery_host_test.cpp)
  target_compile_features(windows_recovery_host PRIVATE cxx_std_17)
  target_compile_definitions(windows_recovery_host
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_recovery_host PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_recovery_host
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_recovery_host)

  add_executable(windows_uninstall_record_proof
    test/helper/windows_uninstall_record_proof_test.cpp)
  target_compile_features(windows_uninstall_record_proof PRIVATE cxx_std_17)
  target_compile_definitions(windows_uninstall_record_proof
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_uninstall_record_proof PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_uninstall_record_proof
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_uninstall_record_proof)

  add_executable(windows_install_authorizer
    test/helper/windows_install_authorizer_test.cpp)
  target_compile_features(windows_install_authorizer PRIVATE cxx_std_17)
  target_compile_definitions(windows_install_authorizer
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_install_authorizer PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_install_authorizer
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_install_authorizer DISCOVERY_MODE PRE_TEST)

  add_executable(windows_archive_restage
    test/helper/windows_archive_restage_test.cpp)
  target_compile_features(windows_archive_restage PRIVATE cxx_std_17)
  target_compile_definitions(windows_archive_restage
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00
      MINIZ_NO_ZLIB_APIS)
  target_include_directories(windows_archive_restage
    PRIVATE ${DESKTOP_UPDATER_MINIZ_DIR})
  if(MSVC)
    target_compile_options(windows_archive_restage PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_archive_restage
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_archive_restage DISCOVERY_MODE PRE_TEST)

  add_executable(windows_transaction
    test/helper/windows_transaction_test.cpp)
  target_compile_features(windows_transaction PRIVATE cxx_std_17)
  target_compile_definitions(windows_transaction
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_transaction PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_transaction
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_transaction DISCOVERY_MODE PRE_TEST)

  add_executable(windows_crash_recovery
    test/helper/windows_crash_recovery_test.cpp)
  target_compile_features(windows_crash_recovery PRIVATE cxx_std_17)
  target_compile_definitions(windows_crash_recovery
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_crash_recovery PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_crash_recovery
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_crash_recovery)

  add_executable(windows_install_strategy
    test/helper/windows_install_strategy_test.cpp)
  target_compile_features(windows_install_strategy PRIVATE cxx_std_17)
  target_compile_definitions(windows_install_strategy
    PRIVATE
      UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
      _WIN32_WINNT=0x0A00)
  if(MSVC)
    target_compile_options(windows_install_strategy PRIVATE /utf-8)
  endif()
  target_link_libraries(windows_install_strategy
    PRIVATE desktop_updater_install_helper_support GTest::gtest_main)
  gtest_discover_tests(windows_install_strategy
    TEST_PREFIX "windows_install_strategy.")

  if(DESKTOP_UPDATER_NATIVE_RUNTIME)
    add_executable(desktop_updater_runtime_lifecycle_test
      test/runtime/client_lifecycle_test.cpp
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/client_lifecycle.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/client_lifecycle_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/json_value.cc)
    target_compile_features(desktop_updater_runtime_lifecycle_test
      PRIVATE cxx_std_17)
    target_include_directories(desktop_updater_runtime_lifecycle_test PRIVATE
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
    add_test(NAME desktop_updater_runtime_lifecycle
      COMMAND desktop_updater_runtime_lifecycle_test)

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
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/archive_fixture_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/contract_fixture_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/diagnostics_fixture_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/update_client_core_fixture_tests.cc)
    target_compile_features(desktop_updater_runtime_contract_test
      PRIVATE cxx_std_17)
    target_include_directories(desktop_updater_runtime_contract_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MINIZ_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR})
    target_link_libraries(desktop_updater_runtime_contract_test
      PRIVATE
        desktop_updater_native_static
        bcrypt crypt32 winhttp wintrust)
    target_sources(desktop_updater_runtime_contract_test PRIVATE
      $<TARGET_OBJECTS:desktop_updater_runtime_objects>)
    add_test(NAME desktop_updater_runtime_contract
      COMMAND desktop_updater_runtime_contract_test
        ${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-contract)

    add_executable(desktop_updater_runtime_artifact_test
      test/runtime/artifact_stager_test.cpp)
    target_compile_features(desktop_updater_runtime_artifact_test
      PRIVATE cxx_std_17)
    target_include_directories(desktop_updater_runtime_artifact_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MINIZ_DIR})
    target_link_libraries(desktop_updater_runtime_artifact_test
      PRIVATE
        desktop_updater_native_static
        bcrypt crypt32 winhttp wintrust)
    target_sources(desktop_updater_runtime_artifact_test PRIVATE
      $<TARGET_OBJECTS:desktop_updater_runtime_objects>)
    add_test(NAME desktop_updater_runtime_artifact
      COMMAND desktop_updater_runtime_artifact_test
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
      PRIVATE
        desktop_updater_native_static
        bcrypt crypt32 winhttp wintrust)
    target_sources(desktop_updater_runtime_transport_test PRIVATE
      $<TARGET_OBJECTS:desktop_updater_runtime_objects>)
    add_test(NAME desktop_updater_runtime_transport
      COMMAND desktop_updater_runtime_transport_test)

    add_executable(desktop_updater_runtime_redirect_url_test
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/redirect_url_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/redirect_url.cc)
    target_compile_features(desktop_updater_runtime_redirect_url_test
      PRIVATE cxx_std_17)
    target_include_directories(desktop_updater_runtime_redirect_url_test PRIVATE
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
    add_test(NAME desktop_updater_runtime_redirect_url
      COMMAND desktop_updater_runtime_redirect_url_test)

    add_executable(desktop_updater_runtime_stage_path_test
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/stage_provenance_path_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/stage_provenance.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/json_value.cc)
    target_compile_features(desktop_updater_runtime_stage_path_test
      PRIVATE cxx_std_17)
    target_include_directories(desktop_updater_runtime_stage_path_test PRIVATE
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
    target_link_libraries(desktop_updater_runtime_stage_path_test
      PRIVATE bcrypt)
    add_test(NAME desktop_updater_runtime_stage_path
      COMMAND desktop_updater_runtime_stage_path_test)
  endif()
endif()
