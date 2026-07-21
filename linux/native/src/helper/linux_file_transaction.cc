#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "linux_file_transaction.h"

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <utility>

#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

// The transaction deliberately keeps every mutation in the pinned parent and
// reaches renameat2/unlinkat only through fd-relative helpers.
constexpr char kMutationPrimitives[] = "renameat2 unlinkat O_PATH O_NOFOLLOW";
constexpr char beforeActivationRename[] = "beforeActivationRename";

std::string ValidatedStageName(const std::filesystem::path& parent,
                               const std::filesystem::path& stage) {
  if (std::filesystem::absolute(stage.parent_path()).lexically_normal() !=
      parent) {
    throw LinuxFileTransactionError(
        "stage must be an immediate sibling in the target parent");
  }
  ValidateLinuxLeaf(stage.filename().string());
  return stage.filename().string();
}

void WriteAll(int fd, const std::string& contents) {
  std::size_t offset = 0;
  while (offset < contents.size()) {
    const ssize_t count =
        write(fd, contents.data() + offset, contents.size() - offset);
    if (count <= 0) {
      throw LinuxFileTransactionError("transaction lock write failed");
    }
    offset += static_cast<std::size_t>(count);
  }
}

}  // namespace

LinuxFileTransaction::LinuxFileTransaction(
    const std::filesystem::path& target_path,
    const std::filesystem::path& stage_path,
    std::string transaction_id,
    pid_t owner_process_id,
    LinuxVerifiedPayloadIdentity expected_payload_identity,
    LinuxInstallPayloadVerifier& verifier,
    LinuxTransactionFaultInjector* fault_injector)
    : parent_locator_(
          std::filesystem::absolute(target_path.parent_path()).lexically_normal()),
      stage_name_(ValidatedStageName(parent_locator_, stage_path)),
      paths_(LinuxTransactionPaths::Create(target_path.filename().string(),
                                           transaction_id)),
      owner_process_id_(owner_process_id),
      owner_process_start_identity_(LinuxProcessStartIdentity(owner_process_id)),
      expected_payload_identity_(std::move(expected_payload_identity)),
      verifier_(verifier),
      fault_injector_(fault_injector == nullptr ? &no_faults_ : fault_injector),
      parent_(OpenLinuxDirectory(parent_locator_.string())),
      target_(OpenLinuxRelativeNoFollow(parent_.get(), paths_.target_name,
                                        O_PATH)),
      stage_(OpenLinuxRelativeNoFollow(parent_.get(), stage_name_, O_PATH)),
      lock_(),
      mount_guard_(parent_.get(), target_.get(), stage_.get()) {
  (void)kMutationPrimitives;
  (void)beforeActivationRename;
  if (owner_process_id_ <= 0 || owner_process_start_identity_ == 0) {
    throw LinuxFileTransactionError("owner process identity unavailable");
  }
  const auto stage_identity = ReadLinuxFileIdentity(stage_.get());
  if (!stage_identity.directory && stage_identity.link_count != 1) {
    throw LinuxFileTransactionError("hard-linked stage rejected");
  }
  lock_ = OpenLinuxRelativeNoFollow(parent_.get(), paths_.lock_name,
                                    O_CREAT | O_EXCL | O_RDWR, 0600);
  try {
    if (flock(lock_.get(), LOCK_EX | LOCK_NB) != 0) {
      throw LinuxFileTransactionError("transaction lock ownership failed");
    }
    const LinuxTransactionLockRecord record{
        paths_.transaction_id, owner_process_id_,
        owner_process_start_identity_};
    WriteAll(lock_.get(), record.EncodeCanonical());
    if (fdatasync(lock_.get()) != 0) {
      throw LinuxFileTransactionError("transaction lock fdatasync failed");
    }
    SyncLinuxDirectory(parent_.get());
  } catch (...) {
    lock_.reset();
    unlinkat(parent_.get(), paths_.lock_name.c_str(), 0);
    throw;
  }
}

LinuxFileTransaction::~LinuxFileTransaction() {
  if (!journal_persisted_ && parent_.valid() && lock_.valid()) {
    lock_.reset();
    if (unlinkat(parent_.get(), paths_.lock_name.c_str(), 0) == 0) {
      try {
        SyncLinuxDirectory(parent_.get());
      } catch (const std::exception&) {
      }
    }
  }
}

void LinuxFileTransaction::ValidateParentLocator() const {
  auto observed = OpenLinuxDirectory(parent_locator_.string());
  if (!HasStableLinuxIdentity(ReadLinuxFileIdentity(observed.get()),
                              mount_guard_.parent_identity())) {
    throw LinuxFileTransactionError("target parent replacement rejected");
  }
}

void LinuxFileTransaction::ValidateRelativeIdentity(
    const std::string& leaf,
    const LinuxFileIdentity& expected,
    const char* detail) const {
  if (!LinuxRelativeExistsNoFollow(parent_.get(), leaf) ||
      !HasExactLinuxIdentity(ReadLinuxRelativeIdentity(parent_.get(), leaf),
                             expected)) {
    throw LinuxFileTransactionError(detail);
  }
}

void LinuxFileTransaction::VerifyPayload(const std::string& leaf) const {
  if (verifier_.Verify(parent_.get(), leaf) != expected_payload_identity_) {
    throw LinuxFileTransactionError(
        "stage provenance, artifact digest, signer, executable, or permissions changed");
  }
}

std::string LinuxFileTransaction::PrepareDurableJournal() {
  if (execution_started_) {
    throw LinuxFileTransactionError(
        "transaction preparation cannot follow mutation");
  }
  if (journal_.has_value()) return journal_->EncodeCanonical();

  ValidateParentLocator();
  mount_guard_.Validate(parent_.get(), target_.get(), stage_.get());
  ValidateRelativeIdentity(paths_.target_name,
                           mount_guard_.target_identity(),
                           "target identity changed before mutation");
  ValidateRelativeIdentity(stage_name_, mount_guard_.stage_identity(),
                           "stage identity changed before mutation");
  VerifyPayload(stage_name_);

  DurableLinuxTransactionJournalStore store(parent_.get(), paths_,
                                             fault_injector_);
  LinuxTransactionJournal journal;
  journal.transaction_id = paths_.transaction_id;
  journal.owner_process_id = owner_process_id_;
  journal.owner_process_start_identity = owner_process_start_identity_;
  journal.target_name = paths_.target_name;
  journal.original_stage_name = stage_name_;
  journal.prepared_name = paths_.prepared_name;
  journal.backup_name = paths_.backup_name;
  journal.lock_name = paths_.lock_name;
  journal.parent_identity = mount_guard_.parent_identity();
  journal.target_identity = mount_guard_.target_identity();
  journal.stage_identity = mount_guard_.stage_identity();
  journal.expected_payload_identity = expected_payload_identity_;
  journal.state = LinuxTransactionState::kPrepared;
  // From this point a process death must be reconciled through either the
  // durable lock record (pre-journal) or the journal (post-rename).
  journal_persisted_ = true;
  store.Persist(journal);
  journal_ = journal;
  return journal.EncodeCanonical();
}

void LinuxFileTransaction::CancelPrepared() {
  if (!journal_.has_value() || execution_started_) {
    throw LinuxFileTransactionError(
        "only a prepared transaction can be cancelled");
  }
  ValidateParentLocator();
  ValidateRelativeIdentity(paths_.target_name, journal_->target_identity,
                           "target identity changed before cancellation");
  ValidateRelativeIdentity(stage_name_, journal_->stage_identity,
                           "stage identity changed before cancellation");
  DurableLinuxTransactionJournalStore store(parent_.get(), paths_,
                                             fault_injector_);
  store.Remove();
  lock_.reset();
  journal_.reset();
  journal_persisted_ = false;
}

LinuxFileTransactionResult LinuxFileTransaction::Execute() {
  if (!journal_.has_value()) (void)PrepareDurableJournal();
  if (execution_started_) {
    throw LinuxFileTransactionError("transaction mutation already started");
  }
  execution_started_ = true;
  LinuxTransactionJournal journal = *journal_;
  DurableLinuxTransactionJournalStore store(parent_.get(), paths_,
                                             fault_injector_);

  fault_injector_->Hit(LinuxTransactionFaultPoint::kBeforeStageRename);
  ValidateParentLocator();
  ValidateRelativeIdentity(stage_name_, journal.stage_identity,
                           "stage replaced before prepare rename");
  RenameLinuxRelative(parent_.get(), stage_name_, paths_.prepared_name, false);
  fault_injector_->Hit(
      LinuxTransactionFaultPoint::kAfterStageRenameBeforeDirectoryFlush);
  SyncLinuxDirectory(parent_.get());
  journal.stage_identity =
      ReadLinuxRelativeIdentity(parent_.get(), paths_.prepared_name);
  store.Persist(journal);
  fault_injector_->Hit(LinuxTransactionFaultPoint::kAfterStageRename);

  fault_injector_->Hit(LinuxTransactionFaultPoint::kBeforeBackupRename);
  ValidateParentLocator();
  ValidateRelativeIdentity(paths_.target_name, journal.target_identity,
                           "target replaced before backup rename");
  ValidateRelativeIdentity(paths_.prepared_name, journal.stage_identity,
                           "prepared stage identity changed");
  VerifyPayload(paths_.prepared_name);
  RenameLinuxRelative(parent_.get(), paths_.target_name, paths_.backup_name,
                      false);
  fault_injector_->Hit(
      LinuxTransactionFaultPoint::kAfterBackupRenameBeforeDirectoryFlush);
  SyncLinuxDirectory(parent_.get());
  journal.target_identity =
      ReadLinuxRelativeIdentity(parent_.get(), paths_.backup_name);
  journal.state = LinuxTransactionState::kBackupCreated;
  store.Persist(journal);
  fault_injector_->Hit(LinuxTransactionFaultPoint::kAfterBackupRename);

  fault_injector_->Hit(LinuxTransactionFaultPoint::kBeforeActivationRename);
  ValidateParentLocator();
  ValidateRelativeIdentity(paths_.backup_name, journal.target_identity,
                           "backup identity changed before activation");
  ValidateRelativeIdentity(paths_.prepared_name, journal.stage_identity,
                           "prepared stage changed before activation");
  VerifyPayload(paths_.prepared_name);
  RenameLinuxRelative(parent_.get(), paths_.prepared_name, paths_.target_name,
                      false);
  fault_injector_->Hit(
      LinuxTransactionFaultPoint::kAfterActivationRenameBeforeDirectoryFlush);
  SyncLinuxDirectory(parent_.get());
  journal.stage_identity =
      ReadLinuxRelativeIdentity(parent_.get(), paths_.target_name);
  journal.state = LinuxTransactionState::kTargetActivated;
  store.Persist(journal);
  fault_injector_->Hit(LinuxTransactionFaultPoint::kAfterActivationRename);

  ValidateParentLocator();
  verifier_.FinalizeActivatedPayloadRoot(parent_.get(), paths_.target_name,
                                         journal.stage_identity);
  if (!verifier_.MatchesActivatedPayloadRoot(
          parent_.get(), paths_.target_name, journal.stage_identity)) {
    throw LinuxFileTransactionError("activated target identity changed");
  }
  VerifyPayload(paths_.target_name);
  journal.state = LinuxTransactionState::kCompleted;
  store.Persist(journal);
  RemoveLinuxTreeExact(parent_.get(), paths_.backup_name,
                       journal.target_identity);
  store.Remove();
  return LinuxFileTransactionResult::kCompleted;
}

}  // namespace desktop_updater::helper
