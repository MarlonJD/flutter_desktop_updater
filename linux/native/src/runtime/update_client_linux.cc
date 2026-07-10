#include "desktop_updater_runtime.h"

#include <sys/stat.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "artifact_stager_linux.h"
#include "diagnostics.h"
#include "sha256_openssl.h"
#include "update_client_core.h"
#include "update_transport_curl.h"

namespace desktop_updater {
namespace runtime {
namespace {

RuntimeOutcome Outcome(const std::string& value) {
  if (value == "noUpdate") return RuntimeOutcome::kNoUpdate;
  if (value == "updateAvailable") return RuntimeOutcome::kUpdateAvailable;
  if (value == "freshInstallRequired") {
    return RuntimeOutcome::kFreshInstallRequired;
  }
  if (value == "unsupportedMinimumUpdater") {
    return RuntimeOutcome::kUnsupportedMinimumUpdater;
  }
  if (value == "unsupportedMinimumOS") {
    return RuntimeOutcome::kUnsupportedMinimumOS;
  }
  if (value == "rolloutIneligible") {
    return RuntimeOutcome::kRolloutIneligible;
  }
  if (value == "unsupportedArtifactKind") {
    return RuntimeOutcome::kUnsupportedArtifactKind;
  }
  if (value == "signatureFailure") {
    return RuntimeOutcome::kSignatureFailure;
  }
  if (value == "packageIdentityMismatch") {
    return RuntimeOutcome::kPackageIdentityMismatch;
  }
  if (value == "downloadFailure") {
    return RuntimeOutcome::kDownloadFailure;
  }
  if (value == "artifactIntegrityFailure") {
    return RuntimeOutcome::kArtifactIntegrityFailure;
  }
  if (value == "unsafeArchive") return RuntimeOutcome::kUnsafeArchive;
  if (value == "stagingFailure") return RuntimeOutcome::kStagingFailure;
  if (value == "installHandoffFailure") {
    return RuntimeOutcome::kInstallHandoffFailure;
  }
  return RuntimeOutcome::kInvalidDescriptor;
}

std::string Timestamp() {
  const auto now = std::chrono::system_clock::now();
  const std::time_t seconds = std::chrono::system_clock::to_time_t(now);
  std::tm utc{};
  gmtime_r(&seconds, &utc);
  char buffer[32];
  std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc);
  return buffer;
}

void EnsureDirectory(const std::string& path) {
  if (path.empty()) throw std::invalid_argument("Directory path is empty.");
  std::string current;
  std::size_t start = 0;
  if (path.front() == '/') {
    current = "/";
    start = 1;
  }
  while (start <= path.size()) {
    const std::size_t slash = path.find('/', start);
    const std::string segment = path.substr(start, slash - start);
    if (!segment.empty()) {
      if (!current.empty() && current.back() != '/') current += '/';
      current += segment;
      if (mkdir(current.c_str(), 0700) != 0 && errno != EEXIST) {
        throw std::runtime_error("Unable to create runtime directory.");
      }
    }
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
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

internal::ClientConfiguration CoreConfiguration(
    const RuntimeConfiguration& configuration) {
  internal::ClientConfiguration result;
  result.app_archive_url = configuration.app_archive_url;
  result.expected_package_id = configuration.expected_package_id;
  result.current_version = configuration.current_version;
  result.has_current_build_number = configuration.has_current_build_number;
  result.current_build_number = configuration.current_build_number;
  result.current_updater_version = configuration.current_updater_version;
  result.platform = configuration.platform;
  result.channel = configuration.channel;
  result.installation_identity = configuration.installation_identity;
  result.require_index_signature = configuration.require_index_signature;
  result.require_descriptor_signature =
      configuration.require_descriptor_signature;
  result.pinned_public_keys_by_id = configuration.pinned_public_keys_by_id;
  result.minimum_os_resolver = configuration.minimum_os_resolver;
  return result;
}

internal::TransportOptions TransportConfiguration(
    const RuntimeConfiguration& configuration) {
  internal::TransportOptions result;
  result.timeout_milliseconds = configuration.download_timeout_milliseconds;
  result.maximum_metadata_bytes = configuration.maximum_metadata_bytes;
  result.request_headers_provider = configuration.request_headers_provider;
  return result;
}

}  // namespace

class UpdateClient::Impl {
 public:
  explicit Impl(RuntimeConfiguration configuration)
      : configuration_(std::move(configuration)),
        transport_(TransportConfiguration(configuration_)) {
    const RuntimeConfigurationValidation validation =
        ValidateRuntimeConfiguration(configuration_);
    if (!validation.ok) throw std::invalid_argument(validation.error);
  }

  RuntimeResult CheckForUpdate() {
    Record("check", "info", "Checking for a native update.");
    check_ = internal::CheckForUpdateCore(
        CoreConfiguration(configuration_), &transport_,
        internal::OpenSSLSha256);
    Record(check_.outcome == "updateAvailable" ? "descriptor" : "check",
           check_.outcome == "updateAvailable" ? "info" : "warning",
           check_.message);
    return Result(check_.outcome, check_.message);
  }

  RuntimeResult DownloadVerifyAndStage(
      const std::string& download_directory,
      const std::string& staging_directory,
      const std::string& executable_relative_path) {
    if (check_.outcome != "updateAvailable" || !check_.has_descriptor) {
      return Result(check_.outcome,
                    "No verified update is ready to download.");
    }
    std::string artifact_path;
    try {
      EnsureDirectory(download_directory);
      artifact_path = download_directory + "/" +
                      ArtifactFileName(check_.descriptor.artifact.url);
      Record("download", "info", "Downloading verified native artifact.");
      internal::ArtifactDownloadRequest request;
      request.url = check_.descriptor.artifact.url;
      request.destination_path = artifact_path;
      request.expected_length = check_.descriptor.artifact.length;
      request.expected_sha256 = check_.descriptor.artifact.sha256;
      transport_.DownloadArtifact(request);
      Record("verify", "info",
             "Artifact length and SHA-256 are verified.");
    } catch (const std::exception& error) {
      const std::string message = error.what();
      const bool integrity = message.find("length") != std::string::npos ||
                             message.find("SHA-256") != std::string::npos;
      Record("download", "error", message);
      return Result(integrity ? "artifactIntegrityFailure" : "downloadFailure",
                    message);
    }

    try {
      internal::ArchiveLimits limits;
      limits.maximum_archive_entries =
          configuration_.maximum_archive_entries;
      limits.maximum_uncompressed_bytes =
          configuration_.maximum_uncompressed_bytes;
      limits.maximum_single_entry_bytes =
          configuration_.maximum_single_entry_bytes;
      internal::StageLinuxZip(
          artifact_path, staging_directory, executable_relative_path,
          check_.descriptor, configuration_.expected_package_id, limits);
      staged_path_ = staging_directory;
      Record("stage", "info", "Verified native artifact is staged.");
      return Result("updateAvailable", "Verified native artifact is staged.");
    } catch (const std::exception& error) {
      const std::string message = error.what();
      const bool unsafe = message.find("ZIP") != std::string::npos ||
                          message.find("Archive") != std::string::npos ||
                          message.find("archive") != std::string::npos ||
                          message.find("path") != std::string::npos ||
                          message.find("traversal") != std::string::npos;
      const std::string outcome =
          unsafe ? "unsafeArchive" : "stagingFailure";
      Record("stage", "error", message);
      return Result(outcome, message);
    }
  }

  RuntimeResult InstallAndRelaunch(
      const std::string& install_root,
      const std::string& executable_relative_path,
      const std::vector<std::string>& removed_files,
      const std::string& diagnostics_log_path) {
    if (staged_path_.empty() || !check_.has_descriptor) {
      return Result("installHandoffFailure",
                    "No staged update is ready for helper handoff.");
    }
    Record("install", "info",
           "Handing staged update to the Linux helper.");
    const native::InstallResult validation =
        internal::ValidateLinuxInstallHandoff(
            staged_path_, install_root, executable_relative_path,
            configuration_.expected_package_id, removed_files,
            diagnostics_log_path);
    if (!validation.ok) {
      Record("install", "error", validation.error);
      return Result("installHandoffFailure", validation.error);
    }
    const native::InstallResult handoff = internal::HandoffLinuxInstall(
        staged_path_, install_root, executable_relative_path,
        configuration_.expected_package_id, removed_files,
        diagnostics_log_path);
    if (!handoff.ok) {
      Record("install", "error", handoff.error);
      return Result("installHandoffFailure", handoff.error);
    }
    return Result("updateAvailable", "Linux helper handoff scheduled.");
  }

  std::vector<std::string> RedactedDiagnostics() const {
    return diagnostics_.RedactedLogLines();
  }

 private:
  RuntimeResult Result(const std::string& outcome,
                       const std::string& message) const {
    RuntimeResult result;
    result.outcome = Outcome(outcome);
    result.message = message;
    if (check_.has_descriptor) {
      result.release_version = check_.descriptor.version;
      result.artifact_kind = check_.descriptor.artifact.kind;
    }
    if (check_.has_selected_item) {
      const auto& selected = check_.selected_item;
      result.mandatory = selected.mandatory;
      result.has_selected_build_number = selected.has_build_number;
      result.selected_build_number = selected.build_number;
      result.selected_platform = selected.platform;
      result.selected_channel = selected.channel;
      if (selected.has_fresh_install) {
        result.fresh_install_url = selected.fresh_install.download_url;
        result.fresh_install_message = selected.fresh_install.message;
      }
    }
    result.staged_path = staged_path_;
    result.support_policy_status = check_.support_policy_status;
    return result;
  }

  void Record(const std::string& stage,
              const std::string& level,
              const std::string& message) {
    diagnostics_.Record(
        {Timestamp(), stage, level, message, std::string()});
  }

  RuntimeConfiguration configuration_;
  internal::CurlUpdateTransport transport_;
  internal::ClientCheckResult check_;
  internal::DiagnosticsRecorder diagnostics_;
  std::string staged_path_;
};

UpdateClient::UpdateClient(RuntimeConfiguration configuration)
    : impl_(new Impl(std::move(configuration))) {}

UpdateClient::~UpdateClient() = default;
UpdateClient::UpdateClient(UpdateClient&&) noexcept = default;
UpdateClient& UpdateClient::operator=(UpdateClient&&) noexcept = default;

RuntimeResult UpdateClient::CheckForUpdate() {
  return impl_->CheckForUpdate();
}

RuntimeResult UpdateClient::DownloadVerifyAndStage(
    const std::string& download_directory,
    const std::string& staging_directory,
    const std::string& executable_relative_path) {
  return impl_->DownloadVerifyAndStage(download_directory, staging_directory,
                                       executable_relative_path);
}

RuntimeResult UpdateClient::InstallAndRelaunch(
    const std::string& install_root,
    const std::string& executable_relative_path,
    const std::vector<std::string>& removed_files,
    const std::string& diagnostics_log_path) {
  return impl_->InstallAndRelaunch(install_root, executable_relative_path,
                                   removed_files, diagnostics_log_path);
}

std::vector<std::string> UpdateClient::RedactedDiagnostics() const {
  return impl_->RedactedDiagnostics();
}

}  // namespace runtime
}  // namespace desktop_updater
