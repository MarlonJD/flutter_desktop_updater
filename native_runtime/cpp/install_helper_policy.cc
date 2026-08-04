#include "install_helper_policy.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <iomanip>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "json_value.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

const std::set<std::string> kPolicyFields = {
    "policyVersion",
    "policyId",
    "applicationPackageId",
    "helperServiceId",
    "allowedApplicationSigner",
    "allowedHelperSigner",
    "allowedTargetClasses",
    "allowedInstallRoots",
    "releaseRootPublicKeys",
    "allowedStrategies",
    "minimumHelperProtocolVersion",
};

const std::set<std::string> kTargetClasses = {
    "sameUserWritable",    "applicationBundle",
    "applicationDirectory", "singleExecutable",
    "protectedApplication", "systemPackage",
    "externalManaged",
};

const std::set<std::string> kSignerKinds = {
    "appleDesignatedRequirement",
    "authenticodePublisher",
    "sha256",
};

const std::vector<std::pair<std::string, std::set<std::string>>>
    kStrategyProviders = {
        {"directoryReplace", {"platformDirectory"}},
        {"singleFileReplace", {"platformFile"}},
        {"verifiedInstallerHandoff", {"macosInstaller", "windowsInno"}},
        {"systemPackageTransaction", {"apt", "dnf"}},
        {"externalManagedRefresh", {"flatpak", "snap"}},
};

const std::regex kIdentifierPattern(
    "^[a-z0-9](?:[a-z0-9._-]{1,126}[a-z0-9])?$");
const std::regex kSha256Pattern("^[0-9a-f]{64}$");
const std::regex kKeyIdPattern("^[A-Za-z0-9._-]{1,128}$");
const std::regex kWindowsAbsolutePattern("^[A-Za-z]:[\\\\/]");
const std::regex kWindowsRootPattern("^[A-Za-z]:[\\\\/]?$");

std::string Field(const std::string& prefix, const std::string& key) {
  return prefix.empty() ? key : prefix + "." + key;
}

void RequireExactKeys(const JsonValue& value,
                      const std::set<std::string>& required,
                      const std::string& prefix = {}) {
  const JsonValue::Object& object = value.object();
  for (const std::string& key : required) {
    if (object.find(key) == object.end()) {
      throw HelperPolicyError("missingField:" + Field(prefix, key));
    }
  }
  for (const auto& entry : object) {
    if (required.find(entry.first) == required.end()) {
      throw HelperPolicyError("unknownField:" + Field(prefix, entry.first));
    }
  }
}

std::string RequiredString(const JsonValue& value,
                           const std::string& key,
                           const std::string& field) {
  const std::string result = value.at(key).string();
  if (result.empty() ||
      std::all_of(result.begin(), result.end(), [](unsigned char byte) {
        return std::isspace(byte) != 0;
      })) {
    throw HelperPolicyError("invalidString:" + field);
  }
  return result;
}

std::int64_t RequiredInteger(const JsonValue& value,
                             const std::string& key,
                             const std::string& field,
                             std::int64_t minimum) {
  const std::int64_t result = value.at(key).integer();
  if (result < minimum) {
    throw HelperPolicyError("invalidInteger:" + field);
  }
  return result;
}

std::string RequiredIdentifier(const JsonValue& value,
                               const std::string& key,
                               const std::string& field) {
  const std::string result = RequiredString(value, key, field);
  if (!std::regex_match(result, kIdentifierPattern)) {
    throw HelperPolicyError("invalidIdentifier:" + field);
  }
  return result;
}

std::vector<std::string> RequiredStringArray(const JsonValue& value,
                                             const std::string& key,
                                             bool allow_empty) {
  const JsonValue::Array& array = value.at(key).array();
  if (!allow_empty && array.empty()) {
    throw HelperPolicyError("invalidArray:" + key);
  }
  std::vector<std::string> result;
  result.reserve(array.size());
  for (const JsonValue& entry : array) {
    const std::string item = entry.string();
    if (item.empty()) {
      throw HelperPolicyError("invalidString:" + key);
    }
    result.push_back(item);
  }
  return result;
}

HelperPolicySigner ParseSigner(const JsonValue& value,
                               const std::string& field) {
  RequireExactKeys(value, {"kind", "value"}, field);
  const std::string kind = RequiredString(value, "kind", field + ".kind");
  const std::string signer =
      RequiredString(value, "value", field + ".value");
  if (kSignerKinds.find(kind) == kSignerKinds.end()) {
    throw HelperPolicyError("invalidSigner");
  }
  if (signer.find('*') != std::string::npos ||
      signer.find('?') != std::string::npos) {
    throw HelperPolicyError("wildcardSigner");
  }
  if (kind == "sha256" && !std::regex_match(signer, kSha256Pattern)) {
    throw HelperPolicyError("invalidSigner");
  }
  return {kind, signer};
}

void ValidateInstallRoot(const std::string& root) {
  if (root == "/" || std::regex_match(root, kWindowsRootPattern)) {
    throw HelperPolicyError("rootFilesystemAuthorization");
  }
  if (root.empty() ||
      (root.front() != '/' &&
       !std::regex_search(root, kWindowsAbsolutePattern))) {
    throw HelperPolicyError("relativeInstallRoot");
  }
  if (root.find('*') != std::string::npos ||
      root.find('?') != std::string::npos) {
    throw HelperPolicyError("invalidInstallRoot");
  }
  std::string segment;
  for (std::size_t index = 0; index <= root.size(); ++index) {
    const bool separator =
        index == root.size() || root[index] == '/' || root[index] == '\\';
    if (!separator) {
      segment.push_back(root[index]);
      continue;
    }
    if (segment == "." || segment == "..") {
      throw HelperPolicyError("invalidInstallRoot");
    }
    segment.clear();
  }
}

int Base64Index(char value) {
  if (value >= 'A' && value <= 'Z') return value - 'A';
  if (value >= 'a' && value <= 'z') return value - 'a' + 26;
  if (value >= '0' && value <= '9') return value - '0' + 52;
  if (value == '+') return 62;
  if (value == '/') return 63;
  return -1;
}

bool IsCanonicalEd25519PublicKey(const std::string& value) {
  if (value.size() != 44 || value.back() != '=') return false;
  for (std::size_t index = 0; index + 1 < value.size(); ++index) {
    if (Base64Index(value[index]) < 0) return false;
  }
  return (Base64Index(value[42]) & 0x03) == 0;
}

std::vector<HelperPolicyReleaseRootPublicKey> ParseReleaseRoots(
    const JsonValue& value) {
  const JsonValue::Array& array = value.array();
  if (array.empty()) {
    throw HelperPolicyError("emptyReleaseRootPublicKeys");
  }
  std::set<std::string> key_ids;
  std::vector<HelperPolicyReleaseRootPublicKey> result;
  result.reserve(array.size());
  for (const JsonValue& entry : array) {
    RequireExactKeys(entry, {"keyId", "algorithm", "publicKeyBase64"},
                     "releaseRootPublicKeys");
    const std::string key_id = RequiredString(
        entry, "keyId", "releaseRootPublicKeys.keyId");
    if (!std::regex_match(key_id, kKeyIdPattern)) {
      throw HelperPolicyError("invalidReleaseKeyId");
    }
    if (!key_ids.insert(key_id).second) {
      throw HelperPolicyError("duplicateReleaseKeyId");
    }
    const std::string algorithm = RequiredString(
        entry, "algorithm", "releaseRootPublicKeys.algorithm");
    if (algorithm != "ed25519") {
      throw HelperPolicyError("invalidReleaseKeyAlgorithm");
    }
    const JsonValue& encoded_value = entry.at("publicKeyBase64");
    if (encoded_value.type() != JsonValue::Type::kString) {
      throw HelperPolicyError(
          "invalidType:releaseRootPublicKeys.publicKeyBase64");
    }
    const std::string encoded = encoded_value.string();
    if (encoded.empty() || !IsCanonicalEd25519PublicKey(encoded)) {
      throw HelperPolicyError("emptyReleaseRootPublicKey");
    }
    result.push_back({key_id, algorithm, encoded});
  }
  return result;
}

const std::set<std::string>* ProvidersForStrategy(
    const std::string& strategy) {
  for (const auto& entry : kStrategyProviders) {
    if (entry.first == strategy) return &entry.second;
  }
  return nullptr;
}

std::vector<HelperPolicyAllowedStrategy> ParseStrategies(
    const JsonValue& value) {
  const JsonValue::Array& array = value.array();
  if (array.empty()) throw HelperPolicyError("emptyAllowedStrategies");
  std::set<std::string> seen;
  std::vector<HelperPolicyAllowedStrategy> result;
  result.reserve(array.size());
  for (const JsonValue& entry : array) {
    RequireExactKeys(entry, {"strategy", "provider"}, "allowedStrategies");
    const std::string strategy = RequiredString(
        entry, "strategy", "allowedStrategies.strategy");
    const std::set<std::string>* providers = ProvidersForStrategy(strategy);
    if (providers == nullptr) throw HelperPolicyError("unknownStrategy");
    const std::string provider = RequiredString(
        entry, "provider", "allowedStrategies.provider");
    if (providers->find(provider) == providers->end()) {
      throw HelperPolicyError("strategyProviderMismatch");
    }
    if (!seen.insert(strategy + std::string(1, '\0') + provider).second) {
      throw HelperPolicyError("duplicateAllowedStrategy");
    }
    result.push_back({strategy, provider});
  }
  return result;
}

constexpr std::array<std::uint32_t, 64> kSha256Constants = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

std::uint32_t RotateRight(std::uint32_t value, int count) {
  return (value >> count) | (value << (32 - count));
}

std::string Sha256Hex(const std::string& input) {
  std::vector<std::uint8_t> bytes(input.begin(), input.end());
  const std::uint64_t bit_length =
      static_cast<std::uint64_t>(bytes.size()) * 8;
  bytes.push_back(0x80);
  while (bytes.size() % 64 != 56) bytes.push_back(0);
  for (int shift = 56; shift >= 0; shift -= 8) {
    bytes.push_back(static_cast<std::uint8_t>(bit_length >> shift));
  }

  std::array<std::uint32_t, 8> hash = {
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  };
  for (std::size_t offset = 0; offset < bytes.size(); offset += 64) {
    std::array<std::uint32_t, 64> words = {};
    for (std::size_t index = 0; index < 16; ++index) {
      const std::size_t start = offset + index * 4;
      words[index] = static_cast<std::uint32_t>(bytes[start]) << 24 |
                     static_cast<std::uint32_t>(bytes[start + 1]) << 16 |
                     static_cast<std::uint32_t>(bytes[start + 2]) << 8 |
                     static_cast<std::uint32_t>(bytes[start + 3]);
    }
    for (std::size_t index = 16; index < words.size(); ++index) {
      const std::uint32_t first = RotateRight(words[index - 15], 7) ^
                                  RotateRight(words[index - 15], 18) ^
                                  (words[index - 15] >> 3);
      const std::uint32_t second = RotateRight(words[index - 2], 17) ^
                                   RotateRight(words[index - 2], 19) ^
                                   (words[index - 2] >> 10);
      words[index] = words[index - 16] + first + words[index - 7] + second;
    }
    std::array<std::uint32_t, 8> state = hash;
    for (std::size_t index = 0; index < words.size(); ++index) {
      const std::uint32_t choose =
          (state[4] & state[5]) ^ (~state[4] & state[6]);
      const std::uint32_t majority =
          (state[0] & state[1]) ^ (state[0] & state[2]) ^
          (state[1] & state[2]);
      const std::uint32_t sum_one = RotateRight(state[4], 6) ^
                                    RotateRight(state[4], 11) ^
                                    RotateRight(state[4], 25);
      const std::uint32_t sum_zero = RotateRight(state[0], 2) ^
                                     RotateRight(state[0], 13) ^
                                     RotateRight(state[0], 22);
      const std::uint32_t temporary_one =
          state[7] + sum_one + choose + kSha256Constants[index] + words[index];
      const std::uint32_t temporary_two = sum_zero + majority;
      state[7] = state[6];
      state[6] = state[5];
      state[5] = state[4];
      state[4] = state[3] + temporary_one;
      state[3] = state[2];
      state[2] = state[1];
      state[1] = state[0];
      state[0] = temporary_one + temporary_two;
    }
    for (std::size_t index = 0; index < hash.size(); ++index) {
      hash[index] += state[index];
    }
  }
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (std::uint32_t value : hash) output << std::setw(8) << value;
  return output.str();
}

}  // namespace

HelperPolicyV1::HelperPolicyV1(
    std::int64_t policy_version,
    std::string policy_id,
    std::string application_package_id,
    std::string helper_service_id,
    HelperPolicySigner allowed_application_signer,
    HelperPolicySigner allowed_helper_signer,
    std::vector<std::string> allowed_target_classes,
    std::vector<std::string> allowed_install_roots,
    std::vector<HelperPolicyReleaseRootPublicKey> release_root_public_keys,
    std::vector<HelperPolicyAllowedStrategy> allowed_strategies,
    std::int64_t minimum_helper_protocol_version,
    std::string canonical_json,
    std::string canonical_sha256)
    : policy_version(policy_version),
      policy_id(std::move(policy_id)),
      application_package_id(std::move(application_package_id)),
      helper_service_id(std::move(helper_service_id)),
      allowed_application_signer(std::move(allowed_application_signer)),
      allowed_helper_signer(std::move(allowed_helper_signer)),
      allowed_target_classes(std::move(allowed_target_classes)),
      allowed_install_roots(std::move(allowed_install_roots)),
      release_root_public_keys(std::move(release_root_public_keys)),
      allowed_strategies(std::move(allowed_strategies)),
      minimum_helper_protocol_version(minimum_helper_protocol_version),
      canonical_json(std::move(canonical_json)),
      canonical_sha256(std::move(canonical_sha256)) {}

HelperPolicyError::HelperPolicyError(std::string code)
    : std::runtime_error(code), code_(std::move(code)) {}

HelperPolicyV1 ParseHelperPolicyV1(
    const std::string& json,
    const std::string& expected_application_package_id,
    std::int64_t minimum_accepted_policy_version) {
  try {
    const JsonValue root = ParseJson(json);
    RequireExactKeys(root, kPolicyFields);
    const std::int64_t policy_version =
        RequiredInteger(root, "policyVersion", "policyVersion", 1);
    if (policy_version < minimum_accepted_policy_version) {
      throw HelperPolicyError("policyRollback");
    }
    const std::string policy_id =
        RequiredIdentifier(root, "policyId", "policyId");
    const std::string application_package_id = RequiredIdentifier(
        root, "applicationPackageId", "applicationPackageId");
    if (application_package_id != expected_application_package_id) {
      throw HelperPolicyError("applicationPackageIdMismatch");
    }
    const std::string helper_service_id =
        RequiredIdentifier(root, "helperServiceId", "helperServiceId");
    const HelperPolicySigner application_signer = ParseSigner(
        root.at("allowedApplicationSigner"), "allowedApplicationSigner");
    const HelperPolicySigner helper_signer =
        ParseSigner(root.at("allowedHelperSigner"), "allowedHelperSigner");

    std::vector<std::string> target_classes = RequiredStringArray(
        root, "allowedTargetClasses", false);
    std::set<std::string> unique_target_classes;
    for (const std::string& target_class : target_classes) {
      if (kTargetClasses.find(target_class) == kTargetClasses.end()) {
        throw HelperPolicyError("unknownTargetClass");
      }
      if (!unique_target_classes.insert(target_class).second) {
        throw HelperPolicyError("duplicateTargetClass");
      }
    }

    std::vector<std::string> install_roots =
        RequiredStringArray(root, "allowedInstallRoots", true);
    std::set<std::string> unique_install_roots;
    for (const std::string& install_root : install_roots) {
      ValidateInstallRoot(install_root);
      if (!unique_install_roots.insert(install_root).second) {
        throw HelperPolicyError("duplicateInstallRoot");
      }
    }
    std::vector<HelperPolicyReleaseRootPublicKey> release_roots =
        ParseReleaseRoots(root.at("releaseRootPublicKeys"));
    std::vector<HelperPolicyAllowedStrategy> strategies =
        ParseStrategies(root.at("allowedStrategies"));
    const std::int64_t minimum_protocol = RequiredInteger(
        root, "minimumHelperProtocolVersion", "minimumHelperProtocolVersion",
        1);

    if (install_roots.empty()) {
      const bool elevated_target = std::any_of(
          target_classes.begin(), target_classes.end(),
          [](const std::string& value) { return value != "sameUserWritable"; });
      const bool elevated_strategy = std::any_of(
          strategies.begin(), strategies.end(),
          [](const HelperPolicyAllowedStrategy& value) {
            return value.strategy != "directoryReplace" &&
                   value.strategy != "singleFileReplace";
          });
      if (elevated_target || elevated_strategy) {
        throw HelperPolicyError("portablePolicyRequestsElevation");
      }
    }

    const std::string canonical_json = EncodeCanonicalJson(root);
    return HelperPolicyV1(
        policy_version, policy_id, application_package_id, helper_service_id,
        application_signer, helper_signer, std::move(target_classes),
        std::move(install_roots), std::move(release_roots),
        std::move(strategies), minimum_protocol, canonical_json,
        Sha256Hex(canonical_json));
  } catch (const HelperPolicyError&) {
    throw;
  } catch (const JsonError&) {
    throw HelperPolicyError("invalidPolicyJson");
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
