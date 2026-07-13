#include "desktop_updater_runtime_c.h"

#include <array>
#include <cstdint>
#include <cstring>

namespace {

int32_t DESKTOP_UPDATER_RUNTIME_CALL MinimumOSResolver(
    void*,
    const char*,
    const char*) {
  return 1;
}

desktop_updater_runtime_header_list_v1 DESKTOP_UPDATER_RUNTIME_CALL
HeadersProvider(void*, const char*) {
  desktop_updater_runtime_header_list_v1 headers{};
  headers.abi_version = DESKTOP_UPDATER_RUNTIME_ABI_VERSION;
  headers.struct_size = sizeof(headers);
  return headers;
}

const char* OwnedString(const char* value) {
  const std::size_t length = std::strlen(value);
  char* copy = new char[length + 1];
  std::memcpy(copy, value, length + 1);
  return copy;
}

}  // namespace

int main() {
  if (desktop_updater_runtime_abi_version_v1() !=
          DESKTOP_UPDATER_RUNTIME_ABI_VERSION ||
      desktop_updater_runtime_result_size_v1() !=
          sizeof(desktop_updater_runtime_result_v1)) {
    return 1;
  }
  const auto check_for_update =
      &desktop_updater_runtime_client_check_for_update_v1;
  const auto download_verify_and_stage =
      &desktop_updater_runtime_client_download_verify_and_stage_v1;
  const auto install_and_relaunch =
      &desktop_updater_runtime_client_install_and_relaunch_v1;
  desktop_updater_runtime_stage_request_v1 stage_request{};
  stage_request.abi_version = DESKTOP_UPDATER_RUNTIME_ABI_VERSION;
  stage_request.struct_size = sizeof(stage_request);
  desktop_updater_runtime_install_request_v1 install_request{};
  install_request.abi_version = DESKTOP_UPDATER_RUNTIME_ABI_VERSION;
  install_request.struct_size = sizeof(install_request);
  if (check_for_update == nullptr || download_verify_and_stage == nullptr ||
      install_and_relaunch == nullptr || stage_request.struct_size == 0 ||
      install_request.struct_size == 0) {
    return 1;
  }
  const std::array<uint8_t, 32> public_key{};
  const desktop_updater_runtime_pinned_key_v1 pinned_key{
      "native-contract-stable", public_key.data(), public_key.size()};
  desktop_updater_runtime_configuration_v1 configuration{};
  configuration.abi_version = DESKTOP_UPDATER_RUNTIME_ABI_VERSION;
  configuration.struct_size = sizeof(configuration);
  configuration.app_archive_url_utf8 =
      "https://updates.example.test/app-archive.json";
  configuration.expected_package_id_utf8 = "com.example.native-contract";
  configuration.current_version_utf8 = "2.7.0";
  configuration.current_build_number = 270;
  configuration.has_current_build_number = 1;
  configuration.current_updater_version_utf8 = "2.7.0";
  configuration.platform_utf8 = "windows";
  configuration.channel_utf8 = "stable";
  configuration.require_descriptor_signature = 1;
  configuration.require_index_signature = 1;
  configuration.pinned_public_keys = &pinned_key;
  configuration.pinned_public_key_count = 1;
  configuration.minimum_os_resolver = MinimumOSResolver;
  configuration.request_headers_provider = HeadersProvider;
  configuration.download_timeout_milliseconds = 30000;
  configuration.maximum_metadata_bytes = 4LL * 1024LL * 1024LL;
  configuration.maximum_archive_entries = 100000;
  configuration.maximum_uncompressed_bytes =
      8LL * 1024LL * 1024LL * 1024LL;
  configuration.maximum_single_entry_bytes = 4LL * 1024LL * 1024LL * 1024LL;

  desktop_updater_runtime_result_v1 result =
      desktop_updater_runtime_client_create_v1(&configuration);
  if (result.ok == 0 || result.client == nullptr ||
      result.outcome != DESKTOP_UPDATER_RUNTIME_NO_UPDATE) {
    desktop_updater_runtime_result_free_v1(&result);
    return 1;
  }
  desktop_updater_runtime_client_v1* client = result.client;
  result.client = nullptr;
  desktop_updater_runtime_result_free_v1(&result);
  result = desktop_updater_runtime_client_install_and_relaunch_v1(
      client, &install_request);
  if (result.outcome != DESKTOP_UPDATER_RUNTIME_INSTALL_HANDOFF_FAILURE) {
    desktop_updater_runtime_result_free_v1(&result);
    desktop_updater_runtime_client_free_v1(client);
    return 1;
  }
  desktop_updater_runtime_result_free_v1(&result);
  desktop_updater_runtime_client_free_v1(client);
  result.message_utf8 = OwnedString("fresh install required");
  result.release_version_utf8 = OwnedString("2.7.0");
  result.artifact_kind_utf8 = OwnedString("innoInstaller");
  result.staged_path_utf8 = OwnedString("C:\\staged\\update.exe");
  result.support_policy_status_utf8 = OwnedString("warning");
  result.selected_platform_utf8 = OwnedString("windows");
  result.selected_channel_utf8 = OwnedString("stable");
  result.fresh_install_url_utf8 = OwnedString("https://example.test/setup.exe");
  result.fresh_install_message_utf8 = OwnedString("Download the installer.");
  result.mandatory = 1;
  result.has_selected_build_number = 1;
  result.selected_build_number = 270;
  if (result.selected_platform_utf8 == nullptr ||
      result.selected_channel_utf8 == nullptr ||
      result.fresh_install_url_utf8 == nullptr ||
      result.fresh_install_message_utf8 == nullptr) {
    return 1;
  }
  desktop_updater_runtime_result_free_v1(&result);
  if (result.message_utf8 != nullptr || result.release_version_utf8 != nullptr ||
      result.artifact_kind_utf8 != nullptr || result.staged_path_utf8 != nullptr ||
      result.support_policy_status_utf8 != nullptr ||
      result.selected_platform_utf8 != nullptr ||
      result.selected_channel_utf8 != nullptr ||
      result.fresh_install_url_utf8 != nullptr ||
      result.fresh_install_message_utf8 != nullptr || result.mandatory != 0 ||
      result.has_selected_build_number != 0 ||
      result.selected_build_number != 0) {
    return 1;
  }
  desktop_updater_runtime_result_free_v1(&result);
  if (result.selected_platform_utf8 != nullptr ||
      result.selected_channel_utf8 != nullptr ||
      result.fresh_install_url_utf8 != nullptr ||
      result.fresh_install_message_utf8 != nullptr) {
    return 1;
  }
  return 0;
}
