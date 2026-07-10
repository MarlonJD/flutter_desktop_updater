#include "install_transaction_tests.h"

#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#include "install_transaction.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

class FakeOperations final : public InstallTransactionOperations {
 public:
  bool CreateJournalExclusive(const std::string& path,
                              const InstallTransactionJournal& journal) override {
    if (journals.count(path) != 0) return false;
    journals[path] = journal;
    persisted_states.push_back(journal.state);
    return true;
  }

  InstallTransactionJournal ReadJournal(const std::string& path) override {
    return journals.at(path);
  }

  void PersistJournal(const std::string& path,
                      const InstallTransactionJournal& journal) override {
    journals.at(path) = journal;
    persisted_states.push_back(journal.state);
    if (interrupt_after == journal.state) {
      throw std::runtime_error("injected abrupt termination");
    }
  }

  void RemoveJournal(const std::string& path) override { journals.erase(path); }
  bool PathExists(const std::string& path) override {
    return paths.count(path) != 0;
  }
  void RenamePath(const std::string& from, const std::string& to) override {
    Require(paths.erase(from) == 1, "rename source is missing");
    Require(paths.count(to) == 0, "rename destination already exists");
    paths.insert(to);
  }
  void RemoveTree(const std::string& path) override {
    removed_paths.push_back(path);
    paths.erase(path);
  }
  bool VerifyActivatedTarget(const InstallTransactionJournal&) override {
    return activated_target_valid;
  }
  bool IsOwnerLive(std::int64_t pid,
                   const std::string& process_start_token) override {
    return live_owners.count(std::make_pair(pid, process_start_token)) != 0;
  }
  void EmitDiagnostic(const std::string& event) override {
    diagnostics.push_back(event);
  }

  std::map<std::string, InstallTransactionJournal> journals;
  std::set<std::string> paths;
  std::set<std::pair<std::int64_t, std::string>> live_owners;
  std::vector<std::string> removed_paths;
  std::vector<std::string> diagnostics;
  std::vector<InstallTransactionState> persisted_states;
  InstallTransactionState interrupt_after = InstallTransactionState::kNone;
  bool activated_target_valid = true;
};

InstallTransactionJournal Journal() {
  InstallTransactionJournal journal;
  journal.schema_version = 1;
  journal.owner_pid = 42;
  journal.owner_process_start_token = "boot-a:100";
  journal.nonce = "123e4567-e89b-42d3-a456-426614174000";
  journal.package_id = "com.example.app";
  journal.target = "/Applications/Example";
  journal.prepared = "/Applications/.Example.prepared-123e4567-e89b-42d3-a456-426614174000";
  journal.backup = "/Applications/.Example.backup-123e4567-e89b-42d3-a456-426614174000";
  journal.stage_provenance_sha256 = std::string(64, 'a');
  journal.state = InstallTransactionState::kPrepared;
  return journal;
}

void LiveOwnerExcludesSecondHelperAndPidReuseDoesNot() {
  FakeOperations operations;
  const InstallTransactionJournal journal = Journal();
  operations.paths = {journal.target, journal.prepared};
  const std::string path = InstallTransactionJournalPath(journal.target);
  Require(AcquireInstallTransaction(journal, &operations).ok,
          "first transaction did not acquire lock");
  operations.live_owners.insert(
      std::make_pair(journal.owner_pid, journal.owner_process_start_token));
  const InstallTransactionResult live =
      AcquireInstallTransaction(journal, &operations);
  Require(!live.ok && live.error.find("live owner") != std::string::npos,
          "live owner did not exclude a second helper");

  operations.live_owners.clear();
  InstallTransactionJournal next = journal;
  next.owner_process_start_token = "boot-a:200";
  next.nonce = "223e4567-e89b-42d3-a456-426614174000";
  next.prepared =
      "/Applications/.Example.prepared-223e4567-e89b-42d3-a456-426614174000";
  next.backup =
      "/Applications/.Example.backup-223e4567-e89b-42d3-a456-426614174000";
  operations.paths.insert(next.prepared);
  Require(AcquireInstallTransaction(next, &operations).ok,
          "dead owner with reused PID did not recover and acquire");
  Require(operations.journals.at(path).owner_process_start_token ==
              next.owner_process_start_token,
          "new owner identity was not persisted");
}

void AbruptTerminationAfterEveryStateRecoversDeterministically() {
  for (InstallTransactionState interruption : {
           InstallTransactionState::kBackupCreated,
           InstallTransactionState::kTargetActivated,
           InstallTransactionState::kCompleted,
       }) {
    FakeOperations operations;
    const InstallTransactionJournal journal = Journal();
    operations.paths = {journal.target, journal.prepared};
    Require(AcquireInstallTransaction(journal, &operations).ok,
            "transaction did not acquire lock");
    operations.interrupt_after = interruption;
    try {
      RunInstallTransaction(journal.target, journal.package_id, &operations);
    } catch (const std::runtime_error&) {
    }
    operations.interrupt_after = InstallTransactionState::kNone;
    const InstallTransactionResult recovered =
        RecoverPendingInstall(journal.target, journal.package_id, &operations);
    Require(recovered.ok, "interrupted state did not recover");
    Require(operations.paths.count(journal.target) == 1,
            "recovery did not leave an installed target");
    Require(operations.paths.count(journal.prepared) == 0,
            "recovery left the prepared tree behind");
    Require(operations.paths.count(journal.backup) == 0,
            "recovery left the backup tree behind");
    Require(operations.journals.empty(), "recovery left the journal behind");
  }
}

void MissingPreparedAfterBackupRestoresBackupWithoutUnboundedDeletion() {
  FakeOperations operations;
  InstallTransactionJournal journal = Journal();
  journal.state = InstallTransactionState::kTargetActivated;
  operations.journals[InstallTransactionJournalPath(journal.target)] = journal;
  operations.paths = {journal.backup};

  const InstallTransactionResult recovered =
      RecoverPendingInstall(journal.target, journal.package_id, &operations);
  Require(recovered.ok, "missing prepared tree did not restore backup");
  Require(operations.paths.count(journal.target) == 1,
          "backup was not restored to target");
  for (const std::string& removed : operations.removed_paths) {
    Require(IsJournalOwnedPath(journal, removed),
            "recovery deleted a path absent from the journal");
  }
}

void InvalidActivatedTargetRollsBack() {
  FakeOperations operations;
  InstallTransactionJournal journal = Journal();
  journal.state = InstallTransactionState::kTargetActivated;
  operations.journals[InstallTransactionJournalPath(journal.target)] = journal;
  operations.paths = {journal.target, journal.backup};
  operations.activated_target_valid = false;

  const InstallTransactionResult recovered =
      RecoverPendingInstall(journal.target, journal.package_id, &operations);
  Require(recovered.ok, "invalid activation did not recover");
  Require(operations.paths.count(journal.target) == 1,
          "rollback did not restore backup");
  Require(operations.paths.count(journal.backup) == 0,
          "rollback retained backup alias");
  Require(!operations.removed_paths.empty() &&
              operations.removed_paths.front() == journal.target,
          "invalid activated target was not removed before restore");
}

void ForgedJournalPathsFailClosedWithoutMutation() {
  FakeOperations operations;
  InstallTransactionJournal journal = Journal();
  journal.backup = "/Users/outside";
  operations.journals[InstallTransactionJournalPath(journal.target)] = journal;
  operations.paths = {journal.target, journal.prepared, journal.backup};
  const std::set<std::string> before = operations.paths;

  const InstallTransactionResult recovered =
      RecoverPendingInstall(journal.target, journal.package_id, &operations);
  Require(!recovered.ok, "forged journal path was accepted");
  Require(operations.paths == before && operations.removed_paths.empty(),
          "forged journal mutated filesystem state");
}

}  // namespace

void RunInstallTransactionTests() {
  LiveOwnerExcludesSecondHelperAndPidReuseDoesNot();
  AbruptTerminationAfterEveryStateRecoversDeterministically();
  MissingPreparedAfterBackupRestoresBackupWithoutUnboundedDeletion();
  InvalidActivatedTargetRollsBack();
  ForgedJournalPathsFailClosedWithoutMutation();
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
