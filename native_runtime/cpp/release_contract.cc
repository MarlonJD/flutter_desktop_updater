#include "release_contract.h"

#include <algorithm>
#include <cctype>
#include <climits>
#include <cstdlib>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <utility>

#include "optional/monocypher-ed25519.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

std::string RequiredString(const JsonValue& value, const std::string& key) {
  const std::string result = value.at(key).string();
  if (result.empty()) throw JsonError("Empty JSON string: " + key);
  return result;
}

bool HasScheme(const std::string& value) {
  const std::size_t separator = value.find(':');
  return separator != std::string::npos && separator > 0;
}

std::int64_t ParseComponent(const std::string& value) {
  if (value.empty() || !std::all_of(value.begin(), value.end(), ::isdigit)) {
    throw JsonError("Invalid semantic version component.");
  }
  char* end = nullptr;
  const long long parsed = std::strtoll(value.c_str(), &end, 10);
  if (end == nullptr || *end != '\0' || parsed < 0) {
    throw JsonError("Invalid semantic version component.");
  }
  return static_cast<std::int64_t>(parsed);
}

std::vector<std::string> Split(const std::string& value, char separator) {
  std::vector<std::string> result;
  std::size_t start = 0;
  while (true) {
    const std::size_t next = value.find(separator, start);
    result.push_back(value.substr(start, next - start));
    if (next == std::string::npos) return result;
    start = next + 1;
  }
}

int ComparePrerelease(const std::vector<std::string>& left,
                      const std::vector<std::string>& right) {
  if (left.empty() != right.empty()) return left.empty() ? 1 : -1;
  const std::size_t count = std::min(left.size(), right.size());
  for (std::size_t index = 0; index < count; ++index) {
    if (left[index] == right[index]) continue;
    const bool left_numeric =
        !left[index].empty() &&
        std::all_of(left[index].begin(), left[index].end(), ::isdigit);
    const bool right_numeric =
        !right[index].empty() &&
        std::all_of(right[index].begin(), right[index].end(), ::isdigit);
    if (left_numeric && right_numeric) {
      const std::int64_t left_value = ParseComponent(left[index]);
      const std::int64_t right_value = ParseComponent(right[index]);
      return left_value < right_value ? -1 : 1;
    }
    if (left_numeric != right_numeric) return left_numeric ? -1 : 1;
    return left[index] < right[index] ? -1 : 1;
  }
  if (left.size() == right.size()) return 0;
  return left.size() < right.size() ? -1 : 1;
}

bool RolloutIncludes(const ReleaseIndexItem& item,
                     const std::string& identity,
                     const Sha256Function& sha256) {
  if (!item.has_rollout) return true;
  if (item.rollout.percentage == 100) return true;
  if (item.rollout.percentage <= 0 || identity.empty()) return false;
  const std::vector<std::uint8_t> digest = sha256(
      item.rollout.salt + "\n" + item.channel + "\n" + identity);
  if (digest.size() != 32) throw JsonError("SHA-256 provider returned bad size.");
  std::uint32_t value = 0;
  for (std::size_t index = 0; index < 4; ++index) {
    value = (value << 8) + digest[index];
  }
  return value % 100 < static_cast<std::uint32_t>(item.rollout.percentage);
}

void ValidateArtifact(const ReleaseArtifact& artifact) {
  static const std::regex kSha256("^[0-9a-f]{64}$");
  if (artifact.kind != "zip" && artifact.kind != "dmg" &&
      artifact.kind != "pkgInstaller" && artifact.kind != "innoInstaller") {
    throw JsonError("Unsupported artifact kind: " + artifact.kind);
  }
  if (!HasScheme(artifact.url)) throw JsonError("Artifact URL is not absolute.");
  if (!std::regex_match(artifact.sha256, kSha256)) {
    throw JsonError("Invalid artifact SHA-256.");
  }
  if (artifact.length < 0) throw JsonError("Invalid artifact length.");
}

void ValidateInstall(const ReleaseDescriptor& descriptor) {
  const std::string strategy = RequiredString(descriptor.install, "strategy");
  if (descriptor.artifact.kind == "dmg") {
    if (descriptor.platform != "macos" || strategy != "wholeBundleReplace") {
      throw JsonError("Invalid DMG install strategy.");
    }
    const JsonValue& metadata = descriptor.install.at("macosDmg");
    const std::string name = RequiredString(metadata, "appBundleName");
    if (name.size() < 4 || name.substr(name.size() - 4) != ".app") {
      throw JsonError("Invalid DMG app bundle name.");
    }
  } else if (descriptor.artifact.kind == "pkgInstaller") {
    if (descriptor.platform != "macos" || strategy != "pkgInstaller") {
      throw JsonError("Invalid PKG install strategy.");
    }
    const JsonValue& metadata = descriptor.install.at("macosPkg");
    if (RequiredString(metadata, "launchMode") != "installerApp" ||
        metadata.at("expectedPackageIds").array().empty()) {
      throw JsonError("Invalid PKG install metadata.");
    }
  } else if (descriptor.artifact.kind == "innoInstaller") {
    if (descriptor.platform != "windows" || strategy != "innoInstaller") {
      throw JsonError("Invalid Inno install strategy.");
    }
    const JsonValue& metadata = descriptor.install.at("inno");
    if (metadata.at("silentArgs").array().empty()) {
      throw JsonError("Invalid Inno silent arguments.");
    }
    metadata.at("authenticode").object();
  }
}

ReleaseArtifact ParseArtifact(const JsonValue& json) {
  ReleaseArtifact result;
  result.kind = RequiredString(json, "kind");
  result.url = RequiredString(json, "url");
  result.sha256 = RequiredString(json, "sha256");
  result.length = json.at("length").integer();
  result.raw = json;
  ValidateArtifact(result);
  return result;
}

std::string OptionalString(const JsonValue& value, const std::string& key) {
  const JsonValue* found = value.find(key);
  return found == nullptr ? std::string() : found->string();
}

}  // namespace

DesktopVersion ParseDesktopVersion(const std::string& value,
                                   bool has_build_number,
                                   std::int64_t build_number) {
  if (value.empty()) throw JsonError("Version must not be empty.");
  DesktopVersion result;
  result.raw = value;
  const std::vector<std::string> build_split = Split(value, '+');
  if (build_split.size() > 2) throw JsonError("Invalid version build metadata.");
  const std::vector<std::string> prerelease_split = Split(build_split[0], '-');
  if (prerelease_split.size() > 2) throw JsonError("Invalid prerelease version.");
  const std::vector<std::string> components = Split(prerelease_split[0], '.');
  if (components.size() != 3) throw JsonError("Version needs three components.");
  result.major = ParseComponent(components[0]);
  result.minor = ParseComponent(components[1]);
  result.patch = ParseComponent(components[2]);
  if (prerelease_split.size() == 2) {
    result.prerelease = Split(prerelease_split[1], '.');
    if (std::any_of(result.prerelease.begin(), result.prerelease.end(),
                    [](const std::string& item) { return item.empty(); })) {
      throw JsonError("Empty prerelease identifier.");
    }
  }
  result.has_build_number = has_build_number;
  result.build_number = build_number;
  if (!has_build_number && build_split.size() == 2) {
    result.build_number = ParseComponent(build_split[1]);
    result.has_build_number = true;
  }
  if (result.has_build_number && result.build_number < 0) {
    throw JsonError("Negative build number.");
  }
  return result;
}

int CompareDesktopVersions(const DesktopVersion& left,
                           const DesktopVersion& right) {
  if (left.has_build_number && right.has_build_number) {
    if (left.build_number == right.build_number) return 0;
    return left.build_number < right.build_number ? -1 : 1;
  }
  if (left.major != right.major) return left.major < right.major ? -1 : 1;
  if (left.minor != right.minor) return left.minor < right.minor ? -1 : 1;
  if (left.patch != right.patch) return left.patch < right.patch ? -1 : 1;
  return ComparePrerelease(left.prerelease, right.prerelease);
}

ReleaseIndexItem ParseReleaseIndexItem(const JsonValue& json) {
  ReleaseIndexItem result;
  result.version = RequiredString(json, "version");
  ParseDesktopVersion(result.version);
  const JsonValue* build = json.find("buildNumber");
  if (build == nullptr) build = json.find("shortVersion");
  if (build != nullptr) {
    result.has_build_number = true;
    result.build_number = build->integer();
    if (result.build_number < 0) throw JsonError("Negative index build number.");
  }
  result.platform = RequiredString(json, "platform");
  result.channel = OptionalString(json, "channel");
  if (result.channel.empty()) result.channel = "stable";
  const JsonValue* mandatory = json.find("mandatory");
  result.mandatory = mandatory != nullptr && mandatory->boolean();
  result.release = RequiredString(json, "release");
  if (!HasScheme(result.release)) throw JsonError("Index release URL not absolute.");
  if (const JsonValue* rollout = json.find("rollout")) {
    result.has_rollout = true;
    result.rollout.percentage = rollout->at("percentage").integer();
    result.rollout.salt = RequiredString(*rollout, "salt");
    if (result.rollout.percentage < 0 || result.rollout.percentage > 100) {
      throw JsonError("Invalid rollout percentage.");
    }
  }
  if (const JsonValue* fresh = json.find("freshInstall")) {
    result.has_fresh_install = true;
    result.fresh_install.download_url = RequiredString(*fresh, "downloadUrl");
    if (!HasScheme(result.fresh_install.download_url)) {
      throw JsonError("Fresh install URL not absolute.");
    }
    result.fresh_install.message = OptionalString(*fresh, "message");
  }
  result.raw = json;
  return result;
}

ReleaseIndex ParseReleaseIndex(const std::string& json) {
  const JsonValue root = ParseJson(json);
  ReleaseIndex result;
  result.schema_version = root.at("schemaVersion").integer();
  if (result.schema_version != 3) throw JsonError("Index schema must be 3.");
  result.app_name = RequiredString(root, "appName");
  for (const JsonValue& item : root.at("items").array()) {
    result.items.push_back(ParseReleaseIndexItem(item));
  }
  if (const JsonValue* policy = root.find("supportPolicy")) {
    result.has_support_policy = true;
    result.support_policy.minimum_supported_version = ParseDesktopVersion(
        RequiredString(*policy, "minimumSupportedVersion"));
    result.support_policy.enforced_after = RequiredString(*policy, "enforcedAfter");
  }
  result.raw = root;
  return result;
}

ReleaseDescriptor ParseReleaseDescriptor(const std::string& json) {
  const JsonValue root = ParseJson(json);
  ReleaseDescriptor result;
  result.schema_version = root.at("schemaVersion").integer();
  if (result.schema_version != 3) throw JsonError("Descriptor schema must be 3.");
  result.package_id = RequiredString(root, "packageId");
  result.app_name = RequiredString(root, "appName");
  result.version = RequiredString(root, "version");
  ParseDesktopVersion(result.version);
  if (const JsonValue* build = root.find("buildNumber")) {
    result.has_build_number = true;
    result.build_number = build->integer();
    if (result.build_number < 0) throw JsonError("Negative descriptor build.");
  }
  result.platform = RequiredString(root, "platform");
  result.channel = OptionalString(root, "channel");
  if (result.channel.empty()) result.channel = "stable";
  result.artifact = ParseArtifact(root.at("artifact"));
  result.install = root.at("install");
  if (const JsonValue* signature = root.find("signature")) {
    result.has_signature = true;
    result.signature.algorithm = RequiredString(*signature, "algorithm");
    result.signature.public_key_id = RequiredString(*signature, "publicKeyId");
    result.signature.value = signature->at("value").string();
  }
  result.minimum_updater_version = RequiredString(root, "minimumUpdaterVersion");
  ParseDesktopVersion(result.minimum_updater_version);
  if (const JsonValue* minimum_os = root.find("minimumOS")) {
    for (const auto& entry : minimum_os->object()) {
      if (entry.first.empty() || entry.second.string().empty()) {
        throw JsonError("Invalid minimum OS entry.");
      }
      result.minimum_os.emplace(entry.first, entry.second.string());
    }
  }
  if (const JsonValue* deltas = root.find("deltaArtifacts")) {
    for (const JsonValue& delta : deltas->array()) {
      delta.object();
      result.delta_artifacts.push_back(delta);
    }
  }
  result.generated_at = RequiredString(root, "generatedAt");
  result.raw = root;
  ValidateInstall(result);
  return result;
}

const ReleaseIndexItem* SelectReleaseIndexItem(
    const ReleaseIndex& index,
    const std::string& platform,
    const std::string& channel,
    const DesktopVersion& current_version,
    const std::string& installation_identity,
    const Sha256Function& sha256) {
  const ReleaseIndexItem* selected = nullptr;
  for (const ReleaseIndexItem& item : index.items) {
    if (item.platform != platform || item.channel != channel ||
        !RolloutIncludes(item, installation_identity, sha256)) {
      continue;
    }
    const DesktopVersion candidate = ParseDesktopVersion(
        item.version, item.has_build_number && item.build_number > 0,
        item.build_number);
    if (CompareDesktopVersions(candidate, current_version) <= 0) continue;
    if (selected == nullptr ||
        CompareDesktopVersions(
            candidate,
            ParseDesktopVersion(selected->version,
                                selected->has_build_number &&
                                    selected->build_number > 0,
                                selected->build_number)) > 0) {
      selected = &item;
    }
  }
  return selected;
}

std::string CanonicalSignatureBytes(const ReleaseDescriptor& descriptor) {
  JsonValue canonical = descriptor.raw;
  JsonValue* signature = nullptr;
  auto iterator = canonical.object().find("signature");
  if (iterator != canonical.object().end()) signature = &iterator->second;
  if (signature != nullptr) {
    signature->object()["value"] = JsonValue(std::string());
  }
  return EncodeCanonicalJson(canonical);
}

bool VerifyDescriptorSignature(
    const ReleaseDescriptor& descriptor,
    const std::map<std::string, std::vector<std::uint8_t>>& pinned_keys) {
  if (!descriptor.has_signature || descriptor.signature.algorithm != "ed25519") {
    return false;
  }
  const auto key = pinned_keys.find(descriptor.signature.public_key_id);
  if (key == pinned_keys.end() || key->second.size() != 32) return false;
  std::vector<std::uint8_t> signature;
  try {
    signature = DecodeBase64(descriptor.signature.value);
  } catch (const JsonError&) {
    return false;
  }
  if (signature.size() != 64) return false;
  const std::string message = CanonicalSignatureBytes(descriptor);
  return crypto_ed25519_check(signature.data(), key->second.data(),
                              reinterpret_cast<const std::uint8_t*>(
                                  message.data()),
                              message.size()) == 0;
}

std::string DescriptorBindingOutcome(const ReleaseDescriptor& descriptor,
                                     const ReleaseIndexItem& item,
                                     const std::string& expected_package_id) {
  if (descriptor.package_id != expected_package_id) {
    return "packageIdentityMismatch";
  }
  if (descriptor.version != item.version ||
      descriptor.has_build_number != item.has_build_number ||
      (descriptor.has_build_number &&
       descriptor.build_number != item.build_number) ||
      descriptor.platform != item.platform || descriptor.channel != item.channel) {
    return "invalidDescriptor";
  }
  return "match";
}

std::string DescriptorPolicyOutcome(
    const ReleaseDescriptor& descriptor,
    const DesktopVersion& current_updater_version,
    const std::string& platform,
    const std::function<bool(const std::string&, const std::string&)>&
        minimum_os_resolver) {
  if (CompareDesktopVersions(
          current_updater_version,
          ParseDesktopVersion(descriptor.minimum_updater_version)) < 0) {
    return "unsupportedMinimumUpdater";
  }
  const auto minimum_os = descriptor.minimum_os.find(platform);
  if (minimum_os != descriptor.minimum_os.end() &&
      !minimum_os_resolver(platform, minimum_os->second)) {
    return "unsupportedMinimumOS";
  }
  return "updateAvailable";
}

std::string SupportPolicyOutcome(const ReleaseSupportPolicy& policy,
                                 const DesktopVersion& current_version,
                                 const std::string& now) {
  if (CompareDesktopVersions(current_version,
                             policy.minimum_supported_version) >= 0) {
    return "updateAvailable";
  }
  return now >= policy.enforced_after ? "supportPolicyBlocked"
                                      : "supportPolicyWarning";
}

std::vector<std::uint8_t> DecodeBase64(const std::string& value) {
  static const std::string alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  if (value.empty() || value.size() % 4 != 0) {
    throw JsonError("Invalid base64 length.");
  }
  std::vector<std::uint8_t> output;
  for (std::size_t offset = 0; offset < value.size(); offset += 4) {
    const bool final_group = offset + 4 == value.size();
    const bool pad_two = value[offset + 2] == '=';
    const bool pad_three = value[offset + 3] == '=';
    if ((pad_two && !pad_three) || (!final_group && (pad_two || pad_three)) ||
        value[offset] == '=' || value[offset + 1] == '=') {
      throw JsonError("Invalid base64 padding.");
    }
    const std::size_t first = alphabet.find(value[offset]);
    const std::size_t second = alphabet.find(value[offset + 1]);
    const std::size_t third = pad_two ? 0 : alphabet.find(value[offset + 2]);
    const std::size_t fourth = pad_three ? 0 : alphabet.find(value[offset + 3]);
    if (first == std::string::npos || second == std::string::npos ||
        third == std::string::npos || fourth == std::string::npos) {
      throw JsonError("Invalid base64 byte.");
    }
    if ((pad_two && (second & 0x0F) != 0) ||
        (pad_three && !pad_two && (third & 0x03) != 0)) {
      throw JsonError("Non-canonical base64 padding bits.");
    }
    const std::uint32_t combined =
        (static_cast<std::uint32_t>(first) << 18) |
        (static_cast<std::uint32_t>(second) << 12) |
        (static_cast<std::uint32_t>(third) << 6) |
        static_cast<std::uint32_t>(fourth);
    output.push_back(static_cast<std::uint8_t>((combined >> 16) & 0xFF));
    if (!pad_two) {
      output.push_back(static_cast<std::uint8_t>((combined >> 8) & 0xFF));
    }
    if (!pad_three) {
      output.push_back(static_cast<std::uint8_t>(combined & 0xFF));
    }
  }
  return output;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
