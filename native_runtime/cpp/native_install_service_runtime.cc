#include "native_install_service_runtime.h"

#include <memory>
#include <string>

#include "native_install_request.h"
#include "native_install_wire.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

NativeInstallOneShotServiceRuntimeV1::NativeInstallOneShotServiceRuntimeV1(
    NativeInstallOneShotSessionV1& session,
    NativeInstallCallerExitMonitorFactoryV1& caller_monitor_factory)
    : session_(session), caller_monitor_factory_(caller_monitor_factory) {}

void NativeInstallOneShotServiceRuntimeV1::Run(
    NativeInstallWireChannelV1& channel) {
  const std::string canonical_request = channel.ReadFrame();
  const NativeInstallTransactionRequestV1 request =
      ParseNativeInstallTransactionRequestV1(canonical_request);
  std::unique_ptr<NativeInstallCallerExitMonitorV1> caller_monitor =
      caller_monitor_factory_.Create(
          request.caller.process_id,
          request.caller.process_start_identity);
  if (caller_monitor == nullptr) {
    throw NativeInstallSessionError("caller exit monitor is unavailable");
  }

  enum class Phase {
    kInitial,
    kPrepared,
    kCommitAccepted,
    kExecuting,
    kFinished,
  };
  Phase phase = Phase::kInitial;
  const NativeInstallReservationV1 reservation =
      session_.Prepare(canonical_request);
  phase = Phase::kPrepared;
  try {
    channel.WriteFrame(EncodeNativeInstallReservationV1(reservation));
    const std::string canonical_command = channel.ReadFrameUntil(
        reservation.expires_at_unix_milliseconds);
    const NativeInstallWireCommandV1 command =
        ParseNativeInstallWireCommandV1(canonical_command);
    if (command.operation == "commitAfterExit") {
      const NativeInstallReservationV1 acknowledged =
          session_.AcceptCommit(canonical_command);
      phase = Phase::kCommitAccepted;
      channel.WriteFrame(EncodeNativeInstallReservationV1(acknowledged));
      caller_monitor->WaitForExit(
          reservation.expires_at_unix_milliseconds);
      phase = Phase::kExecuting;
      (void)session_.ExecuteAfterCallerExit();
      phase = Phase::kFinished;
      return;
    }
    if (command.operation == "cancelReservation") {
      const NativeInstallRecoveryResultV1 result =
          session_.Cancel(canonical_command);
      phase = Phase::kFinished;
      channel.WriteFrame(EncodeNativeInstallRecoveryResultV1(result));
      return;
    }
    throw NativeInstallWireError("unsupportedOperation");
  } catch (...) {
    try {
      if (phase == Phase::kPrepared) {
        (void)session_.CancelBeforeCommitOnCallerExit();
      } else if (phase == Phase::kCommitAccepted) {
        (void)session_.CancelCommitAwaitingCallerExit();
      }
    } catch (...) {
      // A failed rollback remains journal-backed recovery work.
    }
    throw;
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
