#ifndef DESKTOP_UPDATER_LINUX_HELPER_UNIX_SOCKET_TRANSPORT_H_
#define DESKTOP_UPDATER_LINUX_HELPER_UNIX_SOCKET_TRANSPORT_H_

#include <sys/types.h>

#include <cstdint>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "native_install_service_runtime.h"
#include "native_install_wire.h"

namespace desktop_updater::helper {

class UnixSocketTransportError : public std::runtime_error {
 public:
  explicit UnixSocketTransportError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct LinuxPeerBinding {
  pid_t pid;
  uid_t uid;
  gid_t gid;
  std::uint64_t process_start_identity;
  std::string nonce;
};

enum class PkexecResult {
  kLaunched,
  kCancelled,
  kUnavailable,
  kFailed,
};

constexpr std::size_t kMaximumLinuxWireFrameBytes = 1024 * 1024;

class LinuxSeqpacketWireChannel final
    : public desktop_updater::runtime::internal::NativeInstallWireChannelV1 {
 public:
  explicit LinuxSeqpacketWireChannel(int socket_fd);

  std::string ReadFrame() override;
  std::string ReadFrameUntil(
      std::int64_t expires_at_unix_milliseconds) override;
  void WriteFrame(const std::string& canonical_frame) override;

 private:
  std::string ReadFrameAt(std::int64_t deadline_unix_milliseconds);

  int socket_fd_;
};

class LinuxOneShotClientSession {
 public:
  LinuxOneShotClientSession(
      int socket_fd,
      std::string expected_helper_endpoint_identity_sha256,
      const std::string& canonical_request,
      std::int64_t startup_deadline_unix_milliseconds,
      pid_t helper_process_id = -1);
  ~LinuxOneShotClientSession();

  LinuxOneShotClientSession(const LinuxOneShotClientSession&) = delete;
  LinuxOneShotClientSession& operator=(const LinuxOneShotClientSession&) =
      delete;
  LinuxOneShotClientSession(LinuxOneShotClientSession&&) = delete;
  LinuxOneShotClientSession& operator=(LinuxOneShotClientSession&&) = delete;

  const desktop_updater::runtime::internal::NativeInstallReservationV1&
  reservation() const;
  desktop_updater::runtime::internal::NativeInstallReservationV1
  CommitAfterExit();
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
  CancelReservation();

 private:
  enum class State { kPrepared, kCommitAccepted, kCancelled };

  int socket_fd_;
  std::string expected_helper_endpoint_identity_sha256_;
  LinuxSeqpacketWireChannel channel_;
  desktop_updater::runtime::internal::NativeInstallReservationV1 reservation_;
  State state_ = State::kPrepared;
  pid_t helper_process_id_ = -1;
};

struct LinuxControlExchangeResult {
  std::string canonical_response;
  std::string helper_endpoint_identity_sha256;
};

std::string Sha256LinuxBytes(const std::string& bytes);
std::string Sha256LinuxFile(const std::filesystem::path& path);
std::unique_ptr<LinuxOneShotClientSession>
LaunchUnprivilegedLinuxHelper(
    const std::filesystem::path& helper_path,
    const std::string& canonical_request,
    std::int64_t startup_timeout_milliseconds);
std::unique_ptr<LinuxOneShotClientSession> LaunchPrivilegedLinuxBroker(
    const std::string& canonical_request,
    std::int64_t startup_timeout_milliseconds);
LinuxControlExchangeResult ExchangeUnprivilegedLinuxHelperControl(
    const std::filesystem::path& helper_path,
    const std::string& canonical_request,
    const std::string& request_nonce,
    std::int64_t startup_timeout_milliseconds);
LinuxControlExchangeResult ExchangePrivilegedLinuxBrokerControl(
    const std::string& canonical_request,
    const std::string& request_nonce,
    std::int64_t startup_timeout_milliseconds);

// Waits for exactly [child] without ever treating EINTR, ECHILD, or another
// waitpid failure as a successful exit. The deadline is an absolute Unix time
// in milliseconds and is shared with the surrounding helper exchange.
int WaitForLinuxChildExitUntil(
    pid_t child,
    std::int64_t deadline_unix_milliseconds);

std::string DeriveLinuxSocketPath(const std::filesystem::path& runtime_dir,
                                  const std::string& nonce);
void ValidateLinuxPeerBinding(const LinuxPeerBinding& expected,
                              const LinuxPeerBinding& observed);
void ValidatePkexecArguments(const std::vector<std::string>& arguments);
PkexecResult ClassifyPkexecExit(int exit_code);
std::uint64_t LinuxProcessStartIdentity(pid_t pid);
int OpenLinuxPidfd(pid_t pid);
LinuxPeerBinding ReadLinuxPeerBinding(int socket_fd,
                                     const std::string& nonce);
int ConnectAuthenticatedUnixSocket(const std::filesystem::path& socket_path,
                                   const std::string& nonce);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_UNIX_SOCKET_TRANSPORT_H_
