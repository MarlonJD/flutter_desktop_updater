#include "desktop_updater_runtime.h"

#include <cstddef>

namespace desktop_updater {
namespace runtime {
namespace {

RuntimeConfigurationValidation Failure(const std::string& message) {
  return RuntimeConfigurationValidation{false, message};
}

bool HasScheme(const std::string& url) {
  const std::size_t separator = url.find(':');
  return separator != std::string::npos && separator > 0;
}

}  // namespace

RuntimeConfigurationValidation ValidateRuntimeConfiguration(
    const RuntimeConfiguration& configuration) {
  if (!HasScheme(configuration.app_archive_url)) {
    return Failure("app_archive_url must be absolute.");
  }
  if (configuration.expected_package_id.empty() ||
      configuration.current_version.empty() ||
      configuration.current_updater_version.empty() ||
      configuration.platform.empty() || configuration.channel.empty()) {
    return Failure("Runtime identity fields must not be empty.");
  }
  if (configuration.has_current_build_number &&
      configuration.current_build_number < 0) {
    return Failure("current_build_number must not be negative.");
  }
  if (configuration.pinned_public_keys_by_id.empty()) {
    return Failure("At least one pinned public key is required.");
  }
  for (const auto& entry : configuration.pinned_public_keys_by_id) {
    if (entry.first.empty() || entry.second.size() != 32) {
      return Failure(
          "Pinned Ed25519 keys require a non-empty ID and 32 bytes.");
    }
  }
  if (!configuration.minimum_os_resolver ||
      !configuration.request_headers_provider) {
    return Failure("Runtime callbacks are required.");
  }
  if (configuration.download_timeout_milliseconds <= 0 ||
      configuration.maximum_metadata_bytes <= 0 ||
      configuration.maximum_archive_entries <= 0 ||
      configuration.maximum_uncompressed_bytes <= 0 ||
      configuration.maximum_single_entry_bytes <= 0) {
    return Failure(
        "Runtime timeouts and safety limits must be greater than zero.");
  }
  return RuntimeConfigurationValidation{true, std::string()};
}

}  // namespace runtime
}  // namespace desktop_updater
