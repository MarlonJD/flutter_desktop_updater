#include "windows_recovery_service.h"

#include <winternl.h>

#include <utility>

namespace desktop_updater::helper {
namespace {

constexpr char manualActionRequired[] = "manualActionRequired";
constexpr char backupIdentityMismatch[] = "backupIdentityMismatch";
constexpr char stageProvenanceSha256[] = "stageProvenanceSha256";
constexpr char artifactSha256[] = "artifactSha256";
constexpr char authenticodePublisher[] = "authenticodePublisher";

UniqueWindowsHandle OpenRecoveryParent(const std::filesystem::path& path) {
  HANDLE handle = CreateFileW(
      path.c_str(), GENERIC_READ | GENERIC_WRITE | FILE_TRAVERSE | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "recovery parent unavailable");
  }
  UniqueWindowsHandle result(handle);
  const auto identity = ReadWindowsFileIdentity(result.get());
  if (!identity.directory ||
      (identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kReparsePoint,
        "recovery parent is not authoritative");
  }
  return result;
}

}  // namespace

bool Win32ProcessLivenessChecker::IsSameProcessAlive(
    DWORD process_id,
    std::uint64_t start_identity) {
  try {
    return WindowsProcessStartIdentity(process_id) == start_identity;
  } catch (const std::exception&) {
    return false;
  }
}

WindowsRecoveryService::WindowsRecoveryService(
    const std::filesystem::path& target_path,
    std::string transaction_id,
    WindowsVerifiedPayloadIdentity expected_payload_identity,
    WindowsInstallPayloadVerifier& verifier,
    WindowsProcessLivenessChecker& liveness_checker)
    : target_path_(std::filesystem::absolute(target_path).lexically_normal()),
      parent_path_(target_path_.parent_path()),
      paths_(WindowsTransactionPaths::Create(target_path_.filename().wstring(),
                                             transaction_id)),
      expected_payload_identity_(std::move(expected_payload_identity)),
      verifier_(verifier),
      liveness_checker_(liveness_checker) {}

WindowsRecoveryOutcome WindowsRecoveryService::Recover() {
  try {
    auto parent = OpenRecoveryParent(parent_path_);
    const bool journal_exists =
        ExistsRelativeNoReparse(parent.get(), paths_.journal_name);
    const bool next_exists =
        ExistsRelativeNoReparse(parent.get(), paths_.journal_next_name);

    UniqueWindowsHandle ownership_lock;
    try {
      ownership_lock = OpenRelativeNoReparse(
          parent.get(), paths_.lock_name,
          GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE, 0, FILE_OPEN,
          FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
    } catch (const WindowsTransactionJournalError& error) {
      if (error.code() ==
          WindowsTransactionJournalError::Code::kSharingViolation) {
        return WindowsRecoveryOutcome::kLiveOwner;
      }
      const DWORD open_error = GetLastError();
      if (!journal_exists && !next_exists &&
          (open_error == ERROR_FILE_NOT_FOUND ||
           open_error == ERROR_PATH_NOT_FOUND)) {
        return WindowsRecoveryOutcome::kNothingToRecover;
      }
      return WindowsRecoveryOutcome::kManualActionRequired;
    }
    if (next_exists || !journal_exists) {
      return WindowsRecoveryOutcome::kManualActionRequired;
    }

    DurableWindowsTransactionJournalStore store(parent.get(), paths_);
    const auto loaded = store.Load();
    if (!loaded.has_value()) {
      return WindowsRecoveryOutcome::kManualActionRequired;
    }
    if (liveness_checker_.IsSameProcessAlive(
            loaded->owner_process_id,
            loaded->owner_process_start_identity)) {
      return WindowsRecoveryOutcome::kLiveOwner;
    }
    return RecoverOwned(parent.get(), ownership_lock, store, *loaded);
  } catch (const std::exception&) {
    (void)manualActionRequired;
    return WindowsRecoveryOutcome::kManualActionRequired;
  }
}

WindowsFileIdentity WindowsRecoveryService::Identity(
    HANDLE parent,
    const std::wstring& name) const {
  auto handle = OpenRelativeNoReparse(
      parent, name, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  return ReadWindowsFileIdentity(handle.get());
}

bool WindowsRecoveryService::VerifyPayload(
    HANDLE parent,
    const std::wstring& name) const {
  try {
    const auto identity = verifier_.Verify(parent, name);
    return identity == expected_payload_identity_ &&
           !identity.package_id.empty() &&
           !identity.authenticode_publisher.empty() &&
           !identity.package_identity_sha256.empty() &&
           !identity.stage_provenance_sha256.empty() &&
           !identity.artifact_sha256.empty() &&
           !identity.executable_relative_path.empty() &&
           !identity.executable_sha256.empty();
  } catch (const std::exception&) {
    return false;
  }
}

void WindowsRecoveryService::RecoveryRename(
    HANDLE parent,
    const std::wstring& source,
    const std::wstring& destination) const {
  auto object = OpenRelativeNoReparse(
      parent, source, DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES |
                          SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  RenameHandleRelative(object.get(), parent, destination, false);
  FlushWindowsDirectory(parent);
}

WindowsRecoveryOutcome WindowsRecoveryService::RecoverOwned(
    HANDLE parent,
    UniqueWindowsHandle& ownership_lock,
    DurableWindowsTransactionJournalStore& store,
    WindowsTransactionJournal journal) {
  try {
    if (journal.schema_version != WindowsTransactionJournal::kSchemaVersion ||
        journal.transaction_id != paths_.transaction_id ||
        journal.target_name != paths_.target_name ||
        journal.prepared_name != paths_.prepared_name ||
        journal.backup_name != paths_.backup_name ||
        journal.lock_name != paths_.lock_name ||
        journal.expected_payload_identity != expected_payload_identity_ ||
        ReadWindowsFileIdentity(parent) != journal.parent_identity ||
        journal.state == WindowsTransactionState::kManualActionRequired) {
      return WindowsRecoveryOutcome::kManualActionRequired;
    }

    auto stage_parent = OpenRecoveryParent(
        std::filesystem::path(journal.original_stage_parent_path));
    if (ReadWindowsFileIdentity(stage_parent.get()) !=
        journal.stage_parent_identity) {
      return WindowsRecoveryOutcome::kManualActionRequired;
    }
    bool target_exists = ExistsRelativeNoReparse(parent, paths_.target_name);
    bool stage_exists = ExistsRelativeNoReparse(
        stage_parent.get(), journal.original_stage_name);
    bool prepared_exists =
        ExistsRelativeNoReparse(parent, paths_.prepared_name);
    bool backup_exists = ExistsRelativeNoReparse(parent, paths_.backup_name);

    if ((stage_exists && prepared_exists) ||
        (target_exists && backup_exists && prepared_exists)) {
      return WindowsRecoveryOutcome::kManualActionRequired;
    }
    const bool observations_match_state = [&]() {
      switch (journal.state) {
        case WindowsTransactionState::kPrepared:
          return !backup_exists || (!target_exists && prepared_exists);
        case WindowsTransactionState::kBackupCreated:
          return backup_exists && !stage_exists &&
                 ((prepared_exists && !target_exists) ||
                  (!prepared_exists && target_exists));
        case WindowsTransactionState::kTargetActivated:
          return backup_exists && target_exists && !stage_exists &&
                 !prepared_exists;
        case WindowsTransactionState::kCompleted:
          return target_exists && !stage_exists && !prepared_exists;
        case WindowsTransactionState::kManualActionRequired:
          return false;
      }
      return false;
    }();
    if (!observations_match_state) {
      return WindowsRecoveryOutcome::kManualActionRequired;
    }
    if (backup_exists && Identity(parent, paths_.backup_name) !=
                             journal.target_identity) {
      (void)backupIdentityMismatch;
      return WindowsRecoveryOutcome::kManualActionRequired;
    }

    if (!prepared_exists && stage_exists) {
      if (Identity(stage_parent.get(), journal.original_stage_name) !=
              journal.stage_identity ||
          !VerifyPayload(stage_parent.get(), journal.original_stage_name)) {
        return WindowsRecoveryOutcome::kManualActionRequired;
      }
      auto stage = OpenRelativeNoReparse(
          stage_parent.get(), journal.original_stage_name,
          DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
          FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
      RenameHandleRelative(stage.get(), parent, paths_.prepared_name, false);
      FlushWindowsDirectory(stage_parent.get());
      FlushWindowsDirectory(parent);
      stage_exists = false;
      prepared_exists = true;
    }

    if (!backup_exists && prepared_exists) {
      if (!target_exists ||
          Identity(parent, paths_.target_name) != journal.target_identity) {
        return WindowsRecoveryOutcome::kManualActionRequired;
      }
      RecoveryRename(parent, paths_.target_name, paths_.backup_name);
      target_exists = false;
      backup_exists = true;
      journal.state = WindowsTransactionState::kBackupCreated;
      store.Persist(journal);
    }

    if (backup_exists && prepared_exists && !target_exists) {
      if (Identity(parent, paths_.prepared_name) != journal.stage_identity ||
          !VerifyPayload(parent, paths_.prepared_name)) {
        return WindowsRecoveryOutcome::kManualActionRequired;
      }
      RecoveryRename(parent, paths_.prepared_name, paths_.target_name);
      prepared_exists = false;
      target_exists = true;
      journal.state = WindowsTransactionState::kTargetActivated;
      store.Persist(journal);
    }

    if (!target_exists || prepared_exists || stage_exists ||
        Identity(parent, paths_.target_name) != journal.stage_identity ||
        !VerifyPayload(parent, paths_.target_name)) {
      return WindowsRecoveryOutcome::kManualActionRequired;
    }

    if (backup_exists) {
      if (Identity(parent, paths_.backup_name) != journal.target_identity) {
        return WindowsRecoveryOutcome::kManualActionRequired;
      }
      journal.state = WindowsTransactionState::kTargetActivated;
      store.Persist(journal);
      journal.state = WindowsTransactionState::kCompleted;
      store.Persist(journal);
      // Backup deletion is authorized only after the activated payload's
      // package identity, executable proof, stageProvenanceSha256,
      // artifactSha256, and authenticodePublisher all matched above.
      DeleteTreeRelative(parent, paths_.backup_name, journal.target_identity);
    }
    store.Remove();
    DeleteHandleExact(ownership_lock.get());
    ownership_lock.reset();
    FlushWindowsDirectory(parent);
    return WindowsRecoveryOutcome::kRecovered;
  } catch (const std::exception&) {
    return WindowsRecoveryOutcome::kManualActionRequired;
  }
}

}  // namespace desktop_updater::helper
