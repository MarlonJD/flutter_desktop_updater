#include <gtest/gtest.h>
#include <windows.h>

#include <string>
#include <vector>

#include "desktop_updater_native.h"
#include "desktop_updater_native_c.h"

namespace desktop_updater_native {
namespace test {

TEST(DesktopUpdaterNative, ProductVersionBuildNumberWithMetadata) {
  std::wstring build_number;

  EXPECT_EQ(ParseProductVersionBuildNumber(L"1.2.3+4", &build_number),
            ProductVersionBuildParseResult::kBuildNumber);
  EXPECT_EQ(build_number, L"4");
}

TEST(DesktopUpdaterNative, ProductVersionBuildNumberMissingIsValid) {
  std::wstring build_number;

  EXPECT_EQ(ParseProductVersionBuildNumber(L"1.2.3", &build_number),
            ProductVersionBuildParseResult::kNoBuildNumber);
  EXPECT_TRUE(build_number.empty());
}

TEST(DesktopUpdaterNative, ProductVersionBuildNumberRejectsEmptyMetadata) {
  std::wstring build_number;

  EXPECT_EQ(ParseProductVersionBuildNumber(L"1.2.3+", &build_number),
            ProductVersionBuildParseResult::kInvalid);
}

TEST(DesktopUpdaterNative, RemovedFileMustBeStrictChildPath) {
  EXPECT_TRUE(IsStrictChildPathForTesting(L"C:\\App", L"C:\\App\\data.txt"));
  EXPECT_FALSE(IsStrictChildPathForTesting(L"C:\\App", L"C:\\App"));
  EXPECT_FALSE(IsStrictChildPathForTesting(L"C:\\App", L"C:\\Other\\data.txt"));
}

TEST(DesktopUpdaterNative, InnoUninstallArtifactsAreInstallerOwnedFiles) {
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(L"unins000.exe"));
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(L"unins000.dat"));
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(L"unins000.msg"));
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(L"UNINS001.EXE"));
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(
      L"C:\\Program Files\\Example\\unins002.dat"));

  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"unins.exe"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"unins00.exe"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"unins000.tmp"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"uninstall.exe"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"example.exe"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L""));
}

TEST(DesktopUpdaterNative, ProgramFilesInstallDirectoryIsProtected) {
  const std::vector<std::wstring> protected_roots = {
      L"C:\\Program Files",
      L"C:\\Program Files (x86)",
  };

  EXPECT_TRUE(IsKnownProtectedInstallDirectoryForTesting(
      L"C:\\Program Files\\egas-manager", protected_roots));
  EXPECT_TRUE(IsKnownProtectedInstallDirectoryForTesting(
      L"C:\\Program Files (x86)\\egas-manager", protected_roots));
  EXPECT_TRUE(IsKnownProtectedInstallDirectoryForTesting(
      L"C:\\Program Files", protected_roots));
  EXPECT_FALSE(IsKnownProtectedInstallDirectoryForTesting(
      L"C:\\Users\\alex\\AppData\\Local\\egas-manager", protected_roots));
  EXPECT_FALSE(IsKnownProtectedInstallDirectoryForTesting(
      L"C:\\Program Files Backup\\egas-manager", protected_roots));
}

TEST(DesktopUpdaterNativeCAbi, NullRequestFailsWithoutThrowing) {
  desktop_updater_result result =
      desktop_updater_schedule_install_and_relaunch(nullptr);

  EXPECT_EQ(result.ok, 0);
  ASSERT_NE(result.error_message, nullptr);
  desktop_updater_result_free(result);
}

}  // namespace test
}  // namespace desktop_updater_native
