#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RELAUNCH_SERVICE_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RELAUNCH_SERVICE_H_

#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

#include "windows_file_transaction.h"

namespace desktop_updater::helper {

class WindowsRelaunchError : public std::runtime_error {
 public:
  explicit WindowsRelaunchError(const std::string& detail)
      : std::runtime_error(detail) {}
};

class AuthenticodeWindowsPayloadVerifier final
    : public WindowsInstallPayloadVerifier {
 public:
  explicit AuthenticodeWindowsPayloadVerifier(
      WindowsVerifiedPayloadIdentity expectation);

  WindowsVerifiedPayloadIdentity Verify(
      HANDLE parent,
      const std::wstring& bundle_leaf) override;

 private:
  WindowsVerifiedPayloadIdentity expectation_;
  std::vector<UniqueWindowsHandle> retained_stage_handles_;
};

class WindowsProcessLauncher {
 public:
  virtual ~WindowsProcessLauncher() = default;
  virtual void Launch(const std::filesystem::path& executable) = 0;
};

class CreateProcessWindowsLauncher final : public WindowsProcessLauncher {
 public:
  void Launch(const std::filesystem::path& executable) override;
};

// Captures the exact authenticated app token before the app exits so the
// elevated helper never relaunches the updated app with its own admin token.
class CallerTokenWindowsLauncher final : public WindowsProcessLauncher {
 public:
  explicit CallerTokenWindowsLauncher(HANDLE caller_process);
  void Launch(const std::filesystem::path& executable) override;

 private:
  UniqueWindowsHandle caller_primary_token_;
};

class WindowsRelaunchService {
 public:
  WindowsRelaunchService(
      WindowsVerifiedPayloadIdentity expected_payload_identity,
      WindowsInstallPayloadVerifier& verifier,
      WindowsProcessLauncher& launcher);

  void Relaunch(const std::filesystem::path& application_path);

 private:
  WindowsVerifiedPayloadIdentity expected_payload_identity_;
  WindowsInstallPayloadVerifier& verifier_;
  WindowsProcessLauncher& launcher_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RELAUNCH_SERVICE_H_
