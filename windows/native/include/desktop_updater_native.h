#ifndef DESKTOP_UPDATER_NATIVE_H_
#define DESKTOP_UPDATER_NATIVE_H_

#include <cstdint>
#include <string>
#include <vector>

namespace desktop_updater {
namespace native {

enum class InstallTargetProofSource {
  kRegistryUninstallRecord,
  kInstalledIdentityMarker,
};

enum class WindowsPathComponentState {
  kSafe,
  kUnavailable,
  kReparsePoint,
};

enum class InstallElevationPolicy {
  kAuto,
  kAlways,
  kNever,
};

enum class InstallLaunchDecision {
  kNormal,
  kElevated,
  kReject,
};

struct InstallTargetProof {
  std::wstring canonical_root;
  std::wstring executable_relative_path;
  std::wstring package_id;
  InstallTargetProofSource source;
};

struct InstallRequest {
  std::wstring staging_path;
  std::wstring install_root;
  std::wstring executable_relative_path;
  std::wstring expected_package_id;
  std::vector<std::wstring> removed_files;
  std::wstring diagnostics_log_path;
  std::wstring expected_provenance_sha256;
  std::wstring expected_artifact_sha256;
  std::vector<std::wstring> allowed_signer_thumbprints;
  InstallElevationPolicy elevation_policy = InstallElevationPolicy::kAuto;
};

struct InstallResult {
  bool ok;
  std::string error_message;
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

InstallResult PrepareInstall(const InstallRequest& request,
                             InstallReservation* reservation);
InstallTransactionStatus CommitAfterExit(
    const InstallReservation& reservation);
InstallTransactionStatus CancelReservation(
    const InstallReservation& reservation);
InstallTransactionStatus QueryTransaction(const std::string& transaction_id);
InstallTransactionStatus RecoverPendingInstall(
    const std::string& transaction_id);

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request);

InstallLaunchDecision ResolveInstallLaunchDecision(
    InstallElevationPolicy policy,
    bool target_is_protected,
    bool target_is_writable,
    bool process_is_elevated);

bool IsStrictChildPath(const std::wstring& root,
                       const std::wstring& candidate);

bool IsKnownProtectedInstallDirectory(
    const std::wstring& directory,
    const std::vector<std::wstring>& protected_roots);

bool IsInstallerOwnedWindowsFile(const std::wstring& file_name);

bool RegistryRecordMatchesInstallTarget(
    const std::wstring& install_location,
    const std::wstring& package_id,
    const std::wstring& canonical_target,
    const std::wstring& expected_package_id);

bool IsUnsafeWindowsInstallRoot(
    const std::wstring& canonical_root,
    const std::vector<std::wstring>& exact_roots,
    const std::vector<std::wstring>& tree_roots);

WindowsPathComponentState ClassifyWindowsPathComponentAttributes(
    std::uint32_t attributes);

bool InstalledIdentityMarkerMatchesJson(
    const std::string& contents,
    const std::wstring& expected_package_id);

}  // namespace native
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_H_
