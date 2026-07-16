#ifndef DESKTOP_UPDATER_LINUX_NATIVE_LINUX_HELPER_LOCATOR_H_
#define DESKTOP_UPDATER_LINUX_NATIVE_LINUX_HELPER_LOCATOR_H_

#include <filesystem>
#include <stdexcept>
#include <string>

namespace desktop_updater::native::internal {

class LinuxHelperLocatorError : public std::runtime_error {
 public:
  explicit LinuxHelperLocatorError(const std::string& detail)
      : std::runtime_error(detail) {}
};

// Resolves only package-owned layouts relative to the retained running
// executable: Flutter bundle lib/, a sibling helper, or <prefix>/bin paired
// with <prefix>/libexec. Environment/PATH lookups are deliberately excluded.
std::filesystem::path LocatePackagedLinuxHelper(
    const std::filesystem::path& current_executable);

}  // namespace desktop_updater::native::internal

#endif  // DESKTOP_UPDATER_LINUX_NATIVE_LINUX_HELPER_LOCATOR_H_
