#include <gtest/gtest.h>

#include <string>

#include "windows_install_authorizer.h"

namespace desktop_updater::helper {
namespace {

WindowsHelperPolicy TestPolicy() {
  return WindowsHelperPolicy::ForTesting(
      "com.example.app", "Example Software LLC", "Trusted Helper LLC",
      std::string(64, 'a'), {L"C:\\Program Files\\Example"});
}

desktop_updater::runtime::internal::NativeInstallTransactionRequestV1
Request() {
  using desktop_updater::runtime::internal::
      NativeInstallTransactionRequestV1;
  NativeInstallTransactionRequestV1 request;
  request.package_id = "com.example.app";
  request.target.executable_relative_path = "bin/example.exe";
  request.signed_descriptor.canonical_sha256 = std::string(64, 'b');
  request.stage.provenance_sha256 = std::string(64, 'c');
  request.stage.artifact_sha256 = std::string(64, 'd');
  return request;
}

desktop_updater::runtime::internal::StageProvenanceMarker Marker() {
  desktop_updater::runtime::internal::StageProvenanceMarker marker;
  marker.entries.push_back(
      {"bin/example.exe", "file", 42, std::string(64, 'e'), ""});
  return marker;
}

TEST(WindowsInstallAuthorizer, RetainsCompleteSealedPolicy) {
  const WindowsHelperPolicy policy = TestPolicy();
  const auto mapped = BuildWindowsNativeInstallAuthorizationPolicy(policy);
  EXPECT_EQ(policy.policy_id(), mapped.policy_id);
  EXPECT_EQ(policy.application_package_id(), mapped.application_package_id);
  EXPECT_EQ(policy.allowed_target_classes(), mapped.allowed_target_classes);
  ASSERT_EQ(1U, mapped.release_root_public_keys.size());
  EXPECT_EQ(policy.release_root_public_keys()[0].key_id,
            mapped.release_root_public_keys[0].key_id);
  ASSERT_EQ(1U, mapped.allowed_strategies.size());
  EXPECT_EQ("directoryReplace", mapped.allowed_strategies[0].strategy);
  EXPECT_EQ("platformDirectory", mapped.allowed_strategies[0].provider);
  EXPECT_EQ(1, mapped.minimum_helper_protocol_version);
}

TEST(WindowsInstallAuthorizer, RejectsExecutableInventoryDrift) {
  const auto expected =
      BuildWindowsExpectedPayloadIdentity(Request(), Marker(),
                                          std::string(64, 'f'), TestPolicy());
  EXPECT_EQ("com.example.app", expected.package_id);
  EXPECT_EQ("Example Software LLC", expected.authenticode_publisher);
  EXPECT_EQ(std::string(64, 'e'), expected.executable_sha256);
  EXPECT_EQ(std::string(64, 'c'), expected.stage_provenance_sha256);
  EXPECT_EQ(std::string(64, 'f'), expected.payload_seal_sha256);

  EXPECT_THROW(BuildWindowsExpectedPayloadIdentity(
                   Request(), Marker(), "caller-controlled", TestPolicy()),
               desktop_updater::runtime::internal::
                   NativeInstallAuthorizationError);

  auto marker = Marker();
  marker.entries[0].sha256 = "not-a-sha256";
  EXPECT_THROW(BuildWindowsExpectedPayloadIdentity(Request(), marker,
                                                   std::string(64, 'f'),
                                                   TestPolicy()),
               desktop_updater::runtime::internal::
                   NativeInstallAuthorizationError);
  marker = Marker();
  marker.entries.clear();
  EXPECT_THROW(BuildWindowsExpectedPayloadIdentity(Request(), marker,
                                                   std::string(64, 'f'),
                                                   TestPolicy()),
               desktop_updater::runtime::internal::
                   NativeInstallAuthorizationError);
}

TEST(WindowsInstallAuthorizer, PortableTargetMustBeExactWritableCallerRoot) {
  EXPECT_NO_THROW(ValidatePortableWindowsTargetAuthorityFacts(
      L"C:\\Users\\caller\\Example",
      L"C:\\Users\\caller\\Example\\Example.exe", true, true));
  EXPECT_THROW(ValidatePortableWindowsTargetAuthorityFacts(
                   L"C:\\Users\\caller",
                   L"C:\\Users\\caller\\Example\\Example.exe", true,
                   true),
               desktop_updater::runtime::internal::
                   NativeInstallAuthorizationError);
  EXPECT_THROW(ValidatePortableWindowsTargetAuthorityFacts(
                   L"C:\\Users\\caller\\Example",
                   L"C:\\Users\\caller\\Example\\Example.exe", false,
                   true),
               desktop_updater::runtime::internal::
                   NativeInstallAuthorizationError);
  EXPECT_THROW(ValidatePortableWindowsTargetAuthorityFacts(
                   L"C:\\Users\\caller\\Example",
                   L"C:\\Users\\caller\\Example\\Example.exe", true,
                   false),
               desktop_updater::runtime::internal::
                   NativeInstallAuthorizationError);
}

}  // namespace
}  // namespace desktop_updater::helper
