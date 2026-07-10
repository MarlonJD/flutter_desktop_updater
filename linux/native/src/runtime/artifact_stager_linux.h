#ifndef DESKTOP_UPDATER_RUNTIME_ARTIFACT_STAGER_LINUX_H_
#define DESKTOP_UPDATER_RUNTIME_ARTIFACT_STAGER_LINUX_H_

#include <string>
#include <vector>

#include "artifact_stager.h"
#include "desktop_updater_native.h"
#include "release_contract.h"
#include "stage_provenance.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

struct LinuxStagedArtifact {
  std::string stage_path;
  StageProvenanceState provenance;
};

LinuxStagedArtifact StageLinuxZip(
    const std::string& archive_path,
    const std::string& destination_parent,
    const std::string& executable_relative_path,
    const ReleaseDescriptor& descriptor,
    const std::string& expected_package_id,
    const ArchiveLimits& limits);

native::InstallResult ValidateLinuxInstallHandoff(
    const std::string& staging_path,
    const std::string& install_root,
    const std::string& executable_relative_path,
    const std::string& expected_package_id,
    const std::vector<std::string>& removed_files,
    const std::string& diagnostics_log_path,
    const std::string& expected_provenance_sha256);

native::InstallResult HandoffLinuxInstall(
    const std::string& staging_path,
    const std::string& install_root,
    const std::string& executable_relative_path,
    const std::string& expected_package_id,
    const std::vector<std::string>& removed_files,
    const std::string& diagnostics_log_path,
    const std::string& expected_provenance_sha256);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_ARTIFACT_STAGER_LINUX_H_
