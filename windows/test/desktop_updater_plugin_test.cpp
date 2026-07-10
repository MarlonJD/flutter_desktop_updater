#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>
#include <vector>

#include "desktop_updater_plugin.h"
#include "desktop_updater_native.h"

namespace desktop_updater {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(DesktopUpdaterPlugin, ProductVersionBuildNumberWithMetadata) {
  std::wstring build_number;

  EXPECT_EQ(ParseProductVersionBuildNumber(L"1.2.3+4", &build_number),
            ProductVersionBuildParseResult::kBuildNumber);
  EXPECT_EQ(build_number, L"4");
}

TEST(DesktopUpdaterPlugin, ProductVersionBuildNumberMissingIsValid) {
  std::wstring build_number;

  EXPECT_EQ(ParseProductVersionBuildNumber(L"1.2.3", &build_number),
            ProductVersionBuildParseResult::kNoBuildNumber);
  EXPECT_TRUE(build_number.empty());
}

TEST(DesktopUpdaterPlugin, ProductVersionBuildNumberRejectsEmptyMetadata) {
  std::wstring build_number;

  EXPECT_EQ(ParseProductVersionBuildNumber(L"1.2.3+", &build_number),
            ProductVersionBuildParseResult::kInvalid);
}

TEST(DesktopUpdaterPlugin, RemovedFileMustBeStrictChildPath) {
  EXPECT_TRUE(native::IsStrictChildPath(L"C:\\App", L"C:\\App\\data.txt"));
  EXPECT_FALSE(native::IsStrictChildPath(L"C:\\App", L"C:\\App"));
  EXPECT_FALSE(
      native::IsStrictChildPath(L"C:\\App", L"C:\\Other\\data.txt"));
}

TEST(DesktopUpdaterPlugin, InnoUninstallArtifactsAreInstallerOwnedFiles) {
  EXPECT_TRUE(native::IsInstallerOwnedWindowsFile(L"unins000.exe"));
  EXPECT_TRUE(native::IsInstallerOwnedWindowsFile(L"unins000.dat"));
  EXPECT_TRUE(native::IsInstallerOwnedWindowsFile(L"unins000.msg"));
  EXPECT_TRUE(native::IsInstallerOwnedWindowsFile(L"UNINS001.EXE"));
  EXPECT_TRUE(native::IsInstallerOwnedWindowsFile(
      L"C:\\Program Files\\Example\\unins002.dat"));

  EXPECT_FALSE(native::IsInstallerOwnedWindowsFile(L"unins.exe"));
  EXPECT_FALSE(native::IsInstallerOwnedWindowsFile(L"unins00.exe"));
  EXPECT_FALSE(native::IsInstallerOwnedWindowsFile(L"unins000.tmp"));
  EXPECT_FALSE(native::IsInstallerOwnedWindowsFile(L"uninstall.exe"));
  EXPECT_FALSE(native::IsInstallerOwnedWindowsFile(L"example.exe"));
  EXPECT_FALSE(native::IsInstallerOwnedWindowsFile(L""));
}

TEST(DesktopUpdaterPlugin, ProgramFilesInstallDirectoryIsProtected) {
  const std::vector<std::wstring> protected_roots = {
      L"C:\\Program Files",
      L"C:\\Program Files (x86)",
  };

  EXPECT_TRUE(native::IsKnownProtectedInstallDirectory(
      L"C:\\Program Files\\egas-manager", protected_roots));
  EXPECT_TRUE(native::IsKnownProtectedInstallDirectory(
      L"C:\\Program Files (x86)\\egas-manager", protected_roots));
  EXPECT_TRUE(native::IsKnownProtectedInstallDirectory(
      L"C:\\Program Files", protected_roots));
  EXPECT_FALSE(native::IsKnownProtectedInstallDirectory(
      L"C:\\Users\\alex\\AppData\\Local\\egas-manager", protected_roots));
  EXPECT_FALSE(native::IsKnownProtectedInstallDirectory(
      L"C:\\Program Files Backup\\egas-manager", protected_roots));
}

TEST(DesktopUpdaterPlugin, ProgramFilesTargetRequiresMatchingInstalledIdentity) {
  EXPECT_TRUE(native::RegistryRecordMatchesInstallTarget(
      L"C:\\Program Files\\Example", L"com.example.app",
      L"C:\\Program Files\\Example", L"com.example.app"));
  EXPECT_FALSE(native::RegistryRecordMatchesInstallTarget(
      L"C:\\Program Files\\Other", L"com.example.app",
      L"C:\\Program Files\\Example", L"com.example.app"));
  EXPECT_FALSE(native::RegistryRecordMatchesInstallTarget(
      L"C:\\Program Files\\Example", L"com.example.other",
      L"C:\\Program Files\\Example", L"com.example.app"));
}

TEST(DesktopUpdaterPlugin, GetPlatformVersion) {
  DesktopUpdaterPlugin plugin;
  // Save the reply value from the success callback.
  std::string result_string;
  plugin.HandleMethodCall(
      MethodCall("getPlatformVersion", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&result_string](const EncodableValue* result) {
            result_string = std::get<std::string>(*result);
          },
          nullptr, nullptr));

  // Since the exact string varies by host, just ensure that it's a string
  // with the expected format.
  EXPECT_TRUE(result_string.rfind("Windows ", 0) == 0);
}

}  // namespace test
}  // namespace desktop_updater
