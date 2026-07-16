#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RECOVERY_TRANSPORT_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RECOVERY_TRANSPORT_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <string>

#include "helper_policy_windows.h"
#include "named_pipe_transport.h"
#include "native_install_service_runtime.h"
#include "native_install_session.h"
#include "native_install_wire.h"

namespace desktop_updater::helper {

struct WindowsPersistentRecoveryRequestV1 {
  std::string operation;
  std::int64_t protocol_version = 0;
  std::string policy_id;
  std::string package_id;
  std::string transaction_id;
  std::string request_nonce;

  bool operator==(const WindowsPersistentRecoveryRequestV1& other) const;
};

WindowsPersistentRecoveryRequestV1 ParseWindowsPersistentRecoveryRequestV1(
    const std::string& canonical_json);
std::string EncodeWindowsPersistentRecoveryRequestV1(
    const WindowsPersistentRecoveryRequestV1& request);

struct WindowsElevatedRecoveryResponse {
  ElevationLaunchResult result = ElevationLaunchResult::kFailed;
  bool is_recovery = false;
  desktop_updater::runtime::internal::NativeInstallTransactionStatusV1 status;
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1 recovery;
  std::string helper_endpoint_identity_sha256;
};

WindowsElevatedRecoveryResponse LaunchAuthenticatedElevatedRecoveryRequest(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const WindowsPersistentRecoveryRequestV1& request,
    DWORD timeout_millis);

WindowsElevatedRecoveryResponse LaunchAuthenticatedPortableRecoveryRequest(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const WindowsPersistentRecoveryRequestV1& request,
    DWORD timeout_millis);

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
    DWORD startup_timeout_milliseconds);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RECOVERY_TRANSPORT_H_
