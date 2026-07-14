#include <gtest/gtest.h>

#include <string>

#include "helper_authenticode.h"
#include "helper_policy_windows.h"
#include "named_pipe_transport.h"
#include "windows_helper_bootstrap.h"

namespace desktop_updater::helper {
namespace {

WindowsHelperPolicy TestPolicy() {
  return WindowsHelperPolicy::ForTesting(
      "com.example.app",
      "Example Software LLC",
      "Trusted Helper LLC",
      std::string(64, 'a'),
      {L"C:\\Program Files\\Example"});
}

VerifiedWindowsExecutable ValidIdentity() {
  return VerifiedWindowsExecutable{
      true,
      L"Trusted Helper LLC",
      std::string(64, 'a'),
      L"C:\\Program Files\\Example\\desktop_updater_install_helper.exe",
      true,
      7,
      {1, 2},
  };
}

TEST(WindowsHelperAuth, AcceptsOnlyExactSignedProtectedHelper) {
  EXPECT_NO_THROW(ValidateWindowsHelperIdentity(
      ValidIdentity(), TestPolicy(), true));

  auto wrong_signer = ValidIdentity();
  wrong_signer.publisher = L"Attacker LLC";
  EXPECT_THROW(ValidateWindowsHelperIdentity(
                   wrong_signer, TestPolicy(), true),
               WindowsHelperTrustError);

  auto unsigned_helper = ValidIdentity();
  unsigned_helper.signature_valid = false;
  EXPECT_THROW(ValidateWindowsHelperIdentity(
                   unsigned_helper, TestPolicy(), true),
               WindowsHelperTrustError);

  auto replaced_helper = ValidIdentity();
  replaced_helper.sha256 = std::string(64, 'b');
  EXPECT_THROW(ValidateWindowsHelperIdentity(
                   replaced_helper, TestPolicy(), true),
               WindowsHelperTrustError);

  auto writable_helper = ValidIdentity();
  writable_helper.installer_protected_location = false;
  EXPECT_THROW(ValidateWindowsHelperIdentity(
                   writable_helper, TestPolicy(), true),
               WindowsHelperTrustError);
}

TEST(WindowsHelperAuth, RejectsPortableElevationAndUnsealedPolicy) {
  EXPECT_THROW(WindowsHelperPolicy::ForTesting(
                   "com.example.app",
                   "",
                   "",
                   std::string(64, 'a'),
                   {}),
               WindowsHelperPolicyError);
  EXPECT_EQ(
      WindowsHelperPolicyError::Code::kPortableElevationRejected,
      WindowsHelperPolicy::PortableElevationErrorForTesting());
}

TEST(WindowsHelperAuth, RetainsCompleteSealedAuthorizationContext) {
  const WindowsHelperPolicy policy = TestPolicy();
  EXPECT_EQ("com.example.desktop-updater", policy.policy_id());
  EXPECT_EQ(1, policy.minimum_helper_protocol_version());
  EXPECT_FALSE(policy.release_root_public_keys().empty());
  EXPECT_TRUE(policy.AllowsRequest(
      1, "applicationDirectory", "directoryReplace", "platformDirectory"));
  EXPECT_FALSE(policy.AllowsRequest(
      1, "applicationDirectory", "verifiedInstallerHandoff", "windowsInno"));
  EXPECT_FALSE(policy.AllowsRequest(
      2, "applicationDirectory", "directoryReplace", "platformDirectory"));
}

TEST(WindowsHelperAuth, PipeNameAndPeerAreBoundToOneNonceAndToken) {
  const std::string nonce(43, 'A');
  const std::wstring pipe_name = DerivePipeName(nonce);
  EXPECT_EQ(L"\\\\.\\pipe\\desktop-updater-" +
                std::wstring(43, L'A'),
            pipe_name);
  EXPECT_THROW(DerivePipeName(std::string(43, '/')),
               NamedPipeTransportError);

  PeerBinding binding{4242, L"S-1-5-21-100", nonce};
  EXPECT_NO_THROW(ValidatePeerBinding(
      binding, 4242, L"S-1-5-21-100", nonce));
  EXPECT_THROW(ValidatePeerBinding(
                   binding, 4243, L"S-1-5-21-100", nonce),
               NamedPipeTransportError);
  EXPECT_THROW(ValidatePeerBinding(
                   binding, 4242, L"S-1-5-21-999", nonce),
               NamedPipeTransportError);
  EXPECT_THROW(ValidatePeerBinding(
                   binding, 4242, L"S-1-5-21-100", std::string(43, 'B')),
               NamedPipeTransportError);
}

TEST(WindowsHelperAuth, UacCancellationAndTimeoutRemainPreMutation) {
  EXPECT_EQ(ElevationLaunchResult::kCancelled,
            ClassifyElevationResult(ERROR_CANCELLED, false));
  EXPECT_EQ(ElevationLaunchResult::kTimedOut,
            ClassifyElevationResult(WAIT_TIMEOUT, true));
}

TEST(WindowsHelperAuth, GeneratesUnpredictableReadyTokenShape) {
  const std::string first = SecureWindowsReadyToken();
  const std::string second = SecureWindowsReadyToken();
  EXPECT_EQ(43U, first.size());
  EXPECT_EQ(43U, second.size());
  EXPECT_NE(first, second);
  EXPECT_EQ(std::string::npos, first.find_first_not_of(
                                   "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                   "abcdefghijklmnopqrstuvwxyz"
                                   "0123456789-_"));
}

}  // namespace
}  // namespace desktop_updater::helper
