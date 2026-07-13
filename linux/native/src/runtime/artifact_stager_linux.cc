#include "artifact_stager_linux.h"

#include <fstream>
#include <stdexcept>
#include <sys/stat.h>

#include "sha256_openssl.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

native::InstallRequest LinuxInstallRequest(
    const std::string& staging_path,
    const std::string& install_root,
    const std::string& executable_relative_path,
    const std::string& expected_package_id,
    const std::vector<std::string>& removed_files,
    const std::string& diagnostics_log_path,
    const std::string& expected_provenance_sha256) {
  const StageProvenanceMarker marker = VerifyStageProvenance(
      staging_path, expected_provenance_sha256, OpenSSLSha256);
  std::vector<native::InstallProvenanceEntry> entries;
  for (const StageProvenanceEntry& entry : marker.entries) {
    entries.push_back({entry.path, entry.kind, entry.length,
                       entry.sha256, entry.target});
  }
  return {native::LinuxInstallOperation::kInstall,
          staging_path,
          install_root,
          NormalizeSafeArchivePath(executable_relative_path),
          expected_package_id,
          removed_files,
          diagnostics_log_path,
          expected_provenance_sha256,
          marker.nonce,
          entries};
}

}  // namespace

LinuxStagedArtifact StageLinuxZip(const std::string& archive_path,
                   const std::string& destination_parent,
                   const std::string& executable_relative_path,
                   const ReleaseDescriptor& descriptor,
                   const std::string& expected_package_id,
                   const ArchiveLimits& limits) {
  if (expected_package_id.empty() ||
      descriptor.package_id != expected_package_id ||
      descriptor.platform != "linux" || descriptor.artifact.kind != "zip") {
    throw std::invalid_argument("expected_package_id does not match release.");
  }
  const std::string executable = NormalizeSafeArchivePath(
      executable_relative_path);
  const OwnedStage stage = CreateOwnedStage(destination_parent);
  try {
    StageZipArchive(archive_path, stage.path, limits);
    {
      std::ifstream source(archive_path, std::ios::binary);
      std::ofstream destination(
          stage.path + "/.desktop_updater_artifact.zip", std::ios::binary);
      destination << source.rdbuf();
      if (!source || !destination) {
        throw std::runtime_error("Unable to retain verified ZIP artifact.");
      }
    }
    struct stat binary {};
    if (stat((stage.path + "/" + executable).c_str(), &binary) != 0 ||
        !S_ISREG(binary.st_mode) || (binary.st_mode & S_IXUSR) == 0) {
      throw std::runtime_error(
          "Staged Linux executable is missing or not executable.");
    }
    std::ofstream manifest(
        stage.path + "/.desktop_updater_release_manifest.json",
        std::ios::binary);
    manifest << EncodeCanonicalJson(descriptor.raw) << "\n";
    manifest.close();
    if (!manifest) {
      throw std::runtime_error("Unable to write release manifest.");
    }
    const StageProvenanceState provenance = WriteStageProvenance(
        stage, expected_package_id,
        StageBytesToHex(OpenSSLSha256(EncodeCanonicalJson(descriptor.raw))),
        descriptor.artifact.sha256, OpenSSLSha256);
    return {stage.path, provenance};
  } catch (...) {
    try {
      RemoveStagingDirectory(stage.path);
    } catch (...) {
      // Preserve the staging failure that triggered cleanup.
    }
    throw;
  }
}

native::InstallResult ValidateLinuxInstallHandoff(
    const std::string& staging_path,
    const std::string& install_root,
    const std::string& executable_relative_path,
    const std::string& expected_package_id,
    const std::vector<std::string>& removed_files,
    const std::string& diagnostics_log_path,
    const std::string& expected_provenance_sha256) {
  return native::ValidateInstallRequest(LinuxInstallRequest(
      staging_path, install_root, executable_relative_path,
      expected_package_id, removed_files, diagnostics_log_path,
      expected_provenance_sha256));
}

native::InstallResult HandoffLinuxInstall(
    const std::string& staging_path,
    const std::string& install_root,
    const std::string& executable_relative_path,
    const std::string& expected_package_id,
    const std::vector<std::string>& removed_files,
    const std::string& diagnostics_log_path,
    const std::string& expected_provenance_sha256) {
  return native::ScheduleInstallAndRelaunch(LinuxInstallRequest(
      staging_path, install_root, executable_relative_path,
      expected_package_id, removed_files, diagnostics_log_path,
      expected_provenance_sha256));
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
