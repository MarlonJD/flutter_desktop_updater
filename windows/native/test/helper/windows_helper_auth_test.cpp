#include <gtest/gtest.h>

#include <array>
#include <filesystem>
#include <string>

#include "helper_authenticode.h"
#include "helper_policy_windows.h"
#include "named_pipe_transport.h"
#include "windows_helper_bootstrap.h"
#include "windows_install_authorizer.h"

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

WindowsHelperPolicy ProtectedInnoTestPolicy() {
  return WindowsHelperPolicy::ForProtectedInnoTesting(
      "com.example.app",
      "Example Software LLC",
      "Trusted Helper LLC",
      std::string(64, 'a'),
      {L"C:\\Program Files\\Example"});
}

const char kPortablePolicy[] =
    "{\"allowedApplicationSigner\":{\"kind\":\"sha256\",\"value\":"
    "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},"
    "\"allowedHelperSigner\":{\"kind\":\"sha256\",\"value\":"
    "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},"
    "\"allowedInstallRoots\":[],\"allowedStrategies\":[{\"provider\":"
    "\"platformDirectory\",\"strategy\":\"directoryReplace\"},{\"provider\":"
    "\"platformFile\",\"strategy\":\"singleFileReplace\"}],"
    "\"allowedTargetClasses\":[\"sameUserWritable\"],"
    "\"applicationPackageId\":\"com.example.app\",\"helperServiceId\":"
    "\"com.example.desktop-updater.helper\",\"minimumHelperProtocolVersion\":1,"
    "\"policyId\":\"com.example.desktop-updater.portable\",\"policyVersion\":1,"
    "\"releaseRootPublicKeys\":[{\"algorithm\":\"ed25519\",\"keyId\":"
    "\"stable-2026\",\"publicKeyBase64\":"
    "\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\"}]}";

WindowsHelperPolicy PortablePolicy() {
  return WindowsHelperPolicy::Load(
      kPortablePolicy,
      "99b18f06fc11f18ad34b7cad9d10408ae0726679b20e44a84c518f886db0cf10",
      "com.example.app", std::string(64, 'b'));
}

VerifiedWindowsExecutable ValidIdentity() {
  return VerifiedWindowsExecutable{
      true,
      L"Trusted Helper LLC",
      std::string(64, 'c'),
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

TEST(WindowsHelperAuth, RetainedExecutableIdentityUsesTheOpenFileHandle) {
  std::array<wchar_t, 32768> path_buffer{};
  const DWORD path_length = GetModuleFileNameW(
      nullptr, path_buffer.data(), static_cast<DWORD>(path_buffer.size()));
  ASSERT_GT(path_length, 0U);
  ASSERT_LT(path_length, path_buffer.size());
  const std::filesystem::path executable_path(
      path_buffer.data(), path_buffer.data() + path_length);
  HANDLE executable = CreateFileW(
      executable_path.c_str(), GENERIC_READ | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  ASSERT_NE(INVALID_HANDLE_VALUE, executable);

  const VerifiedWindowsExecutable observed =
      VerifyRetainedWindowsExecutable(executable, executable_path);
  EXPECT_FALSE(observed.sha256.empty());
  EXPECT_TRUE(
      VerifyRetainedWindowsExecutableStillMatches(executable, observed));

  VerifiedWindowsExecutable changed = observed;
  changed.sha256.front() = changed.sha256.front() == '0' ? '1' : '0';
  EXPECT_FALSE(
      VerifyRetainedWindowsExecutableStillMatches(executable, changed));
  CloseHandle(executable);
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

TEST(WindowsHelperAuth, AcceptsSealedPortablePolicyWithoutElevationAuthority) {
  const WindowsHelperPolicy policy = PortablePolicy();
  EXPECT_TRUE(policy.is_portable());
  EXPECT_EQ("sha256", policy.application_signer_kind());
  EXPECT_EQ(std::string(64, 'a'), policy.application_signer_identity());
  EXPECT_EQ("sha256", policy.helper_signer_kind());
  EXPECT_EQ(std::string(64, 'b'), policy.helper_signer_identity());
  EXPECT_TRUE(policy.allowed_install_roots().empty());
  EXPECT_TRUE(policy.AllowsRequest(
      1, "sameUserWritable", "directoryReplace", "platformDirectory"));
  EXPECT_TRUE(policy.AllowsRequest(
      1, "sameUserWritable", "singleFileReplace", "platformFile"));
  EXPECT_FALSE(policy.AllowsRequest(
      1, "applicationDirectory", "directoryReplace", "platformDirectory"));
  EXPECT_FALSE(policy.AllowsRequest(
      1, "sameUserWritable", "verifiedInstallerHandoff", "windowsInno"));
}

TEST(WindowsHelperAuth, PortableHelperMustRemainSignedAndDigestBound) {
  VerifiedWindowsExecutable portable{
      true,
      L"Trusted Helper LLC",
      std::string(64, 'd'),
      std::string(64, 'b'),
      L"C:\\Users\\caller\\Example\\desktop_updater_install_helper.exe",
      false,
      7,
      {1, 2},
  };
  EXPECT_NO_THROW(ValidateWindowsHelperIdentity(
      portable, PortablePolicy(), false));

  portable.signature_valid = false;
  EXPECT_THROW(ValidateWindowsHelperIdentity(
                   portable, PortablePolicy(), false),
               WindowsHelperTrustError);
  portable.signature_valid = true;
  portable.sha256 = std::string(64, 'c');
  EXPECT_THROW(ValidateWindowsHelperIdentity(
                   portable, PortablePolicy(), false),
               WindowsHelperTrustError);
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

TEST(WindowsHelperAuth, ProtectedInnoAuthorityIsExplicitAndNarrow) {
  const WindowsHelperPolicy policy = ProtectedInnoTestPolicy();
  EXPECT_FALSE(policy.is_portable());
  EXPECT_TRUE(policy.AllowsRequest(
      1, "applicationDirectory", "verifiedInstallerHandoff", "windowsInno"));
  EXPECT_FALSE(policy.AllowsRequest(
      1, "applicationDirectory", "directoryReplace", "platformDirectory"));
  EXPECT_FALSE(policy.AllowsRequest(
      1, "sameUserWritable", "verifiedInstallerHandoff", "windowsInno"));
}

TEST(WindowsHelperAuth, ProductionAuthorizerClassifiesOnlySealedStrategies) {
  desktop_updater::runtime::internal::NativeInstallTransactionRequestV1
      request;
  request.protocol_version = 1;
  request.target.target_class = "applicationDirectory";
  request.strategy = "directoryReplace";
  request.provider = "platformDirectory";
  EXPECT_EQ(WindowsProtectedInstallTransactionKind::kDirectoryReplace,
            ClassifyWindowsProtectedInstallTransaction(TestPolicy(), request));

  request.strategy = "verifiedInstallerHandoff";
  request.provider = "windowsInno";
  EXPECT_EQ(WindowsProtectedInstallTransactionKind::kWindowsInno,
            ClassifyWindowsProtectedInstallTransaction(
                ProtectedInnoTestPolicy(), request));
  EXPECT_THROW(ClassifyWindowsProtectedInstallTransaction(TestPolicy(), request),
               desktop_updater::runtime::internal::
                   NativeInstallAuthorizationError);

  request.target.target_class = "sameUserWritable";
  EXPECT_THROW(ClassifyWindowsProtectedInstallTransaction(
                   ProtectedInnoTestPolicy(), request),
               desktop_updater::runtime::internal::
                   NativeInstallAuthorizationError);
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

TEST(WindowsHelperAuth, PipeDaclAdmitsExactOverTheShoulderHelperSid) {
  const std::wstring caller_sid = L"S-1-5-21-100";
  const std::wstring helper_sid = L"S-1-5-21-200";
  EXPECT_EQ(L"D:P(A;;GA;;;S-1-5-21-100)(A;;GA;;;SY)",
            BuildCallerPipeDaclSddl(caller_sid, L""));
  EXPECT_EQ(
      L"D:P(A;;GA;;;S-1-5-21-100)(A;;GA;;;S-1-5-21-200)(A;;GA;;;SY)",
      BuildCallerPipeDaclSddl(caller_sid, helper_sid));
  EXPECT_EQ(L"D:P(A;;GA;;;S-1-5-21-100)(A;;GA;;;SY)",
            BuildCallerPipeDaclSddl(caller_sid, caller_sid));
  EXPECT_EQ(std::wstring::npos,
            BuildCallerPipeDaclSddl(caller_sid, helper_sid).find(L";;;BA"));
  EXPECT_THROW(BuildCallerPipeDaclSddl(L"", helper_sid),
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
