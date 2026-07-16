#include <gtest/gtest.h>

#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "linux_helper_policy.h"
#include "linux_mount_guard.h"
#include "linux_native_install_service.h"
#include "native_install_request.h"
#include "native_install_wire.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {

namespace {

class ScopedRuntimeDirectory {
 public:
  ScopedRuntimeDirectory() {
    std::string pattern = "/tmp/desktop-updater-runtime-XXXXXX";
    std::vector<char> encoded(pattern.begin(), pattern.end());
    encoded.push_back('\0');
    char* created = mkdtemp(encoded.data());
    if (created == nullptr || chmod(created, 0700) != 0) {
      throw std::runtime_error("secure runtime directory setup failed");
    }
    path_ = created;
    if (const char* current = std::getenv("XDG_RUNTIME_DIR"); current != nullptr) {
      previous_ = current;
    }
    if (setenv("XDG_RUNTIME_DIR", path_.c_str(), 1) != 0) {
      throw std::runtime_error("XDG_RUNTIME_DIR setup failed");
    }
  }

  ~ScopedRuntimeDirectory() {
    if (previous_.has_value()) {
      (void)setenv("XDG_RUNTIME_DIR", previous_->c_str(), 1);
    } else {
      (void)unsetenv("XDG_RUNTIME_DIR");
    }
    std::error_code error;
    std::filesystem::remove_all(path_, error);
  }

  const std::filesystem::path& path() const { return path_; }

 private:
  std::filesystem::path path_;
  std::optional<std::string> previous_;
};

LinuxHelperPolicy TestPolicy() {
  return LinuxHelperPolicy::ForTesting(
      "com.example.app", "Example Publisher", std::string(64, 'a'),
      "/usr/libexec/desktop-updater-helper", {"/opt/example"});
}

desktop_updater::runtime::internal::NativeInstallTransactionRequestV1
CanonicalRequest() {
  using desktop_updater::runtime::internal::
      NativeInstallTransactionRequestV1;
  NativeInstallTransactionRequestV1 request;
  request.schema_version = 1;
  request.protocol_version = 1;
  request.transaction_id = "00000000-0000-4000-8000-000000000009";
  request.policy_id = "com.example.desktop-updater.portable";
  request.package_id = "com.example.app";
  request.strategy = "directoryReplace";
  request.provider = "platformDirectory";
  request.target = {"applicationDirectory", "/opt/Example", "Example",
                    "bin/example", std::string(64, 'a')};
  request.current_identity = {"1.0.0", 1, std::string(64, 'b')};
  request.desired_identity = {"2.0.0", 2, std::string(64, 'c')};
  request.stage = {"/opt/desktop_updater_stage", std::string(64, 'd'),
                   std::string(64, 'e'), std::string(64, 'f'), 42};
  request.signed_descriptor = {
      std::string(64, 'c'), "ed25519", "stable-2026",
      std::string(86, 'A') + "=="};
  request.caller = {static_cast<std::int64_t>(getpid()), "linux:123",
                    std::string(64, 'a'), "com.example.app",
                    std::string(64, 'a')};
  request.request_nonce = std::string(43, 'A');
  request.diagnostics_destination = {true, "platformLog", {}};
  return request;
}

TEST(LinuxHelperAuth, RequiresRootOwnedNonWritableBrokerAndPolicy) {
  const LinuxFileSecurity sealed{0, 0, S_IFREG | 0755, false, false};
  EXPECT_NO_THROW(ValidateProtectedFileSecurity(sealed, "broker"));
  EXPECT_THROW(
      ValidateProtectedFileSecurity(
          LinuxFileSecurity{1000, 0, S_IFREG | 0755, false, false},
          "broker"),
      LinuxHelperPolicyError);
  EXPECT_THROW(
      ValidateProtectedFileSecurity(
          LinuxFileSecurity{0, 0, S_IFREG | 0775, false, false}, "policy"),
      LinuxHelperPolicyError);
  EXPECT_THROW(
      ValidateProtectedFileSecurity(
          LinuxFileSecurity{0, 0, S_IFREG | 0755, true, false}, "broker"),
      LinuxHelperPolicyError);
}

TEST(LinuxHelperAuth, BindsExactBrokerDigestAndPackagePolicy) {
  LinuxVerifiedFile broker{
      "/usr/libexec/desktop-updater-helper", 7, 9, std::string(64, 'a'),
      LinuxFileSecurity{0, 0, S_IFREG | 0755, false, false}};
  EXPECT_NO_THROW(ValidateLinuxBrokerIdentity(broker, TestPolicy()));
  broker.sha256 = std::string(64, 'b');
  EXPECT_THROW(ValidateLinuxBrokerIdentity(broker, TestPolicy()),
               LinuxHelperPolicyError);
  EXPECT_THROW(LinuxHelperPolicy::ForTesting(
                   "com.example.other", "", std::string(64, 'a'),
                   "/tmp/helper", {}),
               LinuxHelperPolicyError);
}

TEST(LinuxHelperAuth,
     AllowedRootTraversalRejectsIntermediateSymlinkBeforeOutsideMutation) {
  ScopedRuntimeDirectory fixture;
  const std::filesystem::path allowed_root = fixture.path() / "allowed";
  const std::filesystem::path outside_root = fixture.path() / "outside";
  const std::filesystem::path outside_parent = outside_root / "real-parent";
  const std::filesystem::path redirect = allowed_root / "redirect";
  const std::filesystem::path candidate_parent = redirect / "real-parent";
  const std::filesystem::path outside_marker =
      outside_parent / "escaped-mutation";
  std::filesystem::create_directories(allowed_root);
  std::filesystem::create_directories(outside_parent);
  std::filesystem::create_directory_symlink(outside_root, redirect);

  bool rejected = false;
  try {
    auto parent = OpenLinuxDirectory(candidate_parent.string());
    auto marker = OpenLinuxRelativeNoFollow(
        parent.get(), outside_marker.filename().string(),
        O_CREAT | O_EXCL | O_WRONLY, 0600);
  } catch (const LinuxMountGuardError&) {
    rejected = true;
  }

  EXPECT_TRUE(rejected);
  EXPECT_FALSE(std::filesystem::exists(outside_marker));
}

TEST(LinuxHelperAuth,
     ProtectedBrokerRejectsCopiedLauncherAtDifferentInstallTarget) {
  ScopedRuntimeDirectory fixture;
  const std::filesystem::path target = fixture.path() / "ProtectedTarget";
  const std::filesystem::path copied_launcher = target / "copied-launcher";
  std::filesystem::create_directories(target);
  ASSERT_TRUE(std::filesystem::copy_file("/proc/self/exe", copied_launcher));
  ASSERT_EQ(0, chmod(copied_launcher.c_str(), 0755));

  auto request = CanonicalRequest();
  request.target.path_hint = target.string();
  request.target.target_name_hint = target.filename().string();
  request.target.executable_relative_path = copied_launcher.filename().string();
  const LinuxPeerBinding peer{
      getpid(), geteuid(), getegid(), LinuxProcessStartIdentity(getpid()),
      request.request_nonce};
  auto retained_target = OpenLinuxDirectory(target.string());

  try {
    ProveAuthenticatedLinuxInstallTarget(peer, request,
                                         retained_target.get());
    FAIL() << "copied launcher unexpectedly proved the protected target";
  } catch (const LinuxHelperPolicyError& error) {
    EXPECT_NE(std::string::npos,
              std::string(error.what()).find(
                  "authenticated caller executable does not match install "
                  "target"));
  }
}

TEST(LinuxHelperAuth, ProvesTheExactAuthenticatedRunningExecutable) {
  std::string executable(4096, '\0');
  const ssize_t length =
      readlink("/proc/self/exe", executable.data(), executable.size());
  ASSERT_GT(length, 0);
  executable.resize(static_cast<std::size_t>(length));
  const std::filesystem::path executable_path(executable);
  auto request = CanonicalRequest();
  request.target.path_hint = executable_path.parent_path().string();
  request.target.target_name_hint =
      executable_path.parent_path().filename().string();
  request.target.executable_relative_path = executable_path.filename().string();
  const LinuxPeerBinding peer{
      getpid(), geteuid(), getegid(), LinuxProcessStartIdentity(getpid()),
      request.request_nonce};
  auto retained_target =
      OpenLinuxDirectory(executable_path.parent_path().string());
  EXPECT_NO_THROW(ProveAuthenticatedLinuxInstallTarget(
      peer, request, retained_target.get()));
}

TEST(LinuxHelperAuth, RetainedRecoveryAuthorityCannotAuthorizeNewInstall) {
  using desktop_updater::runtime::internal::
      EncodeCanonicalNativeInstallTransactionRequestV1;
  ScopedRuntimeDirectory fixture;
  const auto request = CanonicalRequest();
  const std::filesystem::path authority =
      fixture.path() / (request.transaction_id + ".authority");
  std::filesystem::create_directories(authority);
  int sockets[2] = {-1, -1};
  ASSERT_EQ(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets), 0);
  LinuxSeqpacketWireChannel channel(sockets[0]);
  const LinuxPeerBinding peer{
      getpid(), geteuid(), getegid(), LinuxProcessStartIdentity(getpid()),
      request.request_nonce};

  EXPECT_THROW(
      RunLinuxNativeInstallService(
          channel, peer, authority / "desktop-updater-helper", false,
          EncodeCanonicalNativeInstallTransactionRequestV1(request)),
      LinuxHelperPolicyError);
  close(sockets[0]);
  close(sockets[1]);
}

TEST(LinuxHelperAuth, SocketPeerAndNonceAreBoundExactlyOnce) {
  const std::string nonce(43, 'A');
  const std::string socket = DeriveLinuxSocketPath("/run/user/1000", nonce);
  EXPECT_EQ("/run/user/1000/desktop-updater-" + nonce + ".sock", socket);
  EXPECT_THROW(DeriveLinuxSocketPath("/tmp", std::string(43, '/')),
               UnixSocketTransportError);

  const LinuxPeerBinding binding{4242, 1000, 1000, 99, nonce};
  EXPECT_NO_THROW(ValidateLinuxPeerBinding(binding, binding));
  auto spoof = binding;
  spoof.uid = 0;
  EXPECT_THROW(ValidateLinuxPeerBinding(binding, spoof),
               UnixSocketTransportError);
  spoof = binding;
  spoof.process_start_identity = 100;
  EXPECT_THROW(ValidateLinuxPeerBinding(binding, spoof),
               UnixSocketTransportError);
}

TEST(LinuxHelperAuth, PkexecReceivesOnlySocketAndNonce) {
  const std::string nonce(43, 'A');
  EXPECT_NO_THROW(ValidatePkexecArguments(
      {"/usr/bin/pkexec", "/usr/libexec/desktop-updater-helper", "--socket",
       "/run/user/1000/desktop-updater-" + nonce + ".sock", "--nonce",
       nonce}));
  EXPECT_THROW(ValidatePkexecArguments(
                   {"/usr/bin/pkexec", "/usr/libexec/desktop-updater-helper",
                    "--target", "/opt/example"}),
               UnixSocketTransportError);
  EXPECT_THROW(ValidatePkexecArguments(
                   {"/usr/bin/pkexec", "/tmp/fake-helper", "--socket", "x",
                    "--nonce", std::string(43, 'A')}),
               UnixSocketTransportError);
  EXPECT_EQ(PkexecResult::kCancelled, ClassifyPkexecExit(126));
}

TEST(LinuxHelperAuth, CanonicalV1FramesRoundTripAcrossSeqpacket) {
  using desktop_updater::runtime::internal::
      EncodeCanonicalNativeInstallTransactionRequestV1;
  using desktop_updater::runtime::internal::
      EncodeNativeInstallReservationV1;
  using desktop_updater::runtime::internal::NativeInstallReservationV1;
  using desktop_updater::runtime::internal::
      ParseNativeInstallReservationV1;
  using desktop_updater::runtime::internal::
      ParseNativeInstallTransactionRequestV1;

  int sockets[2] = {-1, -1};
  ASSERT_EQ(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets), 0);
  LinuxSeqpacketWireChannel client(sockets[0]);
  LinuxSeqpacketWireChannel helper(sockets[1]);
  const auto request = CanonicalRequest();
  const std::string canonical_request =
      EncodeCanonicalNativeInstallTransactionRequestV1(request);

  client.WriteFrame(canonical_request);
  const auto observed =
      ParseNativeInstallTransactionRequestV1(helper.ReadFrame());
  EXPECT_EQ(request.transaction_id, observed.transaction_id);
  EXPECT_EQ(request.request_nonce, observed.request_nonce);

  const NativeInstallReservationV1 reservation{
      1,
      request.transaction_id,
      std::string(43, 'B'),
      std::string(64, 'c'),
      std::string(64, 'd'),
      4'000'000'000'000LL,
  };
  helper.WriteFrame(EncodeNativeInstallReservationV1(reservation));
  EXPECT_EQ(reservation,
            ParseNativeInstallReservationV1(client.ReadFrameUntil(
                reservation.expires_at_unix_milliseconds)));

  close(sockets[0]);
  close(sockets[1]);
}

TEST(LinuxHelperAuth, RejectsAdHocAndLengthMismatchedFrames) {
  int sockets[2] = {-1, -1};
  ASSERT_EQ(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets), 0);
  LinuxSeqpacketWireChannel receiver(sockets[1]);

  const std::string ad_hoc = "READY caller-chosen-token";
  ASSERT_EQ(send(sockets[0], ad_hoc.data(), ad_hoc.size(), MSG_NOSIGNAL),
            static_cast<ssize_t>(ad_hoc.size()));
  EXPECT_THROW(receiver.ReadFrame(), UnixSocketTransportError);

  const std::vector<unsigned char> mismatched = {0, 0, 0, 5, '{', '}'};
  ASSERT_EQ(send(sockets[0], mismatched.data(), mismatched.size(), MSG_NOSIGNAL),
            static_cast<ssize_t>(mismatched.size()));
  EXPECT_THROW(receiver.ReadFrame(), UnixSocketTransportError);

  close(sockets[0]);
  close(sockets[1]);
}

TEST(LinuxHelperAuth, OneShotClientUsesCanonicalReservationAndCommand) {
  using desktop_updater::runtime::internal::
      EncodeCanonicalNativeInstallTransactionRequestV1;
  using desktop_updater::runtime::internal::
      EncodeNativeInstallReservationV1;
  using desktop_updater::runtime::internal::
      ParseNativeInstallTransactionRequestV1;
  using desktop_updater::runtime::internal::ParseNativeInstallWireCommandV1;

  int sockets[2] = {-1, -1};
  ASSERT_EQ(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets), 0);
  const auto request = CanonicalRequest();
  const std::string canonical_request =
      EncodeCanonicalNativeInstallTransactionRequestV1(request);
  const std::string endpoint_digest(64, 'd');
  const desktop_updater::runtime::internal::NativeInstallReservationV1
      reservation{1,
                  request.transaction_id,
                  std::string(43, 'B'),
                  std::string(64, 'c'),
                  endpoint_digest,
                  4'000'000'000'000LL};

  std::thread helper([&] {
    LinuxSeqpacketWireChannel channel(sockets[1]);
    const auto observed =
        ParseNativeInstallTransactionRequestV1(channel.ReadFrame());
    EXPECT_EQ(request.transaction_id, observed.transaction_id);
    channel.WriteFrame(EncodeNativeInstallReservationV1(reservation));
    const auto command =
        ParseNativeInstallWireCommandV1(channel.ReadFrameUntil(
            reservation.expires_at_unix_milliseconds));
    EXPECT_EQ("commitAfterExit", command.operation);
    EXPECT_EQ(reservation.transaction_id, command.transaction_id);
    EXPECT_EQ(reservation.ready_token, command.ready_token);
    channel.WriteFrame(EncodeNativeInstallReservationV1(reservation));
    close(sockets[1]);
  });

  LinuxOneShotClientSession session(
      sockets[0], endpoint_digest, canonical_request,
      reservation.expires_at_unix_milliseconds);
  EXPECT_EQ(reservation, session.reservation());
  EXPECT_EQ(reservation, session.CommitAfterExit());
  helper.join();
}

TEST(LinuxHelperAuth, StartupTimeoutRemovesSocketAndReapsChild) {
  using desktop_updater::runtime::internal::
      EncodeCanonicalNativeInstallTransactionRequestV1;

  if (geteuid() == 0) {
    GTEST_SKIP() << "portable helper launch requires a non-root test user";
  }
  ScopedRuntimeDirectory runtime_directory;
  auto request = CanonicalRequest();
  request.request_nonce = std::string(43, 'C');
  const std::filesystem::path socket_path =
      DeriveLinuxSocketPath(runtime_directory.path(), request.request_nonce);

  EXPECT_THROW(
      LaunchUnprivilegedLinuxHelper(
          DESKTOP_UPDATER_NONCONNECTING_HELPER_FIXTURE,
          EncodeCanonicalNativeInstallTransactionRequestV1(request), 25),
      UnixSocketTransportError);
  EXPECT_FALSE(std::filesystem::exists(socket_path));
  EXPECT_EQ(-1, waitpid(-1, nullptr, WNOHANG));
  EXPECT_EQ(ECHILD, errno);
}

TEST(LinuxHelperAuth, PortableLauncherRejectsRootCredentials) {
  if (geteuid() != 0) {
    GTEST_SKIP() << "root credential boundary requires a root test user";
  }
  try {
    (void)LaunchUnprivilegedLinuxHelper("/does/not/matter", "{}", 25);
    FAIL() << "portable helper unexpectedly accepted root credentials";
  } catch (const UnixSocketTransportError& error) {
    EXPECT_NE(std::string::npos,
              std::string(error.what()).find("refuses root credentials"));
  }
}

TEST(LinuxHelperAuth, FailedCommandReapsUnacknowledgedHelperChild) {
  using desktop_updater::runtime::internal::
      EncodeCanonicalNativeInstallTransactionRequestV1;
  using desktop_updater::runtime::internal::EncodeNativeInstallReservationV1;
  using desktop_updater::runtime::internal::ParseNativeInstallWireCommandV1;

  int sockets[2] = {-1, -1};
  ASSERT_EQ(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets), 0);
  const auto request = CanonicalRequest();
  const std::string canonical_request =
      EncodeCanonicalNativeInstallTransactionRequestV1(request);
  const std::string endpoint_digest(64, 'd');
  const desktop_updater::runtime::internal::NativeInstallReservationV1
      reservation{1,
                  request.transaction_id,
                  std::string(43, 'B'),
                  std::string(64, 'c'),
                  endpoint_digest,
                  4'000'000'000'000LL};

  const pid_t child = fork();
  ASSERT_GE(child, 0);
  if (child == 0) {
    close(sockets[0]);
    try {
      LinuxSeqpacketWireChannel channel(sockets[1]);
      (void)channel.ReadFrame();
      channel.WriteFrame(EncodeNativeInstallReservationV1(reservation));
      (void)ParseNativeInstallWireCommandV1(
          channel.ReadFrameUntil(reservation.expires_at_unix_milliseconds));
      close(sockets[1]);
      for (;;) pause();
    } catch (...) {
      _exit(91);
    }
  }

  close(sockets[1]);
  {
    LinuxOneShotClientSession session(
        sockets[0], endpoint_digest, canonical_request,
        reservation.expires_at_unix_milliseconds, child);
    EXPECT_THROW(session.CommitAfterExit(), UnixSocketTransportError);
  }
  EXPECT_EQ(-1, waitpid(child, nullptr, WNOHANG));
  EXPECT_EQ(ECHILD, errno);
}

TEST(LinuxHelperAuth, ChildWaitRejectsNonChildInsteadOfFabricatingSuccess) {
  const auto deadline =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::system_clock::now().time_since_epoch())
          .count() +
      100;
  EXPECT_THROW(WaitForLinuxChildExitUntil(getpid(), deadline),
               UnixSocketTransportError);
}

TEST(LinuxHelperAuth, ChildWaitUsesDeadlineAndReturnsExactExitStatus) {
  const pid_t exiting = fork();
  ASSERT_GE(exiting, 0);
  if (exiting == 0) _exit(23);
  const auto now = [] {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
  };
  const int status = WaitForLinuxChildExitUntil(exiting, now() + 1'000);
  ASSERT_TRUE(WIFEXITED(status));
  EXPECT_EQ(23, WEXITSTATUS(status));

  const pid_t blocked = fork();
  ASSERT_GE(blocked, 0);
  if (blocked == 0) {
    for (;;) pause();
  }
  EXPECT_THROW(WaitForLinuxChildExitUntil(blocked, now() + 25),
               UnixSocketTransportError);
  ASSERT_EQ(0, kill(blocked, SIGKILL));
  int killed = 0;
  ASSERT_EQ(blocked, waitpid(blocked, &killed, 0));
  ASSERT_TRUE(WIFSIGNALED(killed));
  EXPECT_EQ(SIGKILL, WTERMSIG(killed));
}

}  // namespace
}  // namespace desktop_updater::helper
