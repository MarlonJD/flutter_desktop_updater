#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_RELAUNCH_SERVICE_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_RELAUNCH_SERVICE_H_

#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

#include "linux_file_transaction.h"

namespace desktop_updater::helper {

class LinuxRelaunchError : public std::runtime_error {
 public:
  explicit LinuxRelaunchError(const std::string& detail)
      : std::runtime_error(detail) {}
};

class FdRelativeLinuxPayloadVerifier final
    : public LinuxInstallPayloadVerifier {
 public:
  explicit FdRelativeLinuxPayloadVerifier(
      LinuxVerifiedPayloadIdentity expectation);

  LinuxVerifiedPayloadIdentity Verify(
      int parent,
      const std::string& payload_leaf) override;

 private:
  LinuxVerifiedPayloadIdentity expectation_;
};

class LinuxProcessLauncher {
 public:
  virtual ~LinuxProcessLauncher() = default;
  struct Identity {
    pid_t source_process_id = 0;
    std::uint64_t source_process_start_identity = 0;
    uid_t uid = 0;
    gid_t gid = 0;
    std::vector<gid_t> supplementary_groups;
    std::string home_directory;
    std::vector<std::string> sanitized_environment;
  };

  virtual void Launch(int executable_fd,
                      const std::string& argv0,
                      const Identity& identity) = 0;
};

class FexecveLinuxProcessLauncher final : public LinuxProcessLauncher {
 public:
  void Launch(int executable_fd,
              const std::string& argv0,
              const Identity& identity) override;
};

LinuxProcessLauncher::Identity CaptureLinuxRelaunchIdentity(
    pid_t process_id,
    std::uint64_t process_start_identity,
    uid_t uid,
    gid_t gid);

class LinuxRelaunchService {
 public:
  LinuxRelaunchService(
      LinuxVerifiedPayloadIdentity expected_payload_identity,
      LinuxInstallPayloadVerifier& verifier,
      LinuxProcessLauncher& launcher,
      LinuxProcessLauncher::Identity launch_identity);

  void Relaunch(const std::filesystem::path& application_path);

 private:
  LinuxVerifiedPayloadIdentity expected_payload_identity_;
  LinuxInstallPayloadVerifier& verifier_;
  LinuxProcessLauncher& launcher_;
  LinuxProcessLauncher::Identity launch_identity_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_RELAUNCH_SERVICE_H_
