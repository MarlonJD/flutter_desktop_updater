#ifndef DESKTOP_UPDATER_NATIVE_H_
#define DESKTOP_UPDATER_NATIVE_H_

#include <cstdint>
#include <string>
#include <vector>

namespace desktop_updater {
namespace native {

enum class LinuxInstallOperation {
  kRestart,
  kInstall,
};

enum class InstallTargetProofSource {
  kRunningExecutableContext,
  kLegacySelfContainedBundle,
  kInstalledIdentityMarker,
};

struct InstallTargetProof {
  std::string canonical_root;
  std::string executable_relative_path;
  std::string package_id;
  InstallTargetProofSource source;
};

struct InstallProvenanceEntry {
  std::string path;
  std::string kind;
  std::int64_t length;
  std::string sha256;
  std::string target;
};

struct InstallRequest {
  LinuxInstallOperation operation;
  std::string staging_path;
  std::string install_root;
  std::string executable_relative_path;
  std::string package_id;
  std::vector<std::string> removed_files;
  std::string diagnostics_log_path;
  std::string expected_provenance_sha256;
  std::string provenance_nonce;
  std::vector<InstallProvenanceEntry> provenance_entries;
};

struct InstallResult {
  bool ok;
  std::string error;
};

enum class InstallTransactionState : std::uint32_t {
  kUnknown = 0,
  kPrepared = 1,
  kCommitAccepted = 2,
  kCompleted = 3,
  kCancelled = 4,
  kExpired = 5,
  kRolledBack = 6,
  kManualActionRequired = 7,
};

enum class InstallTransactionResultCode : std::uint32_t {
  kNone = 0,
  kAccepted = 1,
  kSucceeded = 2,
  kRejected = 3,
  kEndpointUnavailable = 4,
  kAuthenticationFailed = 5,
  kInvalidResponse = 6,
  kRecoveryRequired = 7,
  kRelaunchFailure = 8,
};

struct InstallReservation {
  std::string transaction_id;
  std::string ready_token;
  std::string response_digest_sha256;
  std::string helper_endpoint_identity_sha256;
  std::int64_t expires_at_unix_milliseconds = 0;
};

struct InstallTransactionStatus {
  std::string transaction_id;
  InstallTransactionState state = InstallTransactionState::kUnknown;
  InstallTransactionResultCode result_code =
      InstallTransactionResultCode::kNone;
  std::string detail;
  std::string response_digest_sha256;
  std::string helper_endpoint_identity_sha256;
};

InstallResult ValidateInstallRequest(const InstallRequest& request);
InstallResult PrepareInstall(const InstallRequest& request,
                             InstallReservation* reservation);
InstallTransactionStatus CommitAfterExit(
    const InstallReservation& reservation);
InstallTransactionStatus CancelReservation(
    const InstallReservation& reservation);
InstallTransactionStatus QueryTransaction(const std::string& transaction_id);
InstallTransactionStatus RecoverPendingInstall(
    const std::string& transaction_id);
// Arms a same-user relaunch that starts after the caller exits. A successful
// caller must terminate promptly so the replacement process can start.
InstallResult RestartCurrentApplication();
InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request);

}  // namespace native
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_H_
