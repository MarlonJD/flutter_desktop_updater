#include <gtest/gtest.h>

#include <sys/stat.h>
#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <string>

#include "linux_helper_locator.h"

namespace desktop_updater::native::internal {
namespace {

namespace fs = std::filesystem;

void Executable(const fs::path& path) {
  fs::create_directories(path.parent_path());
  std::ofstream(path, std::ios::binary) << "#!/bin/false\n";
  chmod(path.c_str(), 0755);
}

TEST(LinuxHelperLocator, ResolvesPortableBundleLibBeforeSibling) {
  const fs::path root = fs::temp_directory_path() /
                        ("desktop-updater-locator-portable-" +
                         std::to_string(getpid()));
  const fs::path application = root / "app" / "example";
  const fs::path bundled = root / "app" / "lib" /
                           "desktop-updater-helper";
  const fs::path sibling = root / "app" / "desktop-updater-helper";
  Executable(application);
  Executable(bundled);
  Executable(sibling);

  EXPECT_EQ(fs::canonical(bundled), LocatePackagedLinuxHelper(application));
  fs::remove_all(root);
}

TEST(LinuxHelperLocator, ResolvesRelocatedInstalledPrefixFromBin) {
  const fs::path root = fs::temp_directory_path() /
                        ("desktop-updater-locator-prefix-" +
                         std::to_string(getpid()));
  const fs::path application = root / "relocated-sdk" / "bin" / "consumer";
  const fs::path helper = root / "relocated-sdk" / "libexec" /
                          "desktop-updater-helper";
  Executable(application);
  Executable(helper);

  EXPECT_EQ(fs::canonical(helper), LocatePackagedLinuxHelper(application));
  fs::remove_all(root);
}

TEST(LinuxHelperLocator, RejectsSymlinkAndMissingCandidates) {
  const fs::path root = fs::temp_directory_path() /
                        ("desktop-updater-locator-reject-" +
                         std::to_string(getpid()));
  const fs::path application = root / "bin" / "consumer";
  const fs::path attacker = root / "attacker";
  const fs::path helper = root / "libexec" / "desktop-updater-helper";
  Executable(application);
  Executable(attacker);
  fs::create_directories(helper.parent_path());
  ASSERT_EQ(symlink(attacker.c_str(), helper.c_str()), 0);

  EXPECT_THROW(LocatePackagedLinuxHelper(application),
               LinuxHelperLocatorError);
  fs::remove_all(root);
}

}  // namespace
}  // namespace desktop_updater::native::internal
