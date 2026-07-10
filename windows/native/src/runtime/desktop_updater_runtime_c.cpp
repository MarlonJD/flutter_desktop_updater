#include "desktop_updater_runtime_c.h"

#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

struct desktop_updater_runtime_client_v1 {
  std::string app_archive_url;
  std::string expected_package_id;
  std::string current_version;
  int64_t current_build_number;
  bool has_current_build_number;
  std::string current_updater_version;
  std::string platform;
  std::string channel;
  std::string installation_identity;
  bool require_descriptor_signature;
  std::vector<std::pair<std::string, std::vector<uint8_t>>> pinned_public_keys;
  desktop_updater_runtime_minimum_os_resolver_v1 minimum_os_resolver;
  desktop_updater_runtime_headers_provider_v1 request_headers_provider;
  void* application_context;
  uint64_t download_timeout_milliseconds;
  int64_t maximum_metadata_bytes;
  int64_t maximum_archive_entries;
  int64_t maximum_uncompressed_bytes;
  int64_t maximum_single_entry_bytes;
};

namespace {

const char* CopyMessage(const std::string& message) {
  std::unique_ptr<char[]> bytes(new char[message.size() + 1]);
  std::memcpy(bytes.get(), message.data(), message.size());
  bytes[message.size()] = '\0';
  return bytes.release();
}

std::string RequiredString(const char* value, const char* name) {
  if (value == nullptr || value[0] == '\0') {
    throw std::invalid_argument(std::string(name) + " must not be empty.");
  }
  return value;
}

desktop_updater_runtime_result_v1 EmptyResult() {
  desktop_updater_runtime_result_v1 result{};
  result.abi_version = DESKTOP_UPDATER_RUNTIME_ABI_VERSION;
  result.struct_size = sizeof(result);
  result.outcome = DESKTOP_UPDATER_RUNTIME_INVALID_DESCRIPTOR;
  return result;
}

desktop_updater_runtime_result_v1 Failure(const std::string& message) {
  desktop_updater_runtime_result_v1 result = EmptyResult();
  result.message_utf8 = CopyMessage(message);
  return result;
}

void ValidateLimits(
    const desktop_updater_runtime_configuration_v1& configuration) {
  if (configuration.download_timeout_milliseconds == 0 ||
      configuration.maximum_metadata_bytes <= 0 ||
      configuration.maximum_archive_entries <= 0 ||
      configuration.maximum_uncompressed_bytes <= 0 ||
      configuration.maximum_single_entry_bytes <= 0) {
    throw std::invalid_argument(
        "Runtime timeouts and safety limits must be greater than zero.");
  }
}

}  // namespace

extern "C" desktop_updater_runtime_result_v1 DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_client_create_v1(
    const desktop_updater_runtime_configuration_v1* configuration) {
  try {
    if (configuration == nullptr) {
      return Failure("Runtime configuration is required.");
    }
    if (configuration->abi_version != DESKTOP_UPDATER_RUNTIME_ABI_VERSION) {
      return Failure("Unsupported runtime ABI version.");
    }
    if (configuration->struct_size < sizeof(*configuration)) {
      return Failure("Runtime configuration struct is undersized.");
    }
    if (configuration->minimum_os_resolver == nullptr ||
        configuration->request_headers_provider == nullptr) {
      return Failure("Runtime callbacks are required.");
    }
    if (configuration->has_current_build_number != 0 &&
        configuration->current_build_number < 0) {
      return Failure("current_build_number must not be negative.");
    }
    if (configuration->require_descriptor_signature != 0 &&
        configuration->pinned_public_key_count == 0) {
      return Failure("At least one pinned public key is required.");
    }
    if (configuration->pinned_public_key_count > 0 &&
        configuration->pinned_public_keys == nullptr) {
      return Failure("Pinned public key entries are required.");
    }
    ValidateLimits(*configuration);

    std::unique_ptr<desktop_updater_runtime_client_v1> client(
        new desktop_updater_runtime_client_v1());
    client->app_archive_url =
        RequiredString(configuration->app_archive_url_utf8, "app_archive_url");
    client->expected_package_id = RequiredString(
        configuration->expected_package_id_utf8, "expected_package_id");
    client->current_version =
        RequiredString(configuration->current_version_utf8, "current_version");
    client->current_build_number = configuration->current_build_number;
    client->has_current_build_number =
        configuration->has_current_build_number != 0;
    client->current_updater_version = RequiredString(
        configuration->current_updater_version_utf8,
        "current_updater_version");
    client->platform =
        RequiredString(configuration->platform_utf8, "platform");
    client->channel = RequiredString(configuration->channel_utf8, "channel");
    if (configuration->installation_identity_utf8 != nullptr) {
      client->installation_identity = configuration->installation_identity_utf8;
    }
    client->require_descriptor_signature =
        configuration->require_descriptor_signature != 0;
    for (size_t index = 0; index < configuration->pinned_public_key_count;
         ++index) {
      const desktop_updater_runtime_pinned_key_v1& key =
          configuration->pinned_public_keys[index];
      if (key.public_key_id_utf8 == nullptr ||
          key.public_key_id_utf8[0] == '\0' || key.public_key_bytes == nullptr ||
          key.public_key_length != 32) {
        return Failure("Pinned Ed25519 keys require an ID and 32 bytes.");
      }
      client->pinned_public_keys.emplace_back(
          key.public_key_id_utf8,
          std::vector<uint8_t>(key.public_key_bytes,
                               key.public_key_bytes + key.public_key_length));
    }
    client->minimum_os_resolver = configuration->minimum_os_resolver;
    client->request_headers_provider = configuration->request_headers_provider;
    client->application_context = configuration->application_context;
    client->download_timeout_milliseconds =
        configuration->download_timeout_milliseconds;
    client->maximum_metadata_bytes = configuration->maximum_metadata_bytes;
    client->maximum_archive_entries = configuration->maximum_archive_entries;
    client->maximum_uncompressed_bytes =
        configuration->maximum_uncompressed_bytes;
    client->maximum_single_entry_bytes =
        configuration->maximum_single_entry_bytes;

    desktop_updater_runtime_result_v1 result = EmptyResult();
    result.ok = 1;
    result.outcome = DESKTOP_UPDATER_RUNTIME_NO_UPDATE;
    result.client = client.release();
    return result;
  } catch (const std::exception& error) {
    try {
      return Failure(error.what());
    } catch (...) {
      return EmptyResult();
    }
  } catch (...) {
    try {
      return Failure("Unknown native runtime failure.");
    } catch (...) {
      return EmptyResult();
    }
  }
}

extern "C" void DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_client_free_v1(
    desktop_updater_runtime_client_v1* client) {
  delete client;
}

extern "C" void DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_result_free_v1(
    desktop_updater_runtime_result_v1* result) {
  if (result == nullptr) {
    return;
  }
  delete[] result->message_utf8;
  result->message_utf8 = nullptr;
  result->client = nullptr;
  result->ok = 0;
}
