#ifndef DESKTOP_UPDATER_RUNTIME_C_H_
#define DESKTOP_UPDATER_RUNTIME_C_H_

#include <stddef.h>
#include <stdint.h>

#define DESKTOP_UPDATER_RUNTIME_ABI_VERSION 2u

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

typedef enum desktop_updater_runtime_outcome_abi2 {
  DESKTOP_UPDATER_RUNTIME_NO_UPDATE_ABI2 = 0,
  DESKTOP_UPDATER_RUNTIME_UPDATE_AVAILABLE_ABI2 = 1,
  DESKTOP_UPDATER_RUNTIME_FRESH_INSTALL_REQUIRED_ABI2 = 2,
  DESKTOP_UPDATER_RUNTIME_UNSUPPORTED_MINIMUM_UPDATER_ABI2 = 3,
  DESKTOP_UPDATER_RUNTIME_UNSUPPORTED_MINIMUM_OS_ABI2 = 4,
  DESKTOP_UPDATER_RUNTIME_ROLLOUT_INELIGIBLE_ABI2 = 5,
  DESKTOP_UPDATER_RUNTIME_UNSUPPORTED_ARTIFACT_KIND_ABI2 = 6,
  DESKTOP_UPDATER_RUNTIME_INVALID_DESCRIPTOR_ABI2 = 7,
  DESKTOP_UPDATER_RUNTIME_SIGNATURE_FAILURE_ABI2 = 8,
  DESKTOP_UPDATER_RUNTIME_PACKAGE_IDENTITY_MISMATCH_ABI2 = 9,
  DESKTOP_UPDATER_RUNTIME_DOWNLOAD_FAILURE_ABI2 = 10,
  DESKTOP_UPDATER_RUNTIME_ARTIFACT_INTEGRITY_FAILURE_ABI2 = 11,
  DESKTOP_UPDATER_RUNTIME_UNSAFE_ARCHIVE_ABI2 = 12,
  DESKTOP_UPDATER_RUNTIME_STAGING_FAILURE_ABI2 = 13,
  DESKTOP_UPDATER_RUNTIME_INSTALL_HANDOFF_FAILURE_ABI2 = 14,
} desktop_updater_runtime_outcome_abi2;

typedef struct desktop_updater_runtime_pinned_key_abi2 {
  const char* public_key_id_utf8;
  const uint8_t* public_key_bytes;
  size_t public_key_length;
} desktop_updater_runtime_pinned_key_abi2;

typedef struct desktop_updater_runtime_header_abi2 {
  const char* name_utf8;
  const char* value_utf8;
} desktop_updater_runtime_header_abi2;

typedef struct desktop_updater_runtime_header_list_abi2 {
  uint32_t abi_version;
  size_t struct_size;
  const desktop_updater_runtime_header_abi2* entries;
  size_t entry_count;
  void* release_context;
  void(DESKTOP_UPDATER_RUNTIME_CALL* release)(
      void* release_context,
      const desktop_updater_runtime_header_abi2* entries,
      size_t entry_count);
} desktop_updater_runtime_header_list_abi2;

typedef int32_t(DESKTOP_UPDATER_RUNTIME_CALL*
                    desktop_updater_runtime_minimum_os_resolver_abi2)(
    void* application_context,
    const char* platform_utf8,
    const char* minimum_os_utf8);

typedef desktop_updater_runtime_header_list_abi2(DESKTOP_UPDATER_RUNTIME_CALL*
                                                    desktop_updater_runtime_headers_provider_abi2)(
    void* application_context,
    const char* url_utf8);

typedef struct desktop_updater_runtime_configuration_abi2 {
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
  const desktop_updater_runtime_pinned_key_abi2* pinned_public_keys;
  size_t pinned_public_key_count;
  desktop_updater_runtime_minimum_os_resolver_abi2 minimum_os_resolver;
  desktop_updater_runtime_headers_provider_abi2 request_headers_provider;
  void* application_context;
  uint64_t download_timeout_milliseconds;
  int64_t maximum_metadata_bytes;
  int64_t maximum_archive_entries;
  int64_t maximum_uncompressed_bytes;
  int64_t maximum_single_entry_bytes;
} desktop_updater_runtime_configuration_abi2;

typedef struct desktop_updater_runtime_client_abi2
    desktop_updater_runtime_client_abi2;

typedef struct desktop_updater_runtime_result_abi2 {
  uint32_t abi_version;
  size_t struct_size;
  int32_t ok;
  desktop_updater_runtime_outcome_abi2 outcome;
  desktop_updater_runtime_client_abi2* client;
  const char* message_utf8;
  const char* release_version_utf8;
  const char* artifact_kind_utf8;
  const char* staged_path_utf8;
  const char* support_policy_status_utf8;
  int32_t mandatory;
  int32_t has_selected_build_number;
  int64_t selected_build_number;
  const char* selected_platform_utf8;
  const char* selected_channel_utf8;
  const char* fresh_install_url_utf8;
  const char* fresh_install_message_utf8;
} desktop_updater_runtime_result_abi2;

typedef struct desktop_updater_runtime_stage_request_abi2 {
  uint32_t abi_version;
  size_t struct_size;
  const char* download_directory_utf8;
  const char* staging_directory_utf8;
} desktop_updater_runtime_stage_request_abi2;

typedef struct desktop_updater_runtime_install_request_abi2 {
  uint32_t abi_version;
  size_t struct_size;
  const char* transaction_id_utf8;
  const char* const* removed_files_utf8;
  size_t removed_file_count;
  const char* install_root_utf8;
  const char* executable_relative_path_utf8;
  const char* expected_package_id_utf8;
} desktop_updater_runtime_install_request_abi2;

#ifdef __cplusplus
static_assert(offsetof(desktop_updater_runtime_configuration_abi2,
                       abi_version) == 0,
              "ABI2 runtime configuration must start with abi_version");
static_assert(offsetof(desktop_updater_runtime_configuration_abi2,
                       struct_size) > 0,
              "ABI2 runtime configuration must expose struct_size");
static_assert(offsetof(desktop_updater_runtime_result_abi2, abi_version) == 0,
              "ABI2 runtime result must start with abi_version");
static_assert(offsetof(desktop_updater_runtime_result_abi2, struct_size) > 0,
              "ABI2 runtime result must expose struct_size");
static_assert(offsetof(desktop_updater_runtime_stage_request_abi2,
                       abi_version) == 0,
              "ABI2 stage request must start with abi_version");
static_assert(offsetof(desktop_updater_runtime_install_request_abi2,
                       abi_version) == 0,
              "ABI2 install request must start with abi_version");
#endif

DESKTOP_UPDATER_RUNTIME_EXPORT uint32_t DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_abi_version_abi2(void);

DESKTOP_UPDATER_RUNTIME_EXPORT size_t DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_result_size_abi2(void);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_abi2
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_create_abi2(
        const desktop_updater_runtime_configuration_abi2* configuration);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_abi2
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_check_for_update_abi2(
        desktop_updater_runtime_client_abi2* client);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_abi2
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_download_verify_and_stage_abi2(
        desktop_updater_runtime_client_abi2* client,
        const desktop_updater_runtime_stage_request_abi2* request);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_abi2
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_prepare_install_abi2(
        desktop_updater_runtime_client_abi2* client,
        const desktop_updater_runtime_install_request_abi2* request);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_abi2
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_commit_after_exit_abi2(
        desktop_updater_runtime_client_abi2* client);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_abi2
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_cancel_reservation_abi2(
        desktop_updater_runtime_client_abi2* client);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_abi2
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_query_transaction_abi2(
        desktop_updater_runtime_client_abi2* client,
        const char* transaction_id_utf8);

DESKTOP_UPDATER_RUNTIME_EXPORT desktop_updater_runtime_result_abi2
    DESKTOP_UPDATER_RUNTIME_CALL
    desktop_updater_runtime_client_resolve_pending_install_after_exit_abi2(
        desktop_updater_runtime_client_abi2* client,
        const char* transaction_id_utf8);

DESKTOP_UPDATER_RUNTIME_EXPORT void DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_client_free_abi2(
    desktop_updater_runtime_client_abi2* client);

DESKTOP_UPDATER_RUNTIME_EXPORT void DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_result_free_abi2(
    desktop_updater_runtime_result_abi2* result);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // DESKTOP_UPDATER_RUNTIME_C_H_
