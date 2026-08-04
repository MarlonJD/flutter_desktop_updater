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

typedef enum desktop_updater_install_elevation_policy_v1 {
  DESKTOP_UPDATER_INSTALL_ELEVATION_AUTO = 0,
  DESKTOP_UPDATER_INSTALL_ELEVATION_ALWAYS = 1,
  DESKTOP_UPDATER_INSTALL_ELEVATION_NEVER = 2,
} desktop_updater_install_elevation_policy_v1;

typedef struct desktop_updater_install_request_v1 {
  uint32_t abi_version;
  size_t struct_size;
  const uint16_t* staging_path;
  const uint16_t* diagnostics_log_path;
  const uint16_t* const* removed_files;
  size_t removed_file_count;
  const uint16_t* expected_provenance_sha256;
  const uint16_t* expected_artifact_sha256;
  const uint16_t* const* allowed_signer_thumbprints;
  size_t allowed_signer_thumbprint_count;
  const uint16_t* install_root;
  const uint16_t* executable_relative_path;
  const uint16_t* expected_package_id;
  uint32_t elevation_policy;
} desktop_updater_install_request_v1;

typedef struct desktop_updater_result_v1 {
  uint32_t abi_version;
  int32_t ok;
  const char* error_message_utf8;
} desktop_updater_result_v1;

typedef enum desktop_updater_transaction_state_v1 {
  DESKTOP_UPDATER_TRANSACTION_UNKNOWN = 0,
  DESKTOP_UPDATER_TRANSACTION_PREPARED = 1,
  DESKTOP_UPDATER_TRANSACTION_COMMIT_ACCEPTED = 2,
  DESKTOP_UPDATER_TRANSACTION_COMPLETED = 3,
  DESKTOP_UPDATER_TRANSACTION_CANCELLED = 4,
  DESKTOP_UPDATER_TRANSACTION_EXPIRED = 5,
  DESKTOP_UPDATER_TRANSACTION_ROLLED_BACK = 6,
  DESKTOP_UPDATER_TRANSACTION_MANUAL_ACTION_REQUIRED = 7,
} desktop_updater_transaction_state_v1;

typedef enum desktop_updater_transaction_result_code_v1 {
  DESKTOP_UPDATER_TRANSACTION_RESULT_NONE = 0,
  DESKTOP_UPDATER_TRANSACTION_RESULT_ACCEPTED = 1,
  DESKTOP_UPDATER_TRANSACTION_RESULT_SUCCEEDED = 2,
  DESKTOP_UPDATER_TRANSACTION_RESULT_REJECTED = 3,
  DESKTOP_UPDATER_TRANSACTION_RESULT_ENDPOINT_UNAVAILABLE = 4,
  DESKTOP_UPDATER_TRANSACTION_RESULT_AUTHENTICATION_FAILED = 5,
  DESKTOP_UPDATER_TRANSACTION_RESULT_INVALID_RESPONSE = 6,
  DESKTOP_UPDATER_TRANSACTION_RESULT_RECOVERY_REQUIRED = 7,
  DESKTOP_UPDATER_TRANSACTION_RESULT_RELAUNCH_FAILURE = 8,
} desktop_updater_transaction_result_code_v1;

typedef enum desktop_updater_prepare_outcome_v2 {
  DESKTOP_UPDATER_PREPARE_OUTCOME_REJECTED = 0,
  DESKTOP_UPDATER_PREPARE_OUTCOME_PREPARED = 1,
  DESKTOP_UPDATER_PREPARE_OUTCOME_RECOVERY_REQUIRED = 2,
} desktop_updater_prepare_outcome_v2;

typedef struct desktop_updater_reservation_handle_v1
    desktop_updater_reservation_handle_v1;

typedef struct desktop_updater_transaction_status_v1 {
  uint32_t abi_version;
  size_t struct_size;
  uint32_t state;
  uint32_t result_code;
  const char* transaction_id_utf8;
  const char* detail_utf8;
  const char* response_digest_sha256_utf8;
  const char* helper_endpoint_identity_sha256_utf8;
} desktop_updater_transaction_status_v1;

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_prepare_install_v1(
    const desktop_updater_install_request_v1* request,
    desktop_updater_reservation_handle_v1** reservation,
    desktop_updater_transaction_status_v1* status);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_prepare_install_v2(
    const desktop_updater_install_request_v1* request,
    const uint16_t* transaction_id,
    desktop_updater_reservation_handle_v1** reservation,
    desktop_updater_transaction_status_v1* status,
    uint32_t* prepare_outcome);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_commit_after_exit_v1(
    desktop_updater_reservation_handle_v1* reservation,
    desktop_updater_transaction_status_v1* status);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_cancel_reservation_v1(
    desktop_updater_reservation_handle_v1* reservation,
    desktop_updater_transaction_status_v1* status);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_query_transaction_v1(
    const uint16_t* transaction_id,
    desktop_updater_transaction_status_v1* status);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_recover_pending_install_v1(
    const uint16_t* transaction_id,
    desktop_updater_transaction_status_v1* status);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_resolve_pending_install_after_exit_v1(
    const uint16_t* transaction_id,
    desktop_updater_transaction_status_v1* status);

DESKTOP_UPDATER_NATIVE_EXPORT void DESKTOP_UPDATER_CALL
desktop_updater_transaction_status_free_v1(
    desktop_updater_transaction_status_v1* status);

DESKTOP_UPDATER_NATIVE_EXPORT void DESKTOP_UPDATER_CALL
desktop_updater_reservation_release_v1(
    desktop_updater_reservation_handle_v1* reservation);

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_schedule_install_and_relaunch_v1(
    const desktop_updater_install_request_v1* request);

DESKTOP_UPDATER_NATIVE_EXPORT void DESKTOP_UPDATER_CALL
desktop_updater_result_free_v1(desktop_updater_result_v1* result);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // DESKTOP_UPDATER_NATIVE_C_H_
