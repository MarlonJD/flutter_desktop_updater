#ifndef DESKTOP_UPDATER_NATIVE_RUNTIME_INSTALL_TRANSACTION_H_
#define DESKTOP_UPDATER_NATIVE_RUNTIME_INSTALL_TRANSACTION_H_

#include <cstdint>
#include <string>

namespace desktop_updater {
namespace runtime {
namespace internal {

enum class InstallTransactionState {
  kNone,
  kPrepared,
  kBackupCreated,
  kTargetActivated,
  kCompleted,
};

struct InstallTransactionJournal {
  std::int64_t schema_version = 1;
  std::int64_t owner_pid = 0;
  std::string owner_process_start_token;
  std::string nonce;
  std::string package_id;
  std::string target;
  std::string prepared;
  std::string backup;
  std::string stage_provenance_sha256;
  InstallTransactionState state = InstallTransactionState::kPrepared;
};

struct InstallTransactionResult {
  bool ok = false;
  std::string error;
};

class InstallTransactionOperations {
 public:
  virtual ~InstallTransactionOperations() = default;

  // Implementations must create the journal atomically and durably. Returning
  // false means the journal already exists; all other failures throw.
  virtual bool CreateJournalExclusive(
      const std::string& path,
      const InstallTransactionJournal& journal) = 0;
  virtual InstallTransactionJournal ReadJournal(const std::string& path) = 0;
  virtual void PersistJournal(const std::string& path,
                              const InstallTransactionJournal& journal) = 0;
  virtual void RemoveJournal(const std::string& path) = 0;

  virtual bool PathExists(const std::string& path) = 0;
  // RenamePath and RemoveTree must durably sync the affected parent directory.
  virtual void RenamePath(const std::string& from, const std::string& to) = 0;
  virtual void RemoveTree(const std::string& path) = 0;
  virtual bool VerifyActivatedTarget(
      const InstallTransactionJournal& journal) = 0;
  virtual bool IsOwnerLive(std::int64_t pid,
                           const std::string& process_start_token) = 0;
  virtual void EmitDiagnostic(const std::string& event) = 0;
};

std::string InstallTransactionJournalPath(const std::string& target);
bool IsJournalOwnedPath(const InstallTransactionJournal& journal,
                        const std::string& path);

InstallTransactionResult AcquireInstallTransaction(
    const InstallTransactionJournal& journal,
    InstallTransactionOperations* operations);
InstallTransactionResult RunInstallTransaction(
    const std::string& target,
    const std::string& package_id,
    InstallTransactionOperations* operations);
InstallTransactionResult RecoverPendingInstall(
    const std::string& target,
    const std::string& package_id,
    InstallTransactionOperations* operations);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_RUNTIME_INSTALL_TRANSACTION_H_
