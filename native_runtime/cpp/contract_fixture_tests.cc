#include "contract_fixture_tests.h"

#include <fstream>
#include <iterator>
#include <map>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "update_client_core.h"
#include "update_transport.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

class FixtureTransport final : public UpdateTransport {
 public:
  explicit FixtureTransport(
      std::map<std::string, std::vector<std::uint8_t>> metadata)
      : metadata_(std::move(metadata)) {}

  std::vector<std::uint8_t> DownloadMetadata(
      const std::string& url) override {
    ++metadata_requests;
    metadata_urls.push_back(url);
    const auto found = metadata_.find(url);
    if (found == metadata_.end()) {
      throw std::runtime_error("Fixture metadata URL is missing.");
    }
    return found->second;
  }

  void DownloadArtifact(const ArtifactDownloadRequest&) override {
    ++artifact_requests;
  }

  int metadata_requests = 0;
  int artifact_requests = 0;
  std::vector<std::string> metadata_urls;

 private:
  std::map<std::string, std::vector<std::uint8_t>> metadata_;
};

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

std::vector<std::uint8_t> Bytes(const std::string& value) {
  return std::vector<std::uint8_t>(value.begin(), value.end());
}

ClientConfiguration FixtureConfiguration(const std::string& index_url) {
  ClientConfiguration configuration;
  configuration.app_archive_url = index_url;
  configuration.expected_package_id = "com.example.native-contract";
  configuration.current_version = "2.7.0";
  configuration.current_updater_version = "2.7.0";
  configuration.platform = "macos";
  configuration.channel = "stable";
  configuration.installation_identity = "fixture-device";
  configuration.require_descriptor_signature = false;
  configuration.minimum_os_resolver = [](const std::string&,
                                         const std::string&) { return true; };
  return configuration;
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
}

void TestFreshInstallClient(const JsonValue& fixture,
                            const JsonValue& signatures,
                            const Sha256Function& sha256) {
  const std::string index_url =
      "https://updates.example.test/app-archive.json";
  const std::string descriptor_url =
      "https://updates.example.test/releases/2.7.0/release.json";
  const JsonValue& valid = signatures.at("cases").array().front();
  const JsonValue& descriptor = valid.at("descriptor");
  for (const JsonValue& entry : fixture.at("freshInstallCases").array()) {
    JsonValue::Object item;
    item.emplace("version", descriptor.at("version"));
    item.emplace("buildNumber", descriptor.at("buildNumber"));
    item.emplace("platform", descriptor.at("platform"));
    item.emplace("channel", descriptor.at("channel"));
    item.emplace("mandatory", JsonValue(true));
    item.emplace("release", JsonValue(descriptor_url));
    item.emplace("freshInstall", entry.at("input"));
    JsonValue::Array items;
    items.emplace_back(JsonValue(std::move(item)));
    JsonValue::Object index;
    index.emplace("schemaVersion", JsonValue(std::int64_t{3}));
    index.emplace("appName", JsonValue(std::string("Example.app")));
    index.emplace("items", JsonValue(std::move(items)));
    const std::string encoded = EncodeCanonicalJson(JsonValue(std::move(index)));
    FixtureTransport transport({
        {index_url, Bytes(encoded)},
        {descriptor_url, Bytes(EncodeCanonicalJson(descriptor))},
    });
    ClientConfiguration configuration = FixtureConfiguration(index_url);
    configuration.current_version = "2.6.0";
    configuration.has_current_build_number = true;
    configuration.current_build_number = 260;
    configuration.require_descriptor_signature = true;
    configuration.pinned_public_keys_by_id.emplace(
        valid.at("publicKeyId").string(),
        DecodeBase64(valid.at("publicKeyBase64").string()));
    const ClientCheckResult result = CheckForUpdateCore(
        configuration, &transport, sha256);
    Expect(result.outcome == entry.at("expectedOutcome").string(),
           "Fresh-install client outcome differs from Dart.");
    Expect(result.has_selected_item &&
               result.selected_item.has_fresh_install &&
               result.selected_item.mandatory && result.has_descriptor,
           "Fresh-install selected result lost public policy fields.");
    Expect(transport.metadata_requests == 2 &&
               transport.metadata_urls ==
                   std::vector<std::string>({index_url, descriptor_url}) &&
               transport.artifact_requests == 0 &&
               !entry.at("expectedArtifactDownload").boolean(),
           "Fresh-install check requested an artifact.");
  }
}

void TestDescriptorValidation(const JsonValue& fixture) {
  for (const JsonValue& entry : fixture.at("cases").array()) {
    bool valid = true;
    try {
      ParseReleaseDescriptor(EncodeCanonicalJson(entry.at("descriptor")));
    } catch (const std::exception&) {
      valid = false;
    }
    Expect(valid == entry.at("expectedValid").boolean(),
           "Descriptor validation differs from Dart: " +
               entry.at("name").string());
  }
}

const ReleaseIndexItem* SelectParityIdentity(
    const std::string& identity,
    std::int64_t percentage,
    const Sha256Function& sha256,
    ReleaseIndex* index) {
  const std::string encoded =
      "{\"schemaVersion\":3,\"appName\":\"Example.app\",\"items\":[{"
      "\"version\":\"2.8.0\",\"platform\":\"macos\","
      "\"channel\":\"stable\",\"mandatory\":false,"
      "\"release\":\"https://updates.example.test/release.json\","
      "\"rollout\":{\"percentage\":" + std::to_string(percentage) +
      ",\"salt\":\"native-contract-rollout\"}}]}";
  *index = ParseReleaseIndex(encoded);
  return SelectReleaseIndexItem(*index, "macos", "stable",
                                ParseDesktopVersion("2.7.0"), identity,
                                sha256);
}

void TestIndexValidation(const JsonValue& fixture) {
  for (const JsonValue& entry : fixture.at("indexValidationCases").array()) {
    bool valid = false;
    std::string channel;
    try {
      const ReleaseIndex index =
          ParseReleaseIndex(EncodeCanonicalJson(entry.at("index")));
      valid = true;
      channel = index.items.front().channel;
    } catch (const JsonError&) {
      valid = false;
    }
    Expect(valid == entry.at("expectedValid").boolean(),
           "Index validation differs from Dart: " +
               entry.at("name").string());
    if (const JsonValue* expected = entry.find("expectedChannel")) {
      Expect(channel == expected->string(),
             "Index channel default differs from Dart.");
    }
  }
}

void TestParityCases(const JsonValue& fixture,
                     const std::string& fixture_root,
                     const Sha256Function& sha256) {
  for (const JsonValue& entry : fixture.at("parityCases").array()) {
    const std::string name = entry.at("name").string();
    if (name == "rollout identity trims surrounding whitespace") {
      ReleaseIndex raw_index;
      ReleaseIndex normalized_index;
      const ReleaseIndexItem* raw = SelectParityIdentity(
          entry.at("identity").string(), 60, sha256, &raw_index);
      const ReleaseIndexItem* normalized = SelectParityIdentity(
          entry.at("expectedNormalizedIdentity").string(), 60, sha256,
          &normalized_index);
      Expect((raw == nullptr) == (normalized == nullptr),
             "Rollout identity whitespace was not normalized.");
    } else if (name == "whitespace-only rollout identity is absent") {
      ReleaseIndex index;
      Expect(SelectParityIdentity(entry.at("identity").string(), 50, sha256,
                                  &index) == nullptr,
             "Whitespace-only rollout identity was treated as present.");
    } else if (name == "minimum OS keys and values are trimmed") {
      JsonValue descriptor = ParseJson(ReadFile(
          fixture_root + "/release-contract/release-macos-zip.json"));
      descriptor.object()["minimumOS"] = entry.at("minimumOS");
      const ReleaseDescriptor parsed =
          ParseReleaseDescriptor(EncodeCanonicalJson(descriptor));
      const auto expected = entry.at("expectedMinimumOS").object();
      Expect(parsed.minimum_os.size() == 1 &&
                 parsed.minimum_os.at(expected.begin()->first) ==
                     expected.begin()->second.string(),
             "Minimum OS normalization differs from Dart.");
    } else if (name == "hyphen is valid inside prerelease identifier" ||
               name ==
                   "first numeric build metadata component is the build number") {
      Expect(CompareDesktopVersions(
                 ParseDesktopVersion(entry.at("candidate").string()),
                 ParseDesktopVersion(entry.at("current").string())) > 0,
             "Version ordering parity case differs from Dart.");
    } else if (name ==
               "ISO offset and UTC deadline represent the same instant") {
      ReleaseSupportPolicy policy;
      policy.minimum_supported_version = ParseDesktopVersion("9.0.0");
      policy.enforced_after = entry.at("right").string();
      Expect(SupportPolicyOutcome(policy, ParseDesktopVersion("2.7.0"),
                                  entry.at("left").string()) ==
                 "supportPolicyBlocked",
             "Support deadline instants were compared as strings.");
    } else if (name == "same-second fractional deadline remains warning") {
      ReleaseSupportPolicy policy;
      policy.minimum_supported_version = ParseDesktopVersion("9.0.0");
      policy.enforced_after = entry.at("deadline").string();
      Expect(SupportPolicyOutcome(policy, ParseDesktopVersion("2.7.0"),
                                  entry.at("now").string()) ==
                 "supportPolicyWarning",
             "Fractional support deadline precision was discarded.");
    }
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

  for (const JsonValue& entry : fixture.at("normalizationCases").array()) {
    const ReleaseDescriptor descriptor = ParseReleaseDescriptor(
        EncodeCanonicalJson(entry.at("inputDescriptor")));
    const std::vector<std::uint8_t> canonical =
        DecodeBase64(entry.at("canonicalUtf8Base64").string());
    const std::string actual = CanonicalSignatureBytes(descriptor);
    Expect(std::vector<std::uint8_t>(actual.begin(), actual.end()) == canonical,
           "Normalized canonical descriptor differs from Dart: " +
               entry.at("name").string());
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
  const JsonValue signatures = ParseJson(
      ReadFile(fixture_root + "/canonical-signature-cases.json"));
  TestSelection(selection, sha256);
  TestPolicies(selection);
  TestFreshInstallClient(selection, signatures, sha256);
  TestBinding(selection);
  TestIndexValidation(selection);
  TestParityCases(selection, fixture_root, sha256);
  TestDescriptorValidation(ParseJson(ReadFile(
      fixture_root + "/descriptor-validation-cases.json")));
  TestSignatures(signatures);
  TestCapabilityDescriptors(fixture_root);
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
