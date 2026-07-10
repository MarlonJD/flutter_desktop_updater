#ifndef DESKTOP_UPDATER_NATIVE_H_
#define DESKTOP_UPDATER_NATIVE_H_

#include <string>
#include <vector>

namespace desktop_updater {
namespace native {

struct InstallRequest {
  std::wstring staging_path;
  std::vector<std::wstring> removed_files;
  std::wstring diagnostics_log_path;
  std::wstring expected_provenance_sha256;
  std::wstring expected_artifact_sha256;
  std::vector<std::wstring> allowed_signer_thumbprints;
  bool request_elevation_if_needed = true;
};

struct InstallResult {
  bool ok;
  std::string error_message;
};

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request);

bool IsStrictChildPath(const std::wstring& root,
                       const std::wstring& candidate);

bool IsKnownProtectedInstallDirectory(
    const std::wstring& directory,
    const std::vector<std::wstring>& protected_roots);

bool IsInstallerOwnedWindowsFile(const std::wstring& file_name);

}  // namespace native
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_H_
