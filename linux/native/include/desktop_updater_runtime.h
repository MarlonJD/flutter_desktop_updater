#ifndef DESKTOP_UPDATER_RUNTIME_H_
#define DESKTOP_UPDATER_RUNTIME_H_

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace desktop_updater {
namespace runtime {

enum class RuntimeOutcome {
  kNoUpdate,
  kUpdateAvailable,
  kFreshInstallRequired,
  kUnsupportedMinimumUpdater,
  kUnsupportedMinimumOS,
  kRolloutIneligible,
  kUnsupportedArtifactKind,
  kInvalidDescriptor,
  kSignatureFailure,
  kPackageIdentityMismatch,
  kDownloadFailure,
  kArtifactIntegrityFailure,
  kUnsafeArchive,
  kStagingFailure,
  kInstallHandoffFailure,
};

using MinimumOSResolver =
    std::function<bool(const std::string& platform,
                       const std::string& minimum_os)>;
using RequestHeadersProvider =
    std::function<std::map<std::string, std::string>(const std::string& url)>;

struct RuntimeConfiguration {
  std::string app_archive_url;
  std::string expected_package_id;
  std::string current_version;
  bool has_current_build_number = false;
  std::int64_t current_build_number = 0;
  std::string current_updater_version;
  std::string platform;
  std::string channel = "stable";
  std::string installation_identity;
  bool require_descriptor_signature = true;
  std::map<std::string, std::vector<std::uint8_t>> pinned_public_keys_by_id;
  MinimumOSResolver minimum_os_resolver;
  RequestHeadersProvider request_headers_provider;
  std::int64_t download_timeout_milliseconds = 30000;
  std::int64_t maximum_metadata_bytes = 4LL * 1024LL * 1024LL;
  std::int64_t maximum_archive_entries = 100000;
  std::int64_t maximum_uncompressed_bytes = 8LL * 1024LL * 1024LL * 1024LL;
  std::int64_t maximum_single_entry_bytes = 4LL * 1024LL * 1024LL * 1024LL;
};

struct RuntimeConfigurationValidation {
  bool ok;
  std::string error;
};

struct RuntimeResult {
  RuntimeOutcome outcome;
  std::string message;
};

RuntimeConfigurationValidation ValidateRuntimeConfiguration(
    const RuntimeConfiguration& configuration);

}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_H_
