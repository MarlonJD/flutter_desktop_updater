#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "linux_recovery_service.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#include <utility>

#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

constexpr char manualActionRequired[] = "manualActionRequired";
constexpr char liveOwner[] = "liveOwner";

bool Matches(int parent,
             const std::string& leaf,
             const LinuxFileIdentity& identity) {
  return LinuxRelativeExistsNoFollow(parent, leaf) &&
         ReadLinuxRelativeIdentity(parent, leaf) == identity;
}

bool CompatibleObservation(const LinuxTransactionJournal& journal,
                           bool target_exists,
                           bool stage_exists,
                           bool prepared_exists,
                           bool backup_exists) {
  switch (journal.state) {
    case LinuxTransactionState::kPrepared:
      return (target_exists && stage_exists && !prepared_exists &&
              !backup_exists) ||
             (target_exists && !stage_exists && prepared_exists &&
              !backup_exists) ||
             (!target_exists && !stage_exists && prepared_exists &&
              backup_exists);
    case LinuxTransactionState::kBackupCreated:
      return (!target_exists && !stage_exists && prepared_exists &&
              backup_exists) ||
             (target_exists && !stage_exists && !prepared_exists &&
              backup_exists);
    case LinuxTransactionState::kTargetActivated:
      return target_exists && !stage_exists && !prepared_exists &&
             backup_exists;
    case LinuxTransactionState::kCompleted:
      return target_exists && !stage_exists && !prepared_exists;
    case LinuxTransactionState::kManualActionRequired:
      return false;
  }
  return false;
}

}  // namespace

bool PidfdLinuxProcessLivenessChecker::IsSameProcessAlive(
    pid_t process_id,
    std::uint64_t process_start_identity) {
  const int pidfd = static_cast<int>(
      syscall(SYS_pidfd_open, process_id, static_cast<unsigned int>(0)));
  if (pidfd >= 0) {
    UniqueLinuxFd retained(pidfd);
    pollfd descriptor{pidfd, POLLIN, 0};
    const int observed = poll(&descriptor, 1, 0);
    if (observed < 0) return false;
    if (observed > 0 && (descriptor.revents & POLLIN) != 0) return false;
    try {
      return LinuxProcessStartIdentity(process_id) ==
             process_start_identity;
    } catch (const std::exception&) {
      return false;
    }
  }
  if (errno == ESRCH) return false;
  try {
    return LinuxProcessStartIdentity(process_id) == process_start_identity;
  } catch (const std::exception&) {
    return false;
  }
}

LinuxRecoveryService::LinuxRecoveryService(
    const std::filesystem::path& target_path,
    std::string transaction_id,
    LinuxVerifiedPayloadIdentity expected_payload_identity,
    LinuxInstallPayloadVerifier& verifier,
    LinuxProcessLivenessChecker& liveness_checker)
    : parent_locator_(
          std::filesystem::absolute(target_path.parent_path()).lexically_normal()),
      paths_(LinuxTransactionPaths::Create(target_path.filename().string(),
                                           transaction_id)),
      expected_payload_identity_(std::move(expected_payload_identity)),
      verifier_(verifier),
      liveness_checker_(liveness_checker) {}

LinuxRecoveryOutcome LinuxRecoveryService::Recover() {
  (void)manualActionRequired;
  (void)liveOwner;
  try {
    auto parent = OpenLinuxDirectory(parent_locator_.string());
    DurableLinuxTransactionJournalStore store(parent.get(), paths_);
    if (store.HasAmbiguousNext()) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }
    const auto loaded = store.Load();
    if (!loaded.has_value()) {
      if (!LinuxRelativeExistsNoFollow(parent.get(), paths_.lock_name)) {
        return LinuxRecoveryOutcome::kNothingToRecover;
      }
      auto orphan_lock = OpenLinuxRelativeNoFollow(
          parent.get(), paths_.lock_name, O_RDWR);
      if (flock(orphan_lock.get(), LOCK_EX | LOCK_NB) != 0) {
        return LinuxRecoveryOutcome::kLiveOwner;
      }
      const auto record = LinuxTransactionLockRecord::DecodeStrict(
          ReadLinuxRelativeUtf8(parent.get(), paths_.lock_name, 4096));
      if (record.transaction_id != paths_.transaction_id) {
        return LinuxRecoveryOutcome::kManualActionRequired;
      }
      if (liveness_checker_.IsSameProcessAlive(
              record.owner_process_id,
              record.owner_process_start_identity)) {
        return LinuxRecoveryOutcome::kLiveOwner;
      }
      if (LinuxRelativeExistsNoFollow(parent.get(), paths_.prepared_name) ||
          LinuxRelativeExistsNoFollow(parent.get(), paths_.backup_name)) {
        return LinuxRecoveryOutcome::kManualActionRequired;
      }
      if (unlinkat(parent.get(), paths_.lock_name.c_str(), 0) != 0) {
        return LinuxRecoveryOutcome::kManualActionRequired;
      }
      orphan_lock.reset();
      SyncLinuxDirectory(parent.get());
      return LinuxRecoveryOutcome::kNothingToRecover;
    }
    if (!LinuxRelativeExistsNoFollow(parent.get(), paths_.lock_name)) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }
    auto transaction_lock = OpenLinuxRelativeNoFollow(
        parent.get(), paths_.lock_name, O_RDWR);
    if (flock(transaction_lock.get(), LOCK_EX | LOCK_NB) != 0) {
      return LinuxRecoveryOutcome::kLiveOwner;
    }
    const auto lock_record = LinuxTransactionLockRecord::DecodeStrict(
        ReadLinuxRelativeUtf8(parent.get(), paths_.lock_name, 4096));
    if (lock_record.transaction_id != paths_.transaction_id) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }
    if (loaded->owner_process_id != lock_record.owner_process_id ||
        loaded->owner_process_start_identity !=
            lock_record.owner_process_start_identity) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }
    LinuxTransactionJournal journal = *loaded;
    if (journal.transaction_id != paths_.transaction_id ||
        journal.target_name != paths_.target_name ||
        journal.prepared_name != paths_.prepared_name ||
        journal.backup_name != paths_.backup_name ||
        journal.lock_name != paths_.lock_name ||
        journal.parent_identity != ReadLinuxFileIdentity(parent.get()) ||
        journal.expected_payload_identity != expected_payload_identity_) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }
    if (liveness_checker_.IsSameProcessAlive(
            journal.owner_process_id,
            journal.owner_process_start_identity)) {
      return LinuxRecoveryOutcome::kLiveOwner;
    }

    auto ownership = OpenLinuxRelativeNoFollow(
        parent.get(), paths_.recovery_lock_name, O_CREAT | O_RDWR, 0600);
    if (flock(ownership.get(), LOCK_EX | LOCK_NB) != 0) {
      return LinuxRecoveryOutcome::kLiveOwner;
    }
    if (!LinuxRelativeExistsNoFollow(parent.get(), paths_.lock_name)) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }

    bool target_exists =
        LinuxRelativeExistsNoFollow(parent.get(), paths_.target_name);
    bool stage_exists =
        LinuxRelativeExistsNoFollow(parent.get(), journal.original_stage_name);
    bool prepared_exists =
        LinuxRelativeExistsNoFollow(parent.get(), paths_.prepared_name);
    bool backup_exists =
        LinuxRelativeExistsNoFollow(parent.get(), paths_.backup_name);
    if (!CompatibleObservation(journal, target_exists, stage_exists,
                               prepared_exists, backup_exists)) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }
    if (target_exists) {
      const auto identity =
          ReadLinuxRelativeIdentity(parent.get(), paths_.target_name);
      if (identity != journal.target_identity &&
          !verifier_.MatchesActivatedPayloadRoot(
              parent.get(), paths_.target_name, journal.stage_identity)) {
        return LinuxRecoveryOutcome::kManualActionRequired;
      }
    }
    if (backup_exists &&
        !Matches(parent.get(), paths_.backup_name, journal.target_identity)) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }

    if (stage_exists) {
      if (!Matches(parent.get(), journal.original_stage_name,
                   journal.stage_identity) ||
          verifier_.Verify(parent.get(), journal.original_stage_name) !=
              expected_payload_identity_) {
        return LinuxRecoveryOutcome::kManualActionRequired;
      }
      RenameLinuxRelative(parent.get(), journal.original_stage_name,
                          paths_.prepared_name, false);
      SyncLinuxDirectory(parent.get());
      stage_exists = false;
      prepared_exists = true;
    }

    if (!backup_exists && prepared_exists) {
      if (!target_exists ||
          !Matches(parent.get(), paths_.target_name, journal.target_identity)) {
        return LinuxRecoveryOutcome::kManualActionRequired;
      }
      RenameLinuxRelative(parent.get(), paths_.target_name, paths_.backup_name,
                          false);
      SyncLinuxDirectory(parent.get());
      target_exists = false;
      backup_exists = true;
      journal.state = LinuxTransactionState::kBackupCreated;
      store.Persist(journal);
    }

    if (backup_exists && prepared_exists && !target_exists) {
      if (!Matches(parent.get(), paths_.prepared_name, journal.stage_identity) ||
          verifier_.Verify(parent.get(), paths_.prepared_name) !=
              expected_payload_identity_) {
        return LinuxRecoveryOutcome::kManualActionRequired;
      }
      RenameLinuxRelative(parent.get(), paths_.prepared_name,
                          paths_.target_name, false);
      SyncLinuxDirectory(parent.get());
      prepared_exists = false;
      target_exists = true;
      journal.state = LinuxTransactionState::kTargetActivated;
      store.Persist(journal);
    }

    if (target_exists && !prepared_exists && backup_exists) {
      verifier_.FinalizeActivatedPayloadRoot(
          parent.get(), paths_.target_name, journal.stage_identity);
    }

    if (!target_exists || stage_exists || prepared_exists ||
        !verifier_.MatchesActivatedPayloadRoot(
            parent.get(), paths_.target_name, journal.stage_identity) ||
        verifier_.Verify(parent.get(), paths_.target_name) !=
            expected_payload_identity_) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }

    if (backup_exists) {
      if (!Matches(parent.get(), paths_.backup_name, journal.target_identity)) {
        return LinuxRecoveryOutcome::kManualActionRequired;
      }
      journal.state = LinuxTransactionState::kTargetActivated;
      store.Persist(journal);
      journal.state = LinuxTransactionState::kCompleted;
      store.Persist(journal);
      // Cleanup is authorized only after package identity, stageProvenance,
      // artifact digest, executable proof, signer, owner, and mode all match.
      RemoveLinuxTreeExact(parent.get(), paths_.backup_name,
                           journal.target_identity);
    }
    store.Remove();
    if (unlinkat(parent.get(), paths_.recovery_lock_name.c_str(), 0) != 0 &&
        errno != ENOENT) {
      return LinuxRecoveryOutcome::kManualActionRequired;
    }
    SyncLinuxDirectory(parent.get());
    return LinuxRecoveryOutcome::kRecovered;
  } catch (const std::exception&) {
    return LinuxRecoveryOutcome::kManualActionRequired;
  }
}

}  // namespace desktop_updater::helper
