#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_BOOTSTRAP_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_BOOTSTRAP_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

#include "helper_authenticode.h"
#include "helper_policy_windows.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

class WindowsHelperBootstrap {
 public:
  WindowsHelperBootstrap(WindowsHelperPolicy policy,
                         VerifiedWindowsExecutable helper_identity,
                         UniqueWindowsHandle helper_file,
                         UniqueWindowsHandle policy_file);

  const WindowsHelperPolicy& policy() const { return policy_; }
  const VerifiedWindowsExecutable& helper_identity() const {
    return helper_identity_;
  }

 private:
  WindowsHelperPolicy policy_;
  VerifiedWindowsExecutable helper_identity_;
  UniqueWindowsHandle helper_file_;
  UniqueWindowsHandle policy_file_;
};

WindowsHelperBootstrap LoadWindowsHelperBootstrap(DWORD caller_process_id);

std::string SecureWindowsReadyToken();
std::vector<std::uint8_t> WindowsHelperSha256Bytes(
    const std::string& bytes);
std::string WindowsHelperSha256Hex(const std::string& bytes);
std::int64_t WindowsHelperNowUnixMilliseconds();

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_BOOTSTRAP_H_
