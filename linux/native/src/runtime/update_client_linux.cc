#include "desktop_updater_runtime.h"

#include <sys/stat.h>

#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "artifact_stager_linux.h"
#include "client_lifecycle.h"
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

class OwnedDownloadStageGuard {
 public:
  explicit OwnedDownloadStageGuard(std::string path)
      : path_(std::move(path)) {}

  ~OwnedDownloadStageGuard() {
    try {
      internal::RemoveStagingDirectory(path_);
    } catch (...) {
      // The exclusive download child is best-effort temporary storage.
    }
  }

  const std::string& path() const { return path_; }

 private:
  std::string path_;
};

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
    const internal::CheckLease lease = lifecycle_.BeginCheck();
    if (lease.status == internal::ClientLifecycleStatus::kInstallInProgress) {
      return Result("installHandoffFailure",
                    "An install helper handoff is already in progress.");
    }
    Record("check", "info", "Checking for a native update.");
    internal::ClientCheckResult check = internal::CheckForUpdateCore(
        CoreConfiguration(configuration_), &transport_,
        internal::OpenSSLSha256);
    if (!lifecycle_.PublishCheck(lease, check)) {
      return Result("invalidDescriptor",
                    "Update check was invalidated before completion.");
    }
    Record(check.outcome == "updateAvailable" ? "descriptor" : "check",
           check.outcome == "updateAvailable" ? "info" : "warning",
           check.message);
    return Result(check.outcome, check.message);
  }

  RuntimeResult DownloadVerifyAndStage(
      const std::string& download_directory,
      const std::string& staging_directory,
      const std::string& executable_relative_path) {
    const internal::StageLease lease = lifecycle_.BeginStage();
    if (lease.status == internal::ClientLifecycleStatus::kInstallInProgress) {
      return Result("installHandoffFailure",
                    "An install helper handoff is already in progress.");
    }
    if (lease.status != internal::ClientLifecycleStatus::kAllowed) {
      return Result("invalidDescriptor",
                    "No client-bound update check is ready to stage.");
    }
    const internal::ClientCheckResult check = lease.check;
    if (check.outcome != "updateAvailable" || !check.has_descriptor) {
      return Result(check.outcome,
                    "No verified update is ready to download.");
    }
    std::string artifact_path;
    std::unique_ptr<OwnedDownloadStageGuard> download_stage;
    try {
      EnsureDirectory(download_directory);
      const internal::OwnedStage owned_download =
          internal::CreateOwnedStage(download_directory);
      download_stage.reset(new OwnedDownloadStageGuard(owned_download.path));
      artifact_path = download_stage->path() + "/" +
                      ArtifactFileName(check.descriptor.artifact.url);
      Record("download", "info", "Downloading verified native artifact.");
      internal::ArtifactDownloadRequest request;
      request.url = check.descriptor.artifact.url;
      request.destination_path = artifact_path;
      request.expected_length = check.descriptor.artifact.length;
      request.expected_sha256 = check.descriptor.artifact.sha256;
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
      EnsureDirectory(staging_directory);
      const internal::LinuxStagedArtifact staged = internal::StageLinuxZip(
          artifact_path, staging_directory, executable_relative_path,
          check.descriptor, configuration_.expected_package_id, limits);
      if (!lifecycle_.PublishStage(
              lease, staged.stage_path, staged.provenance.marker_sha256)) {
        return Result("invalidDescriptor",
                      "A newer staging attempt invalidated this update.");
      }
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

  RuntimeResult PrepareInstall(
      const std::string& transaction_id,
      const std::string& install_root,
      const std::string& executable_relative_path,
      const std::vector<std::string>& removed_files) {
    const internal::LifecycleSnapshot snapshot = lifecycle_.Snapshot();
    if (snapshot.staged_path.empty() || !snapshot.check.has_descriptor) {
      return Result("installHandoffFailure",
                    "No staged update is ready for helper handoff.");
    }
    Record("install", "info",
           "Handing staged update to the Linux helper.");
    const native::InstallResult validation =
        internal::ValidateLinuxInstallHandoff(
            snapshot.staged_path, install_root, executable_relative_path,
            configuration_.expected_package_id, removed_files,
            snapshot.stage_provenance_sha256,
            snapshot.check.descriptor.artifact.sha256);
    if (!validation.ok) {
      Record("install", "error", validation.error);
      return Result("installHandoffFailure", validation.error);
    }
    const internal::InstallHandoff install_handoff =
        lifecycle_.BeginInstall(snapshot);
    if (install_handoff.status != internal::ClientLifecycleStatus::kAllowed) {
      return Result("installHandoffFailure",
                    "No staged update is ready for helper handoff.");
    }
    internal::SchedulingRollbackGuard rollback(&lifecycle_, install_handoff);
    native::InstallReservation reservation;
    native::InstallResult prepare_result{false, std::string()};
    try {
      prepare_result = internal::HandoffLinuxInstall(
          install_handoff.staged_path, install_root, executable_relative_path,
          configuration_.expected_package_id, removed_files,
          install_handoff.stage_provenance_sha256,
          snapshot.check.descriptor.artifact.sha256, transaction_id,
          &reservation);
    } catch (const std::exception& error) {
      Record("install", "error", error.what());
      return Result("installHandoffFailure", error.what());
    } catch (...) {
      Record("install", "error", "Unknown Linux helper scheduling failure.");
      return Result("installHandoffFailure",
                    "Unknown Linux helper scheduling failure.");
    }
    if (!prepare_result.ok) {
      Record("install", "error", prepare_result.error);
      return Result("installHandoffFailure", prepare_result.error);
    }
    if (!rollback.Confirm()) {
      return Result("installHandoffFailure",
                    "Linux helper handoff confirmation failed.");
    }
    pending_handoff_ = std::move(install_handoff);
    pending_reservation_ = std::move(reservation);
    return Result("updateAvailable", "Linux helper prepareInstall accepted.");
  }

  RuntimeResult CommitAfterExit() {
    if (pending_reservation_.transaction_id.empty()) {
      return Result("installHandoffFailure",
                    "No prepared Linux install transaction is available.");
    }
    const native::InstallTransactionStatus status =
        native::CommitAfterExit(pending_reservation_);
    const bool accepted =
        (status.state == native::InstallTransactionState::kCommitAccepted ||
         status.state == native::InstallTransactionState::kCompleted) &&
        (status.result_code == native::InstallTransactionResultCode::kAccepted ||
         status.result_code == native::InstallTransactionResultCode::kSucceeded) &&
        status.transaction_id == pending_reservation_.transaction_id &&
        status.response_digest_sha256 ==
            pending_reservation_.response_digest_sha256 &&
        status.helper_endpoint_identity_sha256 ==
            pending_reservation_.helper_endpoint_identity_sha256;
    if (!accepted) {
      return Result("installHandoffFailure",
                    status.detail.empty()
                        ? "Linux helper commit was not accepted."
                        : status.detail);
    }
    if (!lifecycle_.CompleteInstall(pending_handoff_)) {
      return Result("installHandoffFailure",
                    "Linux helper lifecycle completion failed.");
    }
    try {
      internal::RemoveStagingDirectory(pending_handoff_.staged_path);
    } catch (const std::exception& error) {
      Record("stage", "warning",
             std::string("Linux handoff staging cleanup failed: ") +
                 error.what());
    } catch (...) {
      Record("stage", "warning", "Linux handoff staging cleanup failed.");
    }
    const std::string detail = status.detail;
    pending_handoff_ = internal::InstallHandoff();
    pending_reservation_ = native::InstallReservation();
    return Result("updateAvailable", detail);
  }

  RuntimeResult CancelReservation() {
    if (pending_reservation_.transaction_id.empty()) {
      return Result("installHandoffFailure",
                    "No prepared Linux install transaction is available.");
    }
    const native::InstallTransactionStatus status =
        native::CancelReservation(pending_reservation_);
    if (status.state != native::InstallTransactionState::kCancelled) {
      return Result("installHandoffFailure",
                    status.detail.empty()
                        ? "Linux helper cancellation was not accepted."
                        : status.detail);
    }
    (void)lifecycle_.CompleteInstall(pending_handoff_);
    pending_handoff_ = internal::InstallHandoff();
    pending_reservation_ = native::InstallReservation();
    return Result("updateAvailable", status.detail);
  }

  RuntimeResult QueryTransaction(const std::string& transaction_id) {
    const native::InstallTransactionStatus status =
        native::QueryTransaction(transaction_id);
    return Result("updateAvailable", status.detail);
  }

  RuntimeResult RecoverPendingInstall(const std::string& transaction_id) {
    const native::InstallTransactionStatus status =
        native::RecoverPendingInstall(transaction_id);
    return Result("updateAvailable", status.detail);
  }

  std::vector<std::string> RedactedDiagnostics() const {
    std::lock_guard<std::mutex> lock(diagnostics_mutex_);
    return diagnostics_.RedactedLogLines();
  }

 private:
  RuntimeResult Result(const std::string& outcome,
                       const std::string& message) const {
    RuntimeResult result;
    const internal::LifecycleSnapshot snapshot = lifecycle_.Snapshot();
    result.outcome = Outcome(outcome);
    result.message = message;
    if (snapshot.check.has_descriptor) {
      result.release_version = snapshot.check.descriptor.version;
      result.artifact_kind = snapshot.check.descriptor.artifact.kind;
    }
    if (snapshot.check.has_selected_item) {
      const auto& selected = snapshot.check.selected_item;
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
    result.staged_path = snapshot.staged_path;
    result.support_policy_status = snapshot.check.support_policy_status;
    return result;
  }

  void Record(const std::string& stage,
              const std::string& level,
              const std::string& message) {
    std::lock_guard<std::mutex> lock(diagnostics_mutex_);
    diagnostics_.Record(
        {Timestamp(), stage, level, message, std::string()});
  }

  RuntimeConfiguration configuration_;
  internal::CurlUpdateTransport transport_;
  mutable std::mutex diagnostics_mutex_;
  internal::DiagnosticsRecorder diagnostics_;
  internal::ClientLifecycleState lifecycle_;
  internal::InstallHandoff pending_handoff_;
  native::InstallReservation pending_reservation_;
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

RuntimeResult UpdateClient::PrepareInstall(
    const std::string& transaction_id,
    const std::string& install_root,
    const std::string& executable_relative_path,
    const std::vector<std::string>& removed_files) {
  return impl_->PrepareInstall(transaction_id, install_root,
                               executable_relative_path, removed_files);
}

RuntimeResult UpdateClient::CommitAfterExit() {
  return impl_->CommitAfterExit();
}

RuntimeResult UpdateClient::CancelReservation() {
  return impl_->CancelReservation();
}

RuntimeResult UpdateClient::QueryTransaction(const std::string& transaction_id) {
  return impl_->QueryTransaction(transaction_id);
}

RuntimeResult UpdateClient::RecoverPendingInstall(
    const std::string& transaction_id) {
  return impl_->RecoverPendingInstall(transaction_id);
}

std::vector<std::string> UpdateClient::RedactedDiagnostics() const {
  return impl_->RedactedDiagnostics();
}

}  // namespace runtime
}  // namespace desktop_updater
