#ifndef DESKTOP_UPDATER_RUNTIME_RELEASE_CONTRACT_H_
#define DESKTOP_UPDATER_RUNTIME_RELEASE_CONTRACT_H_

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "json_value.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

using Sha256Function =
    std::function<std::vector<std::uint8_t>(const std::string&)>;

struct DesktopVersion {
  std::string raw;
  std::int64_t major = 0;
  std::int64_t minor = 0;
  std::int64_t patch = 0;
  std::vector<std::string> prerelease;
  bool has_build_number = false;
  std::int64_t build_number = 0;
};

DesktopVersion ParseDesktopVersion(
    const std::string& value,
    bool has_build_number = false,
    std::int64_t build_number = 0);
int CompareDesktopVersions(const DesktopVersion& left,
                           const DesktopVersion& right);

struct ReleaseRollout {
  std::int64_t percentage = 0;
  std::string salt;
};

struct ReleaseFreshInstall {
  std::string download_url;
  bool has_message = false;
  std::string message;
};

struct ReleaseSupportPolicy {
  DesktopVersion minimum_supported_version;
  std::string enforced_after;
};

struct ReleaseIndexItem {
  std::string version;
  bool has_build_number = false;
  std::int64_t build_number = 0;
  std::string platform;
  std::string channel;
  bool mandatory = false;
  std::string release;
  bool has_rollout = false;
  ReleaseRollout rollout;
  bool has_fresh_install = false;
  ReleaseFreshInstall fresh_install;
  JsonValue raw;
};

struct ReleaseSignature {
  std::string algorithm;
  std::string public_key_id;
  std::string value;
};

struct ReleaseIndex {
  std::int64_t schema_version = 0;
  std::string app_name;
  std::vector<ReleaseIndexItem> items;
  bool has_support_policy = false;
  ReleaseSupportPolicy support_policy;
  bool has_signature = false;
  ReleaseSignature signature;
  JsonValue raw;
};

struct ReleaseArtifact {
  std::string kind;
  std::string url;
  std::string sha256;
  std::int64_t length = 0;
  JsonValue raw;
};

struct ReleaseDescriptor {
  std::int64_t schema_version = 0;
  std::string package_id;
  std::string app_name;
  std::string version;
  bool has_build_number = false;
  std::int64_t build_number = 0;
  std::string platform;
  std::string channel;
  ReleaseArtifact artifact;
  JsonValue install;
  bool has_signature = false;
  ReleaseSignature signature;
  std::string minimum_updater_version;
  std::map<std::string, std::string> minimum_os;
  std::vector<JsonValue> delta_artifacts;
  std::string generated_at;
  JsonValue raw;
};

ReleaseIndex ParseReleaseIndex(const std::string& json);
ReleaseIndexItem ParseReleaseIndexItem(const JsonValue& json);
ReleaseDescriptor ParseReleaseDescriptor(const std::string& json);
const ReleaseIndexItem* SelectReleaseIndexItem(
    const ReleaseIndex& index,
    const std::string& platform,
    const std::string& channel,
    const DesktopVersion& current_version,
    const std::string& installation_identity,
    const Sha256Function& sha256);

std::string CanonicalSignatureBytes(const ReleaseDescriptor& descriptor);
std::string CanonicalIndexSignatureBytes(const ReleaseIndex& index);
bool VerifyIndexSignature(
    const ReleaseIndex& index,
    const std::map<std::string, std::vector<std::uint8_t>>& pinned_keys);
bool VerifyDescriptorSignature(
    const ReleaseDescriptor& descriptor,
    const std::map<std::string, std::vector<std::uint8_t>>& pinned_keys);

std::string DescriptorBindingOutcome(const ReleaseDescriptor& descriptor,
                                     const ReleaseIndexItem& item,
                                     const std::string& expected_package_id);
std::string DescriptorPolicyOutcome(
    const ReleaseDescriptor& descriptor,
    const DesktopVersion& current_updater_version,
    const std::string& platform,
    const std::function<bool(const std::string&, const std::string&)>&
        minimum_os_resolver);
std::string SupportPolicyOutcome(const ReleaseSupportPolicy& policy,
                                 const DesktopVersion& current_version,
                                 const std::string& now);

std::vector<std::uint8_t> DecodeBase64(const std::string& value);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_RELEASE_CONTRACT_H_
