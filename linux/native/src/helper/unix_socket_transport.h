#ifndef DESKTOP_UPDATER_LINUX_HELPER_UNIX_SOCKET_TRANSPORT_H_
#define DESKTOP_UPDATER_LINUX_HELPER_UNIX_SOCKET_TRANSPORT_H_

#include <sys/types.h>

#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

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
std::string ReceiveCanonicalRequest(int socket_fd,
                                    std::size_t maximum_bytes);
PkexecResult LaunchLinuxBroker(const std::filesystem::path& socket_path,
                               const std::string& nonce);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_UNIX_SOCKET_TRANSPORT_H_
