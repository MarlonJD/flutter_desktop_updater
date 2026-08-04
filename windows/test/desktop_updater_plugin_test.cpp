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

TEST(DesktopUpdaterPlugin, InstallTransactionIdIsCanonicalUuidV4) {
  EXPECT_TRUE(IsCanonicalInstallTransactionId(
      "123e4567-e89b-42d3-a456-426614174000"));
  EXPECT_FALSE(IsCanonicalInstallTransactionId(""));
  EXPECT_FALSE(IsCanonicalInstallTransactionId(
      "123E4567-E89B-42D3-A456-426614174000"));
  EXPECT_FALSE(IsCanonicalInstallTransactionId(
      "123e4567-e89b-12d3-a456-426614174000"));
  EXPECT_FALSE(IsCanonicalInstallTransactionId(
      "123e4567-e89b-42d3-c456-426614174000"));
}

TEST(DesktopUpdaterPlugin, InstallRequestContainsOnlyVerifiedPayloadFields) {
  native::InstallRequest request = {
      L"C:\\stage",
      L"C:\\app",
      L"bin\\example.exe",
      L"com.example.app",
      {},
      L"provenance",
      L"artifact",
  };

  EXPECT_EQ(L"C:\\stage", request.staging_path);
  EXPECT_EQ(L"C:\\app", request.install_root);
  EXPECT_EQ(L"bin\\example.exe", request.executable_relative_path);
  EXPECT_EQ(L"provenance", request.expected_provenance_sha256);
  EXPECT_EQ(L"artifact", request.expected_artifact_sha256);
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

TEST(DesktopUpdaterPlugin, PathComponentAttributesFailClosed) {
  EXPECT_EQ(native::ClassifyWindowsPathComponentAttributes(
                INVALID_FILE_ATTRIBUTES),
            native::WindowsPathComponentState::kUnavailable);
  EXPECT_EQ(native::ClassifyWindowsPathComponentAttributes(
                FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT),
            native::WindowsPathComponentState::kReparsePoint);
  EXPECT_EQ(native::ClassifyWindowsPathComponentAttributes(
                FILE_ATTRIBUTE_DIRECTORY),
            native::WindowsPathComponentState::kSafe);
}

TEST(DesktopUpdaterPlugin, AncestorReparseComponentFailsClosed) {
  const std::vector<DWORD> component_attributes = {
      FILE_ATTRIBUTE_DIRECTORY,
      FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT,
      FILE_ATTRIBUTE_DIRECTORY,
  };
  native::WindowsPathComponentState state =
      native::WindowsPathComponentState::kSafe;
  for (const DWORD attributes : component_attributes) {
    state = native::ClassifyWindowsPathComponentAttributes(attributes);
    if (state != native::WindowsPathComponentState::kSafe) {
      break;
    }
  }
  EXPECT_EQ(state, native::WindowsPathComponentState::kReparsePoint);
}

TEST(DesktopUpdaterPlugin, UnsafeInstallRootsUseComponentBoundaries) {
  const std::vector<std::wstring> exact_roots = {
      L"C:\\Program Files", L"C:\\Users", L"C:\\Users\\alex",
      L"C:\\Users\\alex\\bin", L"C:\\Users\\alex\\.local\\bin",
      L"C:\\Users\\alex\\Desktop", L"C:\\Users\\alex\\Downloads"};
  const std::vector<std::wstring> tree_roots = {
      L"C:\\ProgramData", L"C:\\Users\\Public", L"C:\\Windows",
      L"C:\\Windows\\System32", L"C:\\Temp"};

  EXPECT_TRUE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\", exact_roots, tree_roots));
  for (const std::wstring& root : exact_roots) {
    EXPECT_TRUE(native::IsUnsafeWindowsInstallRoot(
        root, exact_roots, tree_roots)) << root;
  }
  EXPECT_TRUE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\Windows\\SystemApps\\Example", exact_roots, tree_roots));
  EXPECT_TRUE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\Temp\\Example", exact_roots, tree_roots));
  EXPECT_TRUE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\ProgramData\\Example", exact_roots, tree_roots));
  EXPECT_TRUE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\Users\\Public\\Example", exact_roots, tree_roots));

  EXPECT_FALSE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\Program Files\\Example", exact_roots, tree_roots));
  EXPECT_FALSE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\Users\\alex\\AppData\\Local\\Programs\\Example",
      exact_roots, tree_roots));
  EXPECT_FALSE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\Windows Backup\\Example", exact_roots, tree_roots));
  EXPECT_FALSE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\Temp Backup\\Example", exact_roots, tree_roots));
  EXPECT_FALSE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\ProgramData Backup\\Example", exact_roots, tree_roots));
  EXPECT_FALSE(native::IsUnsafeWindowsInstallRoot(
      L"C:\\Users\\Publicity\\Example", exact_roots, tree_roots));
}

TEST(DesktopUpdaterPlugin, InstalledIdentityJsonDecodesPublisherEscapes) {
  std::wstring package_id = L"quote\" slash\\ controls\b\f\n\r\t";
  package_id.push_back(static_cast<wchar_t>(0));
  package_id.push_back(static_cast<wchar_t>(1));
  package_id += L" unicode \u263a";
  const std::string marker =
      "{\"schemaVersion\":1,\"packageId\":"
      "\"quote\\\" slash\\\\ controls\\b\\f\\n\\r\\t\\u0000\\u0001 "
      "unicode \\u263a\"}";

  EXPECT_TRUE(native::InstalledIdentityMarkerMatchesJson(marker, package_id));
  EXPECT_FALSE(native::InstalledIdentityMarkerMatchesJson(
      marker, L"com.example.other"));
  EXPECT_FALSE(native::InstalledIdentityMarkerMatchesJson(
      "{\"packageId\":\"com.example\",\"schemaVersion\":1,\"extra\":1}",
      L"com.example"));
  EXPECT_FALSE(native::InstalledIdentityMarkerMatchesJson(
      std::string(70 * 1024, ' '), L"com.example"));
}

TEST(DesktopUpdaterPlugin, AcceptsOnlyProofBoundNativeCommit) {
  native::InstallReservation reservation = {
      "123e4567-e89b-42d3-a456-426614174000", "ready-token",
      std::string(64, 'a'), std::string(64, 'b'), 1};
  native::InstallTransactionStatus accepted = {
      reservation.transaction_id,
      native::InstallTransactionState::kCommitAccepted,
      native::InstallTransactionResultCode::kAccepted,
      "Install accepted.", reservation.response_digest_sha256,
      reservation.helper_endpoint_identity_sha256};

  EXPECT_TRUE(IsAcceptedInstallHandoff(reservation, accepted));
  accepted.helper_endpoint_identity_sha256 = std::string(64, 'c');
  EXPECT_FALSE(IsAcceptedInstallHandoff(reservation, accepted));
  accepted.helper_endpoint_identity_sha256 =
      reservation.helper_endpoint_identity_sha256;
  accepted.result_code = native::InstallTransactionResultCode::kRejected;
  EXPECT_FALSE(IsAcceptedInstallHandoff(reservation, accepted));
}

TEST(DesktopUpdaterPlugin, MalformedRestartWorkerHandoffFailsClosed) {
  SetEnvironmentVariableW(L"DESKTOP_UPDATER_RESTART_PARENT_HANDLE",
                          L"not-a-handle");
  SetEnvironmentVariableW(L"DESKTOP_UPDATER_RESTART_READY_HANDLE", L"1");

  EXPECT_FALSE(native::AwaitRestartParentExitIfRequested());
  EXPECT_EQ(GetEnvironmentVariableW(
                L"DESKTOP_UPDATER_RESTART_PARENT_HANDLE", nullptr, 0),
            0u);
  EXPECT_EQ(GetEnvironmentVariableW(
                L"DESKTOP_UPDATER_RESTART_READY_HANDLE", nullptr, 0),
            0u);
}

TEST(DesktopUpdaterPlugin, EmptyRestartWorkerHandoffFailsClosed) {
  SetEnvironmentVariableW(L"DESKTOP_UPDATER_RESTART_PARENT_HANDLE", L"");
  SetEnvironmentVariableW(L"DESKTOP_UPDATER_RESTART_READY_HANDLE", L"");

  EXPECT_FALSE(native::AwaitRestartParentExitIfRequested());
  EXPECT_EQ(GetEnvironmentVariableW(
                L"DESKTOP_UPDATER_RESTART_PARENT_HANDLE", nullptr, 0),
            0u);
  EXPECT_EQ(GetEnvironmentVariableW(
                L"DESKTOP_UPDATER_RESTART_READY_HANDLE", nullptr, 0),
            0u);
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
