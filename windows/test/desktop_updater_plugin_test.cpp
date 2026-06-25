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
  EXPECT_TRUE(IsStrictChildPathForTesting(L"C:\\App", L"C:\\App\\data.txt"));
  EXPECT_FALSE(IsStrictChildPathForTesting(L"C:\\App", L"C:\\App"));
  EXPECT_FALSE(IsStrictChildPathForTesting(L"C:\\App", L"C:\\Other\\data.txt"));
}

TEST(DesktopUpdaterPlugin, ProgramFilesInstallDirectoryIsProtected) {
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
