#include <gtest/gtest.h>

#include <fstream>
#include <iterator>
#include <string>

#include "json_value.h"
#include "native_install_authorization.h"
#include "native_install_request.h"
#include "stage_provenance.h"

#ifndef DESKTOP_UPDATER_SIGNATURE_FIXTURE_PATH
#error "DESKTOP_UPDATER_SIGNATURE_FIXTURE_PATH must name canonical-signature-cases.json"
#endif

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

std::string ReadFixture() {
  std::ifstream input(DESKTOP_UPDATER_SIGNATURE_FIXTURE_PATH,
                      std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

struct AuthorizationFixture {
  JsonValue descriptor;
  NativeInstallAuthorizationPolicyV1 policy;
  StageProvenanceMarker marker;
  NativeInstallTransactionRequestV1 request;
  std::string canonical_manifest;
};

AuthorizationFixture Fixture() {
  const JsonValue root = ParseJson(ReadFixture());
  const JsonValue& valid = root.at("cases").array().front();
  const JsonValue descriptor = valid.at("descriptor");
  const std::string manifest = EncodeCanonicalJson(descriptor);
  const std::string descriptor_sha(64, 'c');
  const std::string provenance_sha(64, 'e');
  const std::string ownership_sha(64, 'd');
  const std::string artifact_sha =
      descriptor.at("artifact").at("sha256").string();
  NativeInstallAuthorizationPolicyV1 policy;
  policy.policy_id = "com.example.desktop-updater";
  policy.application_package_id =
      descriptor.at("packageId").string();
  policy.allowed_target_classes = {"applicationBundle"};
  policy.release_root_public_keys = {{
      valid.at("publicKeyId").string(), "ed25519",
      valid.at("publicKeyBase64").string()}};
  policy.allowed_strategies = {
      {"directoryReplace", "platformDirectory"}};
  policy.minimum_helper_protocol_version = 1;

  StageProvenanceMarker marker;
  marker.nonce = "00000000-0000-4000-8000-000000000011";
  marker.package_id = policy.application_package_id;
  marker.descriptor_sha256 = descriptor_sha;
  marker.artifact_sha256 = artifact_sha;

  NativeInstallTransactionRequestV1 request;
  request.schema_version = 1;
  request.protocol_version = 1;
  request.transaction_id = "00000000-0000-4000-8000-000000000011";
  request.policy_id = policy.policy_id;
  request.package_id = policy.application_package_id;
  request.strategy = "directoryReplace";
  request.provider = "platformDirectory";
  request.target = {"applicationBundle", "/Applications/Example.app",
                    "Example.app", "Contents/MacOS/Example",
                    std::string(64, 'a')};
  request.current_identity = {"2.6.0", 260, std::string(64, 'b')};
  request.desired_identity = {
      descriptor.at("version").string(),
      descriptor.at("buildNumber").integer(), descriptor_sha};
  request.stage = {
      "/tmp/stage", ownership_sha, provenance_sha, artifact_sha,
      descriptor.at("artifact").at("length").integer()};
  request.signed_descriptor = {
      descriptor_sha,
      descriptor.at("signature").at("algorithm").string(),
      descriptor.at("signature").at("publicKeyId").string(),
      descriptor.at("signature").at("value").string()};
  request.caller = {4242, "macos:1:2", std::string(64, 'a'),
                    policy.application_package_id, "Example Publisher"};
  request.request_nonce =
      "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA";
  request.diagnostics_destination = {true, "platformLog", {}};
  return {descriptor, policy, marker, request, manifest};
}

std::string FixtureSha256(const std::string& value) {
  if (value == Fixture().marker.nonce) return std::string(64, 'd');
  return std::string(64, 'c');
}

TEST(native_install_authorization,
     VerifiesSignedDescriptorPolicyAndStageBindings) {
  const AuthorizationFixture fixture = Fixture();
  const AuthorizedNativeInstallRequestV1 authorized =
      AuthorizeNativeInstallTransactionRequestV1(
          fixture.request, fixture.policy, "macos",
          fixture.canonical_manifest + "\n", fixture.marker,
          std::string(64, 'e'), FixtureSha256);
  EXPECT_EQ(fixture.request.package_id, authorized.descriptor.package_id);
  EXPECT_EQ(fixture.request.desired_identity.version,
            authorized.descriptor.version);
}

TEST(native_install_authorization, RejectsSignatureAndCapabilityDrift) {
  AuthorizationFixture fixture = Fixture();
  fixture.request.signed_descriptor.signature_base64 =
      std::string(86, 'A') + "==";
  EXPECT_THROW(AuthorizeNativeInstallTransactionRequestV1(
                   fixture.request, fixture.policy, "macos",
                   fixture.canonical_manifest, fixture.marker,
                   std::string(64, 'e'), FixtureSha256),
               NativeInstallAuthorizationError);

  fixture = Fixture();
  fixture.policy.allowed_strategies.clear();
  EXPECT_THROW(AuthorizeNativeInstallTransactionRequestV1(
                   fixture.request, fixture.policy, "macos",
                   fixture.canonical_manifest, fixture.marker,
                   std::string(64, 'e'), FixtureSha256),
               NativeInstallAuthorizationError);
}

}  // namespace
}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
