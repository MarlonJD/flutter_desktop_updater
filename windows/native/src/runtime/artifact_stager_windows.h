#ifndef DESKTOP_UPDATER_RUNTIME_ARTIFACT_STAGER_WINDOWS_H_
#define DESKTOP_UPDATER_RUNTIME_ARTIFACT_STAGER_WINDOWS_H_

#include <string>
#include <vector>

#include "artifact_stager.h"
#include "release_contract.h"
#include "stage_provenance.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

struct WindowsStagedArtifact {
  std::string stage_path;
  StageProvenanceState provenance;
};

WindowsStagedArtifact StageWindowsZip(
    const std::string& archive_path,
    const std::string& destination_parent,
    const ReleaseDescriptor& descriptor,
    const std::string& expected_package_id,
    const ArchiveLimits& limits);
WindowsStagedArtifact StageWindowsInnoInstaller(
    const std::wstring& installer_path,
    const std::string& destination_parent,
    const ReleaseDescriptor& descriptor,
    const std::string& expected_package_id);

struct WindowsInstallHandoffResult {
  bool ok;
  std::string error_message;
};

WindowsInstallHandoffResult HandoffWindowsInstall(
    const std::wstring& staging_path,
    const std::wstring& diagnostics_log_path,
    const std::vector<std::wstring>& removed_files,
    const std::string& expected_provenance_sha256,
    const ReleaseDescriptor& descriptor);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_ARTIFACT_STAGER_WINDOWS_H_
