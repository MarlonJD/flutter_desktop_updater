#include "linux_helper_locator.h"

#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <filesystem>
#include <string>

namespace desktop_updater::native::internal {
namespace {

namespace fs = std::filesystem;

bool IsTrustedOwner(uid_t uid) { return uid == 0 || uid == geteuid(); }

bool IsUsableHelper(const fs::path& candidate) {
  struct stat parent {};
  struct stat before {};
  if (lstat(candidate.parent_path().c_str(), &parent) != 0 ||
      !S_ISDIR(parent.st_mode) || S_ISLNK(parent.st_mode) ||
      !IsTrustedOwner(parent.st_uid) ||
      (parent.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
      lstat(candidate.c_str(), &before) != 0 || !S_ISREG(before.st_mode) ||
      S_ISLNK(before.st_mode) || before.st_nlink != 1 ||
      !IsTrustedOwner(before.st_uid) ||
      (before.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
      (before.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0) {
    return false;
  }
  std::error_code error;
  const fs::path canonical = fs::canonical(candidate, error);
  return !error && canonical == candidate.lexically_normal();
}

}  // namespace

fs::path LocatePackagedLinuxHelper(const fs::path& current_executable) {
  if (!current_executable.is_absolute() ||
      current_executable.lexically_normal() != current_executable) {
    throw LinuxHelperLocatorError("running executable locator rejected");
  }
  std::error_code error;
  const fs::path canonical_executable =
      fs::canonical(current_executable, error);
  if (error || canonical_executable != current_executable) {
    throw LinuxHelperLocatorError("running executable identity rejected");
  }
  const fs::path executable_directory = current_executable.parent_path();
  std::array<fs::path, 3> candidates = {
      executable_directory / "lib" / "desktop-updater-helper",
      executable_directory / "desktop-updater-helper",
      executable_directory.parent_path() / "libexec" /
          "desktop-updater-helper"};
  const std::size_t count = executable_directory.filename() == "bin" ? 3 : 2;
  for (std::size_t index = 0; index < count; ++index) {
    const fs::path candidate = candidates[index].lexically_normal();
    if (IsUsableHelper(candidate)) return fs::canonical(candidate);
  }
  throw LinuxHelperLocatorError(
      "packaged Linux install helper is unavailable");
}

}  // namespace desktop_updater::native::internal
