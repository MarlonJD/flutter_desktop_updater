#include <gtest/gtest.h>

#include <sys/stat.h>
#include <sys/types.h>

#include <string>
#include <vector>

#include "linux_helper_policy.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

LinuxHelperPolicy TestPolicy() {
  return LinuxHelperPolicy::ForTesting(
      "com.example.app", "Example Publisher", std::string(64, 'a'),
      "/usr/libexec/desktop-updater-helper", {"/opt/example"});
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

}  // namespace
}  // namespace desktop_updater::helper
