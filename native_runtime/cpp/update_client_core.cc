#include "update_client_core.h"

#include <algorithm>
#include <chrono>
#include <ctime>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

ClientCheckResult Failure(const std::string& outcome,
                          const std::string& message) {
  ClientCheckResult result;
  result.outcome = outcome;
  result.message = message;
  return result;
}

ClientCheckResult FailureWithSupport(const std::string& outcome,
                                     const std::string& message,
                                     const std::string& support_status) {
  ClientCheckResult result = Failure(outcome, message);
  result.support_policy_status = support_status;
  return result;
}

std::string CurrentTimestamp() {
  const auto now = std::chrono::system_clock::now();
  const std::time_t seconds = std::chrono::system_clock::to_time_t(now);
  std::tm utc{};
#if defined(_WIN32)
  gmtime_s(&utc, &seconds);
#else
  gmtime_r(&seconds, &utc);
#endif
  char buffer[32];
  std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc);
  return buffer;
}

bool IsNewer(const ReleaseIndexItem& item,
             const DesktopVersion& current_version) {
  return CompareDesktopVersions(
             ParseDesktopVersion(item.version,
                                 item.has_build_number &&
                                     item.build_number > 0,
                                 item.build_number),
             current_version) > 0;
}

bool SupportedArtifact(const std::string& platform, const std::string& kind) {
  if (platform == "macos") {
    return kind == "zip" || kind == "dmg" || kind == "pkgInstaller";
  }
  if (platform == "windows") {
    return kind == "zip" || kind == "innoInstaller";
  }
  return platform == "linux" && kind == "zip";
}

std::string BytesToString(const std::vector<std::uint8_t>& bytes) {
  return std::string(bytes.begin(), bytes.end());
}

}  // namespace

ClientCheckResult CheckForUpdateCore(const ClientConfiguration& configuration,
                                     UpdateTransport* transport,
                                     const Sha256Function& sha256) {
  if (transport == nullptr || !sha256 || !configuration.minimum_os_resolver) {
    return Failure("invalidDescriptor", "Runtime dependencies are missing.");
  }

  std::vector<std::uint8_t> index_bytes;
  try {
    index_bytes = transport->DownloadMetadata(configuration.app_archive_url);
  } catch (const std::runtime_error& error) {
    return Failure("downloadFailure", error.what());
  }
  ReleaseIndex index;
  try {
    index = ParseReleaseIndex(BytesToString(index_bytes));
  } catch (const JsonError& error) {
    return Failure("invalidDescriptor", error.what());
  }

  DesktopVersion current_version;
  try {
    current_version = ParseDesktopVersion(
        configuration.current_version, configuration.has_current_build_number,
        configuration.current_build_number);
  } catch (const JsonError& error) {
    return Failure("invalidDescriptor", error.what());
  }

  std::string support_status = "supported";
  if (index.has_support_policy) {
    const std::string outcome = SupportPolicyOutcome(
        index.support_policy, current_version, CurrentTimestamp());
    if (outcome == "supportPolicyWarning") support_status = "warning";
    if (outcome == "supportPolicyBlocked") support_status = "blocked";
  }

  const bool has_newer = std::any_of(
      index.items.begin(), index.items.end(), [&](const ReleaseIndexItem& item) {
        return item.platform == configuration.platform &&
               item.channel == configuration.channel &&
               IsNewer(item, current_version);
      });
  if (!has_newer) {
    return FailureWithSupport("noUpdate", "No newer release is available.",
                              support_status);
  }

  const ReleaseIndexItem* selected = nullptr;
  try {
    selected = SelectReleaseIndexItem(
        index, configuration.platform, configuration.channel, current_version,
        configuration.installation_identity, sha256);
  } catch (const JsonError& error) {
    return FailureWithSupport("invalidDescriptor", error.what(),
                              support_status);
  }
  if (selected == nullptr) {
    return FailureWithSupport("rolloutIneligible",
                              "Installation is outside the rollout cohort.",
                              support_status);
  }

  ClientCheckResult result;
  result.support_policy_status = support_status;
  result.has_selected_item = true;
  result.selected_item = *selected;

  std::vector<std::uint8_t> descriptor_bytes;
  try {
    descriptor_bytes = transport->DownloadMetadata(selected->release);
  } catch (const std::runtime_error& error) {
    return FailureWithSupport("downloadFailure", error.what(),
                              support_status);
  }
  try {
    result.descriptor = ParseReleaseDescriptor(BytesToString(descriptor_bytes));
    result.has_descriptor = true;
  } catch (const JsonError& error) {
    return FailureWithSupport("invalidDescriptor", error.what(),
                              support_status);
  }

  const std::string binding = DescriptorBindingOutcome(
      result.descriptor, *selected, configuration.expected_package_id);
  if (binding != "match") {
    result.outcome = binding;
    result.message = "Descriptor does not match its selected index item.";
    return result;
  }
  if ((configuration.require_descriptor_signature ||
       result.descriptor.has_signature) &&
      !VerifyDescriptorSignature(result.descriptor,
                                 configuration.pinned_public_keys_by_id)) {
    result.outcome = "signatureFailure";
    result.message = "Descriptor Ed25519 signature is invalid.";
    return result;
  }
  if (selected->has_fresh_install) {
    result.outcome = "freshInstallRequired";
    result.message = "Selected release requires a fresh install.";
    return result;
  }
  if (!SupportedArtifact(configuration.platform,
                         result.descriptor.artifact.kind)) {
    result.outcome = "unsupportedArtifactKind";
    result.message = "Artifact kind is not supported on this platform.";
    return result;
  }
  try {
    const std::string policy = DescriptorPolicyOutcome(
        result.descriptor,
        ParseDesktopVersion(configuration.current_updater_version),
        configuration.platform, configuration.minimum_os_resolver);
    if (policy != "updateAvailable") {
      result.outcome = policy;
      result.message = "Selected descriptor is not installable on this host.";
      return result;
    }
  } catch (const JsonError& error) {
    result.outcome = "invalidDescriptor";
    result.message = error.what();
    return result;
  }

  result.outcome = "updateAvailable";
  result.message = "Verified selected native release descriptor.";
  return result;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
