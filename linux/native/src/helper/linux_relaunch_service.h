#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_RELAUNCH_SERVICE_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_RELAUNCH_SERVICE_H_

#include <filesystem>
#include <stdexcept>
#include <string>

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
  virtual void Launch(int executable_fd, const std::string& argv0) = 0;
};

class FexecveLinuxProcessLauncher final : public LinuxProcessLauncher {
 public:
  void Launch(int executable_fd, const std::string& argv0) override;
};

class LinuxRelaunchService {
 public:
  LinuxRelaunchService(
      LinuxVerifiedPayloadIdentity expected_payload_identity,
      LinuxInstallPayloadVerifier& verifier,
      LinuxProcessLauncher& launcher);

  void Relaunch(const std::filesystem::path& application_path);

 private:
  LinuxVerifiedPayloadIdentity expected_payload_identity_;
  LinuxInstallPayloadVerifier& verifier_;
  LinuxProcessLauncher& launcher_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_RELAUNCH_SERVICE_H_
