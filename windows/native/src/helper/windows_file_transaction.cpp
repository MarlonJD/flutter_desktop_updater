#include "windows_file_transaction.h"

#include <winternl.h>

#include <algorithm>
#include <utility>

#include "windows_helper_diagnostics.h"

#ifndef OBJ_DONT_REPARSE
#define OBJ_DONT_REPARSE 0x00001000L
#endif

namespace desktop_updater::helper {
namespace {

constexpr char alternateDataStreamRejected[] = "alternateDataStreamRejected";
constexpr char beforeActivationRename[] = "beforeActivationRename";

UniqueWindowsHandle OpenAbsoluteDirectoryNoReparse(
    const std::filesystem::path& path) {
  HANDLE handle = CreateFileW(
      path.c_str(), GENERIC_READ | GENERIC_WRITE | FILE_TRAVERSE | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "target parent open failed");
  }
  UniqueWindowsHandle result(handle);
  const WindowsFileIdentity identity = ReadWindowsFileIdentity(result.get());
  if (!identity.directory ||
      (identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "target parent is not a non-reparse directory");
  }
  return result;
}

void ThrowFilesystem(const char* detail) {
  const DWORD error = GetLastError();
  const auto code = error == ERROR_SHARING_VIOLATION ||
                            error == ERROR_LOCK_VIOLATION
                        ? WindowsFileTransactionError::Code::kSharingViolation
                        : WindowsFileTransactionError::Code::kFilesystemOperationFailed;
  throw WindowsFileTransactionError(code, detail);
}

UniqueWindowsHandle DuplicateRetainedHandle(HANDLE source,
                                            const char* detail) {
  if (source == nullptr || source == INVALID_HANDLE_VALUE) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        detail);
  }
  HANDLE duplicate = INVALID_HANDLE_VALUE;
  if (!DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(),
                       &duplicate, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        detail);
  }
  return UniqueWindowsHandle(duplicate);
}

}  // namespace

std::uint64_t WindowsProcessStartIdentity(DWORD process_id) {
  UniqueWindowsHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                          FALSE, process_id));
  if (!process.valid()) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "owner process cannot be retained");
  }
  return WindowsProcessStartIdentity(process.get());
}

std::uint64_t WindowsProcessStartIdentity(HANDLE process) {
  if (process == nullptr || process == INVALID_HANDLE_VALUE) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "owner process handle is invalid");
  }
  FILETIME creation{};
  FILETIME exit{};
  FILETIME kernel{};
  FILETIME user{};
  if (!GetProcessTimes(process, &creation, &exit, &kernel, &user)) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "owner process start identity unavailable");
  }
  return (static_cast<std::uint64_t>(creation.dwHighDateTime) << 32) |
         creation.dwLowDateTime;
}

WindowsFileTransaction::WindowsFileTransaction(
    const std::filesystem::path& target_path,
    const std::filesystem::path& stage_path,
    std::string transaction_id,
    DWORD owner_process_id,
    WindowsVerifiedPayloadIdentity expected_payload_identity,
    WindowsInstallPayloadVerifier& verifier,
    WindowsTransactionFaultInjector* fault_injector,
    WindowsTransactionTerminalCallbacks terminal_callbacks,
    std::optional<std::uint64_t> retained_owner_start_identity,
    std::function<void(HANDLE)> durability_barrier)
    : parent_locator_(
          std::filesystem::absolute(target_path.parent_path()).lexically_normal()),
      stage_parent_locator_(
          std::filesystem::absolute(stage_path.parent_path()).lexically_normal()),
      stage_name_(stage_path.filename().wstring()),
      paths_(WindowsTransactionPaths::Create(target_path.filename().wstring(),
                                             transaction_id)),
      owner_process_id_(owner_process_id),
      owner_process_start_identity_(
          retained_owner_start_identity.has_value()
              ? *retained_owner_start_identity
              : WindowsProcessStartIdentity(owner_process_id)),
      expected_payload_identity_(std::move(expected_payload_identity)),
      verifier_(verifier),
      fault_injector_(fault_injector == nullptr ? &no_faults_
                                               : fault_injector),
      terminal_callbacks_(std::move(terminal_callbacks)),
      durability_barrier_(std::move(durability_barrier)),
      parent_(OpenAbsoluteDirectoryNoReparse(parent_locator_)),
      stage_parent_(OpenAbsoluteDirectoryNoReparse(stage_parent_locator_)) {
  if (stage_name_.empty() || stage_name_ == paths_.target_name ||
      stage_name_.find_first_of(L"\\/:*?\"<>|") != std::wstring::npos) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        alternateDataStreamRejected);
  }
  parent_identity_ = ReadWindowsFileIdentity(parent_.get());
  stage_parent_identity_ = ReadWindowsFileIdentity(stage_parent_.get());
  target_ = OpenRelativeNoReparse(
      parent_.get(), paths_.target_name,
      DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  stage_ = OpenRelativeNoReparse(
      stage_parent_.get(), stage_name_,
      DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  target_identity_ = ReadWindowsFileIdentity(target_.get());
  stage_identity_ = ReadWindowsFileIdentity(stage_.get());
  ValidateSameVolume(target_identity_.volume_serial,
                     stage_identity_.volume_serial);
  ValidatePayload(stage_parent_.get(), stage_name_);

  journal_.transaction_id = paths_.transaction_id;
  journal_.owner_process_id = owner_process_id_;
  journal_.owner_process_start_identity = owner_process_start_identity_;
  journal_.target_name = paths_.target_name;
  journal_.original_stage_parent_path = stage_parent_locator_.wstring();
  journal_.original_stage_name = stage_name_;
  journal_.prepared_name = paths_.prepared_name;
  journal_.backup_name = paths_.backup_name;
  journal_.lock_name = paths_.lock_name;
  journal_.parent_identity = parent_identity_;
  journal_.stage_parent_identity = stage_parent_identity_;
  journal_.target_identity = target_identity_;
  journal_.stage_identity = stage_identity_;
  journal_.expected_payload_identity = expected_payload_identity_;
  journal_.state = WindowsTransactionState::kPrepared;

  for (const std::wstring& name : {
           paths_.prepared_name,
           paths_.backup_name,
           paths_.journal_name,
           paths_.journal_next_name,
           paths_.lock_candidate_name,
       }) {
    if (ExistsRelativeNoReparse(parent_.get(), name)) {
      throw WindowsFileTransactionError(
          WindowsFileTransactionError::Code::kDerivedArtifactAlreadyExists,
          "derived transaction artifact already exists");
    }
  }
}

WindowsFileTransaction::WindowsFileTransaction(
    const std::filesystem::path& target_path,
    const std::filesystem::path& stage_path,
    std::string transaction_id,
    DWORD owner_process_id,
    WindowsVerifiedPayloadIdentity expected_payload_identity,
    WindowsInstallPayloadVerifier& verifier,
    HANDLE pinned_parent,
    HANDLE pinned_stage,
    WindowsTransactionFaultInjector* fault_injector,
    WindowsTransactionTerminalCallbacks terminal_callbacks,
    std::optional<std::uint64_t> retained_owner_start_identity,
    std::function<void(HANDLE)> durability_barrier)
    : parent_locator_(
          std::filesystem::absolute(target_path.parent_path()).lexically_normal()),
      stage_parent_locator_(
          std::filesystem::absolute(stage_path.parent_path()).lexically_normal()),
      stage_name_(stage_path.filename().wstring()),
      paths_(WindowsTransactionPaths::Create(target_path.filename().wstring(),
                                             transaction_id)),
      owner_process_id_(owner_process_id),
      owner_process_start_identity_(
          retained_owner_start_identity.has_value()
              ? *retained_owner_start_identity
              : WindowsProcessStartIdentity(owner_process_id)),
      expected_payload_identity_(std::move(expected_payload_identity)),
      verifier_(verifier),
      fault_injector_(fault_injector == nullptr ? &no_faults_
                                               : fault_injector),
      terminal_callbacks_(std::move(terminal_callbacks)),
      durability_barrier_(std::move(durability_barrier)),
      parent_(DuplicateRetainedHandle(pinned_parent,
                                      "pinned target parent is invalid")),
      stage_parent_(DuplicateRetainedHandle(
          pinned_parent, "pinned stage parent is invalid")),
      stage_(DuplicateRetainedHandle(pinned_stage,
                                     "pinned stage root is invalid")) {
  if (stage_parent_locator_ != parent_locator_ || stage_name_.empty() ||
      stage_name_ == paths_.target_name ||
      stage_name_.find_first_of(L"\\/:*?\"<>|") != std::wstring::npos) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        alternateDataStreamRejected);
  }
  parent_identity_ = ReadWindowsFileIdentity(parent_.get());
  stage_parent_identity_ = ReadWindowsFileIdentity(stage_parent_.get());
  if (parent_identity_ != stage_parent_identity_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kStageIdentityChanged,
        "pinned target and stage parent identities differ");
  }
  ValidateParentLocator();
  ValidateStageParentLocator();
  target_ = OpenRelativeNoReparse(
      parent_.get(), paths_.target_name,
      DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  target_identity_ = ReadWindowsFileIdentity(target_.get());
  stage_identity_ = ReadWindowsFileIdentity(stage_.get());
  if (!stage_identity_.directory) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kStageIdentityChanged,
        "pinned stage root is not a directory");
  }
  auto observed_stage = OpenRelativeNoReparse(
      stage_parent_.get(), stage_name_,
      DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  if (ReadWindowsFileIdentity(observed_stage.get()) != stage_identity_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kStageIdentityChanged,
        "pinned stage locator does not name the retained root");
  }
  ValidateSameVolume(target_identity_.volume_serial,
                     stage_identity_.volume_serial);
  ValidatePayload(stage_parent_.get(), stage_name_);

  journal_.transaction_id = paths_.transaction_id;
  journal_.owner_process_id = owner_process_id_;
  journal_.owner_process_start_identity = owner_process_start_identity_;
  journal_.target_name = paths_.target_name;
  journal_.original_stage_parent_path = stage_parent_locator_.wstring();
  journal_.original_stage_name = stage_name_;
  journal_.prepared_name = paths_.prepared_name;
  journal_.backup_name = paths_.backup_name;
  journal_.lock_name = paths_.lock_name;
  journal_.parent_identity = parent_identity_;
  journal_.stage_parent_identity = stage_parent_identity_;
  journal_.target_identity = target_identity_;
  journal_.stage_identity = stage_identity_;
  journal_.expected_payload_identity = expected_payload_identity_;
  journal_.state = WindowsTransactionState::kPrepared;

  for (const std::wstring& name : {
           paths_.prepared_name,
           paths_.backup_name,
           paths_.journal_name,
           paths_.journal_next_name,
           paths_.lock_candidate_name,
       }) {
    if (ExistsRelativeNoReparse(parent_.get(), name)) {
      throw WindowsFileTransactionError(
          WindowsFileTransactionError::Code::kDerivedArtifactAlreadyExists,
          "derived transaction artifact already exists");
    }
  }
}

WindowsFileTransaction::~WindowsFileTransaction() {
  if (completed_) {
    RemoveLockExactNoThrow();
    return;
  }
  if (!journal_persisted_) {
    try {
      // A journal or journal.next artifact means persistence may have crossed
      // a crash boundary even when Persist() did not return. Keep the exact
      // lock so a fresh recovery process can reconcile it authoritatively.
      if (ExistsRelativeNoReparse(parent_.get(), paths_.journal_name) ||
          ExistsRelativeNoReparse(parent_.get(), paths_.journal_next_name)) {
        return;
      }
    } catch (const std::exception&) {
      // Inability to prove that no durable artifact exists must retain the
      // recovery lock.
      return;
    }
    RemoveLockExactNoThrow();
  }
}

void WindowsFileTransaction::ValidateSameVolume(
    std::uint64_t target_volume,
    std::uint64_t stage_volume) {
  if (target_volume != stage_volume) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kCrossVolumeStage,
        "stage and target must share a volume");
  }
}

std::string WindowsFileTransaction::initial_journal_canonical() const {
  if (prepared_ || cancelled_ || completed_ || journal_persisted_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "initial journal snapshot is unavailable");
  }
  return journal_.EncodeCanonical();
}

void WindowsFileTransaction::ValidateParentLocator() const {
  auto observed = OpenAbsoluteDirectoryNoReparse(parent_locator_);
  if (ReadWindowsFileIdentity(observed.get()) != parent_identity_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kTargetParentChanged,
        "target parent path identity changed");
  }
}

void WindowsFileTransaction::ValidateStageParentLocator() const {
  auto observed = OpenAbsoluteDirectoryNoReparse(stage_parent_locator_);
  if (ReadWindowsFileIdentity(observed.get()) != stage_parent_identity_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kStageIdentityChanged,
        "stage parent path identity changed");
  }
}

void WindowsFileTransaction::ValidateIdentity(
    HANDLE parent,
    const std::wstring& name,
    const WindowsFileIdentity& expected,
    WindowsFileTransactionError::Code error) const {
  try {
    auto observed = OpenRelativeNoReparse(
        parent, name,
        FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
        FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
    if (ReadWindowsFileIdentity(observed.get()) != expected) {
      throw WindowsFileTransactionError(error, "retained identity changed");
    }
  } catch (const WindowsFileTransactionError&) {
    throw;
  } catch (const std::exception&) {
    throw WindowsFileTransactionError(error, "retained identity unavailable");
  }
}

void WindowsFileTransaction::ValidatePayload(
    HANDLE parent,
    const std::wstring& name) const {
  try {
    if (verifier_.Verify(parent, name) != expected_payload_identity_) {
      throw WindowsFileTransactionError(
          WindowsFileTransactionError::Code::kStagePayloadChanged,
          "payload identity changed");
    }
  } catch (const WindowsFileTransactionError&) {
    throw;
  } catch (const std::exception&) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kStagePayloadChanged,
        "payload verification failed");
  }
}

void WindowsFileTransaction::DurableRename(
    HANDLE source,
    const std::wstring& destination,
    WindowsTransactionFaultPoint before,
    WindowsTransactionFaultPoint before_directory_flush,
    WindowsTransactionFaultPoint after) {
  fault_injector_->Hit(before);
  try {
    RenameHandleRelative(source, parent_.get(), destination, false);
    fault_injector_->Hit(before_directory_flush);
    FlushMetadata(parent_.get());
    fault_injector_->Hit(after);
  } catch (const WindowsFileTransactionError&) {
    throw;
  } catch (const std::exception&) {
    ThrowFilesystem("handle-relative durable rename failed");
  }
}

void WindowsFileTransaction::Prepare() {
  if (prepared_ || cancelled_ || completed_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "transaction cannot be prepared twice");
  }
  ValidateParentLocator();
  ValidateStageParentLocator();
  ValidateIdentity(stage_parent_.get(), stage_name_, stage_identity_,
                   WindowsFileTransactionError::Code::kStageIdentityChanged);
  ValidatePayload(stage_parent_.get(), stage_name_);
  ValidateIdentity(parent_.get(), paths_.target_name, target_identity_,
                   WindowsFileTransactionError::Code::kTargetIdentityChanged);
  for (const std::wstring& name : {
           paths_.prepared_name,
           paths_.backup_name,
           paths_.journal_name,
           paths_.journal_next_name,
           paths_.lock_candidate_name,
       }) {
    if (ExistsRelativeNoReparse(parent_.get(), name)) {
      throw WindowsFileTransactionError(
          WindowsFileTransactionError::Code::kDerivedArtifactAlreadyExists,
          "derived transaction artifact already exists");
    }
  }
  try {
    UniqueWindowsHandle candidate = OpenRelativeNoReparse(
        parent_.get(), paths_.lock_candidate_name,
        GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE, 0, FILE_CREATE,
        FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
            FILE_WRITE_THROUGH,
        FILE_ATTRIBUTE_HIDDEN);
    try {
      WriteWindowsTransactionLockBinding(candidate.get(),
                                         paths_.transaction_id);
      RenameHandleRelative(candidate.get(), parent_.get(), paths_.lock_name,
                           false);
      FlushMetadata(parent_.get());
      lock_ = std::move(candidate);
    } catch (...) {
      if (candidate.valid()) {
        try {
          DeleteHandleExact(candidate.get());
          candidate.reset();
          FlushMetadata(parent_.get());
        } catch (...) {
          candidate.reset();
        }
      }
      throw;
    }
  } catch (const WindowsTransactionJournalError&) {
    ThrowFilesystem("exclusive target lock acquisition failed");
  }
  journal_store_ = std::make_unique<DurableWindowsTransactionJournalStore>(
      parent_.get(), paths_, fault_injector_);
  journal_store_->Persist(journal_);
  FlushMetadata(parent_.get());
  journal_persisted_ = true;
  ValidateStageParentLocator();
  ValidateIdentity(stage_parent_.get(), stage_name_, stage_identity_,
                   WindowsFileTransactionError::Code::kStageIdentityChanged);
  ValidatePayload(stage_parent_.get(), stage_name_);
  DurableRename(stage_.get(), paths_.prepared_name,
                WindowsTransactionFaultPoint::kBeforeStageRename,
                WindowsTransactionFaultPoint::kAfterStageRenameBeforeDirectoryFlush,
                WindowsTransactionFaultPoint::kAfterStageRename);
  if (stage_parent_identity_ != parent_identity_) {
    FlushMetadata(stage_parent_.get());
  }
  prepared_ = true;
}

std::string WindowsFileTransaction::prepared_journal_canonical() const {
  if (!prepared_ || !journal_persisted_ || cancelled_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "prepared journal is unavailable");
  }
  return journal_.EncodeCanonical();
}

void WindowsFileTransaction::MarkCommitAccepted() {
  if (!prepared_ || !journal_persisted_ || cancelled_ || completed_ ||
      commit_accepted_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "transaction cannot accept commit in its current state");
  }
  journal_store_->Persist(journal_);
  FlushMetadata(parent_.get());
  commit_accepted_ = true;
}

WindowsFileTransactionResult WindowsFileTransaction::ExecutePrepared() {
  if (!prepared_ || !journal_persisted_ || cancelled_ || completed_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "transaction is not prepared for commit");
  }

  ValidateIdentity(parent_.get(), paths_.prepared_name, stage_identity_,
                   WindowsFileTransactionError::Code::kStageIdentityChanged);
  ValidatePayload(parent_.get(), paths_.prepared_name);

  ValidateParentLocator();
  ValidateIdentity(parent_.get(), paths_.target_name, target_identity_,
                   WindowsFileTransactionError::Code::kTargetIdentityChanged);
  RecordWindowsHelperEvent(WindowsHelperEvent::kBackupStart);
  try {
    DurableRename(
        target_.get(), paths_.backup_name,
        WindowsTransactionFaultPoint::kBeforeBackupRename,
        WindowsTransactionFaultPoint::kAfterBackupRenameBeforeDirectoryFlush,
        WindowsTransactionFaultPoint::kAfterBackupRename);
    journal_.state = WindowsTransactionState::kBackupCreated;
    journal_store_->Persist(journal_);
    FlushMetadata(parent_.get());
  } catch (...) {
    RecordWindowsHelperEvent(WindowsHelperEvent::kBackupFailure);
    throw;
  }
  RecordWindowsHelperEvent(WindowsHelperEvent::kBackupSuccess);

  ValidateIdentity(parent_.get(), paths_.prepared_name, stage_identity_,
                   WindowsFileTransactionError::Code::kStageIdentityChanged);
  ValidatePayload(parent_.get(), paths_.prepared_name);
  RecordWindowsHelperEvent(WindowsHelperEvent::kMoveStart);
  try {
    DurableRename(
        stage_.get(), paths_.target_name,
        WindowsTransactionFaultPoint::kBeforeActivationRename,
        WindowsTransactionFaultPoint::kAfterActivationRenameBeforeDirectoryFlush,
        WindowsTransactionFaultPoint::kAfterActivationRename);
    journal_.state = WindowsTransactionState::kTargetActivated;
    journal_store_->Persist(journal_);
    FlushMetadata(parent_.get());
  } catch (...) {
    RecordWindowsHelperEvent(WindowsHelperEvent::kMoveFailure);
    throw;
  }
  RecordWindowsHelperEvent(WindowsHelperEvent::kMoveSuccess);

  ValidateIdentity(parent_.get(), paths_.target_name, stage_identity_,
                   WindowsFileTransactionError::Code::kStageIdentityChanged);
  ValidatePayload(parent_.get(), paths_.target_name);
  journal_.state = WindowsTransactionState::kCompleted;
  journal_store_->Persist(journal_);
  FlushMetadata(parent_.get());

  RecordWindowsHelperEvent(WindowsHelperEvent::kCleanupStart);
  try {
    target_.reset();
    DeleteTreeRelative(parent_.get(), paths_.backup_name, target_identity_);
    FlushMetadata(parent_.get());
    journal_store_->Remove();
    FlushMetadata(parent_.get());
    if (terminal_callbacks_.before_completed_lock_release) {
      terminal_callbacks_.before_completed_lock_release();
    }
    ReleaseLockExact();
    if (terminal_callbacks_.after_completed_lock_release) {
      terminal_callbacks_.after_completed_lock_release();
    }
    completed_ = true;
    FlushMetadata(parent_.get());
  } catch (...) {
    RecordWindowsHelperEvent(WindowsHelperEvent::kCleanupFailure);
    throw;
  }
  RecordWindowsHelperEvent(WindowsHelperEvent::kCleanupSuccess);
  return WindowsFileTransactionResult::kCompleted;
}

void WindowsFileTransaction::CancelPrepared() {
  if (!prepared_ || !journal_persisted_ || cancelled_ || completed_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        "transaction is not a cancellable prepared transaction");
  }
  RecordWindowsHelperEvent(WindowsHelperEvent::kRollbackStart);
  try {
    ValidateParentLocator();
    ValidateStageParentLocator();
    ValidateIdentity(parent_.get(), paths_.prepared_name, stage_identity_,
                     WindowsFileTransactionError::Code::kStageIdentityChanged);
    ValidatePayload(parent_.get(), paths_.prepared_name);
    ValidateIdentity(parent_.get(), paths_.target_name, target_identity_,
                     WindowsFileTransactionError::Code::kTargetIdentityChanged);
    RenameHandleRelative(stage_.get(), stage_parent_.get(), stage_name_, false);
    FlushMetadata(stage_parent_.get());
    if (stage_parent_identity_ != parent_identity_) {
      FlushMetadata(parent_.get());
    }
    ValidateIdentity(stage_parent_.get(), stage_name_, stage_identity_,
                     WindowsFileTransactionError::Code::kStageIdentityChanged);
    ValidatePayload(stage_parent_.get(), stage_name_);
    ValidateIdentity(parent_.get(), paths_.target_name, target_identity_,
                     WindowsFileTransactionError::Code::kTargetIdentityChanged);
    journal_store_->Remove();
    FlushMetadata(parent_.get());
    if (terminal_callbacks_.before_rollback_lock_release) {
      terminal_callbacks_.before_rollback_lock_release();
    }
    ReleaseLockExact();
    if (terminal_callbacks_.after_rollback_lock_release) {
      terminal_callbacks_.after_rollback_lock_release();
    }
    journal_persisted_ = false;
    cancelled_ = true;
    FlushMetadata(parent_.get());
  } catch (...) {
    RecordWindowsHelperEvent(WindowsHelperEvent::kRollbackFailure);
    throw;
  }
  RecordWindowsHelperEvent(WindowsHelperEvent::kRollbackSuccess);
}

WindowsFileTransactionResult WindowsFileTransaction::Execute() {
  if (!prepared_) Prepare();
  return ExecutePrepared();
}

void WindowsFileTransaction::ReleaseLockExact() {
  if (!lock_.valid()) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kFilesystemOperationFailed,
        "transaction lock is unavailable for release");
  }
  DeleteHandleExact(lock_.get());
  lock_.reset();
  FlushMetadata(parent_.get());
}

void WindowsFileTransaction::FlushMetadata(HANDLE directory) const {
  FlushWindowsDirectory(directory);
  if (durability_barrier_) durability_barrier_(directory);
}

void WindowsFileTransaction::RemoveLockExactNoThrow() noexcept {
  if (!lock_.valid()) return;
  try {
    DeleteHandleExact(lock_.get());
    lock_.reset();
    if (parent_.valid()) FlushWindowsDirectory(parent_.get());
  } catch (...) {
    lock_.reset();
  }
}

std::vector<std::wstring> FindWindowsTransactionArtifacts(
    const std::filesystem::path& parent) {
  std::vector<std::wstring> result;
  std::error_code ignored;
  for (const auto& entry : std::filesystem::directory_iterator(parent, ignored)) {
    const std::wstring name = entry.path().filename().wstring();
    if (name.find(L".desktop-updater") != std::wstring::npos) {
      result.push_back(name);
    }
  }
  std::sort(result.begin(), result.end());
  return result;
}

}  // namespace desktop_updater::helper
