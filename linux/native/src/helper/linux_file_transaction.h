#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_FILE_TRANSACTION_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_FILE_TRANSACTION_H_

#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>

#include "linux_transaction_journal.h"

namespace desktop_updater::helper {

class LinuxFileTransactionError : public std::runtime_error {
 public:
  explicit LinuxFileTransactionError(const std::string& detail)
      : std::runtime_error(detail) {}
};

class LinuxInstallPayloadVerifier {
 public:
  virtual ~LinuxInstallPayloadVerifier() = default;
  virtual LinuxVerifiedPayloadIdentity Verify(int parent,
                                              const std::string& payload_leaf) = 0;
  virtual void FinalizeActivatedPayloadRoot(
      int,
      const std::string&,
      const LinuxFileIdentity&) {}
  virtual bool MatchesActivatedPayloadRoot(
      int parent,
      const std::string& leaf,
      const LinuxFileIdentity& staged_identity) {
    return LinuxRelativeExistsNoFollow(parent, leaf) &&
           ReadLinuxRelativeIdentity(parent, leaf) == staged_identity;
  }
};

enum class LinuxFileTransactionResult { kCompleted };

class LinuxFileTransaction {
 public:
  LinuxFileTransaction(
      const std::filesystem::path& target_path,
      const std::filesystem::path& stage_path,
      std::string transaction_id,
      pid_t owner_process_id,
      LinuxVerifiedPayloadIdentity expected_payload_identity,
      LinuxInstallPayloadVerifier& verifier,
      LinuxTransactionFaultInjector* fault_injector = nullptr);
  ~LinuxFileTransaction();

  LinuxFileTransaction(const LinuxFileTransaction&) = delete;
  LinuxFileTransaction& operator=(const LinuxFileTransaction&) = delete;

  std::string PrepareDurableJournal();
  void CancelPrepared();
  LinuxFileTransactionResult Execute();
  const LinuxTransactionPaths& paths() const { return paths_; }

 private:
  void ValidateParentLocator() const;
  void ValidateRelativeIdentity(const std::string& leaf,
                                const LinuxFileIdentity& expected,
                                const char* detail) const;
  void VerifyPayload(const std::string& leaf) const;

  std::filesystem::path parent_locator_;
  std::string stage_name_;
  LinuxTransactionPaths paths_;
  pid_t owner_process_id_;
  std::uint64_t owner_process_start_identity_;
  LinuxVerifiedPayloadIdentity expected_payload_identity_;
  LinuxInstallPayloadVerifier& verifier_;
  NoLinuxTransactionFaultInjector no_faults_;
  LinuxTransactionFaultInjector* fault_injector_;
  UniqueLinuxFd parent_;
  UniqueLinuxFd target_;
  UniqueLinuxFd stage_;
  UniqueLinuxFd lock_;
  LinuxMountGuard mount_guard_;
  std::optional<LinuxTransactionJournal> journal_;
  bool journal_persisted_ = false;
  bool execution_started_ = false;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_FILE_TRANSACTION_H_
