#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_AUTHENTICODE_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_AUTHENTICODE_H_

#include <array>
#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>

#include "helper_policy_windows.h"

namespace desktop_updater::helper {

struct VerifiedWindowsExecutable {
  bool signature_valid;
  std::wstring publisher;
  std::string sha256;
  std::filesystem::path final_path;
  bool installer_protected_location;
  std::uint64_t volume_serial;
  std::array<unsigned char, 16> file_id;
};

class WindowsHelperTrustError : public std::runtime_error {
 public:
  explicit WindowsHelperTrustError(const std::string& detail)
      : std::runtime_error(detail) {}
};

VerifiedWindowsExecutable VerifyWindowsExecutable(
    const std::filesystem::path& path);

void ValidateWindowsHelperIdentity(const VerifiedWindowsExecutable& identity,
                                   const WindowsHelperPolicy& policy,
                                   bool require_protected_location);

bool VerifyWindowsExecutableStillMatches(
    const std::filesystem::path& path,
    const VerifiedWindowsExecutable& identity);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_AUTHENTICODE_H_
