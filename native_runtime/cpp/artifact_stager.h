#ifndef DESKTOP_UPDATER_RUNTIME_ARTIFACT_STAGER_H_
#define DESKTOP_UPDATER_RUNTIME_ARTIFACT_STAGER_H_

#include <cstdint>
#include <string>

namespace desktop_updater {
namespace runtime {
namespace internal {

struct ArchiveLimits {
  std::int64_t maximum_archive_entries = 100000;
  std::int64_t maximum_uncompressed_bytes = 8LL * 1024LL * 1024LL * 1024LL;
  std::int64_t maximum_single_entry_bytes = 4LL * 1024LL * 1024LL * 1024LL;
};

void StageZipArchive(const std::string& archive_path,
                     const std::string& destination_path,
                     const ArchiveLimits& limits);

std::string NormalizeSafeArchivePath(const std::string& input);

void RemoveStagingDirectory(const std::string& path);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_ARTIFACT_STAGER_H_
