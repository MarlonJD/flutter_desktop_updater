#include <gtest/gtest.h>

#include <cstdint>
#include <string>

#include "json_value.h"
#include "stage_provenance.h"
#include "windows_native_install_request_builder.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

constexpr char kDescriptorSha[] =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
constexpr char kArtifactSha[] =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
constexpr char kOwnershipSha[] =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
constexpr char kProvenanceSha[] =
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

std::string Manifest(const std::string& artifact_kind) {
  JsonValue::Object artifact;
  artifact.emplace("kind", JsonValue(artifact_kind));
  artifact.emplace("length", JsonValue(std::int64_t{123456}));
  artifact.emplace("sha256", JsonValue(std::string(kArtifactSha)));
  artifact.emplace("url", JsonValue(std::string("https://example.test/app")));
  JsonValue::Object signature;
  signature.emplace("algorithm", JsonValue(std::string("ed25519")));
  signature.emplace("publicKeyId", JsonValue(std::string("stable-2026")));
  signature.emplace(
      "value",
      JsonValue(std::string(86, 'A') + "=="));
  JsonValue::Object manifest;
  manifest.emplace("appName", JsonValue(std::string("Example")));
  manifest.emplace("artifact", JsonValue(std::move(artifact)));
  manifest.emplace("buildNumber", JsonValue(std::int64_t{280}));
  manifest.emplace("channel", JsonValue(std::string("stable")));
  manifest.emplace("generatedAt",
                   JsonValue(std::string("2026-07-14T00:00:00Z")));
  manifest.emplace("install", JsonValue(JsonValue::Object{}));
  manifest.emplace("minimumUpdaterVersion",
                   JsonValue(std::string("2.7.0")));
  manifest.emplace("packageId", JsonValue(std::string("com.example.app")));
  manifest.emplace("platform", JsonValue(std::string("windows")));
  manifest.emplace("schemaVersion", JsonValue(std::int64_t{3}));
  manifest.emplace("signature", JsonValue(std::move(signature)));
  manifest.emplace("version", JsonValue(std::string("2.8.0")));
  return EncodeCanonicalJson(JsonValue(std::move(manifest)));
}

WindowsNativeInstallEvidenceV1 Evidence() {
  WindowsNativeInstallEvidenceV1 evidence;
  evidence.transaction_id = "00000000-0000-4000-8000-000000000006";
  evidence.policy_id = "com.example.desktop-updater";
  evidence.package_id = "com.example.app";
  evidence.target_path_hint = "C:/Program Files/Example";
  evidence.target_name_hint = "Example";
  evidence.executable_relative_path = "Example.exe";
  evidence.target_identity_proof_sha256 = std::string(64, 'a');
  evidence.current_version = "2.7.0";
  evidence.current_build_number = 270;
  evidence.current_package_identity_sha256 = std::string(64, 'a');
  evidence.stage_path_hint = "C:/staging/desktop_updater_stage_example";
  evidence.expected_provenance_sha256 = kProvenanceSha;
  evidence.expected_artifact_sha256 = kArtifactSha;
  evidence.caller_process_id = 4242;
  evidence.caller_process_start_identity = "windows:123456";
  evidence.caller_executable_sha256 = std::string(64, 'a');
  evidence.caller_signer_identity = "Example Publisher";
  evidence.request_nonce =
      "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA";
  return evidence;
}

StageProvenanceMarker Marker() {
  StageProvenanceMarker marker;
  marker.nonce = "00000000-0000-4000-8000-000000000006";
  marker.package_id = "com.example.app";
  marker.descriptor_sha256 = kDescriptorSha;
  marker.artifact_sha256 = kArtifactSha;
  return marker;
}

std::string TestSha256(const std::string& value) {
  if (value == Marker().nonce) return kOwnershipSha;
  return kDescriptorSha;
}

TEST(windows_native_install_request_builder,
     BuildsFrozenDirectoryReplacementRequest) {
  const NativeInstallTransactionRequestV1 request =
      BuildWindowsNativeInstallTransactionRequestV1(
          Manifest("zip") + "\n", Marker(), Evidence(), TestSha256);
  EXPECT_EQ("directoryReplace", request.strategy);
  EXPECT_EQ("platformDirectory", request.provider);
  EXPECT_EQ("applicationDirectory", request.target.target_class);
  EXPECT_EQ(kOwnershipSha, request.stage.ownership_nonce);
  EXPECT_EQ(kDescriptorSha,
            request.signed_descriptor.canonical_sha256);
  EXPECT_EQ("stable-2026", request.signed_descriptor.key_id);
  EXPECT_EQ("2.8.0", request.desired_identity.version);
  EXPECT_EQ(280, request.desired_identity.build_number);
  EXPECT_EQ(kDescriptorSha,
            request.desired_identity.package_identity_sha256);
}

TEST(windows_native_install_request_builder,
     MapsSignedInnoInstallerAndRejectsBindingDrift) {
  const NativeInstallTransactionRequestV1 request =
      BuildWindowsNativeInstallTransactionRequestV1(
          Manifest("innoInstaller") + "\n", Marker(), Evidence(), TestSha256);
  EXPECT_EQ("verifiedInstallerHandoff", request.strategy);
  EXPECT_EQ("windowsInno", request.provider);

  auto wrong_artifact = Evidence();
  wrong_artifact.expected_artifact_sha256 = std::string(64, 'f');
  EXPECT_THROW(BuildWindowsNativeInstallTransactionRequestV1(
                   Manifest("zip") + "\n", Marker(), wrong_artifact,
                   TestSha256),
               WindowsNativeInstallRequestBuilderError);

  auto wrong_package = Evidence();
  wrong_package.package_id = "com.attacker.app";
  EXPECT_THROW(BuildWindowsNativeInstallTransactionRequestV1(
                   Manifest("zip") + "\n", Marker(), wrong_package,
                   TestSha256),
               WindowsNativeInstallRequestBuilderError);
}

}  // namespace
}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
