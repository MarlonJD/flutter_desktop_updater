#ifndef DESKTOP_UPDATER_RUNTIME_C_H_
#define DESKTOP_UPDATER_RUNTIME_C_H_

#include <stddef.h>
#include <stdint.h>

#define DESKTOP_UPDATER_RUNTIME_ABI_VERSION 1u

#if defined(_WIN32)
#define DESKTOP_UPDATER_RUNTIME_CALL __cdecl
#if defined(DESKTOP_UPDATER_RUNTIME_BUILDING_DLL)
#define DESKTOP_UPDATER_RUNTIME_EXPORT __declspec(dllexport)
#elif defined(DESKTOP_UPDATER_RUNTIME_USING_DLL)
#define DESKTOP_UPDATER_RUNTIME_EXPORT __declspec(dllimport)
#else
#define DESKTOP_UPDATER_RUNTIME_EXPORT
#endif
#else
#define DESKTOP_UPDATER_RUNTIME_CALL
#define DESKTOP_UPDATER_RUNTIME_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum desktop_updater_runtime_outcome_v1 {
  DESKTOP_UPDATER_RUNTIME_NO_UPDATE = 0,
  DESKTOP_UPDATER_RUNTIME_UPDATE_AVAILABLE = 1,
  DESKTOP_UPDATER_RUNTIME_FRESH_INSTALL_REQUIRED = 2,
  DESKTOP_UPDATER_RUNTIME_UNSUPPORTED_MINIMUM_UPDATER = 3,
  DESKTOP_UPDATER_RUNTIME_UNSUPPORTED_MINIMUM_OS = 4,
  DESKTOP_UPDATER_RUNTIME_ROLLOUT_INELIGIBLE = 5,
  DESKTOP_UPDATER_RUNTIME_UNSUPPORTED_ARTIFACT_KIND = 6,
  DESKTOP_UPDATER_RUNTIME_INVALID_DESCRIPTOR = 7,
  DESKTOP_UPDATER_RUNTIME_SIGNATURE_FAILURE = 8,
  DESKTOP_UPDATER_RUNTIME_PACKAGE_IDENTITY_MISMATCH = 9,
  DESKTOP_UPDATER_RUNTIME_DOWNLOAD_FAILURE = 10,
  DESKTOP_UPDATER_RUNTIME_ARTIFACT_INTEGRITY_FAILURE = 11,
  DESKTOP_UPDATER_RUNTIME_UNSAFE_ARCHIVE = 12,
  DESKTOP_UPDATER_RUNTIME_STAGING_FAILURE = 13,
  DESKTOP_UPDATER_RUNTIME_INSTALL_HANDOFF_FAILURE = 14,
} desktop_updater_runtime_outcome_v1;

typedef struct desktop_updater_runtime_pinned_key_v1 {
  const char* public_key_id_utf8;
  const uint8_t* public_key_bytes;
  size_t public_key_length;
} desktop_updater_runtime_pinned_key_v1;

typedef struct desktop_updater_runtime_header_v1 {
  const char* name_utf8;
  const char* value_utf8;
} desktop_updater_runtime_header_v1;

typedef struct desktop_updater_runtime_header_list_v1 {
  uint32_t abi_version;
  size_t struct_size;
  const desktop_updater_runtime_header_v1* entries;
  size_t entry_count;
  void* release_context;
  void(DESKTOP_UPDATER_RUNTIME_CALL* release)(
      void* release_context,
      const desktop_updater_runtime_header_v1* entries,
      size_t entry_count);
} desktop_updater_runtime_header_list_v1;

typedef int32_t(DESKTOP_UPDATER_RUNTIME_CALL*
                    desktop_updater_runtime_minimum_os_resolver_v1)(
    void* application_context,
    const char* platform_utf8,
    const char* minimum_os_utf8);

typedef desktop_updater_runtime_header_list_v1(DESKTOP_UPDATER_RUNTIME_CALL*
                                                   desktop_updater_runtime_headers_provider_v1)(
    void* application_context,
    const char* url_utf8);

typedef struct desktop_updater_runtime_configuration_v1 {
  uint32_t abi_version;
  size_t struct_size;
  const char* app_archive_url_utf8;
  const char* expected_package_id_utf8;
  const char* current_version_utf8;
  int64_t current_build_number;
  int32_t has_current_build_number;
  const char* current_updater_version_utf8;
  const char* platform_utf8;
  const char* channel_utf8;
  const char* installation_identity_utf8;
  int32_t require_descriptor_signature;
  const desktop_updater_runtime_pinned_key_v1* pinned_public_keys;
  size_t pinned_public_key_count;
  desktop_updater_runtime_minimum_os_resolver_v1 minimum_os_resolver;
  desktop_updater_runtime_headers_provider_v1 request_headers_provider;
  void* application_context;
  uint64_t download_timeout_milliseconds;
  int64_t maximum_metadata_bytes;
  int64_t maximum_archive_entries;
  int64_t maximum_uncompressed_bytes;
  int64_t maximum_single_entry_bytes;
} desktop_updater_runtime_configuration_v1;

typedef struct desktop_updater_runtime_client_v1
    desktop_updater_runtime_client_v1;

typedef struct desktop_updater_runtime_result_v1 {
  uint32_t abi_version;
  size_t struct_size;
  int32_t ok;
  desktop_updater_runtime_outcome_v1 outcome;
  desktop_updater_runtime_client_v1* client;
  const char* message_utf8;
  const char* release_version_utf8;
  const char* artifact_kind_utf8;
  const char* staged_path_utf8;
  const char* support_policy_status_utf8;
} desktop_updater_runtime_result_v1;

typedef struct desktop_updater_runtime_stage_request_v1 {
  uint32_t abi_version;
  size_t struct_size;
  const char* download_directory_utf8;
  const char* staging_directory_utf8;
} desktop_updater_runtime_stage_request_v1;

typedef struct desktop_updater_runtime_install_request_v1 {
  uint32_t abi_version;
  size_t struct_size;
  const char* diagnostics_log_path_utf8;
  const char* const* removed_files_utf8;
  size_t removed_file_count;
} desktop_updater_runtime_install_request_v1;

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_v1
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_create_v1(
        const desktop_updater_runtime_configuration_v1* configuration);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_v1
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_check_for_update_v1(
        desktop_updater_runtime_client_v1* client);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_v1
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_download_verify_and_stage_v1(
        desktop_updater_runtime_client_v1* client,
        const desktop_updater_runtime_stage_request_v1* request);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_v1
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_install_and_relaunch_v1(
        desktop_updater_runtime_client_v1* client,
        const desktop_updater_runtime_install_request_v1* request);

DESKTOP_UPDATER_RUNTIME_EXPORT void DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_client_free_v1(
    desktop_updater_runtime_client_v1* client);

DESKTOP_UPDATER_RUNTIME_EXPORT void DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_result_free_v1(
    desktop_updater_runtime_result_v1* result);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // DESKTOP_UPDATER_RUNTIME_C_H_
