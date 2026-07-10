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
} desktop_updater_install_request_v1;

typedef struct desktop_updater_result_v1 {
  uint32_t abi_version;
  int32_t ok;
  const char* error_message_utf8;
} desktop_updater_result_v1;

DESKTOP_UPDATER_NATIVE_EXPORT desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_schedule_install_and_relaunch_v1(
    const desktop_updater_install_request_v1* request);

DESKTOP_UPDATER_NATIVE_EXPORT void DESKTOP_UPDATER_CALL
desktop_updater_result_free_v1(desktop_updater_result_v1* result);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // DESKTOP_UPDATER_NATIVE_C_H_
