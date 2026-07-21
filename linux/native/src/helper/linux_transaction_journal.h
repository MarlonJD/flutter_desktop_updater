#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_TRANSACTION_JOURNAL_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_TRANSACTION_JOURNAL_H_

#include <sys/types.h>

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "linux_mount_guard.h"

namespace desktop_updater::helper {

enum class LinuxTransactionState {
  kPrepared,
  kBackupCreated,
  kTargetActivated,
  kCompleted,
  kManualActionRequired,
};

enum class LinuxTransactionFaultPoint {
  kBeforePreparedJournalFlush,
  kAfterPreparedJournalFlush,
  kBeforeStageRename,
  kAfterStageRenameBeforeDirectoryFlush,
  kAfterStageRename,
  kBeforeBackupRename,
  kAfterBackupRenameBeforeDirectoryFlush,
  kAfterBackupRename,
  kBeforeBackupCreatedJournalFlush,
  kAfterBackupCreatedJournalFlush,
  kBeforeActivationRename,
  kAfterActivationRenameBeforeDirectoryFlush,
  kAfterActivationRename,
  kBeforeTargetActivatedJournalFlush,
  kAfterTargetActivatedJournalFlush,
  kBeforeCompletedJournalFlush,
  kAfterCompletedJournalFlush,
  kDiskFull,
  kShortJournalWrite,
  kFileFsyncFailure,
  kDirectoryFsyncFailure,
};

std::vector<LinuxTransactionFaultPoint> LinuxTransactionCrashInjectionPoints();

class LinuxTransactionFaultInjector {
 public:
  virtual ~LinuxTransactionFaultInjector() = default;
  virtual void Hit(LinuxTransactionFaultPoint point) = 0;
};

class NoLinuxTransactionFaultInjector final
    : public LinuxTransactionFaultInjector {
 public:
  void Hit(LinuxTransactionFaultPoint) override {}
};

class LinuxTransactionJournalError : public std::runtime_error {
 public:
  explicit LinuxTransactionJournalError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct LinuxVerifiedPayloadIdentity {
  std::string package_id;
  std::string signer_identity;
  std::string package_identity_sha256;
  std::string stage_provenance_sha256;
  std::string artifact_sha256;
  std::string executable_relative_path;
  std::string executable_sha256;
  std::uint32_t executable_mode = 0;
  std::uint32_t executable_uid = 0;
  std::uint32_t executable_gid = 0;

  bool operator==(const LinuxVerifiedPayloadIdentity& other) const;
  bool operator!=(const LinuxVerifiedPayloadIdentity& other) const {
    return !(*this == other);
  }
};

struct LinuxTransactionPaths {
  std::string target_name;
  std::string transaction_id;
  std::string prepared_name;
  std::string backup_name;
  std::string journal_name;
  std::string journal_next_name;
  std::string lock_name;
  std::string recovery_lock_name;

  static LinuxTransactionPaths Create(const std::string& target_name,
                                      const std::string& transaction_id);
};

struct LinuxTransactionLockRecord {
  std::string transaction_id;
  pid_t owner_process_id = 0;
  std::uint64_t owner_process_start_identity = 0;

  std::string EncodeCanonical() const;
  static LinuxTransactionLockRecord DecodeStrict(const std::string& json);
};

struct LinuxTransactionJournal {
  static constexpr std::int64_t kSchemaVersion = 2;

  std::int64_t schema_version = kSchemaVersion;
  std::string transaction_id;
  pid_t owner_process_id = 0;
  std::uint64_t owner_process_start_identity = 0;
  std::string target_name;
  std::string original_stage_name;
  std::string prepared_name;
  std::string backup_name;
  std::string lock_name;
  LinuxFileIdentity parent_identity;
  LinuxFileIdentity target_identity;
  LinuxFileIdentity stage_identity;
  LinuxVerifiedPayloadIdentity expected_payload_identity;
  LinuxTransactionState state = LinuxTransactionState::kPrepared;

  std::string EncodeCanonical() const;
  static LinuxTransactionJournal DecodeStrict(const std::string& json);
};

void RenameLinuxRelative(int parent,
                         const std::string& source,
                         const std::string& destination,
                         bool replace_existing);
void RemoveLinuxTreeExact(int parent,
                          const std::string& leaf,
                          const LinuxFileIdentity& expected_identity);
void SyncLinuxDirectory(int parent);
std::string ReadLinuxRelativeUtf8(int parent,
                                 const std::string& leaf,
                                 std::size_t maximum_bytes);

class DurableLinuxTransactionJournalStore {
 public:
  DurableLinuxTransactionJournalStore(
      int parent,
      LinuxTransactionPaths paths,
      LinuxTransactionFaultInjector* fault_injector = nullptr);

  std::optional<LinuxTransactionJournal> Load() const;
  bool HasAmbiguousNext() const;
  void Persist(const LinuxTransactionJournal& journal);
  void Remove();

 private:
  std::pair<LinuxTransactionFaultPoint, LinuxTransactionFaultPoint>
  FaultPoints(LinuxTransactionState state) const;

  int parent_;
  LinuxTransactionPaths paths_;
  NoLinuxTransactionFaultInjector no_faults_;
  LinuxTransactionFaultInjector* fault_injector_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_TRANSACTION_JOURNAL_H_
