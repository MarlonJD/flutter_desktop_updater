#ifndef DESKTOP_UPDATER_NATIVE_C_LEGACY_H_
#define DESKTOP_UPDATER_NATIVE_C_LEGACY_H_

#include <stddef.h>
#include <stdint.h>

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

typedef enum desktop_updater_prepare_outcome_v2 {
  DESKTOP_UPDATER_PREPARE_OUTCOME_REJECTED = 0,
  DESKTOP_UPDATER_PREPARE_OUTCOME_PREPARED = 1,
  DESKTOP_UPDATER_PREPARE_OUTCOME_RECOVERY_REQUIRED = 2,
} desktop_updater_prepare_outcome_v2;

typedef struct desktop_updater_reservation_handle_v1
    desktop_updater_reservation_handle_v1;

#endif  // DESKTOP_UPDATER_NATIVE_C_LEGACY_H_
