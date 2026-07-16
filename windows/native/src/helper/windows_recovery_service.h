#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RECOVERY_SERVICE_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RECOVERY_SERVICE_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>

#include "windows_file_transaction.h"

namespace desktop_updater::helper {

enum class WindowsRecoveryOutcome {
  kRecovered,
  kRolledBack,
  kNothingToRecover,
  kLiveOwner,
  kManualActionRequired,
};

enum class WindowsRecoveryIntent {
  kCompleteCommitted,
  kRollBackUncommitted,
};

class WindowsProcessLivenessChecker {
 public:
  virtual ~WindowsProcessLivenessChecker() = default;
  virtual bool IsSameProcessAlive(DWORD process_id,
                                  std::uint64_t start_identity) = 0;
};

class Win32ProcessLivenessChecker final : public WindowsProcessLivenessChecker {
 public:
  bool IsSameProcessAlive(DWORD process_id,
                          std::uint64_t start_identity) override;
};

class WindowsRecoveryService {
 public:
  WindowsRecoveryService(
      const std::filesystem::path& target_path,
      std::string transaction_id,
      WindowsVerifiedPayloadIdentity expected_payload_identity,
      WindowsInstallPayloadVerifier& verifier,
      WindowsProcessLivenessChecker& liveness_checker,
      WindowsRecoveryIntent intent = WindowsRecoveryIntent::kCompleteCommitted,
      std::function<void(WindowsRecoveryOutcome)> before_lock_release = {},
      std::function<void(WindowsRecoveryOutcome)> after_lock_release = {},
      std::function<void()> after_lock_acquired = {},
      bool require_volume_barrier = false);

  WindowsRecoveryOutcome Recover();

 private:
  WindowsRecoveryOutcome RecoverOwned(
      HANDLE parent,
      UniqueWindowsHandle& ownership_lock,
      DurableWindowsTransactionJournalStore& store,
      WindowsTransactionJournal journal);
  WindowsRecoveryOutcome RollBackOwned(
      HANDLE parent,
      UniqueWindowsHandle& ownership_lock,
      DurableWindowsTransactionJournalStore& store,
      const WindowsTransactionJournal& journal);
  WindowsFileIdentity Identity(HANDLE parent,
                               const std::wstring& name) const;
  bool VerifyPayload(HANDLE parent, const std::wstring& name) const;
  void RecoveryRename(HANDLE parent,
                      const std::wstring& source,
                      const std::wstring& destination) const;
  void FlushMetadata(HANDLE directory) const;

  std::filesystem::path target_path_;
  std::filesystem::path parent_path_;
  WindowsTransactionPaths paths_;
  WindowsVerifiedPayloadIdentity expected_payload_identity_;
  WindowsInstallPayloadVerifier& verifier_;
  WindowsProcessLivenessChecker& liveness_checker_;
  WindowsRecoveryIntent intent_;
  std::function<void(WindowsRecoveryOutcome)> before_lock_release_;
  std::function<void(WindowsRecoveryOutcome)> after_lock_release_;
  std::function<void()> after_lock_acquired_;
  bool require_volume_barrier_ = false;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RECOVERY_SERVICE_H_
