#include "desktop_updater_native_c.h"

#include "desktop_updater_native.h"

#include <cstring>
#include <exception>
#include <new>
#include <string>
#include <vector>

namespace {

desktop_updater_result MakeResult(bool ok, const char* error_message) noexcept {
  if (ok) {
    return {1, nullptr};
  }

  if (error_message == nullptr) {
    return {0, nullptr};
  }

  const size_t message_length = std::strlen(error_message);
  char* message = new (std::nothrow) char[message_length + 1];
  if (message == nullptr) {
    return {0, nullptr};
  }
  std::memcpy(message, error_message, message_length + 1);
  return {0, message};
}

}  // namespace

desktop_updater_result desktop_updater_schedule_install_and_relaunch(
    const desktop_updater_install_request* request) {
  try {
    if (request == nullptr) {
      return MakeResult(false, "install request is required.");
    }

    if (request->removed_file_count > 0 && request->removed_files == nullptr) {
      return MakeResult(false,
                        "removed_files is required when count is non-zero.");
    }

    desktop_updater_native::InstallRequest native_request;
    if (request->staging_path != nullptr) {
      native_request.staging_path = request->staging_path;
    }
    if (request->diagnostics_log_path != nullptr) {
      native_request.diagnostics_log_path = request->diagnostics_log_path;
    }
    for (size_t index = 0; index < request->removed_file_count; index += 1) {
      const wchar_t* value = request->removed_files[index];
      if (value != nullptr) {
        native_request.removed_files.push_back(value);
      }
    }

    const desktop_updater_native::InstallResult result =
        desktop_updater_native::ScheduleInstallAndRelaunch(native_request);
    return MakeResult(result.ok, result.error.c_str());
  } catch (const std::exception& exception) {
    return MakeResult(false, exception.what());
  } catch (...) {
    return MakeResult(false, "Unexpected native exception.");
  }
}

void desktop_updater_result_free(desktop_updater_result result) {
  delete[] result.error_message;
}
