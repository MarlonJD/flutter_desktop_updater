#include "contract_fixture_tests.h"

#include <fstream>
#include <iterator>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

std::string ReadFile(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("Unable to read fixture: " + path);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

void Expect(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

std::string OptionalStringValue(const JsonValue& value,
                                const std::string& key) {
  const JsonValue* found = value.find(key);
  if (found == nullptr || found->type() == JsonValue::Type::kNull) return {};
  return found->string();
}

bool OptionalIntegerValue(const JsonValue& value,
                          const std::string& key,
                          std::int64_t* output) {
  const JsonValue* found = value.find(key);
  if (found == nullptr || found->type() == JsonValue::Type::kNull) return false;
  *output = found->integer();
  return true;
}

void TestSelection(const JsonValue& fixture,
                   const Sha256Function& sha256) {
  for (const JsonValue& entry : fixture.at("selectionCases").array()) {
    const ReleaseIndex index =
        ParseReleaseIndex(EncodeCanonicalJson(entry.at("index")));
    const std::string identity = OptionalStringValue(entry, "identity");
    const ReleaseIndexItem* selected = SelectReleaseIndexItem(
        index, entry.at("platform").string(), entry.at("channel").string(),
        ParseDesktopVersion(entry.at("currentVersion").string()), identity,
        sha256);
    const std::string expected_version =
        OptionalStringValue(entry, "selectedVersion");
    Expect((selected == nullptr) == expected_version.empty(),
           "Selection nullability differs from Dart.");
    if (selected == nullptr) continue;
    Expect(selected->version == expected_version,
           "Selected version differs from Dart.");
    std::int64_t expected_build = 0;
    const bool has_expected_build =
        OptionalIntegerValue(entry, "selectedBuildNumber", &expected_build);
    Expect(selected->has_build_number == has_expected_build,
           "Selected build-number presence differs from Dart.");
    if (has_expected_build) {
      Expect(selected->build_number == expected_build,
             "Selected build number differs from Dart.");
    }
    Expect(selected->platform == entry.at("selectedPlatform").string(),
           "Selected platform differs from Dart.");
    Expect(selected->channel == entry.at("selectedChannel").string(),
           "Selected channel differs from Dart.");
    Expect(selected->release == entry.at("selectedRelease").string(),
           "Selected release URL differs from Dart.");
  }
}

void TestPolicies(const JsonValue& fixture) {
  for (const JsonValue& entry : fixture.at("minimumUpdaterCases").array()) {
    const bool supported = CompareDesktopVersions(
                               ParseDesktopVersion(entry.at("current").string()),
                               ParseDesktopVersion(entry.at("required").string())) >=
                           0;
    Expect(supported == entry.at("expectedSupported").boolean(),
           "Minimum updater outcome differs from Dart.");
  }
  for (const JsonValue& entry : fixture.at("minimumOSCases").array()) {
    const ReleaseDescriptor descriptor =
        ParseReleaseDescriptor(EncodeCanonicalJson(entry.at("descriptor")));
    const std::string outcome = DescriptorPolicyOutcome(
        descriptor, ParseDesktopVersion("99.0.0"),
        entry.at("platform").string(),
        [&entry](const std::string&, const std::string&) {
          return entry.at("callbackResult").boolean();
        });
    Expect(outcome == entry.at("expectedOutcome").string(),
           "Minimum OS outcome differs from Dart.");
  }
  for (const JsonValue& entry : fixture.at("supportPolicyCases").array()) {
    const JsonValue& policy_json = entry.at("policy");
    ReleaseSupportPolicy policy;
    policy.minimum_supported_version = ParseDesktopVersion(
        policy_json.at("minimumSupportedVersion").string());
    policy.enforced_after = policy_json.at("enforcedAfter").string();
    Expect(SupportPolicyOutcome(
               policy,
               ParseDesktopVersion(entry.at("currentVersion").string()),
               entry.at("now").string()) ==
               entry.at("expectedOutcome").string(),
           "Support policy outcome differs from Dart.");
  }
  for (const JsonValue& entry : fixture.at("freshInstallCases").array()) {
    Expect(entry.at("expectedOutcome").string() == "freshInstallRequired" &&
               !entry.at("expectedArtifactDownload").boolean(),
           "Fresh-install fixture is not download-blocking.");
  }
}

void TestBinding(const JsonValue& fixture) {
  for (const JsonValue& entry : fixture.at("descriptorBindingCases").array()) {
    const ReleaseIndexItem item = ParseReleaseIndexItem(entry.at("indexItem"));
    const ReleaseDescriptor descriptor =
        ParseReleaseDescriptor(EncodeCanonicalJson(entry.at("descriptor")));
    Expect(DescriptorBindingOutcome(
               descriptor, item, entry.at("expectedPackageId").string()) ==
               entry.at("expectedOutcome").string(),
           "Descriptor binding outcome differs from Dart.");
  }
}

void TestSignatures(const JsonValue& fixture) {
  for (const JsonValue& entry : fixture.at("cases").array()) {
    const ReleaseDescriptor descriptor =
        ParseReleaseDescriptor(EncodeCanonicalJson(entry.at("descriptor")));
    const std::vector<std::uint8_t> canonical =
        DecodeBase64(entry.at("canonicalUtf8Base64").string());
    const std::string actual = CanonicalSignatureBytes(descriptor);
    Expect(std::vector<std::uint8_t>(actual.begin(), actual.end()) == canonical,
           "Canonical descriptor bytes differ from Dart.");
    std::map<std::string, std::vector<std::uint8_t>> keys;
    keys.emplace(entry.at("publicKeyId").string(),
                 DecodeBase64(entry.at("publicKeyBase64").string()));
    Expect(VerifyDescriptorSignature(descriptor, keys) ==
               entry.at("expectedValid").boolean(),
           "Ed25519 result differs from Dart.");
  }

  const JsonValue& valid = fixture.at("cases").array().front();
  JsonValue malformed = valid.at("descriptor");
  malformed.object()["signature"].object()["value"] =
      JsonValue(std::string("not-base64"));
  const ReleaseDescriptor malformed_descriptor =
      ParseReleaseDescriptor(EncodeCanonicalJson(malformed));
  std::map<std::string, std::vector<std::uint8_t>> keys;
  keys.emplace(valid.at("publicKeyId").string(),
               DecodeBase64(valid.at("publicKeyBase64").string()));
  Expect(!VerifyDescriptorSignature(malformed_descriptor, keys),
         "Malformed signature encoding was accepted.");

  JsonValue missing = valid.at("descriptor");
  missing.object().erase("signature");
  Expect(!VerifyDescriptorSignature(
             ParseReleaseDescriptor(EncodeCanonicalJson(missing)), keys),
         "Missing required signature was accepted by the verifier.");
}

void TestCapabilityDescriptors(const std::string& fixture_root) {
  for (const std::string& name : {
           "release-macos-zip.json", "release-macos-dmg.json",
           "release-macos-pkg.json", "release-windows-zip.json",
           "release-windows-inno.json", "release-linux-zip.json"}) {
    const ReleaseDescriptor descriptor = ParseReleaseDescriptor(
        ReadFile(fixture_root + "/release-contract/" + name));
    Expect(descriptor.schema_version == 3 && !descriptor.package_id.empty() &&
               !descriptor.minimum_updater_version.empty() &&
               descriptor.minimum_os.count(descriptor.platform) == 1,
           "Capability descriptor is incomplete: " + name);
  }
}

}  // namespace

void RunContractFixtureTests(const std::string& fixture_root,
                             const Sha256Function& sha256) {
  const JsonValue selection =
      ParseJson(ReadFile(fixture_root + "/selection-cases.json"));
  TestSelection(selection, sha256);
  TestPolicies(selection);
  TestBinding(selection);
  TestSignatures(ParseJson(
      ReadFile(fixture_root + "/canonical-signature-cases.json")));
  TestCapabilityDescriptors(fixture_root);
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
