#include "unix_socket_transport.h"

#include <fcntl.h>
#include <openssl/evp.h>
#include <signal.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <array>
#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <set>
#include <utility>
#include <vector>

#include "json_value.h"

extern char** environ;

namespace desktop_updater::helper {
namespace {

class ScopedFd {
 public:
  explicit ScopedFd(int fd = -1) : fd_(fd) {}
  ~ScopedFd() {
    if (fd_ >= 0) close(fd_);
  }
  ScopedFd(const ScopedFd&) = delete;
  ScopedFd& operator=(const ScopedFd&) = delete;
  int get() const { return fd_; }
  int release() {
    const int result = fd_;
    fd_ = -1;
    return result;
  }

 private:
  int fd_;
};

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

std::int64_t NowUnixMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

constexpr unsigned char kSocketPathValidated = 0xa5;

int RemainingPollMilliseconds(std::int64_t deadline_unix_milliseconds);

void SendSocketPathValidated(int socket_fd) {
  const unsigned char ready = kSocketPathValidated;
  ssize_t count = -1;
  do {
    count = send(socket_fd, &ready, sizeof(ready), MSG_NOSIGNAL);
  } while (count < 0 && errno == EINTR);
  if (count != static_cast<ssize_t>(sizeof(ready))) {
    throw UnixSocketTransportError("socket validation handshake failed");
  }
}

void ReceiveSocketPathValidated(int socket_fd,
                                std::int64_t deadline_unix_milliseconds) {
  pollfd descriptor{socket_fd, POLLIN, 0};
  int ready = -1;
  do {
    ready = poll(&descriptor, 1,
                 RemainingPollMilliseconds(deadline_unix_milliseconds));
  } while (ready < 0 && errno == EINTR);
  unsigned char value = 0;
  ssize_t count = -1;
  if (ready == 1 && (descriptor.revents & POLLIN) != 0) {
    do {
      count = recv(socket_fd, &value, sizeof(value), 0);
    } while (count < 0 && errno == EINTR);
  }
  if (count != static_cast<ssize_t>(sizeof(value)) ||
      value != kSocketPathValidated) {
    throw UnixSocketTransportError("socket validation handshake rejected");
  }
}

int RemainingPollMilliseconds(std::int64_t deadline_unix_milliseconds) {
  const std::int64_t now = NowUnixMilliseconds();
  if (deadline_unix_milliseconds <= now) {
    throw UnixSocketTransportError("Unix socket frame deadline expired");
  }
  return static_cast<int>(std::min<std::int64_t>(
      deadline_unix_milliseconds - now,
      std::numeric_limits<int>::max()));
}

void ValidateCanonicalFrame(const std::string& frame) {
  try {
    const auto parsed = desktop_updater::runtime::internal::ParseJson(frame);
    if (desktop_updater::runtime::internal::EncodeCanonicalJson(parsed) !=
        frame) {
      throw UnixSocketTransportError("wire frame is not canonical JSON");
    }
  } catch (const UnixSocketTransportError&) {
    throw;
  } catch (const std::exception&) {
    throw UnixSocketTransportError("wire frame JSON rejected");
  }
}

std::filesystem::path SecureRuntimeDirectory() {
  const char* encoded = std::getenv("XDG_RUNTIME_DIR");
  if (encoded == nullptr || encoded[0] == '\0') {
    throw UnixSocketTransportError("XDG_RUNTIME_DIR is unavailable");
  }
  const std::filesystem::path path(encoded);
  if (!path.is_absolute() || path.lexically_normal() != path) {
    throw UnixSocketTransportError("runtime directory locator rejected");
  }
  struct stat status {};
  if (lstat(path.c_str(), &status) != 0 || !S_ISDIR(status.st_mode) ||
      S_ISLNK(status.st_mode) || status.st_uid != geteuid() ||
      (status.st_mode & 0077) != 0) {
    throw UnixSocketTransportError(
        "runtime directory ownership or mode rejected");
  }
  return path;
}

std::int64_t DeadlineAfter(std::int64_t timeout_milliseconds) {
  const std::int64_t now = NowUnixMilliseconds();
  if (timeout_milliseconds <= 0 ||
      now > std::numeric_limits<std::int64_t>::max() -
                timeout_milliseconds) {
    throw UnixSocketTransportError("helper startup deadline rejected");
  }
  return now + timeout_milliseconds;
}

void TerminateAndReap(pid_t child) {
  if (child <= 0) return;
  int status = 0;
  for (;;) {
    const pid_t observed = waitpid(child, &status, WNOHANG);
    if (observed == child || (observed < 0 && errno == ECHILD)) return;
    if (observed < 0 && errno == EINTR) continue;
    if (observed < 0) return;
    break;
  }
  (void)kill(child, SIGKILL);
  for (;;) {
    const pid_t observed = waitpid(child, &status, 0);
    if (observed == child || (observed < 0 && errno == ECHILD)) return;
    if (observed < 0 && errno == EINTR) continue;
    return;
  }
}

class PendingHelperLaunch {
 public:
  PendingHelperLaunch(std::filesystem::path socket_path,
                      const struct stat& socket_identity,
                      pid_t child)
      : socket_path_(std::move(socket_path)),
        socket_device_(socket_identity.st_dev),
        socket_inode_(socket_identity.st_ino),
        child_(child) {}

  ~PendingHelperLaunch() {
    RemoveExactSocket();
    TerminateAndReap(child_);
  }

  PendingHelperLaunch(const PendingHelperLaunch&) = delete;
  PendingHelperLaunch& operator=(const PendingHelperLaunch&) = delete;

  void RemoveExactSocket() {
    if (socket_path_.empty()) return;
    struct stat observed {};
    if (lstat(socket_path_.c_str(), &observed) == 0 &&
        S_ISSOCK(observed.st_mode) && observed.st_dev == socket_device_ &&
        observed.st_ino == socket_inode_) {
      (void)unlink(socket_path_.c_str());
    }
    socket_path_.clear();
  }

  void MarkChildReaped() { child_ = -1; }
  void TransferChildOwnership() { child_ = -1; }

 private:
  std::filesystem::path socket_path_;
  dev_t socket_device_;
  ino_t socket_inode_;
  pid_t child_;
};

}  // namespace

int WaitForLinuxChildExitUntil(
    pid_t child,
    std::int64_t deadline_unix_milliseconds) {
  if (child <= 0) {
    throw UnixSocketTransportError("helper child identity rejected");
  }
  int status = 0;
  for (;;) {
    const pid_t observed = waitpid(child, &status, WNOHANG);
    if (observed == child) return status;
    if (observed < 0) {
      if (errno == EINTR) continue;
      throw UnixSocketTransportError("helper child wait failed");
    }
    const std::int64_t now = NowUnixMilliseconds();
    if (now >= deadline_unix_milliseconds) {
      throw UnixSocketTransportError("helper child exit timed out");
    }
    const int pause_milliseconds = static_cast<int>(
        std::min<std::int64_t>(10, deadline_unix_milliseconds - now));
    int paused = -1;
    do {
      paused = poll(nullptr, 0, pause_milliseconds);
    } while (paused < 0 && errno == EINTR);
    if (paused < 0) {
      throw UnixSocketTransportError("helper child wait failed");
    }
  }
}

LinuxSeqpacketWireChannel::LinuxSeqpacketWireChannel(int socket_fd)
    : socket_fd_(socket_fd) {
  int socket_type = 0;
  socklen_t length = sizeof(socket_type);
  if (socket_fd_ < 0 ||
      getsockopt(socket_fd_, SOL_SOCKET, SO_TYPE, &socket_type, &length) != 0 ||
      length != sizeof(socket_type) || socket_type != SOCK_SEQPACKET) {
    throw UnixSocketTransportError(
        "wire channel requires a Unix SOCK_SEQPACKET socket");
  }
}

std::string LinuxSeqpacketWireChannel::ReadFrame() {
  const std::int64_t now = NowUnixMilliseconds();
  if (now > std::numeric_limits<std::int64_t>::max() - 30'000) {
    throw UnixSocketTransportError("wire frame deadline overflow");
  }
  return ReadFrameAt(now + 30'000);
}

std::string LinuxSeqpacketWireChannel::ReadFrameUntil(
    std::int64_t expires_at_unix_milliseconds) {
  return ReadFrameAt(expires_at_unix_milliseconds);
}

std::string LinuxSeqpacketWireChannel::ReadFrameAt(
    std::int64_t deadline_unix_milliseconds) {
  pollfd descriptor{socket_fd_, POLLIN, 0};
  int ready = -1;
  do {
    ready = poll(&descriptor, 1,
                 RemainingPollMilliseconds(deadline_unix_milliseconds));
  } while (ready < 0 && errno == EINTR);
  if (ready != 1 || (descriptor.revents & POLLIN) == 0) {
    throw UnixSocketTransportError(
        ready == 0 ? "Unix socket frame timed out"
                   : "Unix socket frame wait failed");
  }

  std::vector<unsigned char> packet(kMaximumLinuxWireFrameBytes + 5);
  iovec fragment{packet.data(), packet.size()};
  msghdr message{};
  message.msg_iov = &fragment;
  message.msg_iovlen = 1;
  ssize_t count = -1;
  do {
    count = recvmsg(socket_fd_, &message, MSG_CMSG_CLOEXEC);
  } while (count < 0 && errno == EINTR);
  if (count < 5 || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) != 0) {
    throw UnixSocketTransportError("Unix socket frame bounds rejected");
  }
  const std::uint32_t encoded_length =
      (static_cast<std::uint32_t>(packet[0]) << 24) |
      (static_cast<std::uint32_t>(packet[1]) << 16) |
      (static_cast<std::uint32_t>(packet[2]) << 8) |
      static_cast<std::uint32_t>(packet[3]);
  if (encoded_length == 0 || encoded_length > kMaximumLinuxWireFrameBytes ||
      static_cast<std::size_t>(count) != encoded_length + 4) {
    throw UnixSocketTransportError("Unix socket frame length rejected");
  }
  std::string frame(reinterpret_cast<const char*>(packet.data() + 4),
                    encoded_length);
  ValidateCanonicalFrame(frame);
  return frame;
}

void LinuxSeqpacketWireChannel::WriteFrame(
    const std::string& canonical_frame) {
  if (canonical_frame.empty() ||
      canonical_frame.size() > kMaximumLinuxWireFrameBytes) {
    throw UnixSocketTransportError("Unix socket frame size rejected");
  }
  ValidateCanonicalFrame(canonical_frame);
  const std::uint32_t length =
      static_cast<std::uint32_t>(canonical_frame.size());
  std::vector<unsigned char> packet(4 + canonical_frame.size());
  packet[0] = static_cast<unsigned char>((length >> 24) & 0xff);
  packet[1] = static_cast<unsigned char>((length >> 16) & 0xff);
  packet[2] = static_cast<unsigned char>((length >> 8) & 0xff);
  packet[3] = static_cast<unsigned char>(length & 0xff);
  std::copy(canonical_frame.begin(), canonical_frame.end(), packet.begin() + 4);
  ssize_t count = -1;
  do {
    count = send(socket_fd_, packet.data(), packet.size(), MSG_NOSIGNAL);
  } while (count < 0 && errno == EINTR);
  if (count != static_cast<ssize_t>(packet.size())) {
    throw UnixSocketTransportError("Unix socket frame write failed");
  }
}

LinuxOneShotClientSession::LinuxOneShotClientSession(
    int socket_fd,
    std::string expected_helper_endpoint_identity_sha256,
    const std::string& canonical_request,
    std::int64_t startup_deadline_unix_milliseconds,
    pid_t helper_process_id)
    : socket_fd_(socket_fd),
      expected_helper_endpoint_identity_sha256_(
          std::move(expected_helper_endpoint_identity_sha256)),
      channel_(socket_fd),
      helper_process_id_(helper_process_id) {
  try {
    const auto request = desktop_updater::runtime::internal::
        ParseNativeInstallTransactionRequestV1(canonical_request);
    channel_.WriteFrame(canonical_request);
    reservation_ = desktop_updater::runtime::internal::
        ParseNativeInstallReservationV1(
            channel_.ReadFrameUntil(startup_deadline_unix_milliseconds));
    if (reservation_.transaction_id != request.transaction_id ||
        reservation_.helper_endpoint_identity_sha256 !=
            expected_helper_endpoint_identity_sha256_ ||
        reservation_.expires_at_unix_milliseconds <= NowUnixMilliseconds()) {
      throw UnixSocketTransportError(
          "helper reservation binding changed");
    }
  } catch (...) {
    close(socket_fd_);
    socket_fd_ = -1;
    throw;
  }
}

LinuxOneShotClientSession::~LinuxOneShotClientSession() {
  if (socket_fd_ < 0) return;
  bool cancellation_failed = false;
  if (state_ == State::kPrepared) {
    try {
      (void)CancelReservation();
    } catch (...) {
      cancellation_failed = true;
    }
  }
  close(socket_fd_);
  if (helper_process_id_ > 0) {
    if (cancellation_failed) {
      TerminateAndReap(helper_process_id_);
    } else {
      int status = 0;
      (void)waitpid(helper_process_id_, &status, WNOHANG);
    }
    helper_process_id_ = -1;
  }
}

const desktop_updater::runtime::internal::NativeInstallReservationV1&
LinuxOneShotClientSession::reservation() const {
  return reservation_;
}

desktop_updater::runtime::internal::NativeInstallReservationV1
LinuxOneShotClientSession::CommitAfterExit() {
  using desktop_updater::runtime::internal::EncodeNativeInstallWireCommandV1;
  using desktop_updater::runtime::internal::NativeInstallWireCommandV1;
  using desktop_updater::runtime::internal::ParseNativeInstallReservationV1;
  if (state_ != State::kPrepared) {
    throw UnixSocketTransportError("Linux helper session is not prepared");
  }
  const NativeInstallWireCommandV1 command{
      "commitAfterExit",
      reservation_.protocol_version,
      reservation_.transaction_id,
      reservation_.ready_token,
      reservation_.journal_sha256,
      reservation_.helper_endpoint_identity_sha256};
  channel_.WriteFrame(EncodeNativeInstallWireCommandV1(command));
  const auto acknowledged = ParseNativeInstallReservationV1(
      channel_.ReadFrameUntil(reservation_.expires_at_unix_milliseconds));
  if (!(acknowledged == reservation_) ||
      acknowledged.helper_endpoint_identity_sha256 !=
          expected_helper_endpoint_identity_sha256_) {
    throw UnixSocketTransportError(
        "helper commit acknowledgement binding changed");
  }
  state_ = State::kCommitAccepted;
  return acknowledged;
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
LinuxOneShotClientSession::CancelReservation() {
  using desktop_updater::runtime::internal::EncodeNativeInstallWireCommandV1;
  using desktop_updater::runtime::internal::NativeInstallWireCommandV1;
  using desktop_updater::runtime::internal::ParseNativeInstallRecoveryResultV1;
  if (state_ != State::kPrepared) {
    throw UnixSocketTransportError("Linux helper session is not prepared");
  }
  const NativeInstallWireCommandV1 command{
      "cancelReservation",
      reservation_.protocol_version,
      reservation_.transaction_id,
      reservation_.ready_token,
      reservation_.journal_sha256,
      reservation_.helper_endpoint_identity_sha256};
  channel_.WriteFrame(EncodeNativeInstallWireCommandV1(command));
  const auto result = ParseNativeInstallRecoveryResultV1(
      channel_.ReadFrameUntil(reservation_.expires_at_unix_milliseconds));
  if (result.transaction_id != reservation_.transaction_id ||
      result.journal_sha256 != reservation_.journal_sha256 ||
      result.result_code != "rolledBack" ||
      result.verified_outcome != "oldTarget") {
    throw UnixSocketTransportError(
        "helper cancellation acknowledgement binding changed");
  }
  state_ = State::kCancelled;
  if (helper_process_id_ > 0) {
    int status = 0;
    pid_t reaped = -1;
    do {
      reaped = waitpid(helper_process_id_, &status, WNOHANG);
    } while (reaped < 0 && errno == EINTR);
    if (reaped == 0) {
      TerminateAndReap(helper_process_id_);
    }
    helper_process_id_ = -1;
  }
  return result;
}

std::string Sha256LinuxBytes(const std::string& bytes) {
  EVP_MD_CTX* context = EVP_MD_CTX_new();
  if (context == nullptr) {
    throw UnixSocketTransportError("SHA-256 context allocation failed");
  }
  std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
  unsigned int digest_length = 0;
  const bool ok =
      EVP_DigestInit_ex(context, EVP_sha256(), nullptr) == 1 &&
      EVP_DigestUpdate(context, bytes.data(), bytes.size()) == 1 &&
      EVP_DigestFinal_ex(context, digest.data(), &digest_length) == 1;
  EVP_MD_CTX_free(context);
  if (!ok || digest_length != 32) {
    throw UnixSocketTransportError("SHA-256 calculation failed");
  }
  std::ostringstream encoded;
  encoded << std::hex << std::setfill('0');
  for (unsigned int index = 0; index < digest_length; ++index) {
    encoded << std::setw(2) << static_cast<unsigned int>(digest[index]);
  }
  return encoded.str();
}

static std::string Sha256LinuxFd(int file_descriptor) {
  EVP_MD_CTX* context = EVP_MD_CTX_new();
  if (context == nullptr ||
      EVP_DigestInit_ex(context, EVP_sha256(), nullptr) != 1) {
    EVP_MD_CTX_free(context);
    throw UnixSocketTransportError("SHA-256 context setup failed");
  }
  std::array<char, 64 * 1024> buffer{};
  off_t offset = 0;
  for (;;) {
    ssize_t count = -1;
    do {
      count = pread(file_descriptor, buffer.data(), buffer.size(), offset);
    } while (count < 0 && errno == EINTR);
    if (count == 0) break;
    if (count < 0 ||
        EVP_DigestUpdate(context, buffer.data(),
                         static_cast<std::size_t>(count)) != 1) {
      EVP_MD_CTX_free(context);
      throw UnixSocketTransportError("helper file hash failed");
    }
    offset += count;
  }
  std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
  unsigned int digest_length = 0;
  const bool finalized =
      EVP_DigestFinal_ex(context, digest.data(), &digest_length) == 1;
  EVP_MD_CTX_free(context);
  if (!finalized || digest_length != 32) {
    throw UnixSocketTransportError("helper file hash failed");
  }
  std::ostringstream encoded;
  encoded << std::hex << std::setfill('0');
  for (unsigned int index = 0; index < digest_length; ++index) {
    encoded << std::setw(2) << static_cast<unsigned int>(digest[index]);
  }
  return encoded.str();
}

std::string Sha256LinuxFile(const std::filesystem::path& path) {
  ScopedFd file(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  struct stat status {};
  if (file.get() < 0 || fstat(file.get(), &status) != 0 ||
      !S_ISREG(status.st_mode)) {
    throw UnixSocketTransportError("helper file identity rejected");
  }
  return Sha256LinuxFd(file.get());
}

struct PortableHelperConnection {
  int socket_fd;
  std::string endpoint_digest;
  std::int64_t deadline;
  pid_t child;
};

static PortableHelperConnection ConnectUnprivilegedLinuxHelper(
    const std::filesystem::path& helper_path,
    const std::string& request_nonce,
    std::int64_t startup_timeout_milliseconds) {
  if (geteuid() == 0) {
    throw UnixSocketTransportError(
        "portable helper refuses root credentials; use the installed broker");
  }
  if (!IsNonce(request_nonce)) {
    throw UnixSocketTransportError("portable helper request nonce rejected");
  }
  const std::filesystem::path normalized = helper_path.lexically_normal();
  if (!normalized.is_absolute() || normalized != helper_path) {
    throw UnixSocketTransportError("portable helper locator rejected");
  }
  struct stat helper_path_status {};
  ScopedFd helper(open(helper_path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  struct stat helper_status {};
  if (lstat(helper_path.c_str(), &helper_path_status) != 0 ||
      helper.get() < 0 || fstat(helper.get(), &helper_status) != 0 ||
      !S_ISREG(helper_status.st_mode) || S_ISLNK(helper_path_status.st_mode) ||
      helper_path_status.st_dev != helper_status.st_dev ||
      helper_path_status.st_ino != helper_status.st_ino ||
      helper_status.st_uid != geteuid() ||
      (helper_status.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
      (helper_status.st_mode & S_IXUSR) == 0) {
    throw UnixSocketTransportError(
        "portable helper ownership or identity rejected");
  }
  const std::string endpoint_digest = Sha256LinuxFd(helper.get());
  const std::filesystem::path runtime_directory = SecureRuntimeDirectory();
  const std::filesystem::path socket_path =
      DeriveLinuxSocketPath(runtime_directory, request_nonce);
  struct stat unexpected {};
  if (lstat(socket_path.c_str(), &unexpected) == 0 || errno != ENOENT) {
    throw UnixSocketTransportError("Unix socket locator already exists");
  }

  ScopedFd listener(socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0));
  if (listener.get() < 0) {
    throw UnixSocketTransportError("Unix socket listener creation failed");
  }
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::strncpy(address.sun_path, socket_path.c_str(),
               sizeof(address.sun_path) - 1);
  const socklen_t address_length = static_cast<socklen_t>(
      offsetof(sockaddr_un, sun_path) + socket_path.string().size() + 1);
  if (bind(listener.get(), reinterpret_cast<sockaddr*>(&address),
           address_length) != 0 ||
      chmod(socket_path.c_str(), 0600) != 0 || listen(listener.get(), 1) != 0) {
    unlink(socket_path.c_str());
    throw UnixSocketTransportError("Unix socket listener setup failed");
  }
  struct stat bound_socket {};
  if (lstat(socket_path.c_str(), &bound_socket) != 0 ||
      !S_ISSOCK(bound_socket.st_mode) || bound_socket.st_uid != geteuid() ||
      (bound_socket.st_mode & 0077) != 0) {
    unlink(socket_path.c_str());
    throw UnixSocketTransportError("bound Unix socket identity rejected");
  }

  const pid_t child = fork();
  if (child < 0) {
    unlink(socket_path.c_str());
    throw UnixSocketTransportError("portable helper fork failed");
  }
  if (child == 0) {
    close(listener.get());
    if (fcntl(helper.get(), F_SETFD, 0) != 0) _exit(errno);
    std::string argument_zero = helper_path.filename().string();
    std::string socket_argument = socket_path.string();
    std::string nonce_argument = request_nonce;
    std::array<char*, 6> arguments = {
        argument_zero.data(), const_cast<char*>("--socket"),
        socket_argument.data(), const_cast<char*>("--nonce"),
        nonce_argument.data(), nullptr};
#ifdef SYS_execveat
    syscall(SYS_execveat, helper.get(), "", arguments.data(), environ,
            AT_EMPTY_PATH);
#else
    fexecve(helper.get(), arguments.data(), environ);
#endif
    const int launch_error = errno;
    _exit(launch_error > 0 && launch_error < 126 ? launch_error : 127);
  }

  PendingHelperLaunch pending(socket_path, bound_socket, child);
  const std::int64_t deadline = DeadlineAfter(startup_timeout_milliseconds);
  pollfd descriptor{listener.get(), POLLIN, 0};
  int ready = 0;
  for (;;) {
    const int remaining = RemainingPollMilliseconds(deadline);
    do {
      ready = poll(&descriptor, 1, std::min(remaining, 100));
    } while (ready < 0 && errno == EINTR);
    if (ready != 0) break;
    int child_status = 0;
    const pid_t observed = waitpid(child, &child_status, WNOHANG);
    if (observed == child) {
      pending.MarkChildReaped();
      const int exit_code = WIFEXITED(child_status)
                                ? WEXITSTATUS(child_status)
                                : -1;
      throw UnixSocketTransportError(
          "portable helper exited before connecting: " +
          std::to_string(exit_code));
    }
  }
  if (ready != 1 || (descriptor.revents & POLLIN) == 0) {
    throw UnixSocketTransportError("portable helper connection timed out");
  }
  ScopedFd connected(accept4(listener.get(), nullptr, nullptr, SOCK_CLOEXEC));
  struct stat observed_socket {};
  if (connected.get() < 0 || lstat(socket_path.c_str(), &observed_socket) != 0 ||
      observed_socket.st_dev != bound_socket.st_dev ||
      observed_socket.st_ino != bound_socket.st_ino) {
    throw UnixSocketTransportError("Unix socket accept identity changed");
  }
  const LinuxPeerBinding peer =
      ReadLinuxPeerBinding(connected.get(), request_nonce);
  struct stat peer_executable {};
  const std::filesystem::path peer_executable_path =
      "/proc/" + std::to_string(peer.pid) + "/exe";
  if (peer.pid != child || peer.uid != geteuid() ||
      stat(peer_executable_path.c_str(), &peer_executable) != 0 ||
      peer_executable.st_dev != helper_status.st_dev ||
      peer_executable.st_ino != helper_status.st_ino ||
      lstat(helper_path.c_str(), &helper_path_status) != 0 ||
      helper_path_status.st_dev != helper_status.st_dev ||
      helper_path_status.st_ino != helper_status.st_ino) {
    throw UnixSocketTransportError("portable helper peer identity rejected");
  }
  ReceiveSocketPathValidated(connected.get(), deadline);
  pending.RemoveExactSocket();
  PortableHelperConnection result{connected.release(), endpoint_digest,
                                  deadline, child};
  pending.TransferChildOwnership();
  return result;
}

std::unique_ptr<LinuxOneShotClientSession>
LaunchUnprivilegedLinuxHelper(
    const std::filesystem::path& helper_path,
    const std::string& canonical_request,
    std::int64_t startup_timeout_milliseconds) {
  if (geteuid() == 0) {
    throw UnixSocketTransportError(
        "portable helper refuses root credentials; use the installed broker");
  }
  const auto request = desktop_updater::runtime::internal::
      ParseNativeInstallTransactionRequestV1(canonical_request);
  PortableHelperConnection connection = ConnectUnprivilegedLinuxHelper(
      helper_path, request.request_nonce, startup_timeout_milliseconds);
  try {
    return std::make_unique<LinuxOneShotClientSession>(
        connection.socket_fd, connection.endpoint_digest, canonical_request,
        connection.deadline, connection.child);
  } catch (...) {
    TerminateAndReap(connection.child);
    throw;
  }
}

LinuxControlExchangeResult ExchangeUnprivilegedLinuxHelperControl(
    const std::filesystem::path& helper_path,
    const std::string& canonical_request,
    const std::string& request_nonce,
    std::int64_t startup_timeout_milliseconds) {
  PortableHelperConnection connection = ConnectUnprivilegedLinuxHelper(
      helper_path, request_nonce, startup_timeout_milliseconds);
  try {
    LinuxSeqpacketWireChannel channel(connection.socket_fd);
    channel.WriteFrame(canonical_request);
    std::string response = channel.ReadFrameUntil(connection.deadline);
    close(connection.socket_fd);
    connection.socket_fd = -1;
    const int status =
        WaitForLinuxChildExitUntil(connection.child, connection.deadline);
    connection.child = -1;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      throw UnixSocketTransportError(
          "portable control helper exited unsuccessfully");
    }
    return {std::move(response), std::move(connection.endpoint_digest)};
  } catch (...) {
    if (connection.socket_fd >= 0) close(connection.socket_fd);
    TerminateAndReap(connection.child);
    throw;
  }
}

static PortableHelperConnection ConnectPrivilegedLinuxBroker(
    const std::string& request_nonce,
    std::int64_t startup_timeout_milliseconds) {
  constexpr char broker_path[] = "/usr/libexec/desktop-updater-helper";
  if (geteuid() == 0 || !IsNonce(request_nonce)) {
    throw UnixSocketTransportError(
        "privileged broker requires a non-root authenticated caller");
  }
  struct stat broker_path_status {};
  ScopedFd broker(open(broker_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  struct stat broker_status {};
  struct stat broker_parent {};
  if (lstat(broker_path, &broker_path_status) != 0 || broker.get() < 0 ||
      fstat(broker.get(), &broker_status) != 0 ||
      lstat("/usr/libexec", &broker_parent) != 0 ||
      !S_ISREG(broker_status.st_mode) ||
      S_ISLNK(broker_path_status.st_mode) || broker_status.st_uid != 0 ||
      broker_parent.st_uid != 0 || !S_ISDIR(broker_parent.st_mode) ||
      (broker_status.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
      (broker_parent.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
      (broker_status.st_mode & S_IXUSR) == 0 ||
      broker_path_status.st_dev != broker_status.st_dev ||
      broker_path_status.st_ino != broker_status.st_ino) {
    throw UnixSocketTransportError(
        "fixed privileged broker identity rejected");
  }
  const std::string endpoint_digest = Sha256LinuxFd(broker.get());
  const std::filesystem::path runtime_directory = SecureRuntimeDirectory();
  const std::filesystem::path socket_path =
      DeriveLinuxSocketPath(runtime_directory, request_nonce);
  struct stat unexpected {};
  if (lstat(socket_path.c_str(), &unexpected) == 0 || errno != ENOENT) {
    throw UnixSocketTransportError("Unix socket locator already exists");
  }
  ScopedFd listener(socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0));
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::strncpy(address.sun_path, socket_path.c_str(),
               sizeof(address.sun_path) - 1);
  const socklen_t address_length = static_cast<socklen_t>(
      offsetof(sockaddr_un, sun_path) + socket_path.string().size() + 1);
  if (listener.get() < 0 ||
      bind(listener.get(), reinterpret_cast<sockaddr*>(&address),
           address_length) != 0 ||
      chmod(socket_path.c_str(), 0600) != 0 || listen(listener.get(), 1) != 0) {
    unlink(socket_path.c_str());
    throw UnixSocketTransportError("broker socket listener setup failed");
  }
  struct stat bound_socket {};
  if (lstat(socket_path.c_str(), &bound_socket) != 0 ||
      !S_ISSOCK(bound_socket.st_mode) || bound_socket.st_uid != geteuid() ||
      (bound_socket.st_mode & 0077) != 0) {
    unlink(socket_path.c_str());
    throw UnixSocketTransportError("broker socket identity rejected");
  }
  std::vector<std::string> arguments = {
      "/usr/bin/pkexec", broker_path, "--socket", socket_path.string(),
      "--nonce", request_nonce};
  ValidatePkexecArguments(arguments);
  const pid_t child = fork();
  if (child < 0) {
    unlink(socket_path.c_str());
    throw UnixSocketTransportError("pkexec fork failed");
  }
  if (child == 0) {
    close(listener.get());
    std::array<char*, 7> argv{};
    for (std::size_t index = 0; index < arguments.size(); ++index) {
      argv[index] = arguments[index].data();
    }
    execv(argv[0], argv.data());
    _exit(127);
  }
  PendingHelperLaunch pending(socket_path, bound_socket, child);
  const std::int64_t deadline = DeadlineAfter(startup_timeout_milliseconds);
  pollfd descriptor{listener.get(), POLLIN, 0};
  int ready = 0;
  for (;;) {
    const int remaining = RemainingPollMilliseconds(deadline);
    do {
      ready = poll(&descriptor, 1, std::min(remaining, 100));
    } while (ready < 0 && errno == EINTR);
    if (ready != 0) break;
    int child_status = 0;
    const pid_t observed = waitpid(child, &child_status, WNOHANG);
    if (observed == child) {
      pending.MarkChildReaped();
      const int exit_code = WIFEXITED(child_status)
                                ? WEXITSTATUS(child_status)
                                : -1;
      if (exit_code == 126) {
        throw UnixSocketTransportError(
            "Linux elevation authorization was cancelled");
      }
      if (exit_code == 127) {
        throw UnixSocketTransportError("Linux elevation is unavailable");
      }
      throw UnixSocketTransportError(
          "privileged broker exited before connecting");
    }
  }
  if (ready != 1 || (descriptor.revents & POLLIN) == 0) {
    throw UnixSocketTransportError("privileged broker connection timed out");
  }
  ScopedFd connected(accept4(listener.get(), nullptr, nullptr, SOCK_CLOEXEC));
  struct stat observed_socket {};
  if (connected.get() < 0 || lstat(socket_path.c_str(), &observed_socket) != 0 ||
      observed_socket.st_dev != bound_socket.st_dev ||
      observed_socket.st_ino != bound_socket.st_ino) {
    throw UnixSocketTransportError("broker socket accept identity changed");
  }
  const LinuxPeerBinding peer =
      ReadLinuxPeerBinding(connected.get(), request_nonce);
  struct stat peer_executable {};
  const std::filesystem::path peer_executable_path =
      "/proc/" + std::to_string(peer.pid) + "/exe";
  if (peer.uid != 0 ||
      stat(peer_executable_path.c_str(), &peer_executable) != 0 ||
      peer_executable.st_dev != broker_status.st_dev ||
      peer_executable.st_ino != broker_status.st_ino ||
      lstat(broker_path, &broker_path_status) != 0 ||
      broker_path_status.st_dev != broker_status.st_dev ||
      broker_path_status.st_ino != broker_status.st_ino) {
    throw UnixSocketTransportError("privileged broker peer rejected");
  }
  ReceiveSocketPathValidated(connected.get(), deadline);
  pending.RemoveExactSocket();
  PortableHelperConnection result{connected.release(), endpoint_digest,
                                  deadline, child};
  pending.TransferChildOwnership();
  return result;
}

std::unique_ptr<LinuxOneShotClientSession> LaunchPrivilegedLinuxBroker(
    const std::string& canonical_request,
    std::int64_t startup_timeout_milliseconds) {
  const auto request = runtime::internal::
      ParseNativeInstallTransactionRequestV1(canonical_request);
  PortableHelperConnection connection = ConnectPrivilegedLinuxBroker(
      request.request_nonce, startup_timeout_milliseconds);
  try {
    return std::make_unique<LinuxOneShotClientSession>(
        connection.socket_fd, connection.endpoint_digest, canonical_request,
        connection.deadline, connection.child);
  } catch (...) {
    TerminateAndReap(connection.child);
    throw;
  }
}

LinuxControlExchangeResult ExchangePrivilegedLinuxBrokerControl(
    const std::string& canonical_request,
    const std::string& request_nonce,
    std::int64_t startup_timeout_milliseconds) {
  PortableHelperConnection connection = ConnectPrivilegedLinuxBroker(
      request_nonce, startup_timeout_milliseconds);
  try {
    LinuxSeqpacketWireChannel channel(connection.socket_fd);
    channel.WriteFrame(canonical_request);
    std::string response = channel.ReadFrameUntil(connection.deadline);
    close(connection.socket_fd);
    connection.socket_fd = -1;
    const int status =
        WaitForLinuxChildExitUntil(connection.child, connection.deadline);
    connection.child = -1;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      throw UnixSocketTransportError(
          "privileged control broker exited unsuccessfully");
    }
    return {std::move(response), std::move(connection.endpoint_digest)};
  } catch (...) {
    if (connection.socket_fd >= 0) close(connection.socket_fd);
    TerminateAndReap(connection.child);
    throw;
  }
}

std::string DeriveLinuxSocketPath(const std::filesystem::path& runtime_dir,
                                  const std::string& nonce) {
  if (!IsNonce(nonce)) {
    throw UnixSocketTransportError("nonce must be 32-byte base64url");
  }
  const std::filesystem::path normalized = runtime_dir.lexically_normal();
  if (!normalized.is_absolute() || normalized != runtime_dir) {
    throw UnixSocketTransportError("socket runtime directory rejected");
  }
  const std::string result =
      (normalized / ("desktop-updater-" + nonce + ".sock")).string();
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
  SendSocketPathValidated(socket_fd);
  return socket_fd;
}

}  // namespace desktop_updater::helper
