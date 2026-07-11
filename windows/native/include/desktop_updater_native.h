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
