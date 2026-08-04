#ifndef DESKTOP_UPDATER_NATIVE_C_H_
#define DESKTOP_UPDATER_NATIVE_C_H_

#include <stddef.h>
#include <stdint.h>

#include "desktop_updater_version.h"

#if defined(_WIN32)
#define DESKTOP_UPDATER_CALL __cdecl
#if defined(DESKTOP_UPDATER_NATIVE_BUILDING_DLL)
#define DESKTOP_UPDATER_NATIVE_EXPORT __declspec(dllexport)
#elif defined(DESKTOP_UPDATER_NATIVE_USING_DLL)
#define DESKTOP_UPDATER_NATIVE_EXPORT __declspec(dllimport)
#else
#define DESKTOP_UPDATER_NATIVE_EXPORT
#endif
#else
#define DESKTOP_UPDATER_CALL
#define DESKTOP_UPDATER_NATIVE_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum desktop_updater_transaction_state_abi2 {
  DESKTOP_UPDATER_TRANSACTION_UNKNOWN_ABI2 = 0,
  DESKTOP_UPDATER_TRANSACTION_PREPARED_ABI2 = 1,
  DESKTOP_UPDATER_TRANSACTION_COMMIT_ACCEPTED_ABI2 = 2,
  DESKTOP_UPDATER_TRANSACTION_COMPLETED_ABI2 = 3,
  DESKTOP_UPDATER_TRANSACTION_CANCELLED_ABI2 = 4,
  DESKTOP_UPDATER_TRANSACTION_EXPIRED_ABI2 = 5,
  DESKTOP_UPDATER_TRANSACTION_ROLLED_BACK_ABI2 = 6,
  DESKTOP_UPDATER_TRANSACTION_MANUAL_ACTION_REQUIRED_ABI2 = 7,
} desktop_updater_transaction_state_abi2;

typedef enum desktop_updater_transaction_result_code_abi2 {
  DESKTOP_UPDATER_TRANSACTION_RESULT_NONE_ABI2 = 0,
  DESKTOP_UPDATER_TRANSACTION_RESULT_ACCEPTED_ABI2 = 1,
  DESKTOP_UPDATER_TRANSACTION_RESULT_SUCCEEDED_ABI2 = 2,
  DESKTOP_UPDATER_TRANSACTION_RESULT_REJECTED_ABI2 = 3,
  DESKTOP_UPDATER_TRANSACTION_RESULT_ENDPOINT_UNAVAILABLE_ABI2 = 4,
  DESKTOP_UPDATER_TRANSACTION_RESULT_AUTHENTICATION_FAILED_ABI2 = 5,
  DESKTOP_UPDATER_TRANSACTION_RESULT_INVALID_RESPONSE_ABI2 = 6,
  DESKTOP_UPDATER_TRANSACTION_RESULT_RECOVERY_REQUIRED_ABI2 = 7,
  DESKTOP_UPDATER_TRANSACTION_RESULT_RELAUNCH_FAILURE_ABI2 = 8,
} desktop_updater_transaction_result_code_abi2;

typedef struct desktop_updater_install_request_abi2 {
  uint32_t abi_version;
  size_t struct_size;
  const uint16_t* staging_path;
  const uint16_t* const* removed_files;
  size_t removed_file_count;
  const uint16_t* expected_provenance_sha256;
  const uint16_t* expected_artifact_sha256;
  const uint16_t* install_root;
  const uint16_t* executable_relative_path;
  const uint16_t* expected_package_id;
} desktop_updater_install_request_abi2;

typedef struct desktop_updater_result_abi2 {
  uint32_t abi_version;
  size_t struct_size;
  int32_t ok;
  const char* error_message_utf8;
} desktop_updater_result_abi2;

typedef struct desktop_updater_reservation_handle_abi2
    desktop_updater_reservation_handle_abi2;

typedef struct desktop_updater_transaction_status_abi2 {
  uint32_t abi_version;
  size_t struct_size;
  uint32_t state;
  uint32_t result_code;
  const char* transaction_id_utf8;
  const char* detail_utf8;
  const char* response_digest_sha256_utf8;
  const char* helper_endpoint_identity_sha256_utf8;
} desktop_updater_transaction_status_abi2;

#ifdef __cplusplus
static_assert(offsetof(desktop_updater_install_request_abi2, abi_version) == 0,
              "ABI2 request must start with abi_version");
static_assert(offsetof(desktop_updater_install_request_abi2, struct_size) > 0,
              "ABI2 request must expose struct_size after abi_version");
static_assert(offsetof(desktop_updater_result_abi2, abi_version) == 0,
              "ABI2 result must start with abi_version");
static_assert(offsetof(desktop_updater_result_abi2, struct_size) > 0,
              "ABI2 result must expose struct_size after abi_version");
static_assert(offsetof(desktop_updater_transaction_status_abi2,
                       abi_version) == 0,
              "ABI2 status must start with abi_version");
static_assert(offsetof(desktop_updater_transaction_status_abi2,
                       struct_size) > 0,
              "ABI2 status must expose struct_size after abi_version");
#endif

DESKTOP_UPDATER_NATIVE_EXPORT uint32_t DESKTOP_UPDATER_CALL
desktop_updater_native_abi_version_abi2(void);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_abi2
    DESKTOP_UPDATER_CALL
    desktop_updater_prepare_install_abi2(
        const desktop_updater_install_request_abi2* request,
        const uint16_t* transaction_id,
        desktop_updater_reservation_handle_abi2** reservation,
        desktop_updater_transaction_status_abi2* status);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_abi2
    DESKTOP_UPDATER_CALL
    desktop_updater_commit_after_exit_abi2(
        desktop_updater_reservation_handle_abi2* reservation,
        desktop_updater_transaction_status_abi2* status);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_abi2
    DESKTOP_UPDATER_CALL
    desktop_updater_cancel_reservation_abi2(
        desktop_updater_reservation_handle_abi2* reservation,
        desktop_updater_transaction_status_abi2* status);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_abi2
    DESKTOP_UPDATER_CALL
    desktop_updater_query_transaction_abi2(
        const uint16_t* transaction_id,
        desktop_updater_transaction_status_abi2* status);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_abi2
    DESKTOP_UPDATER_CALL
    desktop_updater_resolve_pending_install_after_exit_abi2(
        const uint16_t* transaction_id,
        desktop_updater_transaction_status_abi2* status);

DESKTOP_UPDATER_NATIVE_EXPORT void DESKTOP_UPDATER_CALL
desktop_updater_transaction_status_free_abi2(
    desktop_updater_transaction_status_abi2* status);

DESKTOP_UPDATER_NATIVE_EXPORT void DESKTOP_UPDATER_CALL
desktop_updater_reservation_release_abi2(
    desktop_updater_reservation_handle_abi2* reservation);

DESKTOP_UPDATER_NATIVE_EXPORT void DESKTOP_UPDATER_CALL
desktop_updater_result_free_abi2(desktop_updater_result_abi2* result);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // DESKTOP_UPDATER_NATIVE_C_H_
