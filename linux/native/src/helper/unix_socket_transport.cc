#include "unix_socket_transport.h"

#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cstring>
#include <fstream>
#include <sstream>
#include <set>

#include "json_value.h"

namespace desktop_updater::helper {
namespace {

bool IsNonce(const std::string& nonce) {
  if (nonce.size() != 43) return false;
  for (unsigned char character : nonce) {
    if (!(character >= 'A' && character <= 'Z') &&
        !(character >= 'a' && character <= 'z') &&
        !(character >= '0' && character <= '9') && character != '-' &&
        character != '_') {
      return false;
    }
  }
  return true;
}

void ConsumeNonce(const std::string& nonce) {
  static std::set<std::string> consumed;
  if (!consumed.insert(nonce).second) {
    throw UnixSocketTransportError("nonce replay rejected");
  }
}

}  // namespace

std::string DeriveLinuxSocketPath(const std::filesystem::path& runtime_dir,
                                  const std::string& nonce) {
  if (!IsNonce(nonce)) {
    throw UnixSocketTransportError("nonce must be 32-byte base64url");
  }
  const std::string root = runtime_dir.lexically_normal().string();
  if (root.rfind("/run/user/", 0) != 0) {
    throw UnixSocketTransportError("socket must live in the caller runtime dir");
  }
  const std::string result =
      (runtime_dir / ("desktop-updater-" + nonce + ".sock")).string();
  if (result.size() >= sizeof(sockaddr_un::sun_path)) {
    throw UnixSocketTransportError("Unix socket locator is too long");
  }
  return result;
}

void ValidateLinuxPeerBinding(const LinuxPeerBinding& expected,
                              const LinuxPeerBinding& observed) {
  if (expected.pid != observed.pid || expected.uid != observed.uid ||
      expected.gid != observed.gid ||
      expected.process_start_identity != observed.process_start_identity ||
      expected.nonce != observed.nonce) {
    throw UnixSocketTransportError("Unix socket peer binding mismatch");
  }
}

void ValidatePkexecArguments(const std::vector<std::string>& arguments) {
  const std::filesystem::path socket_path =
      arguments.size() > 3 ? std::filesystem::path(arguments[3])
                           : std::filesystem::path();
  const std::string expected_socket_name =
      arguments.size() > 5
          ? "desktop-updater-" + arguments[5] + ".sock"
          : std::string();
  if (arguments.size() != 6 || arguments[0] != "/usr/bin/pkexec" ||
      arguments[1] != "/usr/libexec/desktop-updater-helper" ||
      arguments[2] != "--socket" || arguments[4] != "--nonce" ||
      arguments[3].rfind("/run/user/", 0) != 0 ||
      !IsNonce(arguments[5]) ||
      socket_path.lexically_normal() != socket_path ||
      socket_path.filename() != expected_socket_name) {
    throw UnixSocketTransportError(
        "pkexec accepts only fixed broker, socket locator, and nonce");
  }
}

PkexecResult ClassifyPkexecExit(int exit_code) {
  if (exit_code == 0) return PkexecResult::kLaunched;
  if (exit_code == 126) return PkexecResult::kCancelled;
  if (exit_code == 127) return PkexecResult::kUnavailable;
  return PkexecResult::kFailed;
}

std::uint64_t LinuxProcessStartIdentity(pid_t pid) {
  std::ifstream input("/proc/" + std::to_string(pid) + "/stat");
  std::string stat_line;
  if (!std::getline(input, stat_line)) {
    throw UnixSocketTransportError("/proc/ process identity unavailable");
  }
  const std::size_t command_end = stat_line.rfind(')');
  if (command_end == std::string::npos || command_end + 2 >= stat_line.size()) {
    throw UnixSocketTransportError("/proc/ process identity malformed");
  }
  std::istringstream fields(stat_line.substr(command_end + 2));
  std::string value;
  for (int field = 3; field <= 22; ++field) {
    if (!(fields >> value)) {
      throw UnixSocketTransportError("/proc/ process start time missing");
    }
  }
  return std::stoull(value);
}

int OpenLinuxPidfd(pid_t pid) {
#ifdef SYS_pidfd_open
  return static_cast<int>(syscall(SYS_pidfd_open, pid, 0));
#else
  errno = ENOSYS;
  return -1;
#endif
}

LinuxPeerBinding ReadLinuxPeerBinding(int socket_fd,
                                     const std::string& nonce) {
  struct ucred credentials {};
  socklen_t length = sizeof(credentials);
  if (getsockopt(socket_fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) !=
          0 ||
      length != sizeof(credentials)) {
    throw UnixSocketTransportError("SO_PEERCRED failed");
  }
  return {credentials.pid, credentials.uid, credentials.gid,
          LinuxProcessStartIdentity(credentials.pid), nonce};
}

int ConnectAuthenticatedUnixSocket(const std::filesystem::path& socket_path,
                                   const std::string& nonce) {
  ConsumeNonce(nonce);
  struct stat before {};
  struct stat parent {};
  if (lstat(socket_path.parent_path().c_str(), &parent) != 0 ||
      lstat(socket_path.c_str(), &before) != 0 || !S_ISDIR(parent.st_mode) ||
      !S_ISSOCK(before.st_mode) || before.st_uid != parent.st_uid ||
      (parent.st_mode & 0077) != 0 || (before.st_mode & 0077) != 0) {
    throw UnixSocketTransportError("socket path ownership or mode rejected");
  }
  const int socket_fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  if (socket_fd < 0) throw UnixSocketTransportError("socket creation failed");
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::strncpy(address.sun_path, socket_path.c_str(),
               sizeof(address.sun_path) - 1);
  if (connect(socket_fd, reinterpret_cast<sockaddr*>(&address),
              sizeof(address)) != 0) {
    close(socket_fd);
    throw UnixSocketTransportError("socket connection failed");
  }
  struct stat after {};
  if (lstat(socket_path.c_str(), &after) != 0 || before.st_dev != after.st_dev ||
      before.st_ino != after.st_ino) {
    close(socket_fd);
    throw UnixSocketTransportError("socket path replacement rejected");
  }
  (void)ReadLinuxPeerBinding(socket_fd, nonce);
  return socket_fd;
}

std::string ReceiveCanonicalRequest(int socket_fd,
                                    std::size_t maximum_bytes) {
  std::string canonical_request(maximum_bytes + 1, '\0');
  const ssize_t count = recv(socket_fd, canonical_request.data(),
                             canonical_request.size(), 0);
  if (count <= 0 || static_cast<std::size_t>(count) > maximum_bytes) {
    throw UnixSocketTransportError("canonical request size rejected");
  }
  canonical_request.resize(static_cast<std::size_t>(count));
  try {
    const auto parsed =
        desktop_updater::runtime::internal::ParseJson(canonical_request);
    if (desktop_updater::runtime::internal::EncodeCanonicalJson(parsed) !=
        canonical_request) {
      throw UnixSocketTransportError("request is not canonical JSON");
    }
  } catch (const desktop_updater::runtime::internal::JsonError&) {
    throw UnixSocketTransportError("request JSON rejected");
  }
  return canonical_request;
}

PkexecResult LaunchLinuxBroker(const std::filesystem::path& socket_path,
                               const std::string& nonce) {
  std::vector<std::string> arguments = {
      "/usr/bin/pkexec", "/usr/libexec/desktop-updater-helper", "--socket",
      socket_path.string(), "--nonce", nonce};
  ValidatePkexecArguments(arguments);
  const pid_t child = fork();
  if (child < 0) return PkexecResult::kFailed;
  if (child == 0) {
    std::array<char*, 7> argv{};
    for (std::size_t index = 0; index < arguments.size(); ++index) {
      argv[index] = arguments[index].data();
    }
    execv(argv[0], argv.data());
    _exit(127);
  }
  int status = 0;
  if (waitpid(child, &status, 0) != child || !WIFEXITED(status)) {
    return PkexecResult::kFailed;
  }
  return ClassifyPkexecExit(WEXITSTATUS(status));
}

}  // namespace desktop_updater::helper
