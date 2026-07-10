#include "desktop_updater_runtime_c.h"

#include <windows.h>

#include <cstring>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "artifact_stager_windows.h"
#include "client_lifecycle.h"
#include "diagnostics.h"
#include "sha256_bcrypt.h"
#include "update_client_core.h"
#include "update_transport_winhttp.h"

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
  bool require_index_signature;
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
  std::unique_ptr<desktop_updater::runtime::internal::WinHttpUpdateTransport>
      transport;
  desktop_updater::runtime::internal::DiagnosticsRecorder diagnostics;
  std::mutex diagnostics_mutex;
  desktop_updater::runtime::internal::ClientLifecycleState lifecycle;
};

namespace {

const char* CopyMessage(const std::string& message) {
  std::unique_ptr<char[]> bytes(new char[message.size() + 1]);
  std::memcpy(bytes.get(), message.data(), message.size());
  bytes[message.size()] = '\0';
  return bytes.release();
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return std::wstring();
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       value.c_str(), -1, nullptr, 0);
  if (size <= 0) throw std::invalid_argument("Invalid UTF-8 runtime path.");
  std::wstring result(static_cast<std::size_t>(size), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1,
                          &result[0], size) <= 0) {
    throw std::invalid_argument("Invalid UTF-8 runtime path.");
  }
  result.pop_back();
  return result;
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

desktop_updater_runtime_outcome_v1 Outcome(const std::string& value) {
  if (value == "noUpdate") return DESKTOP_UPDATER_RUNTIME_NO_UPDATE;
  if (value == "updateAvailable") {
    return DESKTOP_UPDATER_RUNTIME_UPDATE_AVAILABLE;
  }
  if (value == "freshInstallRequired") {
    return DESKTOP_UPDATER_RUNTIME_FRESH_INSTALL_REQUIRED;
  }
  if (value == "unsupportedMinimumUpdater") {
    return DESKTOP_UPDATER_RUNTIME_UNSUPPORTED_MINIMUM_UPDATER;
  }
  if (value == "unsupportedMinimumOS") {
    return DESKTOP_UPDATER_RUNTIME_UNSUPPORTED_MINIMUM_OS;
  }
  if (value == "rolloutIneligible") {
    return DESKTOP_UPDATER_RUNTIME_ROLLOUT_INELIGIBLE;
  }
  if (value == "unsupportedArtifactKind") {
    return DESKTOP_UPDATER_RUNTIME_UNSUPPORTED_ARTIFACT_KIND;
  }
  if (value == "signatureFailure") {
    return DESKTOP_UPDATER_RUNTIME_SIGNATURE_FAILURE;
  }
  if (value == "packageIdentityMismatch") {
    return DESKTOP_UPDATER_RUNTIME_PACKAGE_IDENTITY_MISMATCH;
  }
  if (value == "downloadFailure") {
    return DESKTOP_UPDATER_RUNTIME_DOWNLOAD_FAILURE;
  }
  if (value == "artifactIntegrityFailure") {
    return DESKTOP_UPDATER_RUNTIME_ARTIFACT_INTEGRITY_FAILURE;
  }
  if (value == "unsafeArchive") return DESKTOP_UPDATER_RUNTIME_UNSAFE_ARCHIVE;
  if (value == "stagingFailure") {
    return DESKTOP_UPDATER_RUNTIME_STAGING_FAILURE;
  }
  if (value == "installHandoffFailure") {
    return DESKTOP_UPDATER_RUNTIME_INSTALL_HANDOFF_FAILURE;
  }
  return DESKTOP_UPDATER_RUNTIME_INVALID_DESCRIPTOR;
}

desktop_updater_runtime_result_v1 Failure(
    const std::string& message,
    desktop_updater_runtime_outcome_v1 outcome =
        DESKTOP_UPDATER_RUNTIME_INVALID_DESCRIPTOR) {
  desktop_updater_runtime_result_v1 result = EmptyResult();
  result.outcome = outcome;
  result.message_utf8 = CopyMessage(message);
  return result;
}

desktop_updater_runtime_result_v1 ClientResult(
    const desktop_updater_runtime_client_v1& client,
    const std::string& outcome,
    const std::string& message) {
  desktop_updater_runtime_result_v1 result = EmptyResult();
  const desktop_updater::runtime::internal::LifecycleSnapshot snapshot =
      client.lifecycle.Snapshot();
  result.ok = 1;
  result.outcome = Outcome(outcome);
  result.message_utf8 = CopyMessage(message);
  if (snapshot.check.has_descriptor) {
    result.release_version_utf8 =
        CopyMessage(snapshot.check.descriptor.version);
    result.artifact_kind_utf8 =
        CopyMessage(snapshot.check.descriptor.artifact.kind);
  }
  if (snapshot.check.has_selected_item) {
    const auto& selected = snapshot.check.selected_item;
    result.mandatory = selected.mandatory ? 1 : 0;
    result.has_selected_build_number = selected.has_build_number ? 1 : 0;
    result.selected_build_number = selected.build_number;
    result.selected_platform_utf8 = CopyMessage(selected.platform);
    result.selected_channel_utf8 = CopyMessage(selected.channel);
    if (selected.has_fresh_install) {
      result.fresh_install_url_utf8 =
          CopyMessage(selected.fresh_install.download_url);
      if (!selected.fresh_install.message.empty()) {
        result.fresh_install_message_utf8 =
            CopyMessage(selected.fresh_install.message);
      }
    }
  }
  if (!snapshot.staged_path.empty()) {
    result.staged_path_utf8 = CopyMessage(snapshot.staged_path);
  }
  result.support_policy_status_utf8 =
      CopyMessage(snapshot.check.support_policy_status);
  return result;
}

void RecordDiagnostic(
    desktop_updater_runtime_client_v1* client,
    desktop_updater::runtime::internal::DiagnosticEntry entry) {
  std::lock_guard<std::mutex> lock(client->diagnostics_mutex);
  client->diagnostics.Record(std::move(entry));
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

std::map<std::string, std::string> RequestHeaders(
    desktop_updater_runtime_client_v1* client,
    const std::string& url) {
  desktop_updater_runtime_header_list_v1 list =
      client->request_headers_provider(client->application_context,
                                       url.c_str());
  struct ReleaseHeaders {
    desktop_updater_runtime_header_list_v1* list;
    ~ReleaseHeaders() {
      if (list->release != nullptr) {
        list->release(list->release_context, list->entries,
                      list->entry_count);
      }
    }
  } release{&list};
  if (list.abi_version != DESKTOP_UPDATER_RUNTIME_ABI_VERSION ||
      list.struct_size < sizeof(list) ||
      (list.entry_count > 0 && list.entries == nullptr)) {
    throw std::invalid_argument("Runtime header callback returned invalid data.");
  }
  std::map<std::string, std::string> result;
  for (std::size_t index = 0; index < list.entry_count; ++index) {
    result.emplace(RequiredString(list.entries[index].name_utf8, "header name"),
                   RequiredString(list.entries[index].value_utf8,
                                  "header value"));
  }
  return result;
}

desktop_updater::runtime::internal::ClientConfiguration CoreConfiguration(
    desktop_updater_runtime_client_v1* client) {
  desktop_updater::runtime::internal::ClientConfiguration result;
  result.app_archive_url = client->app_archive_url;
  result.expected_package_id = client->expected_package_id;
  result.current_version = client->current_version;
  result.has_current_build_number = client->has_current_build_number;
  result.current_build_number = client->current_build_number;
  result.current_updater_version = client->current_updater_version;
  result.platform = client->platform;
  result.channel = client->channel;
  result.installation_identity = client->installation_identity;
  result.require_index_signature = client->require_index_signature;
  result.require_descriptor_signature = client->require_descriptor_signature;
  result.pinned_public_keys_by_id = std::map<std::string,
      std::vector<std::uint8_t>>(client->pinned_public_keys.begin(),
                                client->pinned_public_keys.end());
  result.minimum_os_resolver = [client](const std::string& platform,
                                        const std::string& minimum_os) {
    return client->minimum_os_resolver(client->application_context,
                                       platform.c_str(),
                                       minimum_os.c_str()) != 0;
  };
  return result;
}

std::string ArtifactFileName(const std::string& url) {
  const std::size_t query = url.find_first_of("?#");
  const std::string path = url.substr(0, query);
  const std::size_t slash = path.find_last_of('/');
  const std::string name = path.substr(slash == std::string::npos ? 0
                                                                 : slash + 1);
  if (name.empty() || name == "." || name == ".." ||
      name.find('\\') != std::string::npos) {
    throw std::invalid_argument("Artifact URL has no safe file name.");
  }
  return name;
}

template <typename Request>
void ValidateRequest(const Request* request, const char* name) {
  if (request == nullptr) {
    throw std::invalid_argument(std::string(name) + " is required.");
  }
  if (request->abi_version != DESKTOP_UPDATER_RUNTIME_ABI_VERSION ||
      request->struct_size < sizeof(*request)) {
    throw std::invalid_argument(std::string(name) + " has an invalid ABI.");
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
    if ((configuration->require_index_signature != 0 ||
         configuration->require_descriptor_signature != 0) &&
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
    client->require_index_signature =
        configuration->require_index_signature != 0;
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
    desktop_updater::runtime::internal::TransportOptions transport_options;
    transport_options.timeout_milliseconds = static_cast<std::int64_t>(
        client->download_timeout_milliseconds);
    transport_options.maximum_metadata_bytes = client->maximum_metadata_bytes;
    transport_options.request_headers_provider =
        [raw_client = client.get()](const std::string& url) {
          return RequestHeaders(raw_client, url);
        };
    client->transport.reset(
        new desktop_updater::runtime::internal::WinHttpUpdateTransport(
            std::move(transport_options)));

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

extern "C" desktop_updater_runtime_result_v1 DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_client_check_for_update_v1(
    desktop_updater_runtime_client_v1* client) {
  try {
    if (client == nullptr || client->transport == nullptr) {
      return Failure("Runtime client is required.");
    }
    const auto lease = client->lifecycle.BeginCheck();
    if (lease.status == desktop_updater::runtime::internal::
                            ClientLifecycleStatus::kInstallInProgress) {
      return ClientResult(*client, "installHandoffFailure",
                          "An install helper handoff is already in progress.");
    }
    RecordDiagnostic(
        client, {"", "check", "info", "Checking for a native update.", ""});
    auto check = desktop_updater::runtime::internal::CheckForUpdateCore(
        CoreConfiguration(client), client->transport.get(),
        desktop_updater::runtime::internal::BCryptSha256);
    if (!client->lifecycle.PublishCheck(lease, check)) {
      return ClientResult(*client, "invalidDescriptor",
                          "Update check was invalidated before completion.");
    }
    RecordDiagnostic(
        client,
        {"", check.outcome == "updateAvailable" ? "descriptor" : "check",
         check.outcome == "updateAvailable" ? "info" : "warning",
         check.message, ""});
    return ClientResult(*client, check.outcome, check.message);
  } catch (const std::exception& error) {
    return Failure(error.what());
  } catch (...) {
    return Failure("Unknown native runtime check failure.");
  }
}

extern "C" desktop_updater_runtime_result_v1 DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_client_download_verify_and_stage_v1(
    desktop_updater_runtime_client_v1* client,
    const desktop_updater_runtime_stage_request_v1* request) {
  bool transport_active = false;
  try {
    if (client == nullptr || client->transport == nullptr) {
      return Failure("Runtime client is required.");
    }
    const auto lease = client->lifecycle.BeginStage();
    ValidateRequest(request, "Runtime stage request");
    if (lease.status == desktop_updater::runtime::internal::
                            ClientLifecycleStatus::kInstallInProgress) {
      return ClientResult(*client, "installHandoffFailure",
                          "An install helper handoff is already in progress.");
    }
    if (lease.status != desktop_updater::runtime::internal::
                            ClientLifecycleStatus::kAllowed) {
      return ClientResult(*client, "invalidDescriptor",
                          "No client-bound update check is ready to stage.");
    }
    const auto check = lease.check;
    if (check.outcome != "updateAvailable" || !check.has_descriptor) {
      return ClientResult(*client, check.outcome,
                          "No verified update is ready to download.");
    }
    const std::string download_directory = RequiredString(
        request->download_directory_utf8, "download_directory");
    const std::string staging_directory = RequiredString(
        request->staging_directory_utf8, "staging_directory");
    std::filesystem::create_directories(
        std::filesystem::u8path(download_directory));
    const std::string artifact_path =
        download_directory + "/" +
        ArtifactFileName(check.descriptor.artifact.url);
    desktop_updater::runtime::internal::ArtifactDownloadRequest download;
    download.url = check.descriptor.artifact.url;
    download.destination_path = artifact_path;
    download.expected_length = check.descriptor.artifact.length;
    download.expected_sha256 = check.descriptor.artifact.sha256;
    RecordDiagnostic(
        client,
        {"", "download", "info", "Downloading verified native artifact.",
         ""});
    transport_active = true;
    client->transport->DownloadArtifact(download);
    transport_active = false;
    RecordDiagnostic(
        client,
        {"", "verify", "info",
         "Artifact length and SHA-256 are verified.", ""});
    desktop_updater::runtime::internal::ArchiveLimits limits;
    limits.maximum_archive_entries = client->maximum_archive_entries;
    limits.maximum_uncompressed_bytes = client->maximum_uncompressed_bytes;
    limits.maximum_single_entry_bytes = client->maximum_single_entry_bytes;
    if (check.descriptor.artifact.kind == "zip") {
      desktop_updater::runtime::internal::StageWindowsZip(
          artifact_path, staging_directory, check.descriptor,
          client->expected_package_id, limits);
    } else if (check.descriptor.artifact.kind == "innoInstaller") {
      desktop_updater::runtime::internal::StageWindowsInnoInstaller(
          Utf8ToWide(artifact_path), staging_directory, check.descriptor,
          client->expected_package_id);
    } else {
      return ClientResult(*client, "unsupportedArtifactKind",
                          "Artifact kind is not supported on Windows.");
    }
    if (!client->lifecycle.PublishStage(lease, staging_directory)) {
      return ClientResult(*client, "invalidDescriptor",
                          "A newer staging attempt invalidated this update.");
    }
    RecordDiagnostic(
        client,
        {"", "stage", "info", "Verified native artifact is staged.", ""});
    return ClientResult(*client, "updateAvailable",
                        "Verified native artifact is staged.");
  } catch (const std::exception& error) {
    const std::string message = error.what();
    const bool integrity = message.find("length") != std::string::npos ||
                           message.find("SHA-256") != std::string::npos;
    const bool unsafe = message.find("ZIP") != std::string::npos ||
                        message.find("Archive") != std::string::npos ||
                        message.find("archive") != std::string::npos ||
                        message.find("path") != std::string::npos ||
                        message.find("traversal") != std::string::npos;
    if (transport_active) {
      return ClientResult(
          *client,
          integrity ? "artifactIntegrityFailure" : "downloadFailure",
          message);
    }
    return ClientResult(*client, unsafe ? "unsafeArchive" : "stagingFailure",
                        message);
  } catch (...) {
    return Failure("Unknown native runtime staging failure.",
                   DESKTOP_UPDATER_RUNTIME_STAGING_FAILURE);
  }
}

extern "C" desktop_updater_runtime_result_v1 DESKTOP_UPDATER_RUNTIME_CALL
desktop_updater_runtime_client_install_and_relaunch_v1(
    desktop_updater_runtime_client_v1* client,
    const desktop_updater_runtime_install_request_v1* request) {
  try {
    if (client == nullptr) return Failure("Runtime client is required.");
    ValidateRequest(request, "Runtime install request");
    if (request->removed_file_count > 0 &&
        request->removed_files_utf8 == nullptr) {
      return ClientResult(*client, "installHandoffFailure",
                          "Removed file entries are required.");
    }
    std::vector<std::wstring> removed_files;
    removed_files.reserve(request->removed_file_count);
    for (std::size_t index = 0; index < request->removed_file_count; ++index) {
      removed_files.push_back(Utf8ToWide(RequiredString(
          request->removed_files_utf8[index], "removed file")));
    }
    const std::wstring diagnostics =
        request->diagnostics_log_path_utf8 == nullptr
            ? std::wstring()
            : Utf8ToWide(request->diagnostics_log_path_utf8);
    const auto install_handoff = client->lifecycle.BeginInstall();
    if (install_handoff.status != desktop_updater::runtime::internal::
                                      ClientLifecycleStatus::kAllowed) {
      return ClientResult(*client, "installHandoffFailure",
                          "No staged update is ready for helper handoff.");
    }
    desktop_updater::runtime::internal::SchedulingRollbackGuard rollback(
        &client->lifecycle, install_handoff);
    RecordDiagnostic(client,
                     {"", "install", "info",
                      "Handing staged update to the Windows helper.", ""});
    const auto scheduler_result =
        desktop_updater::runtime::internal::HandoffWindowsInstall(
            Utf8ToWide(install_handoff.staged_path), diagnostics,
            removed_files);
    if (!scheduler_result.ok) {
      return ClientResult(*client, "installHandoffFailure",
                          scheduler_result.error_message);
    }
    if (!rollback.Confirm()) {
      return ClientResult(*client, "installHandoffFailure",
                          "Windows helper handoff confirmation failed.");
    }
    return ClientResult(*client, "updateAvailable",
                        "Windows helper handoff scheduled.");
  } catch (const std::exception& error) {
    return client == nullptr
               ? Failure(error.what(),
                         DESKTOP_UPDATER_RUNTIME_INSTALL_HANDOFF_FAILURE)
               : ClientResult(*client, "installHandoffFailure", error.what());
  } catch (...) {
    return Failure("Unknown native runtime helper handoff failure.",
                   DESKTOP_UPDATER_RUNTIME_INSTALL_HANDOFF_FAILURE);
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
  delete[] result->release_version_utf8;
  delete[] result->artifact_kind_utf8;
  delete[] result->staged_path_utf8;
  delete[] result->support_policy_status_utf8;
  delete[] result->selected_platform_utf8;
  delete[] result->selected_channel_utf8;
  delete[] result->fresh_install_url_utf8;
  delete[] result->fresh_install_message_utf8;
  result->message_utf8 = nullptr;
  result->release_version_utf8 = nullptr;
  result->artifact_kind_utf8 = nullptr;
  result->staged_path_utf8 = nullptr;
  result->support_policy_status_utf8 = nullptr;
  result->selected_platform_utf8 = nullptr;
  result->selected_channel_utf8 = nullptr;
  result->fresh_install_url_utf8 = nullptr;
  result->fresh_install_message_utf8 = nullptr;
  result->mandatory = 0;
  result->has_selected_build_number = 0;
  result->selected_build_number = 0;
  result->client = nullptr;
  result->ok = 0;
}
