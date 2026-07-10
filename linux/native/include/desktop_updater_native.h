#ifndef DESKTOP_UPDATER_NATIVE_H_
#define DESKTOP_UPDATER_NATIVE_H_

#include <string>
#include <vector>

namespace desktop_updater {
namespace native {

enum class LinuxInstallOperation {
  kRestart,
  kInstall,
};

struct InstallRequest {
  LinuxInstallOperation operation;
  std::string staging_path;
  std::string install_root;
  std::string executable_relative_path;
  std::string package_id;
  std::vector<std::string> removed_files;
  std::string diagnostics_log_path;
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
