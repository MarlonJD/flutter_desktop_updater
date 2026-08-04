#include "update_client_core_fixture_tests.h"

#include <array>
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
#include "optional/monocypher-ed25519.h"

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

std::string EncodeBase64ForTest(const std::uint8_t* bytes,
                                std::size_t length) {
  static const char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string result;
  for (std::size_t offset = 0; offset < length; offset += 3) {
    const std::uint32_t first = bytes[offset];
    const std::uint32_t second = offset + 1 < length ? bytes[offset + 1] : 0;
    const std::uint32_t third = offset + 2 < length ? bytes[offset + 2] : 0;
    const std::uint32_t value = (first << 16) | (second << 8) | third;
    result.push_back(kAlphabet[(value >> 18) & 63]);
    result.push_back(kAlphabet[(value >> 12) & 63]);
    result.push_back(offset + 1 < length ? kAlphabet[(value >> 6) & 63] : '=');
    result.push_back(offset + 2 < length ? kAlphabet[value & 63] : '=');
  }
  return result;
}

struct SignedIndexFixture {
  std::string json;
  std::vector<std::uint8_t> public_key;
};

SignedIndexFixture SignIndex(JsonValue index) {
  JsonValue::Object signature;
  signature.emplace("algorithm", JsonValue(std::string("ed25519")));
  signature.emplace("publicKeyId",
                    JsonValue(std::string("native-contract-stable")));
  signature.emplace("value", JsonValue(std::string()));
  index.object()["signature"] = JsonValue(std::move(signature));
  const ReleaseIndex parsed = ParseReleaseIndex(EncodeCanonicalJson(index));
  const std::string canonical = CanonicalIndexSignatureBytes(parsed);

  std::array<std::uint8_t, 32> seed{};
  for (std::size_t index = 0; index < seed.size(); ++index) {
    seed[index] = static_cast<std::uint8_t>(index);
  }
  std::array<std::uint8_t, 64> secret_key{};
  std::array<std::uint8_t, 32> public_key{};
  std::array<std::uint8_t, 64> signature_bytes{};
  crypto_ed25519_key_pair(secret_key.data(), public_key.data(), seed.data());
  crypto_ed25519_sign(
      signature_bytes.data(), secret_key.data(),
      reinterpret_cast<const std::uint8_t*>(canonical.data()),
      canonical.size());
  index.object()["signature"].object()["value"] =
      JsonValue(EncodeBase64ForTest(signature_bytes.data(),
                                   signature_bytes.size()));
  return {EncodeCanonicalJson(index),
          std::vector<std::uint8_t>(public_key.begin(), public_key.end())};
}

std::string ReplaceOnce(std::string value,
                        const std::string& from,
                        const std::string& to) {
  const std::size_t offset = value.find(from);
  if (offset == std::string::npos) {
    throw std::runtime_error("Native index tampering fixture is malformed.");
  }
  value.replace(offset, from.size(), to);
  return value;
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
  const JsonValue index_json = ParseJson(
      "{\"schemaVersion\":3,\"appName\":\"Example.app\","
      "\"supportPolicy\":{\"minimumSupportedVersion\":\"2.7.0\","
      "\"enforcedAfter\":\"2020-01-01T00:00:00.000Z\"},\"items\":[{"
      "\"version\":\"2.7.0\",\"buildNumber\":270,"
      "\"platform\":\"macos\",\"channel\":\"stable\","
      "\"mandatory\":true,\"freshInstall\":{"
      "\"downloadUrl\":\"https://updates.example.test/fresh\"},"
      "\"rollout\":{\"percentage\":100,\"salt\":\"stable-2026\"},"
      "\"release\":\"" + descriptor_url + "\"}]}");
  const SignedIndexFixture index = SignIndex(index_json);
  FixtureTransport transport({
      {index_url, Bytes(index.json)},
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
  configuration.pinned_public_keys_by_id.emplace(
      valid.at("publicKeyId").string(), index.public_key);
  configuration.minimum_os_resolver = [](const std::string&,
                                         const std::string&) { return true; };

  FixtureTransport unsigned_transport({
      {index_url, Bytes(EncodeCanonicalJson(index_json))},
  });
  const ClientCheckResult unsigned_result =
      CheckForUpdateCore(configuration, &unsigned_transport, sha256);
  if (unsigned_result.outcome != "signatureFailure" ||
      unsigned_transport.requests().size() != 1) {
    throw std::runtime_error(
        "Strict native update client accepted an unsigned release index.");
  }

  const ClientCheckResult result =
      CheckForUpdateCore(configuration, &transport, sha256);
  if (result.outcome != "freshInstallRequired" || !result.has_descriptor ||
      result.descriptor.artifact.kind != "zip" ||
      result.support_policy_status != "blocked" ||
      transport.requests().size() != 2) {
    throw std::runtime_error(
        "Native update client did not verify the signed descriptor.");
  }

  FixtureTransport mismatch_transport({
      {index_url, Bytes(index.json)},
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

  const std::vector<std::pair<std::string, std::string>> tampering = {
      {"\"algorithm\":\"ed25519\"", "\"algorithm\":\"\""},
      {"\"publicKeyId\":\"native-contract-stable\"",
       "\"publicKeyId\":\"\""},
      {"\"mandatory\":true", "\"mandatory\":false"},
      {"https://updates.example.test/fresh",
       "https://evil.example.test/fresh"},
      {"\"percentage\":100", "\"percentage\":99"},
      {"2020-01-01T00:00:00.000Z", "2027-01-01T00:00:00.000Z"},
      {descriptor_url, "https://evil.example.test/release.json"},
  };
  configuration.expected_package_id = "com.example.native-contract";
  for (const auto& mutation : tampering) {
    FixtureTransport tampered_transport({
        {index_url,
         Bytes(ReplaceOnce(index.json, mutation.first, mutation.second))},
    });
    const ClientCheckResult tampered =
        CheckForUpdateCore(configuration, &tampered_transport, sha256);
    if (tampered.outcome != "signatureFailure" ||
        tampered_transport.requests().size() != 1) {
      throw std::runtime_error(
          "Native update client selected a tampered release index.");
    }
  }

  JsonValue invalid_descriptor = descriptor;
  const std::array<std::uint8_t, 64> zero_signature{};
  invalid_descriptor.object()["signature"].object()["value"] =
      JsonValue(EncodeBase64ForTest(zero_signature.data(),
                                   zero_signature.size()));
  FixtureTransport invalid_fresh_install_transport({
      {index_url, Bytes(index.json)},
      {descriptor_url, Bytes(EncodeCanonicalJson(invalid_descriptor))},
  });
  const ClientCheckResult invalid_fresh_install = CheckForUpdateCore(
      configuration, &invalid_fresh_install_transport, sha256);
  if (invalid_fresh_install.outcome != "signatureFailure" ||
      invalid_fresh_install_transport.requests().size() != 2) {
    throw std::runtime_error(
        "Fresh install returned before descriptor signature verification.");
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
