#include "install_transaction.h"

#include <cctype>
#include <stdexcept>
#include <utility>

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

InstallTransactionResult Success() { return {true, std::string()}; }

InstallTransactionResult Failure(const std::string& error) {
  return {false, error};
}

std::size_t LastSeparator(const std::string& path) {
  const std::size_t slash = path.find_last_of('/');
  const std::size_t backslash = path.find_last_of('\\');
  if (slash == std::string::npos) return backslash;
  if (backslash == std::string::npos) return slash;
  return slash > backslash ? slash : backslash;
}

bool IsCanonicalAbsolute(const std::string& path) {
  if (path.empty()) return false;
  const bool unix_absolute = path.front() == '/';
  const bool windows_absolute =
      path.size() >= 3 && std::isalpha(static_cast<unsigned char>(path[0])) &&
      path[1] == ':' && (path[2] == '\\' || path[2] == '/');
  if (!unix_absolute && !windows_absolute) return false;
  if (path.size() > 1 && (path.back() == '/' || path.back() == '\\')) {
    return false;
  }
  std::size_t start = unix_absolute ? 1 : 3;
  while (start < path.size()) {
    const std::size_t end = path.find_first_of("/\\", start);
    const std::string part = path.substr(start, end - start);
    if (part.empty() || part == "." || part == "..") return false;
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return true;
}

bool IsLowercaseUuid(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-' || value[14] != '4' ||
      std::string("89ab").find(value[19]) == std::string::npos) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const unsigned char byte = static_cast<unsigned char>(value[index]);
    if (!std::isdigit(byte) && (byte < 'a' || byte > 'f')) return false;
  }
  return true;
}

bool IsLowercaseSha256(const std::string& value) {
  if (value.size() != 64) return false;
  for (unsigned char byte : value) {
    if (!std::isdigit(byte) && (byte < 'a' || byte > 'f')) return false;
  }
  return true;
}

std::string Parent(const std::string& path) {
  const std::size_t separator = LastSeparator(path);
  if (separator == std::string::npos) return std::string();
  if (separator == 0) return "/";
  return path.substr(0, separator);
}

std::string Name(const std::string& path) {
  const std::size_t separator = LastSeparator(path);
  return separator == std::string::npos ? path : path.substr(separator + 1);
}

std::string Sibling(const std::string& target, const std::string& name) {
  const std::string parent = Parent(target);
  const char separator = target.find('\\') == std::string::npos ? '/' : '\\';
  return parent == "/" ? parent + name : parent + separator + name;
}

bool ValidJournal(const InstallTransactionJournal& journal,
                  const std::string& target,
                  const std::string& package_id) {
  if (journal.schema_version != 1 || journal.owner_pid <= 0 ||
      journal.owner_process_start_token.empty() ||
      !IsLowercaseUuid(journal.nonce) || journal.package_id.empty() ||
      journal.package_id != package_id || journal.target != target ||
      !IsCanonicalAbsolute(journal.target) ||
      !IsCanonicalAbsolute(journal.prepared) ||
      !IsCanonicalAbsolute(journal.backup) ||
      !IsLowercaseSha256(journal.stage_provenance_sha256)) {
    return false;
  }
  const std::string target_name = Name(target);
  return journal.prepared ==
             Sibling(target, "." + target_name + ".prepared-" + journal.nonce) &&
         journal.backup ==
             Sibling(target, "." + target_name + ".backup-" + journal.nonce) &&
         journal.state != InstallTransactionState::kNone;
}

void RemoveIfPresent(const InstallTransactionJournal& journal,
                     const std::string& path,
                     InstallTransactionOperations* operations) {
  if (!IsJournalOwnedPath(journal, path)) {
    throw std::runtime_error("Refusing to remove a path absent from journal.");
  }
  if (operations->PathExists(path)) operations->RemoveTree(path);
}

void Persist(const std::string& path,
             InstallTransactionJournal* journal,
             InstallTransactionState state,
             InstallTransactionOperations* operations) {
  journal->state = state;
  operations->PersistJournal(path, *journal);
  operations->EmitDiagnostic("transaction journal persisted");
}

InstallTransactionResult RestoreBackup(
    const std::string& path,
    InstallTransactionJournal* journal,
    InstallTransactionOperations* operations) {
  if (operations->PathExists(journal->target)) {
    RemoveIfPresent(*journal, journal->target, operations);
  }
  if (!operations->PathExists(journal->backup)) {
    return Failure("Install transaction backup is missing.");
  }
  operations->RenamePath(journal->backup, journal->target);
  RemoveIfPresent(*journal, journal->prepared, operations);
  operations->RemoveJournal(path);
  operations->EmitDiagnostic("recovery restored backup");
  return Success();
}

}  // namespace

std::string InstallTransactionJournalPath(const std::string& target) {
  return Sibling(target,
                 "." + Name(target) + ".desktop_updater_transaction.json");
}

bool IsJournalOwnedPath(const InstallTransactionJournal& journal,
                        const std::string& path) {
  return path == journal.target || path == journal.prepared ||
         path == journal.backup;
}

InstallTransactionResult AcquireInstallTransaction(
    const InstallTransactionJournal& journal,
    InstallTransactionOperations* operations) {
  if (operations == nullptr ||
      !ValidJournal(journal, journal.target, journal.package_id)) {
    return Failure("Install transaction journal is invalid.");
  }
  if (!operations->PathExists(journal.target) ||
      !operations->PathExists(journal.prepared) ||
      operations->PathExists(journal.backup)) {
    return Failure("Install transaction paths are not ready.");
  }
  const std::string path = InstallTransactionJournalPath(journal.target);
  if (operations->CreateJournalExclusive(path, journal)) {
    operations->EmitDiagnostic("transaction lock acquired");
    operations->EmitDiagnostic("transaction journal persisted");
    return Success();
  }

  InstallTransactionJournal existing;
  try {
    existing = operations->ReadJournal(path);
  } catch (const std::exception&) {
    return Failure("Existing install transaction journal is unreadable.");
  }
  if (!ValidJournal(existing, journal.target, journal.package_id)) {
    return Failure("Existing install transaction journal is invalid.");
  }
  if (operations->IsOwnerLive(existing.owner_pid,
                              existing.owner_process_start_token)) {
    return Failure("Install transaction has a live owner.");
  }
  const InstallTransactionResult recovered =
      RecoverPendingInstall(journal.target, journal.package_id, operations);
  if (!recovered.ok) return recovered;
  if (!operations->PathExists(journal.prepared)) {
    return Failure("Prepared tree is missing after recovery.");
  }
  if (!operations->CreateJournalExclusive(path, journal)) {
    return Failure("Install transaction lock was concurrently acquired.");
  }
  operations->EmitDiagnostic("transaction lock acquired");
  operations->EmitDiagnostic("transaction journal persisted");
  return Success();
}

InstallTransactionResult RunInstallTransaction(
    const std::string& target,
    const std::string& package_id,
    InstallTransactionOperations* operations) {
  if (operations == nullptr) return Failure("Transaction operations are required.");
  const std::string path = InstallTransactionJournalPath(target);
  InstallTransactionJournal journal = operations->ReadJournal(path);
  if (!ValidJournal(journal, target, package_id) ||
      journal.state != InstallTransactionState::kPrepared) {
    return Failure("Prepared install transaction journal is invalid.");
  }
  if (!operations->PathExists(journal.target) ||
      !operations->PathExists(journal.prepared) ||
      operations->PathExists(journal.backup)) {
    return Failure("Prepared install transaction paths changed.");
  }

  Persist(path, &journal, InstallTransactionState::kBackupCreated, operations);
  operations->RenamePath(journal.target, journal.backup);
  Persist(path, &journal, InstallTransactionState::kTargetActivated, operations);
  operations->RenamePath(journal.prepared, journal.target);
  if (!operations->VerifyActivatedTarget(journal)) {
    return RestoreBackup(path, &journal, operations);
  }
  Persist(path, &journal, InstallTransactionState::kCompleted, operations);
  RemoveIfPresent(journal, journal.backup, operations);
  operations->RemoveJournal(path);
  return Success();
}

InstallTransactionResult RecoverPendingInstall(
    const std::string& target,
    const std::string& package_id,
    InstallTransactionOperations* operations) {
  if (operations == nullptr) return Failure("Transaction operations are required.");
  const std::string path = InstallTransactionJournalPath(target);
  InstallTransactionJournal journal;
  try {
    journal = operations->ReadJournal(path);
  } catch (const std::out_of_range&) {
    return Success();
  } catch (const std::exception&) {
    return Failure("Install transaction journal is unreadable.");
  }
  if (!ValidJournal(journal, target, package_id)) {
    return Failure("Install transaction journal identity or paths are invalid.");
  }
  operations->EmitDiagnostic("recovery detected");

  const bool target_exists = operations->PathExists(journal.target);
  const bool prepared_exists = operations->PathExists(journal.prepared);
  const bool backup_exists = operations->PathExists(journal.backup);
  switch (journal.state) {
    case InstallTransactionState::kPrepared:
      if (!target_exists || backup_exists) {
        return Failure("Prepared transaction has inconsistent paths.");
      }
      RemoveIfPresent(journal, journal.prepared, operations);
      operations->RemoveJournal(path);
      return Success();
    case InstallTransactionState::kBackupCreated:
      if (target_exists && !backup_exists) {
        RemoveIfPresent(journal, journal.prepared, operations);
        operations->RemoveJournal(path);
        return Success();
      }
      if (!target_exists && backup_exists) {
        return RestoreBackup(path, &journal, operations);
      }
      return Failure("Backup-created transaction has inconsistent paths.");
    case InstallTransactionState::kTargetActivated:
      if (!target_exists && backup_exists) {
        return RestoreBackup(path, &journal, operations);
      }
      if (target_exists && backup_exists) {
        if (!operations->VerifyActivatedTarget(journal)) {
          return RestoreBackup(path, &journal, operations);
        }
        RemoveIfPresent(journal, journal.backup, operations);
        RemoveIfPresent(journal, journal.prepared, operations);
        operations->RemoveJournal(path);
        operations->EmitDiagnostic("recovery completed activation");
        return Success();
      }
      if (target_exists && !backup_exists && !prepared_exists &&
          operations->VerifyActivatedTarget(journal)) {
        operations->RemoveJournal(path);
        operations->EmitDiagnostic("recovery completed activation");
        return Success();
      }
      return Failure("Target-activated transaction has inconsistent paths.");
    case InstallTransactionState::kCompleted:
      if (!target_exists || !operations->VerifyActivatedTarget(journal)) {
        if (backup_exists) return RestoreBackup(path, &journal, operations);
        return Failure("Completed transaction target is invalid.");
      }
      RemoveIfPresent(journal, journal.backup, operations);
      RemoveIfPresent(journal, journal.prepared, operations);
      operations->RemoveJournal(path);
      operations->EmitDiagnostic("recovery completed activation");
      return Success();
    case InstallTransactionState::kNone:
      return Failure("Install transaction state is invalid.");
  }
  return Failure("Install transaction state is invalid.");
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
