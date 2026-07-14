#include "windows_file_transaction.h"

#include <winternl.h>

#include <algorithm>
#include <cwctype>
#include <utility>

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

std::wstring NormalizePath(std::wstring value) {
  std::replace(value.begin(), value.end(), L'/', L'\\');
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  while (value.size() > 3 && value.back() == L'\\') value.pop_back();
  return value;
}

void ThrowFilesystem(const char* detail) {
  const DWORD error = GetLastError();
  const auto code = error == ERROR_SHARING_VIOLATION ||
                            error == ERROR_LOCK_VIOLATION
                        ? WindowsFileTransactionError::Code::kSharingViolation
                        : WindowsFileTransactionError::Code::kFilesystemOperationFailed;
  throw WindowsFileTransactionError(code, detail);
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
  FILETIME creation{};
  FILETIME exit{};
  FILETIME kernel{};
  FILETIME user{};
  if (!GetProcessTimes(process.get(), &creation, &exit, &kernel, &user)) {
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
    WindowsTransactionFaultInjector* fault_injector)
    : parent_locator_(
          std::filesystem::absolute(target_path.parent_path()).lexically_normal()),
      stage_name_(stage_path.filename().wstring()),
      paths_(WindowsTransactionPaths::Create(target_path.filename().wstring(),
                                             transaction_id)),
      owner_process_id_(owner_process_id),
      owner_process_start_identity_(WindowsProcessStartIdentity(owner_process_id)),
      expected_payload_identity_(std::move(expected_payload_identity)),
      verifier_(verifier),
      fault_injector_(fault_injector == nullptr ? &no_faults_
                                               : fault_injector),
      parent_(OpenAbsoluteDirectoryNoReparse(parent_locator_)) {
  const auto stage_parent =
      std::filesystem::absolute(stage_path.parent_path()).lexically_normal();
  if (NormalizePath(stage_parent.wstring()) !=
          NormalizePath(parent_locator_.wstring()) ||
      stage_name_.empty() || stage_name_ == paths_.target_name ||
      stage_name_.find_first_of(L"\\/:*?\"<>|") != std::wstring::npos) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kInvalidPathOrTransaction,
        alternateDataStreamRejected);
  }
  parent_identity_ = ReadWindowsFileIdentity(parent_.get());
  target_ = OpenRelativeNoReparse(
      parent_.get(), paths_.target_name,
      DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  stage_ = OpenRelativeNoReparse(
      parent_.get(), stage_name_,
      DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  target_identity_ = ReadWindowsFileIdentity(target_.get());
  stage_identity_ = ReadWindowsFileIdentity(stage_.get());
  ValidateSameVolume(target_identity_.volume_serial,
                     stage_identity_.volume_serial);
  ValidatePayload(stage_name_);

  for (const std::wstring& name : {
           paths_.prepared_name,
           paths_.backup_name,
           paths_.journal_name,
           paths_.journal_next_name,
       }) {
    if (ExistsRelativeNoReparse(parent_.get(), name)) {
      throw WindowsFileTransactionError(
          WindowsFileTransactionError::Code::kDerivedArtifactAlreadyExists,
          "derived transaction artifact already exists");
    }
  }
  try {
    lock_ = OpenRelativeNoReparse(
        parent_.get(), paths_.lock_name,
        GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE, 0, FILE_CREATE,
        FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
            FILE_WRITE_THROUGH,
        FILE_ATTRIBUTE_HIDDEN);
  } catch (const WindowsTransactionJournalError&) {
    ThrowFilesystem("exclusive target lock acquisition failed");
  }
  journal_store_ = std::make_unique<DurableWindowsTransactionJournalStore>(
      parent_.get(), paths_, fault_injector_);
}

WindowsFileTransaction::~WindowsFileTransaction() {
  if (!journal_persisted_ || completed_) RemoveLockExact();
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

void WindowsFileTransaction::ValidateParentLocator() const {
  auto observed = OpenAbsoluteDirectoryNoReparse(parent_locator_);
  if (ReadWindowsFileIdentity(observed.get()) != parent_identity_) {
    throw WindowsFileTransactionError(
        WindowsFileTransactionError::Code::kTargetParentChanged,
        "target parent path identity changed");
  }
}

void WindowsFileTransaction::ValidateIdentity(
    const std::wstring& name,
    const WindowsFileIdentity& expected,
    WindowsFileTransactionError::Code error) const {
  try {
    auto observed = OpenRelativeNoReparse(
        parent_.get(), name, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES |
                                 SYNCHRONIZE,
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

void WindowsFileTransaction::ValidatePayload(const std::wstring& name) const {
  try {
    if (verifier_.Verify(parent_.get(), name) != expected_payload_identity_) {
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
    FlushWindowsDirectory(parent_.get());
    fault_injector_->Hit(after);
  } catch (const WindowsFileTransactionError&) {
    throw;
  } catch (const std::exception&) {
    ThrowFilesystem("handle-relative durable rename failed");
  }
}

WindowsFileTransactionResult WindowsFileTransaction::Execute() {
  ValidateParentLocator();
  ValidateIdentity(stage_name_, stage_identity_,
                   WindowsFileTransactionError::Code::kStageIdentityChanged);
  ValidatePayload(stage_name_);
  ValidateIdentity(paths_.target_name, target_identity_,
                   WindowsFileTransactionError::Code::kTargetIdentityChanged);

  WindowsTransactionJournal journal;
  journal.transaction_id = paths_.transaction_id;
  journal.owner_process_id = owner_process_id_;
  journal.owner_process_start_identity = owner_process_start_identity_;
  journal.target_name = paths_.target_name;
  journal.original_stage_name = stage_name_;
  journal.prepared_name = paths_.prepared_name;
  journal.backup_name = paths_.backup_name;
  journal.lock_name = paths_.lock_name;
  journal.parent_identity = parent_identity_;
  journal.target_identity = target_identity_;
  journal.stage_identity = stage_identity_;
  journal.expected_payload_identity = expected_payload_identity_;
  journal.state = WindowsTransactionState::kPrepared;
  journal_store_->Persist(journal);
  journal_persisted_ = true;

  ValidateIdentity(stage_name_, stage_identity_,
                   WindowsFileTransactionError::Code::kStageIdentityChanged);
  ValidatePayload(stage_name_);
  DurableRename(stage_.get(), paths_.prepared_name,
                WindowsTransactionFaultPoint::kBeforeStageRename,
                WindowsTransactionFaultPoint::kAfterStageRenameBeforeDirectoryFlush,
                WindowsTransactionFaultPoint::kAfterStageRename);

  ValidateParentLocator();
  ValidateIdentity(paths_.target_name, target_identity_,
                   WindowsFileTransactionError::Code::kTargetIdentityChanged);
  DurableRename(target_.get(), paths_.backup_name,
                WindowsTransactionFaultPoint::kBeforeBackupRename,
                WindowsTransactionFaultPoint::kAfterBackupRenameBeforeDirectoryFlush,
                WindowsTransactionFaultPoint::kAfterBackupRename);
  journal.state = WindowsTransactionState::kBackupCreated;
  journal_store_->Persist(journal);

  ValidateIdentity(paths_.prepared_name, stage_identity_,
                   WindowsFileTransactionError::Code::kStageIdentityChanged);
  ValidatePayload(paths_.prepared_name);
  DurableRename(stage_.get(), paths_.target_name,
                WindowsTransactionFaultPoint::kBeforeActivationRename,
                WindowsTransactionFaultPoint::kAfterActivationRenameBeforeDirectoryFlush,
                WindowsTransactionFaultPoint::kAfterActivationRename);
  journal.state = WindowsTransactionState::kTargetActivated;
  journal_store_->Persist(journal);

  ValidateIdentity(paths_.target_name, stage_identity_,
                   WindowsFileTransactionError::Code::kStageIdentityChanged);
  ValidatePayload(paths_.target_name);
  journal.state = WindowsTransactionState::kCompleted;
  journal_store_->Persist(journal);

  target_.reset();
  DeleteTreeRelative(parent_.get(), paths_.backup_name, target_identity_);
  journal_store_->Remove();
  completed_ = true;
  RemoveLockExact();
  FlushWindowsDirectory(parent_.get());
  return WindowsFileTransactionResult::kCompleted;
}

void WindowsFileTransaction::RemoveLockExact() noexcept {
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
