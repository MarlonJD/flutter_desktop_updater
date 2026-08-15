#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_BOOTSTRAP_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_BOOTSTRAP_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

#include "helper_authenticode.h"
#include "helper_policy_windows.h"
#include "windows_protected_helper_locator.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

class WindowsHelperBootstrap {
 public:
  WindowsHelperBootstrap(WindowsHelperPolicy policy,
                         VerifiedWindowsExecutable helper_identity,
                         ProtectedWindowsHelperEndpointV1 endpoint,
                         UniqueWindowsHandle helper_file,
                         UniqueWindowsHandle policy_file);

  const WindowsHelperPolicy& policy() const { return policy_; }
  const VerifiedWindowsExecutable& helper_identity() const {
    return helper_identity_;
  }
  const ProtectedWindowsHelperEndpointV1& endpoint() const {
    return endpoint_;
  }

 private:
  WindowsHelperPolicy policy_;
  VerifiedWindowsExecutable helper_identity_;
  ProtectedWindowsHelperEndpointV1 endpoint_;
  UniqueWindowsHandle helper_file_;
  UniqueWindowsHandle policy_file_;
};

class PortableWindowsHelperBootstrap {
 public:
  PortableWindowsHelperBootstrap(WindowsHelperPolicy policy,
                                 VerifiedWindowsExecutable helper_identity,
                                 UniqueWindowsHandle helper_file,
                                 UniqueWindowsHandle policy_file);

  const WindowsHelperPolicy& policy() const { return policy_; }
  const VerifiedWindowsExecutable& helper_identity() const {
    return helper_identity_;
  }
  HANDLE helper_file() const { return helper_file_.get(); }
  HANDLE policy_file() const { return policy_file_.get(); }

  // The helper executable and policy are retained while the authenticated
  // session runs. Release those read handles before the portable target is
  // renamed so the target directory has no self-held mutation blockers.
  void ReleaseRetainedHandles() noexcept {
    helper_file_.reset();
    policy_file_.reset();
  }

 private:
  WindowsHelperPolicy policy_;
  VerifiedWindowsExecutable helper_identity_;
  UniqueWindowsHandle helper_file_;
  UniqueWindowsHandle policy_file_;
};

WindowsHelperBootstrap LoadWindowsHelperBootstrap(DWORD caller_process_id);
WindowsHelperBootstrap LoadWindowsHelperBootstrapForRegistration();
WindowsHelperBootstrap LoadWindowsHelperBootstrapForAutonomousRecovery(
    const std::string& transaction_id);
PortableWindowsHelperBootstrap LoadPortableWindowsHelperBootstrap(
    DWORD caller_process_id);

std::string SecureWindowsReadyToken();
std::vector<std::uint8_t> WindowsHelperSha256Bytes(
    const std::string& bytes);
std::string WindowsHelperSha256Hex(const std::string& bytes);
std::int64_t WindowsHelperNowUnixMilliseconds();

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_BOOTSTRAP_H_
