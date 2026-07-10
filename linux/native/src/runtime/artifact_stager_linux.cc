#include "artifact_stager_linux.h"

#include <fstream>
#include <stdexcept>
#include <sys/stat.h>

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
    const std::string& diagnostics_log_path) {
  return {native::LinuxInstallOperation::kInstall,
          staging_path,
          install_root,
          NormalizeSafeArchivePath(executable_relative_path),
          expected_package_id,
          removed_files,
          diagnostics_log_path};
}

}  // namespace

void StageLinuxZip(const std::string& archive_path,
                   const std::string& destination_path,
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
  try {
    StageZipArchive(archive_path, destination_path, limits);
    struct stat binary {};
    if (stat((destination_path + "/" + executable).c_str(), &binary) != 0 ||
        !S_ISREG(binary.st_mode) || (binary.st_mode & S_IXUSR) == 0) {
      throw std::runtime_error(
          "Staged Linux executable is missing or not executable.");
    }
    std::ofstream manifest(
        destination_path + "/.desktop_updater_release_manifest.json",
        std::ios::binary);
    manifest << EncodeCanonicalJson(descriptor.raw) << "\n";
    if (!manifest) {
      throw std::runtime_error("Unable to write release manifest.");
    }
  } catch (...) {
    try {
      RemoveStagingDirectory(destination_path);
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
    const std::string& diagnostics_log_path) {
  return native::ValidateInstallRequest(LinuxInstallRequest(
      staging_path, install_root, executable_relative_path,
      expected_package_id, removed_files, diagnostics_log_path));
}

native::InstallResult HandoffLinuxInstall(
    const std::string& staging_path,
    const std::string& install_root,
    const std::string& executable_relative_path,
    const std::string& expected_package_id,
    const std::vector<std::string>& removed_files,
    const std::string& diagnostics_log_path) {
  return native::ScheduleInstallAndRelaunch(LinuxInstallRequest(
      staging_path, install_root, executable_relative_path,
      expected_package_id, removed_files, diagnostics_log_path));
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
