#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_RECOVERY_HOST_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_RECOVERY_HOST_H_

#include <windows.h>
#include <taskschd.h>

#include <filesystem>
#include <stdexcept>
#include <string>

#include "windows_protected_helper_locator.h"

namespace desktop_updater::helper {

class WindowsRecoveryHostError : public std::runtime_error {
 public:
  explicit WindowsRecoveryHostError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct WindowsRecoveryHostTaskDefinition {
  std::string transaction_id;
  std::string recovery_ready_nonce;
  std::wstring task_path;
  std::wstring ready_event_name;
  std::filesystem::path executable_path;
  std::wstring arguments;
  std::wstring security_descriptor;
  std::wstring principal_user_id;
  TASK_LOGON_TYPE logon_type;
  TASK_RUNLEVEL_TYPE run_level;
  TASK_TRIGGER_TYPE2 trigger_type;
  LONG registration_flags;
  LONG run_flags;
};

WindowsRecoveryHostTaskDefinition BuildWindowsRecoveryHostTaskDefinition(
    const ProtectedWindowsHelperEndpointV1& endpoint,
    const std::string& transaction_id,
    const std::string& recovery_ready_nonce);

void SignalWindowsRecoveryHostReady(
    const WindowsRecoveryHostTaskDefinition& definition);

class WindowsRecoveryHostController {
 public:
  virtual ~WindowsRecoveryHostController() = default;
  virtual void ArmAndStart(
      const WindowsRecoveryHostTaskDefinition& definition,
      DWORD startup_timeout_milliseconds) = 0;
  virtual void Disarm(
      const WindowsRecoveryHostTaskDefinition& definition) = 0;
};

class TaskSchedulerWindowsRecoveryHostController final
    : public WindowsRecoveryHostController {
 public:
  void ArmAndStart(const WindowsRecoveryHostTaskDefinition& definition,
                   DWORD startup_timeout_milliseconds) override;
  void Disarm(
      const WindowsRecoveryHostTaskDefinition& definition) override;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_RECOVERY_HOST_H_
