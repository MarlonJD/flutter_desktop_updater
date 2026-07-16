#include "windows_recovery_transport.h"

#include <limits>
#include <utility>

#include "json_value.h"
#include "windows_one_shot_transport.h"
#include "windows_persistent_recovery.h"
#include "windows_relaunch_service.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {
namespace {

bool IsPersistentRecoveryFrame(const std::string& canonical_frame) {
  const auto value = desktop_updater::runtime::internal::ParseJson(
      canonical_frame);
  const auto& object = value.object();
  return object.find("operation") != object.end();
}

}  // namespace

void RunWindowsPersistentRecoveryPipeSession(
    HANDLE pipe,
    DWORD observed_caller_process_id,
    HANDLE observed_caller_process,
    const std::string& transport_nonce,
    const WindowsHelperPolicy& policy,
    desktop_updater::runtime::internal::NativeInstallRequestAuthorizerV1&
        authorizer,
    desktop_updater::runtime::internal::NativeInstallOneShotSessionV1::
        ReadyTokenGenerator ready_token_generator,
    desktop_updater::runtime::internal::NativeInstallOneShotSessionV1::
        Sha256Function sha256,
    desktop_updater::runtime::internal::NativeInstallOneShotSessionV1::Clock
        now_unix_milliseconds,
    std::int64_t reservation_lifetime_milliseconds,
    DWORD startup_timeout_milliseconds) {
  if (!now_unix_milliseconds || startup_timeout_milliseconds == 0) {
    throw WindowsOneShotTransportError(
        "invalid helper dispatch timing dependencies");
  }
  const std::int64_t now = now_unix_milliseconds();
  if (now < 0 ||
      now > std::numeric_limits<std::int64_t>::max() -
                startup_timeout_milliseconds) {
    throw WindowsOneShotTransportError("helper dispatch deadline overflow");
  }
  if (observed_caller_process == nullptr ||
      observed_caller_process == INVALID_HANDLE_VALUE) {
    throw WindowsOneShotTransportError("named-pipe caller cannot be retained");
  }
  WindowsOneShotPipeChannel channel(
      pipe, observed_caller_process, now + startup_timeout_milliseconds);
  const std::string initial_request = channel.ReadFrame();
  if (!IsPersistentRecoveryFrame(initial_request)) {
    RunWindowsOneShotPipeSessionWithInitialRequest(
        pipe, observed_caller_process_id, policy, authorizer,
        std::move(ready_token_generator), std::move(sha256),
        std::move(now_unix_milliseconds),
        reservation_lifetime_milliseconds, startup_timeout_milliseconds,
        initial_request);
    return;
  }

  const WindowsPersistentRecoveryRequestV1 request =
      ParseWindowsPersistentRecoveryRequestV1(initial_request);
  if (request.request_nonce != transport_nonce ||
      request.policy_id != policy.policy_id() ||
      request.package_id != policy.application_package_id()) {
    throw NamedPipeTransportError(
        "persistent recovery request transport binding changed");
  }
  WindowsPersistentRecoveryService service(policy, observed_caller_process);
  if (request.operation == "queryTransaction") {
    channel.WriteFrame(
        desktop_updater::runtime::internal::
            EncodeNativeInstallTransactionStatusV1(
                service.Query(request.transaction_id)));
    return;
  }
  if (request.operation == "resolvePendingInstallAfterExit") {
    CallerTokenWindowsLauncher launcher(observed_caller_process);
    (void)service.ResolvePendingInstallAfterCallerExit(
        request.transaction_id,
        [&channel, observed_caller_process](
            const desktop_updater::runtime::internal::
                NativeInstallTransactionStatusV1& status) {
          channel.WriteFrame(
              desktop_updater::runtime::internal::
                  EncodeNativeInstallTransactionStatusV1(status));
          if (WaitForSingleObject(observed_caller_process, INFINITE) !=
              WAIT_OBJECT_0) {
            throw WindowsOneShotTransportError(
                "pending recovery caller exit wait failed");
          }
        },
        launcher);
    return;
  }
  channel.WriteFrame(
      desktop_updater::runtime::internal::EncodeNativeInstallRecoveryResultV1(
          service.Recover(request.transaction_id)));
}

}  // namespace desktop_updater::helper
