#pragma once

#include <string>
#include <vector>

namespace desktop_updater_native {

enum class ProductVersionBuildParseResult {
  kBuildNumber,
  kNoBuildNumber,
  kInvalid,
};

struct InstallRequest {
  std::wstring staging_path;
  std::vector<std::wstring> removed_files;
  std::wstring diagnostics_log_path;
  bool request_elevation_if_needed = true;
};

struct InstallResult {
  bool ok;
  std::string error;
};

std::wstring Utf8ToWide(const std::string& value);

std::string WideToUtf8(const std::wstring& value);

std::wstring CurrentExecutablePath();

bool ReadCurrentProductVersion(std::wstring* product_version,
                               std::string* error);

ProductVersionBuildParseResult ParseProductVersionBuildNumber(
    const std::wstring& product_version,
    std::wstring* build_number);

bool IsStrictChildPathForTesting(const std::wstring& root,
                                 const std::wstring& candidate);

bool IsKnownProtectedInstallDirectoryForTesting(
    const std::wstring& directory,
    const std::vector<std::wstring>& protected_roots);

bool IsInstallerOwnedWindowsFileForTesting(const std::wstring& file_name);

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request);

}  // namespace desktop_updater_native
