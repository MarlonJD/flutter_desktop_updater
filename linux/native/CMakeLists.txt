cmake_minimum_required(VERSION 3.10)

if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()

project(desktop_updater_native VERSION 3.1.3 LANGUAGES C CXX)

option(DESKTOP_UPDATER_NATIVE_BUILD_TESTS
  "Build desktop_updater native tests" OFF)
option(DESKTOP_UPDATER_NATIVE_RUNTIME
  "Build the preview non-Flutter update runtime" OFF)
option(DESKTOP_UPDATER_INSTALL_SYSTEM_BROKER
  "Install the fixed root broker, polkit action, and sealed policy" OFF)
option(DESKTOP_UPDATER_ENABLE_POLKIT_E2E_FAULT_INJECTION
  "Enable the test-only installed-polkit crash boundary" OFF)

if(DESKTOP_UPDATER_ENABLE_POLKIT_E2E_FAULT_INJECTION AND
   NOT DESKTOP_UPDATER_NATIVE_BUILD_TESTS)
  message(FATAL_ERROR
    "Polkit E2E fault injection requires DESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON")
endif()

find_package(OpenSSL REQUIRED COMPONENTS Crypto)

if(DESKTOP_UPDATER_NATIVE_RUNTIME AND CMAKE_VERSION VERSION_LESS "3.12")
  message(FATAL_ERROR "The native runtime requires CMake 3.12 or later")
endif()

set(DESKTOP_UPDATER_RUNTIME_COMMON_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/../../native_runtime/cpp)
set(DESKTOP_UPDATER_MONOCYPHER_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/monocypher/src)
set(DESKTOP_UPDATER_MINIZ_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/miniz)
set_source_files_properties(${DESKTOP_UPDATER_MINIZ_DIR}/miniz.c PROPERTIES
  COMPILE_DEFINITIONS "MINIZ_NO_ZLIB_APIS;_LARGEFILE64_SOURCE=1")
add_library(desktop_updater_native STATIC
  src/desktop_updater_native.cc
  src/linux_helper_locator.cc
  src/helper/linux_control_wire.cc
  src/helper/unix_socket_transport.cc
  src/linux_native_install_request_builder.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/install_helper_contract.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/install_helper_policy.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_request.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_session.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_wire.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/json_value.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/stage_provenance.cc)
add_library(desktop_updater::native ALIAS desktop_updater_native)
target_compile_features(desktop_updater_native PUBLIC cxx_std_17)
target_include_directories(desktop_updater_native
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
  PRIVATE
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/src/helper)
set_target_properties(desktop_updater_native PROPERTIES
  EXPORT_NAME native
  POSITION_INDEPENDENT_CODE ON)
target_compile_definitions(desktop_updater_native PRIVATE _GNU_SOURCE)
target_link_libraries(desktop_updater_native PUBLIC OpenSSL::Crypto)

add_library(desktop_updater_linux_helper_support STATIC
  ${DESKTOP_UPDATER_MINIZ_DIR}/miniz.c
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_authorization.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_service_runtime.cc
  ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/release_contract.cc
  ${DESKTOP_UPDATER_MONOCYPHER_DIR}/monocypher.c
  ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional/monocypher-ed25519.c
  src/helper/external_managed_refresh.cc
  src/helper/install_strategy.cc
  src/helper/linux_archive_restage.cc
  src/helper/linux_helper_policy.cc
  src/helper/linux_helper_diagnostics.cc
  src/helper/linux_file_transaction.cc
  src/helper/linux_mount_guard.cc
  src/helper/linux_native_install_service.cc
  src/helper/linux_provider_journal.cc
  src/helper/linux_provider_runner.cc
  src/helper/linux_recovery_service.cc
  src/helper/linux_relaunch_service.cc
  src/helper/linux_reservation.cc
  src/helper/linux_transaction_journal.cc)
target_sources(desktop_updater_linux_helper_support PRIVATE
  src/helper/linux_transaction_registry.cc)
target_sources(desktop_updater_linux_helper_support PRIVATE
  src/helper/single_file_replace.cc
  src/helper/system_package_transaction.cc)
target_compile_features(desktop_updater_linux_helper_support PUBLIC cxx_std_17)
target_compile_definitions(desktop_updater_linux_helper_support
  PRIVATE _GNU_SOURCE)
if(DESKTOP_UPDATER_ENABLE_POLKIT_E2E_FAULT_INJECTION)
  target_compile_definitions(desktop_updater_linux_helper_support PRIVATE
    DESKTOP_UPDATER_ENABLE_POLKIT_E2E_FAULT_INJECTION=1)
endif()
target_include_directories(desktop_updater_linux_helper_support
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src/helper
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
  PRIVATE
    ${DESKTOP_UPDATER_MINIZ_DIR}
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional)
target_link_libraries(desktop_updater_linux_helper_support
  PUBLIC desktop_updater_native OpenSSL::Crypto)

add_executable(desktop-updater-helper src/helper/main.cc)
target_compile_features(desktop-updater-helper PRIVATE cxx_std_17)
target_compile_definitions(desktop-updater-helper PRIVATE _GNU_SOURCE)
target_include_directories(desktop-updater-helper
  PRIVATE ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
target_link_libraries(desktop-updater-helper
  PRIVATE desktop_updater_linux_helper_support)

set(DESKTOP_UPDATER_HELPER_POLICY_PACKAGE_ID
  "com.desktopupdater.default" CACHE STRING
  "Package ID for the installed sealed helper policy")
set(DESKTOP_UPDATER_HELPER_SHA256
  "0000000000000000000000000000000000000000000000000000000000000000"
  CACHE STRING "Installer-sealed desktop-updater-helper SHA-256")
set(DESKTOP_UPDATER_HELPER_CANONICAL_POLICY_JSON "" CACHE STRING
  "Escaped canonical helper policy JSON supplied by packaging")
set(DESKTOP_UPDATER_HELPER_CANONICAL_POLICY_SHA256
  "0000000000000000000000000000000000000000000000000000000000000000"
  CACHE STRING "SHA-256 of the canonical helper policy JSON")
if(DESKTOP_UPDATER_INSTALL_SYSTEM_BROKER AND
   (DESKTOP_UPDATER_HELPER_POLICY_PACKAGE_ID STREQUAL
      "com.desktopupdater.default" OR
    DESKTOP_UPDATER_HELPER_SHA256 STREQUAL
      "0000000000000000000000000000000000000000000000000000000000000000" OR
    DESKTOP_UPDATER_HELPER_CANONICAL_POLICY_JSON STREQUAL "" OR
    DESKTOP_UPDATER_HELPER_CANONICAL_POLICY_SHA256 STREQUAL
      "0000000000000000000000000000000000000000000000000000000000000000"))
  message(FATAL_ERROR
    "Consumer-specific sealed helper policy metadata is required for the system broker")
endif()
configure_file(
  polkit/com.desktopupdater.install.policy.in
  ${CMAKE_CURRENT_BINARY_DIR}/com.desktopupdater.install.policy
  @ONLY)
configure_file(
  policy/helper-policy.json.in
  ${CMAKE_CURRENT_BINARY_DIR}/${DESKTOP_UPDATER_HELPER_POLICY_PACKAGE_ID}.json
  @ONLY)

if(DESKTOP_UPDATER_NATIVE_RUNTIME)
  enable_language(C)
  find_package(CURL REQUIRED)
  find_package(Threads REQUIRED)
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
  if(DESKTOP_UPDATER_INSTALL_SYSTEM_BROKER)
    install(TARGETS desktop-updater-helper
      RUNTIME DESTINATION "/usr/libexec")
    install(FILES
      ${CMAKE_CURRENT_BINARY_DIR}/com.desktopupdater.install.policy
      DESTINATION "/usr/share/polkit-1/actions")
    install(FILES
      ${CMAKE_CURRENT_BINARY_DIR}/${DESKTOP_UPDATER_HELPER_POLICY_PACKAGE_ID}.json
      DESTINATION "/etc/desktop-updater/policies")
  else()
    install(TARGETS desktop-updater-helper
      RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR})
  endif()
  if(DESKTOP_UPDATER_NATIVE_RUNTIME)
    install(TARGETS desktop_updater_runtime
      EXPORT desktop_updater_nativeTargets
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
  set(DESKTOP_UPDATER_NATIVE_RUNTIME_BUILT
    ${DESKTOP_UPDATER_NATIVE_RUNTIME})
  file(RELATIVE_PATH DESKTOP_UPDATER_CMAKE_PREFIX_FROM_CONFIGDIR
    "/${CMAKE_INSTALL_LIBDIR}/cmake/desktop_updater_native"
    "/")
  configure_file(
    cmake/desktop_updater_nativeConfig.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfig.cmake
    @ONLY)
  write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/desktop_updater_nativeConfigVersion.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion)
  file(RELATIVE_PATH DESKTOP_UPDATER_PC_PREFIX_FROM_PCFILEDIR
    "/${CMAKE_INSTALL_LIBDIR}/pkgconfig"
    "/")
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
  target_compile_definitions(desktop_updater_linux_helper_support
    PRIVATE DESKTOP_UPDATER_NATIVE_TESTING)
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

  add_executable(desktop_updater_native_durable_state_fixture_emitter
    test/helper/native_durable_state_fixture_emitter.cc)
  target_compile_features(
    desktop_updater_native_durable_state_fixture_emitter PRIVATE cxx_std_17)
  target_compile_definitions(
    desktop_updater_native_durable_state_fixture_emitter PRIVATE _GNU_SOURCE)
  target_link_libraries(
    desktop_updater_native_durable_state_fixture_emitter
    PRIVATE desktop_updater_linux_helper_support)

  add_executable(desktop_updater_native_test
    test/desktop_updater_native_test.cc
    ${DESKTOP_UPDATER_MINIZ_DIR}/miniz.c
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/install_helper_contract_fixture_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_request_fixture_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_authorization.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_authorization_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_service_runtime.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_service_runtime_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_session_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/native_install_wire_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/windows_native_install_request_builder.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/windows_native_install_request_builder_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/install_helper_policy_fixture_tests.cc
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/release_contract.cc
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/monocypher.c
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional/monocypher-ed25519.c)
  target_compile_features(desktop_updater_native_test PRIVATE cxx_std_17)
  target_include_directories(desktop_updater_native_test
    PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MINIZ_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional)
  target_compile_definitions(desktop_updater_native_test PRIVATE
    DESKTOP_UPDATER_COMMIT_CALLER_FIXTURE="$<TARGET_FILE:linux_commit_caller_fixture>"
    DESKTOP_UPDATER_RESTART_CALLER_FIXTURE="$<TARGET_FILE:linux_restart_caller_fixture>"
    DESKTOP_UPDATER_JOURNAL_FIXTURE_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-install-helper/v1/journal-transitions.json\"
    DESKTOP_UPDATER_VALID_REQUEST_FIXTURE_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-install-helper/v1/valid-requests.json\"
    DESKTOP_UPDATER_SIGNATURE_FIXTURE_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-contract/canonical-signature-cases.json\"
    DESKTOP_UPDATER_POLICY_FIXTURE_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-install-helper/v1/policy-cases.json\")
  target_link_libraries(desktop_updater_native_test
    PRIVATE desktop_updater_native GTest::gtest_main)
  add_dependencies(desktop_updater_native_test desktop-updater-helper)

  add_executable(linux_commit_caller_fixture
    test/linux_commit_caller_fixture.cc)
  target_compile_features(linux_commit_caller_fixture PRIVATE cxx_std_17)
  target_include_directories(linux_commit_caller_fixture
    PRIVATE
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${CMAKE_CURRENT_SOURCE_DIR}/src/helper)
  target_link_libraries(linux_commit_caller_fixture
    PRIVATE desktop_updater_native)
  add_executable(linux_restart_caller_fixture
    test/linux_restart_caller_fixture.cc)
  target_compile_features(linux_restart_caller_fixture PRIVATE cxx_std_17)
  target_link_libraries(linux_restart_caller_fixture
    PRIVATE desktop_updater_native)
  add_dependencies(desktop_updater_native_test
    linux_commit_caller_fixture linux_restart_caller_fixture)

  add_executable(linux_polkit_e2e_fixture
    test/linux_polkit_e2e_fixture.cc)
  target_compile_features(linux_polkit_e2e_fixture PRIVATE cxx_std_17)
  target_compile_definitions(linux_polkit_e2e_fixture PRIVATE
    _GNU_SOURCE MINIZ_NO_ZLIB_APIS)
  target_include_directories(linux_polkit_e2e_fixture PRIVATE
    ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
    ${DESKTOP_UPDATER_MINIZ_DIR}
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}
    ${DESKTOP_UPDATER_MONOCYPHER_DIR}/optional
    ${CMAKE_CURRENT_SOURCE_DIR}/src/helper)
  target_link_libraries(linux_polkit_e2e_fixture PRIVATE
    desktop_updater_linux_helper_support)

  include(GoogleTest)
  gtest_discover_tests(desktop_updater_native_test)

  add_executable(linux_helper_locator_test
    test/linux_helper_locator_test.cc)
  target_compile_features(linux_helper_locator_test PRIVATE cxx_std_17)
  target_include_directories(linux_helper_locator_test PRIVATE src)
  target_link_libraries(linux_helper_locator_test
    PRIVATE desktop_updater_native GTest::gtest_main)
  gtest_discover_tests(linux_helper_locator_test
    TEST_PREFIX "linux_helper_locator.")

  add_executable(linux_helper_auth
    test/helper/linux_helper_auth_test.cc)
  add_executable(linux_nonconnecting_helper_fixture
    test/helper/linux_nonconnecting_helper_fixture.cc)
  target_compile_features(linux_helper_auth PRIVATE cxx_std_17)
  target_compile_definitions(linux_helper_auth PRIVATE
    _GNU_SOURCE
    DESKTOP_UPDATER_NONCONNECTING_HELPER_FIXTURE="$<TARGET_FILE:linux_nonconnecting_helper_fixture>")
  target_link_libraries(linux_helper_auth
    PRIVATE desktop_updater_linux_helper_support GTest::gtest_main)
  add_dependencies(linux_helper_auth linux_nonconnecting_helper_fixture)
  gtest_discover_tests(linux_helper_auth)

  add_executable(linux_helper_reservation
    test/helper/linux_helper_reservation_test.cc)
  target_compile_features(linux_helper_reservation PRIVATE cxx_std_17)
  target_compile_definitions(linux_helper_reservation PRIVATE _GNU_SOURCE)
  target_link_libraries(linux_helper_reservation
    PRIVATE desktop_updater_linux_helper_support GTest::gtest_main)
  gtest_discover_tests(linux_helper_reservation)

  add_executable(linux_transaction
    test/helper/linux_transaction_test.cc)
  target_compile_features(linux_transaction PRIVATE cxx_std_17)
  target_compile_definitions(linux_transaction PRIVATE _GNU_SOURCE)
  target_link_libraries(linux_transaction
    PRIVATE desktop_updater_linux_helper_support GTest::gtest_main)
  gtest_discover_tests(linux_transaction TEST_PREFIX "linux_transaction.")

  add_executable(linux_archive_restage
    test/helper/linux_archive_restage_test.cc)
  target_compile_features(linux_archive_restage PRIVATE cxx_std_17)
  target_compile_definitions(linux_archive_restage PRIVATE
    _GNU_SOURCE MINIZ_NO_ZLIB_APIS)
  target_include_directories(linux_archive_restage PRIVATE
    ${DESKTOP_UPDATER_MINIZ_DIR})
  target_link_libraries(linux_archive_restage
    PRIVATE desktop_updater_linux_helper_support GTest::gtest_main)
  gtest_discover_tests(linux_archive_restage
    TEST_PREFIX "linux_archive_restage.")

  add_executable(linux_transaction_registry
    test/helper/linux_transaction_registry_test.cc)
  target_compile_features(linux_transaction_registry PRIVATE cxx_std_17)
  target_compile_definitions(linux_transaction_registry PRIVATE _GNU_SOURCE)
  target_link_libraries(linux_transaction_registry
    PRIVATE desktop_updater_linux_helper_support GTest::gtest_main)
  gtest_discover_tests(linux_transaction_registry
    TEST_PREFIX "linux_transaction_registry.")

  add_executable(linux_crash_recovery
    test/helper/linux_crash_recovery_test.cc)
  target_compile_features(linux_crash_recovery PRIVATE cxx_std_17)
  target_compile_definitions(linux_crash_recovery PRIVATE
    _GNU_SOURCE
    DESKTOP_UPDATER_COMMIT_CALLER_FIXTURE="$<TARGET_FILE:linux_commit_caller_fixture>")
  target_link_libraries(linux_crash_recovery
    PRIVATE desktop_updater_linux_helper_support GTest::gtest_main)
  add_dependencies(linux_crash_recovery linux_commit_caller_fixture)
  gtest_discover_tests(linux_crash_recovery
    TEST_PREFIX "linux_crash_recovery.")

  add_executable(linux_install_strategy
    test/helper/linux_install_strategy_test.cc)
  target_compile_features(linux_install_strategy PRIVATE cxx_std_17)
  target_compile_definitions(linux_install_strategy PRIVATE _GNU_SOURCE)
  target_link_libraries(linux_install_strategy
    PRIVATE desktop_updater_linux_helper_support GTest::gtest_main
      GTest::gmock)
  gtest_discover_tests(linux_install_strategy
    TEST_PREFIX "linux_install_strategy.")

  if(DESKTOP_UPDATER_NATIVE_RUNTIME)
    add_executable(desktop_updater_runtime_lifecycle_test
      test/runtime/client_lifecycle_test.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/client_lifecycle.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/client_lifecycle_tests.cc
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}/json_value.cc)
    target_compile_features(desktop_updater_runtime_lifecycle_test
      PRIVATE cxx_std_17)
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
      PRIVATE cxx_std_17)
    target_include_directories(desktop_updater_runtime_contract_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR}
      ${DESKTOP_UPDATER_MINIZ_DIR}
      ${DESKTOP_UPDATER_MONOCYPHER_DIR})
    target_link_libraries(desktop_updater_runtime_contract_test
      PRIVATE desktop_updater_runtime OpenSSL::Crypto)
    add_test(NAME desktop_updater_runtime_contract
      COMMAND desktop_updater_runtime_contract_test
        ${CMAKE_CURRENT_SOURCE_DIR}/../../fixtures/compat/native-contract)

    add_executable(desktop_updater_runtime_artifact_test
      test/runtime/artifact_stager_test.cc)
    target_compile_features(desktop_updater_runtime_artifact_test
      PRIVATE cxx_std_17)
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
      PRIVATE cxx_std_17)
    target_include_directories(desktop_updater_runtime_transport_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
      ${DESKTOP_UPDATER_RUNTIME_COMMON_DIR})
    target_link_libraries(desktop_updater_runtime_transport_test
      PRIVATE desktop_updater_runtime CURL::libcurl OpenSSL::Crypto)
    add_test(NAME desktop_updater_runtime_transport
      COMMAND desktop_updater_runtime_transport_test)
  endif()
endif()
