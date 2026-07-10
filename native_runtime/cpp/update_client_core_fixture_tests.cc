#include "update_client_core_fixture_tests.h"

#include <fstream>
#include <iterator>
#include <map>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "json_value.h"
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
    const auto found = metadata_.find(url);
    if (found == metadata_.end()) {
      throw std::runtime_error("Fixture metadata URL is missing.");
    }
    requests_.push_back(url);
    return found->second;
  }

  void DownloadArtifact(const ArtifactDownloadRequest&) override {
    throw std::runtime_error("Artifact download must not run during checks.");
  }

  const std::vector<std::string>& requests() const { return requests_; }

 private:
  std::map<std::string, std::vector<std::uint8_t>> metadata_;
  std::vector<std::string> requests_;
};

JsonValue ReadFixture(const std::string& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("Update client fixture is missing.");
  return ParseJson(std::string(std::istreambuf_iterator<char>(input),
                               std::istreambuf_iterator<char>()));
}

std::vector<std::uint8_t> Bytes(const std::string& value) {
  return std::vector<std::uint8_t>(value.begin(), value.end());
}

}  // namespace

void RunUpdateClientCoreFixtureTests(const std::string& fixture_root,
                                     const Sha256Function& sha256) {
  const JsonValue signature =
      ReadFixture(fixture_root + "/canonical-signature-cases.json");
  const JsonValue& valid = signature.at("cases").array().front();
  const JsonValue descriptor = valid.at("descriptor");
  const std::string descriptor_url =
      "https://updates.example.test/releases/release.json";
  const std::string index_url =
      "https://updates.example.test/app-archive.json";
  const std::string index =
      "{\"schemaVersion\":3,\"appName\":\"Example.app\","
      "\"supportPolicy\":{\"minimumSupportedVersion\":\"2.7.0\","
      "\"enforcedAfter\":\"2020-01-01T00:00:00.000Z\"},\"items\":[{"
      "\"version\":\"2.7.0\",\"buildNumber\":270,"
      "\"platform\":\"macos\",\"channel\":\"stable\","
      "\"release\":\"" +
      descriptor_url + "\"}]}";
  FixtureTransport transport({
      {index_url, Bytes(index)},
      {descriptor_url, Bytes(EncodeCanonicalJson(descriptor))},
  });
  ClientConfiguration configuration;
  configuration.app_archive_url = index_url;
  configuration.expected_package_id = "com.example.native-contract";
  configuration.current_version = "2.6.0";
  configuration.has_current_build_number = true;
  configuration.current_build_number = 260;
  configuration.current_updater_version = "2.7.0";
  configuration.platform = "macos";
  configuration.channel = "stable";
  configuration.installation_identity = "cpp-client-test";
  configuration.require_descriptor_signature = true;
  configuration.pinned_public_keys_by_id.emplace(
      valid.at("publicKeyId").string(),
      DecodeBase64(valid.at("publicKeyBase64").string()));
  configuration.minimum_os_resolver = [](const std::string&,
                                         const std::string&) { return true; };

  const ClientCheckResult result =
      CheckForUpdateCore(configuration, &transport, sha256);
  if (result.outcome != "updateAvailable" || !result.has_descriptor ||
      result.descriptor.artifact.kind != "zip" ||
      result.support_policy_status != "blocked" ||
      transport.requests().size() != 2) {
    throw std::runtime_error(
        "Native update client did not verify the signed descriptor.");
  }

  FixtureTransport mismatch_transport({
      {index_url, Bytes(index)},
      {descriptor_url, Bytes(EncodeCanonicalJson(descriptor))},
  });
  configuration.expected_package_id = "com.example.other";
  const ClientCheckResult mismatch =
      CheckForUpdateCore(configuration, &mismatch_transport, sha256);
  if (mismatch.outcome != "packageIdentityMismatch" ||
      mismatch_transport.requests().size() != 2) {
    throw std::runtime_error(
        "Native update client did not reject package identity mismatch.");
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
