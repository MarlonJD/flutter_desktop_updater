#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>

#include "desktop_updater_native_c.h"
#include "desktop_updater_version.h"
#include "windows_path_identity.h"

namespace {

constexpr char16_t kTransactionId[] =
    u"00000000-0000-4000-8000-000000000012";
constexpr char16_t kStagingPath[] = u"C:\\staged\\update.exe";
constexpr char16_t kProvenanceDigest[] =
    u"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
constexpr char16_t kArtifactDigest[] =
    u"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
constexpr char16_t kInstallRoot[] = u"C:\\Program Files\\Example";
constexpr char16_t kExecutable[] = u"Example.exe";
constexpr char16_t kPackageId[] = u"com.example.desktop";

const std::uint16_t* U16(const char16_t* value) {
  return reinterpret_cast<const std::uint16_t*>(value);
}

desktop_updater_install_request_abi2 ValidRequest() {
  desktop_updater_install_request_abi2 request{};
  request.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION;
  request.struct_size = sizeof(request);
  request.staging_path = U16(kStagingPath);
  request.expected_provenance_sha256 = U16(kProvenanceDigest);
  request.expected_artifact_sha256 = U16(kArtifactDigest);
  request.install_root = U16(kInstallRoot);
  request.executable_relative_path = U16(kExecutable);
  request.expected_package_id = U16(kPackageId);
  return request;
}

desktop_updater_transaction_status_abi2 EmptyStatus() {
  desktop_updater_transaction_status_abi2 status{};
  status.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION;
  status.struct_size = sizeof(status);
  return status;
}

void Free(desktop_updater_result_abi2* result,
          desktop_updater_transaction_status_abi2* status) {
  desktop_updater_result_free_abi2(result);
  desktop_updater_transaction_status_free_abi2(status);
}

TEST(DesktopUpdaterNativeCAbi2, ReportsVersionAndStableFieldOrder) {
  EXPECT_EQ(desktop_updater_native_abi_version_abi2(),
            DESKTOP_UPDATER_NATIVE_ABI_VERSION);
  EXPECT_EQ(offsetof(desktop_updater_install_request_abi2, abi_version), 0u);
  EXPECT_LT(offsetof(desktop_updater_install_request_abi2, abi_version),
            offsetof(desktop_updater_install_request_abi2, struct_size));
  EXPECT_LT(offsetof(desktop_updater_install_request_abi2, struct_size),
            offsetof(desktop_updater_install_request_abi2, staging_path));
  EXPECT_LT(offsetof(desktop_updater_install_request_abi2, staging_path),
            offsetof(desktop_updater_install_request_abi2,
                     expected_provenance_sha256));
  EXPECT_LT(offsetof(desktop_updater_install_request_abi2,
                     expected_provenance_sha256),
            offsetof(desktop_updater_install_request_abi2,
                     expected_artifact_sha256));
  EXPECT_LT(offsetof(desktop_updater_install_request_abi2,
                     expected_artifact_sha256),
            offsetof(desktop_updater_install_request_abi2, install_root));
  EXPECT_LT(offsetof(desktop_updater_install_request_abi2, install_root),
            offsetof(desktop_updater_install_request_abi2,
                     executable_relative_path));
  EXPECT_LT(offsetof(desktop_updater_install_request_abi2,
                     executable_relative_path),
            offsetof(desktop_updater_install_request_abi2,
                     expected_package_id));
  EXPECT_EQ(offsetof(desktop_updater_result_abi2, abi_version), 0u);
  EXPECT_EQ(offsetof(desktop_updater_transaction_status_abi2, abi_version),
            0u);
}

TEST(WindowsPathIdentity, AcceptsExtendedLengthPrefixForSamePath) {
  const std::filesystem::path configured =
      L"C:\\Program Files\\DesktopUpdaterHelper\\desktop_updater_install_helper.exe";
  const std::filesystem::path endpoint =
      L"\\\\?\\C:\\Program Files\\DesktopUpdaterHelper\\desktop_updater_install_helper.exe";

  EXPECT_TRUE(
      desktop_updater::native::windows_path_identity::PathEquals(configured,
                                                                  endpoint));
  EXPECT_TRUE(desktop_updater::native::windows_path_identity::PathEquals(
      endpoint, L"c:\\Program Files\\DesktopUpdaterHelper\\desktop_updater_install_helper.exe\\"));
  EXPECT_FALSE(desktop_updater::native::windows_path_identity::PathEquals(
      configured,
      L"C:\\Program Files\\DesktopUpdaterHelper\\other.exe"));
}

TEST(WindowsPathIdentity, BuildsExtendedLengthPathForLocalAndUncPaths) {
  using desktop_updater::native::windows_path_identity::ExtendedLengthPath;

  EXPECT_EQ(
      L"\\\\?\\C:\\Users\\burak\\staged\\manifest.json",
      ExtendedLengthPath(L"C:\\Users\\burak\\staged\\manifest.json"));
  EXPECT_EQ(
      L"\\\\?\\UNC\\server\\share\\staged\\manifest.json",
      ExtendedLengthPath(L"\\\\server\\share\\staged\\manifest.json"));
  EXPECT_EQ(
      L"\\\\?\\C:\\Users\\burak\\staged\\manifest.json",
      ExtendedLengthPath(
          L"\\\\?\\C:\\Users\\burak\\staged\\manifest.json"));
}

TEST(DesktopUpdaterNativeCAbi2, NullRequestDoesNotTouchOutputs) {
  auto status = EmptyStatus();
  status.state = 91;
  status.result_code = 92;
  desktop_updater_reservation_handle_abi2* reservation =
      reinterpret_cast<desktop_updater_reservation_handle_abi2*>(0x1234);

  auto result = desktop_updater_prepare_install_abi2(
      nullptr, U16(kTransactionId), &reservation, &status);

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(reservation,
            reinterpret_cast<desktop_updater_reservation_handle_abi2*>(
                0x1234));
  EXPECT_EQ(status.state, 91u);
  EXPECT_EQ(status.result_code, 92u);
  EXPECT_EQ(status.transaction_id_utf8, nullptr);
  EXPECT_NE(result.error_message_utf8, nullptr);
  Free(&result, &status);
}

TEST(DesktopUpdaterNativeCAbi2, Abi1PrefixIsRejectedBeforeLaterRead) {
  auto request = ValidRequest();
  request.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION_1;
  request.staging_path = reinterpret_cast<const std::uint16_t*>(1);
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_abi2* reservation = nullptr;

  auto result = desktop_updater_prepare_install_abi2(
      &request, U16(kTransactionId), &reservation, &status);

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(reservation, nullptr);
  EXPECT_EQ(status.transaction_id_utf8, nullptr);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("ABI version"),
            std::string::npos);
  Free(&result, &status);
}

TEST(DesktopUpdaterNativeCAbi2, TruncatedPrefixIsRejectedBeforeLaterRead) {
  auto request = ValidRequest();
  request.struct_size = offsetof(desktop_updater_install_request_abi2,
                                 staging_path);
  request.staging_path = reinterpret_cast<const std::uint16_t*>(1);
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_abi2* reservation = nullptr;

  auto result = desktop_updater_prepare_install_abi2(
      &request, U16(kTransactionId), &reservation, &status);

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(reservation, nullptr);
  EXPECT_EQ(status.transaction_id_utf8, nullptr);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("truncated"),
            std::string::npos);
  Free(&result, &status);
}

TEST(DesktopUpdaterNativeCAbi2, InvalidUtf16IsRejected) {
  auto request = ValidRequest();
  constexpr std::uint16_t invalid[] = {0xD800, 0};
  request.staging_path = invalid;
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_abi2* reservation = nullptr;

  auto result = desktop_updater_prepare_install_abi2(
      &request, U16(kTransactionId), &reservation, &status);

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(reservation, nullptr);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("UTF-16"),
            std::string::npos);
  Free(&result, &status);
}

TEST(DesktopUpdaterNativeCAbi2, MissingRequestFieldIsRejected) {
  auto request = ValidRequest();
  request.expected_package_id = nullptr;
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_abi2* reservation = nullptr;

  auto result = desktop_updater_prepare_install_abi2(
      &request, U16(kTransactionId), &reservation, &status);

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(reservation, nullptr);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("expected_package_id"),
            std::string::npos);
  Free(&result, &status);
}

TEST(DesktopUpdaterNativeCAbi2, InvalidTransactionIdIsRejected) {
  auto request = ValidRequest();
  constexpr char16_t invalid[] = u"not-a-uuid";
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_abi2* reservation = nullptr;

  auto result = desktop_updater_prepare_install_abi2(
      &request, U16(invalid), &reservation, &status);

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(reservation, nullptr);
  EXPECT_EQ(status.transaction_id_utf8, nullptr);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("UUIDv4"),
            std::string::npos);
  Free(&result, &status);
}

TEST(DesktopUpdaterNativeCAbi2, CleanupIsIdempotent) {
  auto result = desktop_updater_result_abi2{
      DESKTOP_UPDATER_NATIVE_ABI_VERSION,
      sizeof(desktop_updater_result_abi2),
      0,
      nullptr};
  auto status = EmptyStatus();
  desktop_updater_result_free_abi2(&result);
  desktop_updater_result_free_abi2(&result);
  desktop_updater_transaction_status_free_abi2(&status);
  desktop_updater_transaction_status_free_abi2(&status);
  desktop_updater_reservation_release_abi2(nullptr);
  SUCCEED();
}

}  // namespace
