#ifndef DESKTOP_UPDATER_NATIVE_H_
#define DESKTOP_UPDATER_NATIVE_H_

#include <cstdint>
#include <string>
#include <vector>

namespace desktop_updater {
namespace native {

enum class LinuxInstallOperation {
  kRestart,
  kInstall,
};

enum class InstallTargetProofSource {
  kRunningExecutableContext,
  kSelfContainedFlutterBundle,
  kInstalledIdentityMarker,
};

struct InstallTargetProof {
  std::string canonical_root;
  std::string executable_relative_path;
  std::string package_id;
  InstallTargetProofSource source;
};

struct InstallProvenanceEntry {
  std::string path;
  std::string kind;
  std::int64_t length;
  std::string sha256;
  std::string target;
};

struct InstallRequest {
  LinuxInstallOperation operation;
  std::string staging_path;
  std::string install_root;
  std::string executable_relative_path;
  std::string package_id;
  std::vector<std::string> removed_files;
  std::string diagnostics_log_path;
  std::string expected_provenance_sha256;
  std::string provenance_nonce;
  std::vector<InstallProvenanceEntry> provenance_entries;
};

struct InstallResult {
  bool ok;
  std::string error;
};

InstallResult ValidateInstallRequest(const InstallRequest& request);
InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request);

}  // namespace native
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_H_
