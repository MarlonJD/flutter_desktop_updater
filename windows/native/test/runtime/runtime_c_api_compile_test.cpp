#include "desktop_updater_runtime_c.h"

#include <array>
#include <cstdint>

namespace {

int32_t DESKTOP_UPDATER_RUNTIME_CALL MinimumOSResolver(
    void*,
    const char*,
    const char*) {
  return 1;
}

desktop_updater_runtime_header_list_abi2 DESKTOP_UPDATER_RUNTIME_CALL
HeadersProvider(void*, const char*) {
  desktop_updater_runtime_header_list_abi2 headers{};
  headers.abi_version = DESKTOP_UPDATER_RUNTIME_ABI_VERSION;
  headers.struct_size = sizeof(headers);
  return headers;
}

}  // namespace

int main() {
  if (desktop_updater_runtime_abi_version_abi2() !=
          DESKTOP_UPDATER_RUNTIME_ABI_VERSION ||
      desktop_updater_runtime_result_size_abi2() !=
          sizeof(desktop_updater_runtime_result_abi2)) {
    return 1;
  }

  const auto check_for_update =
      &desktop_updater_runtime_client_check_for_update_abi2;
  const auto download_verify_and_stage =
      &desktop_updater_runtime_client_download_verify_and_stage_abi2;
  const auto prepare_install =
      &desktop_updater_runtime_client_prepare_install_abi2;
  const auto commit_after_exit =
      &desktop_updater_runtime_client_commit_after_exit_abi2;
  const auto cancel_reservation =
      &desktop_updater_runtime_client_cancel_reservation_abi2;
  const auto query_transaction =
      &desktop_updater_runtime_client_query_transaction_abi2;
  const auto resolve_after_exit =
      &desktop_updater_runtime_client_resolve_pending_install_after_exit_abi2;
  if (check_for_update == nullptr || download_verify_and_stage == nullptr ||
      prepare_install == nullptr || commit_after_exit == nullptr ||
      cancel_reservation == nullptr || query_transaction == nullptr ||
      resolve_after_exit == nullptr) {
    return 1;
  }

  const std::array<std::uint8_t, 32> public_key{};
  const desktop_updater_runtime_pinned_key_abi2 pinned_key{
      "native-contract-stable", public_key.data(), public_key.size()};
  desktop_updater_runtime_configuration_abi2 configuration{};
  configuration.abi_version = DESKTOP_UPDATER_RUNTIME_ABI_VERSION;
  configuration.struct_size = sizeof(configuration);
  configuration.app_archive_url_utf8 =
      "https://updates.example.test/app-archive.json";
  configuration.expected_package_id_utf8 = "com.example.native-contract";
  configuration.current_version_utf8 = "3.0.0";
  configuration.current_build_number = 300;
  configuration.has_current_build_number = 1;
  configuration.current_updater_version_utf8 = "3.0.0";
  configuration.platform_utf8 = "windows";
  configuration.channel_utf8 = "stable";
  configuration.pinned_public_keys = &pinned_key;
  configuration.pinned_public_key_count = 1;
  configuration.minimum_os_resolver = MinimumOSResolver;
  configuration.request_headers_provider = HeadersProvider;
  configuration.download_timeout_milliseconds = 30000;
  configuration.maximum_metadata_bytes = 4LL * 1024LL * 1024LL;
  configuration.maximum_archive_entries = 100000;
  configuration.maximum_uncompressed_bytes = 8LL * 1024LL * 1024LL * 1024LL;
  configuration.maximum_single_entry_bytes = 4LL * 1024LL * 1024LL * 1024LL;

  desktop_updater_runtime_result_abi2 result =
      desktop_updater_runtime_client_create_abi2(&configuration);
  if (result.ok == 0 || result.client == nullptr) {
    desktop_updater_runtime_result_free_abi2(&result);
    return 1;
  }
  desktop_updater_runtime_client_abi2* client = result.client;
  result.client = nullptr;
  desktop_updater_runtime_result_free_abi2(&result);

  desktop_updater_runtime_install_request_abi2 install_request{};
  install_request.abi_version = DESKTOP_UPDATER_RUNTIME_ABI_VERSION;
  install_request.struct_size = sizeof(install_request);
  install_request.transaction_id_utf8 =
      "00000000-0000-4000-8000-000000000012";
  install_request.install_root_utf8 = "C:\\Program Files\\Example";
  install_request.executable_relative_path_utf8 = "Example.exe";
  install_request.expected_package_id_utf8 = "com.example.native-contract";
  result = desktop_updater_runtime_client_prepare_install_abi2(
      client, &install_request);
  if (result.outcome != DESKTOP_UPDATER_RUNTIME_INSTALL_HANDOFF_FAILURE_ABI2) {
    desktop_updater_runtime_result_free_abi2(&result);
    desktop_updater_runtime_client_free_abi2(client);
    return 1;
  }
  desktop_updater_runtime_result_free_abi2(&result);
  desktop_updater_runtime_client_free_abi2(client);
  return 0;
}
