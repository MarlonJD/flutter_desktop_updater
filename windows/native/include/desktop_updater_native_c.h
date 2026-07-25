#pragma once

#include <stddef.h>

#if defined(DESKTOP_UPDATER_NATIVE_STATIC)
#define DESKTOP_UPDATER_EXPORT
#elif defined(_WIN32)
#if defined(DESKTOP_UPDATER_NATIVE_BUILDING_DLL)
#define DESKTOP_UPDATER_EXPORT __declspec(dllexport)
#else
#define DESKTOP_UPDATER_EXPORT __declspec(dllimport)
#endif
#else
#define DESKTOP_UPDATER_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct desktop_updater_install_request {
  const wchar_t* staging_path;
  const wchar_t* diagnostics_log_path;
  const wchar_t* const* removed_files;
  size_t removed_file_count;
} desktop_updater_install_request;

typedef struct desktop_updater_result {
  int ok;
  const char* error_message;
} desktop_updater_result;

DESKTOP_UPDATER_EXPORT desktop_updater_result
desktop_updater_schedule_install_and_relaunch(
    const desktop_updater_install_request* request);

DESKTOP_UPDATER_EXPORT void desktop_updater_result_free(
    desktop_updater_result result);

#ifdef __cplusplus
}
#endif
