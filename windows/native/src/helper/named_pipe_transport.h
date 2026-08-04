#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_NAMED_PIPE_TRANSPORT_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_NAMED_PIPE_TRANSPORT_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>

#include "helper_authenticode.h"
#include "helper_policy_windows.h"
#include "native_install_wire.h"

namespace desktop_updater::helper {

class NamedPipeTransportError : public std::runtime_error {
 public:
  explicit NamedPipeTransportError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct PeerBinding {
  DWORD process_id;
  std::wstring user_sid;
  std::string nonce;
};

using WindowsElevatedPipeSessionRunner =
    std::function<void(HANDLE pipe,
                       DWORD caller_process_id,
                       HANDLE caller_process)>;

enum class ElevationLaunchResult {
  kLaunched,
  kCancelled,
  kTimedOut,
  kFailed,
};

struct WindowsElevatedHelperLaunch;

class WindowsElevatedHelperClientSession {
 public:
  ~WindowsElevatedHelperClientSession();
  WindowsElevatedHelperClientSession(
      WindowsElevatedHelperClientSession&& other) = delete;
  WindowsElevatedHelperClientSession& operator=(
      WindowsElevatedHelperClientSession&& other) = delete;
  WindowsElevatedHelperClientSession(
      const WindowsElevatedHelperClientSession&) = delete;
  WindowsElevatedHelperClientSession& operator=(
      const WindowsElevatedHelperClientSession&) = delete;

  const desktop_updater::runtime::internal::NativeInstallReservationV1&
  reservation() const;
  desktop_updater::runtime::internal::NativeInstallReservationV1
  CommitAfterExit();
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
  CancelReservation();

 private:
  struct Impl;
  explicit WindowsElevatedHelperClientSession(std::unique_ptr<Impl> impl);

  std::unique_ptr<Impl> impl_;

  friend struct WindowsElevatedHelperLaunch;
  friend WindowsElevatedHelperLaunch LaunchAuthenticatedElevatedHelper(
      const std::filesystem::path& fixed_helper_path,
      const WindowsHelperPolicy& policy,
      const std::string& nonce,
      const std::string& canonical_request,
      DWORD timeout_millis);
  friend WindowsElevatedHelperLaunch LaunchAuthenticatedPortableHelper(
      const std::filesystem::path& fixed_helper_path,
      const WindowsHelperPolicy& policy,
      const std::string& nonce,
      const std::string& canonical_request,
      DWORD timeout_millis);
};

struct WindowsElevatedHelperLaunch {
  ElevationLaunchResult result = ElevationLaunchResult::kFailed;
  std::unique_ptr<WindowsElevatedHelperClientSession> session;
};

struct WindowsElevatedHelperExchange {
  ElevationLaunchResult result = ElevationLaunchResult::kFailed;
  std::string canonical_response;
  std::string helper_endpoint_identity_sha256;
};

std::wstring DerivePipeName(const std::string& nonce);

std::wstring BuildCallerPipeDaclSddl(const std::wstring& caller_sid,
                                    const std::wstring& helper_sid);

void ValidatePeerBinding(const PeerBinding& binding,
                         DWORD observed_process_id,
                         const std::wstring& observed_user_sid,
                         const std::string& observed_nonce);

ElevationLaunchResult ClassifyElevationResult(DWORD error,
                                              bool wait_timed_out);

WindowsElevatedHelperLaunch LaunchAuthenticatedElevatedHelper(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const std::string& nonce,
    const std::string& canonical_request,
    DWORD timeout_millis);

WindowsElevatedHelperLaunch LaunchAuthenticatedPortableHelper(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const std::string& nonce,
    const std::string& canonical_request,
    DWORD timeout_millis);

WindowsElevatedHelperExchange LaunchAuthenticatedElevatedHelperExchange(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const std::string& nonce,
    const std::string& canonical_request,
    DWORD timeout_millis);

WindowsElevatedHelperExchange LaunchAuthenticatedPortableHelperExchange(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const std::string& nonce,
    const std::string& canonical_request,
    DWORD timeout_millis);

int ConnectElevatedHelperToCallerPipe(const std::wstring& pipe_name,
                                      const std::string& nonce,
                                      DWORD timeout_millis,
                                      const WindowsElevatedPipeSessionRunner&
                                          session_runner);

int ConnectPortableHelperToCallerPipe(const std::wstring& pipe_name,
                                      const std::string& nonce,
                                      DWORD timeout_millis,
                                      const WindowsElevatedPipeSessionRunner&
                                          session_runner);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_NAMED_PIPE_TRANSPORT_H_
