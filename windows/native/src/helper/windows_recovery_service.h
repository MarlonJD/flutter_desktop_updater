#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RECOVERY_SERVICE_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RECOVERY_SERVICE_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <string>

#include "windows_file_transaction.h"

namespace desktop_updater::helper {

enum class WindowsRecoveryOutcome {
  kRecovered,
  kNothingToRecover,
  kLiveOwner,
  kManualActionRequired,
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
      WindowsProcessLivenessChecker& liveness_checker);

  WindowsRecoveryOutcome Recover();

 private:
  WindowsRecoveryOutcome RecoverOwned(
      HANDLE parent,
      UniqueWindowsHandle& ownership_lock,
      DurableWindowsTransactionJournalStore& store,
      WindowsTransactionJournal journal);
  WindowsFileIdentity Identity(HANDLE parent,
                               const std::wstring& name) const;
  bool VerifyPayload(HANDLE parent, const std::wstring& name) const;
  void RecoveryRename(HANDLE parent,
                      const std::wstring& source,
                      const std::wstring& destination) const;

  std::filesystem::path target_path_;
  std::filesystem::path parent_path_;
  WindowsTransactionPaths paths_;
  WindowsVerifiedPayloadIdentity expected_payload_identity_;
  WindowsInstallPayloadVerifier& verifier_;
  WindowsProcessLivenessChecker& liveness_checker_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RECOVERY_SERVICE_H_
