#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_FILE_TRANSACTION_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_FILE_TRANSACTION_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

class WindowsFileTransactionError : public std::runtime_error {
 public:
  enum class Code {
    kInvalidPathOrTransaction,
    kTargetParentChanged,
    kStageIdentityChanged,
    kStagePayloadChanged,
    kTargetIdentityChanged,
    kCrossVolumeStage,
    kDerivedArtifactAlreadyExists,
    kSharingViolation,
    kFilesystemOperationFailed,
    kInjectedFailure,
  };

  WindowsFileTransactionError(Code code, const std::string& detail)
      : std::runtime_error(detail), code_(code) {}
  Code code() const noexcept { return code_; }

 private:
  Code code_;
};

class WindowsInstallPayloadVerifier {
 public:
  virtual ~WindowsInstallPayloadVerifier() = default;
  virtual WindowsVerifiedPayloadIdentity Verify(
      HANDLE parent,
      const std::wstring& bundle_leaf) = 0;
  // Verification may retain handles while the payload identity is being
  // checked. The transaction releases those handles immediately before a
  // directory rename so security-filtered files can be moved atomically.
  virtual void ReleaseRetainedHandles() noexcept {}
};

enum class WindowsFileTransactionResult {
  kCompleted,
};

struct WindowsTransactionTerminalCallbacks {
  std::function<void()> before_completed_lock_release;
  std::function<void()> after_completed_lock_release;
  std::function<void()> before_rollback_lock_release;
  std::function<void()> after_rollback_lock_release;
};

class WindowsFileTransaction {
 public:
  WindowsFileTransaction(
      const std::filesystem::path& target_path,
      const std::filesystem::path& stage_path,
      std::string transaction_id,
      DWORD owner_process_id,
      WindowsVerifiedPayloadIdentity expected_payload_identity,
      WindowsInstallPayloadVerifier& verifier,
      WindowsTransactionFaultInjector* fault_injector = nullptr,
      WindowsTransactionTerminalCallbacks terminal_callbacks = {},
      std::optional<std::uint64_t> retained_owner_start_identity =
          std::nullopt,
      std::function<void(HANDLE)> durability_barrier = {},
      std::function<void()> before_stage_rename = {});
  WindowsFileTransaction(
      const std::filesystem::path& target_path,
      const std::filesystem::path& stage_path,
      std::string transaction_id,
      DWORD owner_process_id,
      WindowsVerifiedPayloadIdentity expected_payload_identity,
      WindowsInstallPayloadVerifier& verifier,
      HANDLE pinned_parent,
      HANDLE pinned_stage,
      WindowsTransactionFaultInjector* fault_injector = nullptr,
      WindowsTransactionTerminalCallbacks terminal_callbacks = {},
      std::optional<std::uint64_t> retained_owner_start_identity =
          std::nullopt,
      std::function<void(HANDLE)> durability_barrier = {},
      std::function<void()> before_stage_rename = {});
  ~WindowsFileTransaction();
  WindowsFileTransaction(const WindowsFileTransaction&) = delete;
  WindowsFileTransaction& operator=(const WindowsFileTransaction&) = delete;

  const WindowsTransactionPaths& paths() const { return paths_; }
  std::string initial_journal_canonical() const;
  void Prepare();
  bool prepared() const { return prepared_; }
  std::string prepared_journal_canonical() const;
  void MarkCommitAccepted();
  WindowsFileTransactionResult ExecutePrepared();
  void CancelPrepared();
  WindowsFileTransactionResult Execute();

  static void ValidateSameVolume(std::uint64_t target_volume,
                                 std::uint64_t stage_volume);

 private:
  void ValidateParentLocator() const;
  void ValidateStageParentLocator() const;
  void ReopenTargetForMutation();
  void ValidateIdentity(HANDLE parent,
                        const std::wstring& name,
                        const WindowsFileIdentity& expected,
                        WindowsFileTransactionError::Code error) const;
  void ValidatePayload(HANDLE parent, const std::wstring& name) const;
  void DurableRename(HANDLE source,
                     const std::wstring& destination,
                     WindowsTransactionFaultPoint before,
                     WindowsTransactionFaultPoint before_directory_flush,
                     WindowsTransactionFaultPoint after);
  void ReleaseLockExact();
  void RemoveLockExactNoThrow() noexcept;
  void FlushMetadata(HANDLE directory) const;

  std::filesystem::path parent_locator_;
  std::filesystem::path stage_parent_locator_;
  std::wstring stage_name_;
  WindowsTransactionPaths paths_;
  DWORD owner_process_id_;
  std::uint64_t owner_process_start_identity_;
  WindowsVerifiedPayloadIdentity expected_payload_identity_;
  WindowsInstallPayloadVerifier& verifier_;
  NoWindowsTransactionFaultInjector no_faults_;
  WindowsTransactionFaultInjector* fault_injector_;
  WindowsTransactionTerminalCallbacks terminal_callbacks_;
  std::function<void(HANDLE)> durability_barrier_;
  std::function<void()> before_stage_rename_;
  UniqueWindowsHandle parent_;
  UniqueWindowsHandle stage_parent_;
  UniqueWindowsHandle target_;
  UniqueWindowsHandle stage_;
  UniqueWindowsHandle lock_;
  WindowsFileIdentity parent_identity_;
  WindowsFileIdentity stage_parent_identity_;
  WindowsFileIdentity target_identity_;
  WindowsFileIdentity stage_identity_;
  std::unique_ptr<DurableWindowsTransactionJournalStore> journal_store_;
  WindowsTransactionJournal journal_;
  bool prepared_ = false;
  bool cancelled_ = false;
  bool journal_persisted_ = false;
  bool commit_accepted_ = false;
  bool completed_ = false;
};

std::vector<std::wstring> FindWindowsTransactionArtifacts(
    const std::filesystem::path& parent);

std::uint64_t WindowsProcessStartIdentity(DWORD process_id);
std::uint64_t WindowsProcessStartIdentity(HANDLE process);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_FILE_TRANSACTION_H_
