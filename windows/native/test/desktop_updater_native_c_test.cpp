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

desktop_updater_transaction_status_v1 EmptyStatus() {
  desktop_updater_transaction_status_v1 status = {};
  status.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION;
  status.struct_size = sizeof(status);
  return status;
}

constexpr std::uint16_t kTransactionId[] = {
    '1', '2', '3', 'e', '4', '5', '6', '7', '-', 'e', '8', '9', 'b', '-',
    '4', '2', 'd', '3', '-', 'a', '4', '5', '6', '-', '4', '2', '6', '6',
    '1', '4', '1', '7', '4', '0', '0', '0', 0};

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
  EXPECT_LT(offsetof(desktop_updater_install_request_v1, expected_package_id),
            offsetof(desktop_updater_install_request_v1, elevation_policy));
  EXPECT_LE(offsetof(desktop_updater_install_request_v1, elevation_policy) +
                sizeof(uint32_t),
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

TEST(DesktopUpdaterNativeCAbi, ElevationPolicyReachesNativeRequest) {
  auto request = ValidRequest();
  request.elevation_policy = DESKTOP_UPDATER_INSTALL_ELEVATION_NEVER;
  InstallRequest captured;

  auto result = internal::ScheduleInstallAndRelaunchWith(
      &request, [&captured](const InstallRequest& parsed) {
        captured = parsed;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 1);
  EXPECT_EQ(captured.elevation_policy, InstallElevationPolicy::kNever);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, InvalidElevationPolicyFailsBeforeScheduler) {
  auto request = ValidRequest();
  request.elevation_policy = 99;
  bool scheduler_called = false;

  auto result = internal::ScheduleInstallAndRelaunchWith(
      &request, [&scheduler_called](const InstallRequest&) {
        scheduler_called = true;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 0);
  EXPECT_FALSE(scheduler_called);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("elevation policy"),
            std::string::npos);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, NeverElevationRejectsUnwritableTarget) {
  EXPECT_EQ(ResolveInstallLaunchDecision(InstallElevationPolicy::kNever,
                                         true, false, false),
            InstallLaunchDecision::kReject);
  EXPECT_EQ(ResolveInstallLaunchDecision(InstallElevationPolicy::kAlways,
                                         false, true, false),
            InstallLaunchDecision::kElevated);
  EXPECT_EQ(ResolveInstallLaunchDecision(InstallElevationPolicy::kAuto,
                                         false, true, false),
            InstallLaunchDecision::kNormal);
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

TEST(DesktopUpdaterNativeCAbi, PrepareV2PropagatesExactTransactionId) {
  auto request = ValidRequest();
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_v1* reservation = nullptr;
  std::uint32_t outcome = 99;
  std::string captured_transaction_id;

  auto result = internal::PrepareInstallV2With(
      &request, kTransactionId, &reservation, &status, &outcome,
      [&captured_transaction_id](const InstallRequest&,
                                 const std::string& transaction_id,
                                 InstallReservation* prepared,
                                 bool* recovery_required) {
        captured_transaction_id = transaction_id;
        *prepared = {transaction_id, "ready-token", std::string(64, 'a'),
                     std::string(64, 'b'), 123};
        *recovery_required = false;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 1);
  EXPECT_EQ(outcome, DESKTOP_UPDATER_PREPARE_OUTCOME_PREPARED);
  EXPECT_EQ(captured_transaction_id,
            "123e4567-e89b-42d3-a456-426614174000");
  ASSERT_NE(reservation, nullptr);
  ASSERT_NE(status.transaction_id_utf8, nullptr);
  EXPECT_STREQ(status.transaction_id_utf8,
               "123e4567-e89b-42d3-a456-426614174000");
  EXPECT_EQ(status.state, DESKTOP_UPDATER_TRANSACTION_PREPARED);
  EXPECT_EQ(status.result_code, DESKTOP_UPDATER_TRANSACTION_RESULT_ACCEPTED);

  desktop_updater_reservation_release_v1(reservation);
  desktop_updater_transaction_status_free_v1(&status);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, PrepareV2ReportsAmbiguousHandoff) {
  auto request = ValidRequest();
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_v1* reservation = nullptr;
  std::uint32_t outcome = 99;

  auto result = internal::PrepareInstallV2With(
      &request, kTransactionId, &reservation, &status, &outcome,
      [](const InstallRequest&, const std::string&, InstallReservation*,
         bool* recovery_required) {
        *recovery_required = true;
        return InstallResult{false, "Commit acknowledgement was lost."};
      });

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(outcome, DESKTOP_UPDATER_PREPARE_OUTCOME_RECOVERY_REQUIRED);
  EXPECT_EQ(reservation, nullptr);
  ASSERT_NE(status.transaction_id_utf8, nullptr);
  EXPECT_STREQ(status.transaction_id_utf8,
               "123e4567-e89b-42d3-a456-426614174000");
  EXPECT_EQ(status.state, DESKTOP_UPDATER_TRANSACTION_UNKNOWN);
  EXPECT_EQ(status.result_code,
            DESKTOP_UPDATER_TRANSACTION_RESULT_RECOVERY_REQUIRED);

  desktop_updater_transaction_status_free_v1(&status);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, PrepareV2ReportsDefiniteRejection) {
  auto request = ValidRequest();
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_v1* reservation = nullptr;
  std::uint32_t outcome = 99;

  auto result = internal::PrepareInstallV2With(
      &request, kTransactionId, &reservation, &status, &outcome,
      [](const InstallRequest&, const std::string&, InstallReservation*,
         bool* recovery_required) {
        *recovery_required = false;
        return InstallResult{false, "Request was rejected before launch."};
      });

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(outcome, DESKTOP_UPDATER_PREPARE_OUTCOME_REJECTED);
  EXPECT_EQ(reservation, nullptr);
  EXPECT_EQ(status.result_code, DESKTOP_UPDATER_TRANSACTION_RESULT_REJECTED);

  desktop_updater_transaction_status_free_v1(&status);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, PrepareV2RejectsChangedTransactionBinding) {
  auto request = ValidRequest();
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_v1* reservation = nullptr;
  std::uint32_t outcome = 99;

  auto result = internal::PrepareInstallV2With(
      &request, kTransactionId, &reservation, &status, &outcome,
      [](const InstallRequest&, const std::string&, InstallReservation* prepared,
         bool* recovery_required) {
        *prepared = {"223e4567-e89b-42d3-a456-426614174000", "ready-token",
                     std::string(64, 'a'), std::string(64, 'b'), 123};
        *recovery_required = false;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(outcome, DESKTOP_UPDATER_PREPARE_OUTCOME_RECOVERY_REQUIRED);
  EXPECT_EQ(reservation, nullptr);
  EXPECT_EQ(status.result_code,
            DESKTOP_UPDATER_TRANSACTION_RESULT_RECOVERY_REQUIRED);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("binding"),
            std::string::npos);

  desktop_updater_transaction_status_free_v1(&status);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, PrepareV2RejectsInvalidIdBeforeHandoff) {
  auto request = ValidRequest();
  auto status = EmptyStatus();
  desktop_updater_reservation_handle_v1* reservation = nullptr;
  std::uint32_t outcome = 99;
  bool preparer_called = false;
  const std::uint16_t invalid_transaction_id[] = {
      '1', '2', '3', 'e', '4', '5', '6', '7', '-', 'e', '8', '9', 'b', '-',
      '1', '2', 'd', '3', '-', 'a', '4', '5', '6', '-', '4', '2', '6', '6',
      '1', '4', '1', '7', '4', '0', '0', '0', 0};

  auto result = internal::PrepareInstallV2With(
      &request, invalid_transaction_id, &reservation, &status, &outcome,
      [&preparer_called](const InstallRequest&, const std::string&,
                         InstallReservation*, bool*) {
        preparer_called = true;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(outcome, DESKTOP_UPDATER_PREPARE_OUTCOME_REJECTED);
  EXPECT_FALSE(preparer_called);
  EXPECT_EQ(reservation, nullptr);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("UUIDv4"),
            std::string::npos);

  desktop_updater_transaction_status_free_v1(&status);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, PrepareV2ValidatesOutputsBeforeHandoff) {
  auto request = ValidRequest();
  auto status = EmptyStatus();
  status.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION + 1;
  desktop_updater_reservation_handle_v1* reservation = nullptr;
  std::uint32_t outcome = 99;
  bool preparer_called = false;

  auto result = internal::PrepareInstallV2With(
      &request, kTransactionId, &reservation, &status, &outcome,
      [&preparer_called](const InstallRequest&, const std::string&,
                         InstallReservation*, bool*) {
        preparer_called = true;
        return InstallResult{true, ""};
      });

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(outcome, DESKTOP_UPDATER_PREPARE_OUTCOME_REJECTED);
  EXPECT_FALSE(preparer_called);
  EXPECT_EQ(reservation, nullptr);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("status ABI"),
            std::string::npos);

  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, StatusOperationValidatesOutputBeforeMutation) {
  auto status = EmptyStatus();
  status.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION + 1;
  bool operation_called = false;

  auto result = internal::StatusOperationWith(
      &status, [&operation_called]() {
        operation_called = true;
        return InstallTransactionStatus{
            "123e4567-e89b-42d3-a456-426614174000",
            InstallTransactionState::kCommitAccepted,
            InstallTransactionResultCode::kAccepted,
            "accepted",
            std::string(64, 'a'),
            std::string(64, 'b')};
      });

  EXPECT_EQ(result.ok, 0);
  EXPECT_FALSE(operation_called);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("ABI version"),
            std::string::npos);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, ResolveAfterExitUsesTransactionStatusShape) {
  auto status = EmptyStatus();
  std::string captured_transaction_id;

  auto result = internal::TransactionOperationWith(
      kTransactionId, &status,
      [&captured_transaction_id](const std::string& transaction_id) {
        captured_transaction_id = transaction_id;
        return InstallTransactionStatus{
            transaction_id,
            InstallTransactionState::kPrepared,
            InstallTransactionResultCode::kRecoveryRequired,
            "Recovery will continue after caller exit.",
            std::string(64, 'a'),
            std::string(64, 'b')};
      });

  EXPECT_EQ(result.ok, 1);
  EXPECT_EQ(captured_transaction_id,
            "123e4567-e89b-42d3-a456-426614174000");
  EXPECT_EQ(status.state, DESKTOP_UPDATER_TRANSACTION_PREPARED);
  EXPECT_EQ(status.result_code,
            DESKTOP_UPDATER_TRANSACTION_RESULT_RECOVERY_REQUIRED);
  ASSERT_NE(status.transaction_id_utf8, nullptr);
  EXPECT_STREQ(status.transaction_id_utf8,
               "123e4567-e89b-42d3-a456-426614174000");

  desktop_updater_transaction_status_free_v1(&status);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, PreservesRelaunchFailureResultCode) {
  auto status = EmptyStatus();

  auto result = internal::TransactionOperationWith(
      kTransactionId, &status, [](const std::string& transaction_id) {
        return InstallTransactionStatus{
            transaction_id,
            InstallTransactionState::kCompleted,
            InstallTransactionResultCode::kRelaunchFailure,
            "Verified install completed but relaunch was not confirmed.",
            std::string(64, 'a'),
            std::string(64, 'b')};
      });

  EXPECT_EQ(result.ok, 1);
  EXPECT_EQ(status.state, DESKTOP_UPDATER_TRANSACTION_COMPLETED);
  EXPECT_EQ(status.result_code,
            DESKTOP_UPDATER_TRANSACTION_RESULT_RELAUNCH_FAILURE);

  desktop_updater_transaction_status_free_v1(&status);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi,
     TransactionOperationValidatesInputsBeforeCallback) {
  int callback_count = 0;
  const internal::TransactionOperation operation =
      [&callback_count](const std::string& transaction_id) {
        ++callback_count;
        return InstallTransactionStatus{
            transaction_id,
            InstallTransactionState::kPrepared,
            InstallTransactionResultCode::kRecoveryRequired,
            "Recovery will continue after caller exit.",
            std::string(64, 'a'),
            std::string(64, 'b')};
      };

  auto null_status_result =
      internal::TransactionOperationWith(kTransactionId, nullptr, operation);
  EXPECT_EQ(null_status_result.ok, 0);
  desktop_updater_result_free_v1(&null_status_result);

  auto wrong_abi_status = EmptyStatus();
  wrong_abi_status.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION + 1;
  auto wrong_abi_result = internal::TransactionOperationWith(
      kTransactionId, &wrong_abi_status, operation);
  EXPECT_EQ(wrong_abi_result.ok, 0);
  desktop_updater_result_free_v1(&wrong_abi_result);

  auto undersized_status = EmptyStatus();
  undersized_status.struct_size =
      sizeof(desktop_updater_transaction_status_v1) - 1;
  auto undersized_result = internal::TransactionOperationWith(
      kTransactionId, &undersized_status, operation);
  EXPECT_EQ(undersized_result.ok, 0);
  desktop_updater_result_free_v1(&undersized_result);

  auto nonzero_status = EmptyStatus();
  const char existing_value[] = "existing";
  nonzero_status.detail_utf8 = existing_value;
  auto nonzero_result = internal::TransactionOperationWith(
      kTransactionId, &nonzero_status, operation);
  EXPECT_EQ(nonzero_result.ok, 0);
  nonzero_status.detail_utf8 = nullptr;
  desktop_updater_result_free_v1(&nonzero_result);

  constexpr std::uint16_t kWrongVersionTransactionId[] = {
      '1', '2', '3', 'e', '4', '5', '6', '7', '-', 'e', '8', '9', 'b', '-',
      '1', '2', 'd', '3', '-', 'a', '4', '5', '6', '-', '4', '2', '6', '6',
      '1', '4', '1', '7', '4', '0', '0', '0', 0};
  auto invalid_id_status = EmptyStatus();
  auto invalid_id_result = internal::TransactionOperationWith(
      kWrongVersionTransactionId, &invalid_id_status, operation);
  EXPECT_EQ(invalid_id_result.ok, 0);
  desktop_updater_result_free_v1(&invalid_id_result);

  constexpr std::uint16_t kNonAsciiTransactionId[] = {
      '1', '2', '3', 'e', '4', '5', '6', '7', '-', 'e', '8', '9', 'b', '-',
      '4', '2', 'd', '3', '-', 'a', '4', '5', '6', '-', '4', '2', '6', '6',
      '1', '4', '1', '7', '4', '0', '0', 0x00e9, 0};
  auto non_ascii_status = EmptyStatus();
  auto non_ascii_result = internal::TransactionOperationWith(
      kNonAsciiTransactionId, &non_ascii_status, operation);
  EXPECT_EQ(non_ascii_result.ok, 0);
  ASSERT_NE(non_ascii_result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(non_ascii_result.error_message_utf8).find("ASCII"),
            std::string::npos);
  desktop_updater_result_free_v1(&non_ascii_result);

  EXPECT_EQ(callback_count, 0);
}

TEST(DesktopUpdaterNativeCAbi,
     TransactionOperationRejectsChangedTransactionBinding) {
  auto status = EmptyStatus();

  auto result = internal::TransactionOperationWith(
      kTransactionId, &status,
      [](const std::string&) {
        return InstallTransactionStatus{
            "223e4567-e89b-42d3-a456-426614174000",
            InstallTransactionState::kPrepared,
            InstallTransactionResultCode::kRecoveryRequired,
            "Recovery will continue after caller exit.",
            std::string(64, 'a'),
            std::string(64, 'b')};
      });

  EXPECT_EQ(result.ok, 0);
  EXPECT_EQ(status.transaction_id_utf8, nullptr);
  EXPECT_EQ(status.detail_utf8, nullptr);
  ASSERT_NE(result.error_message_utf8, nullptr);
  EXPECT_NE(std::string(result.error_message_utf8).find("transaction binding"),
            std::string::npos);

  desktop_updater_transaction_status_free_v1(&status);
  desktop_updater_result_free_v1(&result);
}

TEST(DesktopUpdaterNativeCAbi, ResolveAfterExitEntryPointIsLinked) {
  auto* entry_point = &desktop_updater_resolve_pending_install_after_exit_v1;

  EXPECT_NE(entry_point, nullptr);
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
