#include <gtest/gtest.h>

#include <string>

#include "native_install_wire.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

NativeInstallReservationV1 Reservation() {
  return {
      1,
      "00000000-0000-4000-8000-000000000001",
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      std::string(64, 'a'),
      std::string(64, 'b'),
      1783987200000,
  };
}

TEST(native_install_wire, ReservationAndCommandRoundTripCanonicalV1) {
  const NativeInstallReservationV1 reservation = Reservation();
  const std::string encoded = EncodeNativeInstallReservationV1(reservation);
  EXPECT_EQ(reservation, ParseNativeInstallReservationV1(encoded));

  NativeInstallWireCommandV1 command{
      "commitAfterExit",
      reservation.protocol_version,
      reservation.transaction_id,
      reservation.ready_token,
      reservation.journal_sha256,
      reservation.helper_endpoint_identity_sha256,
  };
  const std::string encoded_command =
      EncodeNativeInstallWireCommandV1(command);
  EXPECT_EQ(command, ParseNativeInstallWireCommandV1(encoded_command));
}

TEST(native_install_wire, StatusAndRecoveryRoundTripCanonicalV1) {
  const NativeInstallTransactionStatusV1 status{
      1,
      "00000000-0000-4000-8000-000000000001",
      "completed",
      "completed",
      std::string(64, 'a'),
  };
  EXPECT_EQ(status, ParseNativeInstallTransactionStatusV1(
                        EncodeNativeInstallTransactionStatusV1(status)));
  const NativeInstallRecoveryResultV1 recovery{
      1,
      status.transaction_id,
      "rolledBack",
      "oldTarget",
      status.journal_sha256,
  };
  EXPECT_EQ(recovery, ParseNativeInstallRecoveryResultV1(
                          EncodeNativeInstallRecoveryResultV1(recovery)));
}

TEST(native_install_wire, RejectsUnknownFieldsNonCanonicalAndSecretDrift) {
  const std::string reservation =
      EncodeNativeInstallReservationV1(Reservation());
  EXPECT_THROW(ParseNativeInstallReservationV1(reservation + "\n"),
               NativeInstallWireError);
  std::string unknown = reservation;
  unknown.insert(1, "\"requestNonce\":\"secret\",");
  EXPECT_THROW(ParseNativeInstallReservationV1(unknown),
               NativeInstallWireError);

  NativeInstallWireCommandV1 command{
      "unsupported",
      1,
      Reservation().transaction_id,
      Reservation().ready_token,
      Reservation().journal_sha256,
      Reservation().helper_endpoint_identity_sha256,
  };
  EXPECT_THROW(EncodeNativeInstallWireCommandV1(command),
               NativeInstallWireError);
}

TEST(native_install_wire, RejectsInconsistentTerminalStatusAndRecovery) {
  NativeInstallTransactionStatusV1 status{
      1,
      Reservation().transaction_id,
      "completed",
      "rolledBack",
      Reservation().journal_sha256,
  };
  EXPECT_THROW(EncodeNativeInstallTransactionStatusV1(status),
               NativeInstallWireError);

  NativeInstallRecoveryResultV1 recovery{
      1,
      Reservation().transaction_id,
      "completed",
      "oldTarget",
      Reservation().journal_sha256,
  };
  EXPECT_THROW(EncodeNativeInstallRecoveryResultV1(recovery),
               NativeInstallWireError);

  recovery.result_code = "relaunchFailure";
  recovery.verified_outcome = "newTarget";
  EXPECT_NO_THROW(EncodeNativeInstallRecoveryResultV1(recovery));
}

}  // namespace
}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
