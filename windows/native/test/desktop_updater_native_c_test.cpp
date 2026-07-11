#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "desktop_updater_native.h"
#include "desktop_updater_native_c.h"
#include "desktop_updater_native_c_internal.h"

namespace desktop_updater {
namespace native {
namespace test {
namespace {

desktop_updater_install_request_v1 ValidRequest() {
  desktop_updater_install_request_v1 request = {};
  request.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION;
  request.struct_size = sizeof(request);
  return request;
}

TEST(DesktopUpdaterNativeCAbi, AbiLayoutMatchesDeclaredFieldOrder) {
  EXPECT_EQ(offsetof(desktop_updater_install_request_v1, abi_version), 0u);
  EXPECT_LT(offsetof(desktop_updater_install_request_v1, abi_version),
            offsetof(desktop_updater_install_request_v1, struct_size));
  EXPECT_LT(offsetof(desktop_updater_install_request_v1, struct_size),
            offsetof(desktop_updater_install_request_v1, staging_path));
  EXPECT_LT(offsetof(desktop_updater_install_request_v1, staging_path),
            offsetof(desktop_updater_install_request_v1, diagnostics_log_path));
  EXPECT_LT(offsetof(desktop_updater_install_request_v1, diagnostics_log_path),
            offsetof(desktop_updater_install_request_v1, removed_files));
  EXPECT_LT(offsetof(desktop_updater_install_request_v1, removed_files),
            offsetof(desktop_updater_install_request_v1, removed_file_count));
  EXPECT_LT(
      offsetof(desktop_updater_install_request_v1,
               allowed_signer_thumbprint_count),
      offsetof(desktop_updater_install_request_v1, install_root));
  EXPECT_LT(offsetof(desktop_updater_install_request_v1, install_root),
            offsetof(desktop_updater_install_request_v1,
                     executable_relative_path));
  EXPECT_LT(offsetof(desktop_updater_install_request_v1,
                     executable_relative_path),
            offsetof(desktop_updater_install_request_v1,
                     expected_package_id));
  EXPECT_LE(offsetof(desktop_updater_install_request_v1,
                     expected_package_id) +
                sizeof(const uint16_t*),
            sizeof(desktop_updater_install_request_v1));
}

TEST(DesktopUpdaterNativeCAbi, NullRequest) {
  desktop_updater_result_v1 result =
      desktop_updater_schedule_install_and_relaunch_v1(nullptr);

  EXPECT_EQ(result.ok, 0);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("must not be null"),
            std::string::npos);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, WrongAbiVersion) {
  auto request = ValidRequest();
  request.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION + 1;

  auto result = desktop_updater_schedule_install_and_relaunch_v1(&request);

  EXPECT_EQ(result.ok, 0);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("ABI version"),
            std::string::npos);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, UndersizedStruct) {
  auto request = ValidRequest();
  request.struct_size = offsetof(desktop_updater_install_request_v1,
                                 removed_file_count);

  auto result = desktop_updater_schedule_install_and_relaunch_v1(&request);

  EXPECT_EQ(result.ok, 0);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("undersized"),
            std::string::npos);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, InvalidUtf16) {
  auto request = ValidRequest();
  const uint16_t invalid[] = {0xD800, 0};
  request.staging_path = invalid;

  auto result = desktop_updater_schedule_install_and_relaunch_v1(&request);

  EXPECT_EQ(result.ok, 0);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("invalid UTF-16"),
            std::string::npos);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, IncompleteStagedHandoffFailsBeforeScheduler) {
  auto request = ValidRequest();
  const uint16_t staging[] = {'C', ':', '\\', 's', 't', 'a', 'g', 'e', 0};
  request.staging_path = staging;
  bool scheduler_called = false;

  auto result = internal::ScheduleInstallAndRelaunchWith(
      &request, [&scheduler_called](const InstallRequest&) {
        scheduler_called = true;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 0);
  EXPECT_FALSE(scheduler_called);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("verified provenance"),
            std::string::npos);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, RemovedFilesReachNativeRequest) {
  auto request = ValidRequest();
  const uint16_t first[] = {'o', 'l', 'd', '.', 'd', 'l', 'l', 0};
  const uint16_t second[] = {'d', 'a', 't', 'a', '/', 'o', 'l', 'd', 0};
  const uint16_t* removed[] = {first, second};
  request.removed_files = removed;
  request.removed_file_count = 2;
  std::vector<std::wstring> captured;

  auto result = internal::ScheduleInstallAndRelaunchWith(
      &request, [&captured](const InstallRequest& parsed) {
        captured = parsed.removed_files;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 1);
  ASSERT_EQ(captured.size(), 2u);
  EXPECT_EQ(captured[0], L"old.dll");
  EXPECT_EQ(captured[1], L"data/old");
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, LegacySizeDoesNotReadAppendedTargetContext) {
  auto request = ValidRequest();
  request.struct_size =
      offsetof(desktop_updater_install_request_v1, install_root);
  InstallRequest captured;

  auto result = internal::ScheduleInstallAndRelaunchWith(
      &request, [&captured](const InstallRequest& parsed) {
        captured = parsed;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 1);
  EXPECT_TRUE(captured.install_root.empty());
  EXPECT_TRUE(captured.executable_relative_path.empty());
  EXPECT_TRUE(captured.expected_package_id.empty());
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, TargetProofContextReachesNativeRequest) {
  auto request = ValidRequest();
  const uint16_t install_root[] = {'C', ':', '\\', 'A', 'p', 'p', 0};
  const uint16_t executable[] = {'E', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'e', 'x', 'e', 0};
  const uint16_t package_id[] = {'c', 'o', 'm', '.', 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0};
  request.install_root = install_root;
  request.executable_relative_path = executable;
  request.expected_package_id = package_id;
  InstallRequest captured;

  auto result = internal::ScheduleInstallAndRelaunchWith(
      &request, [&captured](const InstallRequest& parsed) {
        captured = parsed;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 1);
  EXPECT_EQ(captured.install_root, L"C:\\App");
  EXPECT_EQ(captured.executable_relative_path, L"Example.exe");
  EXPECT_EQ(captured.expected_package_id, L"com.example");
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, ThrownInternalException) {
  auto request = ValidRequest();

  auto result = internal::ScheduleInstallAndRelaunchWith(
      &request, [](const InstallRequest&) -> InstallResult {
        throw std::runtime_error("injected native failure");
      });

  EXPECT_EQ(result.ok, 0);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_STREQ(result.error_message_utf8, "injected native failure");
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, RepeatedFreeIsSafe) {
  auto request = ValidRequest();
  request.abi_version = 99;
  auto result = desktop_updater_schedule_install_and_relaunch_v1(&request);
  ASSERT_NE(result.error_message_utf8, nullptr);

  desktop_updater_result_free_v1(&result);
  desktop_updater_result_free_v1(&result);

  EXPECT_EQ(result.abi_version, 0u);
  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(result.error_message_utf8, nullptr);
}

}  // namespace
}  // namespace test
}  // namespace native
}  // namespace desktop_updater
