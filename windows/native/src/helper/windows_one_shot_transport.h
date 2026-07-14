#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_ONE_SHOT_TRANSPORT_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_ONE_SHOT_TRANSPORT_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>

#include "helper_authenticode.h"
#include "helper_policy_windows.h"
#include "native_install_service_runtime.h"
#include "native_install_session.h"

namespace desktop_updater::helper {

constexpr std::uint32_t kMaximumWindowsOneShotFrameLength = 1024 * 1024;

class WindowsOneShotTransportError : public std::runtime_error {
 public:
  explicit WindowsOneShotTransportError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct ObservedWindowsCallerIdentity {
  DWORD process_id = 0;
  std::uint64_t process_start_identity = 0;
  VerifiedWindowsExecutable executable;
};

std::string WindowsProcessStartIdentityString(std::uint64_t identity);

void ValidateWindowsOneShotFrameLength(std::uint32_t length);

void ValidateWindowsCallerIdentity(
    const desktop_updater::runtime::internal::NativeInstallCallerV1& caller,
    const ObservedWindowsCallerIdentity& observed,
    const WindowsHelperPolicy& policy);

class WindowsOneShotPipeChannel final
    : public desktop_updater::runtime::internal::NativeInstallWireChannelV1 {
 public:
  WindowsOneShotPipeChannel(HANDLE pipe,
                           HANDLE caller_process,
                           std::int64_t startup_deadline_unix_milliseconds);

  std::string ReadFrame() override;
  std::string ReadFrameUntil(
      std::int64_t expires_at_unix_milliseconds) override;
  void WriteFrame(const std::string& canonical_frame) override;

 private:
  std::string ReadFrameAt(std::int64_t deadline_unix_milliseconds);
  void TransferExact(bool write,
                     void* bytes,
                     std::uint32_t length,
                     std::int64_t deadline_unix_milliseconds);

  HANDLE pipe_;
  HANDLE caller_process_;
  std::int64_t startup_deadline_unix_milliseconds_;
};

class WindowsCallerExitMonitorFactory final
    : public desktop_updater::runtime::internal::
          NativeInstallCallerExitMonitorFactoryV1 {
 public:
  WindowsCallerExitMonitorFactory(DWORD observed_caller_process_id,
                                  const WindowsHelperPolicy& policy);

  std::unique_ptr<
      desktop_updater::runtime::internal::NativeInstallCallerExitMonitorV1>
  Create(const desktop_updater::runtime::internal::NativeInstallCallerV1&
             caller) override;

 private:
  DWORD observed_caller_process_id_;
  const WindowsHelperPolicy& policy_;
};

void RunWindowsOneShotPipeSession(
    HANDLE pipe,
    DWORD observed_caller_process_id,
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

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_ONE_SHOT_TRANSPORT_H_
