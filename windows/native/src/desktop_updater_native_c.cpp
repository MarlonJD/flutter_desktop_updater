#include "desktop_updater_native_c.h"

#include <cstring>
#include <exception>
#include <new>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "desktop_updater_native.h"
#include "desktop_updater_native_c_internal.h"

namespace desktop_updater {
namespace native {
namespace internal {
namespace {

desktop_updater_result_v1 SuccessResult() {
  return {DESKTOP_UPDATER_NATIVE_ABI_VERSION, 1, nullptr};
}

desktop_updater_result_v1 ErrorResult(const std::string& message) {
  char* owned_message = new (std::nothrow) char[message.size() + 1];
  if (owned_message == nullptr) {
    return {DESKTOP_UPDATER_NATIVE_ABI_VERSION, 0, nullptr};
  }
  std::memcpy(owned_message, message.c_str(), message.size() + 1);
  return {DESKTOP_UPDATER_NATIVE_ABI_VERSION, 0, owned_message};
}

bool IsHighSurrogate(uint16_t value) {
  return value >= 0xD800 && value <= 0xDBFF;
}

bool IsLowSurrogate(uint16_t value) {
  return value >= 0xDC00 && value <= 0xDFFF;
}

bool ReadUtf16(const uint16_t* value,
               bool allow_null,
               const char* field_name,
               std::wstring* output,
               std::string* error) {
  output->clear();
  if (value == nullptr) {
    if (allow_null) {
      return true;
    }
    *error = std::string(field_name) + " must not be null.";
    return false;
  }

  for (size_t index = 0; value[index] != 0; ++index) {
    const uint16_t code_unit = value[index];
    if (IsHighSurrogate(code_unit)) {
      if (!IsLowSurrogate(value[index + 1])) {
        *error = std::string(field_name) + " contains invalid UTF-16.";
        return false;
      }
      output->push_back(static_cast<wchar_t>(code_unit));
      output->push_back(static_cast<wchar_t>(value[++index]));
      continue;
    }
    if (IsLowSurrogate(code_unit)) {
      *error = std::string(field_name) + " contains invalid UTF-16.";
      return false;
    }
    output->push_back(static_cast<wchar_t>(code_unit));
  }
  return true;
}

bool ParseRequest(const desktop_updater_install_request_v1* request,
                  InstallRequest* parsed,
                  std::string* error) {
  if (request == nullptr) {
    *error = "request must not be null.";
    return false;
  }
  if (request->abi_version != DESKTOP_UPDATER_NATIVE_ABI_VERSION) {
    *error = "Unsupported desktop_updater native ABI version.";
    return false;
  }
  constexpr size_t kLegacyInstallRequestSize =
      offsetof(desktop_updater_install_request_v1,
               expected_provenance_sha256);
  if (request->struct_size < kLegacyInstallRequestSize) {
    *error = "desktop_updater install request struct is undersized.";
    return false;
  }
  if (!ReadUtf16(request->staging_path, true, "staging_path",
                 &parsed->staging_path, error) ||
      !ReadUtf16(request->diagnostics_log_path, true,
                 "diagnostics_log_path", &parsed->diagnostics_log_path,
                 error)) {
    return false;
  }
  const bool has_provenance_fields =
      request->struct_size >= sizeof(desktop_updater_install_request_v1);
  if (has_provenance_fields &&
      (!ReadUtf16(request->expected_provenance_sha256, true,
                 "expected_provenance_sha256",
                 &parsed->expected_provenance_sha256, error) ||
      !ReadUtf16(request->expected_artifact_sha256, true,
                 "expected_artifact_sha256",
                 &parsed->expected_artifact_sha256, error))) {
    return false;
  }
  if (has_provenance_fields &&
      request->allowed_signer_thumbprint_count > 0 &&
      request->allowed_signer_thumbprints == nullptr) {
    *error = "allowed_signer_thumbprints must not be null when its count is non-zero.";
    return false;
  }
  parsed->allowed_signer_thumbprints.clear();
  for (size_t index = 0;
       has_provenance_fields &&
       index < request->allowed_signer_thumbprint_count; ++index) {
    std::wstring thumbprint;
    if (!ReadUtf16(request->allowed_signer_thumbprints[index], false,
                   "allowed_signer_thumbprints item", &thumbprint, error)) {
      return false;
    }
    parsed->allowed_signer_thumbprints.push_back(std::move(thumbprint));
  }
  if (request->removed_file_count > 0 && request->removed_files == nullptr) {
    *error = "removed_files must not be null when removed_file_count is non-zero.";
    return false;
  }

  parsed->removed_files.clear();
  parsed->removed_files.reserve(request->removed_file_count);
  for (size_t index = 0; index < request->removed_file_count; ++index) {
    std::wstring removed_file;
    if (!ReadUtf16(request->removed_files[index], false, "removed_files item",
                   &removed_file, error)) {
      return false;
    }
    parsed->removed_files.push_back(std::move(removed_file));
  }
  parsed->request_elevation_if_needed = true;
  return true;
}

}  // namespace

desktop_updater_result_v1 ScheduleInstallAndRelaunchWith(
    const desktop_updater_install_request_v1* request,
    const InstallScheduler& scheduler) {
  try {
    InstallRequest parsed;
    std::string error;
    if (!ParseRequest(request, &parsed, &error)) {
      return ErrorResult(error);
    }
    const InstallResult result = scheduler(parsed);
    return result.ok ? SuccessResult() : ErrorResult(result.error_message);
  } catch (const std::exception& error) {
    return ErrorResult(error.what());
  } catch (...) {
    return ErrorResult("Unknown C++ exception in desktop_updater native helper.");
  }
}

}  // namespace internal
}  // namespace native
}  // namespace desktop_updater

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_schedule_install_and_relaunch_v1(
    const desktop_updater_install_request_v1* request) {
  return desktop_updater::native::internal::ScheduleInstallAndRelaunchWith(
      request, desktop_updater::native::ScheduleInstallAndRelaunch);
}

void DESKTOP_UPDATER_CALL desktop_updater_result_free_v1(
    desktop_updater_result_v1* result) {
  if (result == nullptr) {
    return;
  }
  delete[] result->error_message_utf8;
  result->error_message_utf8 = nullptr;
  result->abi_version = 0;
  result->ok = 0;
}
