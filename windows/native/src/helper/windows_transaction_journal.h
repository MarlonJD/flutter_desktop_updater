#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_TRANSACTION_JOURNAL_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_TRANSACTION_JOURNAL_H_

#include <windows.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace desktop_updater::helper {

enum class WindowsTransactionState {
  kPrepared,
  kBackupCreated,
  kTargetActivated,
  kCompleted,
  kManualActionRequired,
};

enum class WindowsTransactionFaultPoint {
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
  kFileFlushFailure,
  kDirectoryFlushFailure,
};

std::vector<WindowsTransactionFaultPoint>
WindowsTransactionCrashInjectionPoints();

class WindowsTransactionFaultInjector {
 public:
  virtual ~WindowsTransactionFaultInjector() = default;
  virtual void Hit(WindowsTransactionFaultPoint point) = 0;
};

class NoWindowsTransactionFaultInjector final
    : public WindowsTransactionFaultInjector {
 public:
  void Hit(WindowsTransactionFaultPoint) override {}
};

class WindowsTransactionJournalError : public std::runtime_error {
 public:
  enum class Code {
    kInvalidJournal,
    kPersistenceFailed,
    kReparsePoint,
    kSharingViolation,
  };

  WindowsTransactionJournalError(Code code, const std::string& detail)
      : std::runtime_error(detail), code_(code) {}
  Code code() const noexcept { return code_; }

 private:
  Code code_;
};

class UniqueWindowsHandle {
 public:
  explicit UniqueWindowsHandle(HANDLE handle = INVALID_HANDLE_VALUE)
      : handle_(handle) {}
  ~UniqueWindowsHandle();
  UniqueWindowsHandle(const UniqueWindowsHandle&) = delete;
  UniqueWindowsHandle& operator=(const UniqueWindowsHandle&) = delete;
  UniqueWindowsHandle(UniqueWindowsHandle&& other) noexcept;
  UniqueWindowsHandle& operator=(UniqueWindowsHandle&& other) noexcept;

  HANDLE get() const { return handle_; }
  bool valid() const {
    return handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE;
  }
  HANDLE release();
  void reset(HANDLE handle = INVALID_HANDLE_VALUE);

 private:
  HANDLE handle_;
};

struct WindowsFileIdentity {
  std::uint64_t volume_serial = 0;
  std::array<unsigned char, 16> file_id{};
  DWORD attributes = 0;
  DWORD number_of_links = 0;
  bool directory = false;

  bool operator==(const WindowsFileIdentity& other) const;
  bool operator!=(const WindowsFileIdentity& other) const {
    return !(*this == other);
  }
};

struct WindowsVerifiedPayloadIdentity {
  std::string package_id;
  std::string authenticode_publisher;
  std::string package_identity_sha256;
  std::string stage_provenance_sha256;
  std::string artifact_sha256;
  std::wstring executable_relative_path;
  std::string executable_sha256;

  bool operator==(const WindowsVerifiedPayloadIdentity& other) const;
  bool operator!=(const WindowsVerifiedPayloadIdentity& other) const {
    return !(*this == other);
  }
};

struct WindowsTransactionPaths {
  std::wstring target_name;
  std::string transaction_id;
  std::wstring prepared_name;
  std::wstring backup_name;
  std::wstring journal_name;
  std::wstring journal_next_name;
  std::wstring lock_name;

  static WindowsTransactionPaths Create(const std::wstring& target_name,
                                        const std::string& transaction_id);
};

struct WindowsTransactionJournal {
  static constexpr std::int64_t kSchemaVersion = 1;

  std::int64_t schema_version = kSchemaVersion;
  std::string transaction_id;
  DWORD owner_process_id = 0;
  std::uint64_t owner_process_start_identity = 0;
  std::wstring target_name;
  std::wstring original_stage_parent_path;
  std::wstring original_stage_name;
  std::wstring prepared_name;
  std::wstring backup_name;
  std::wstring lock_name;
  WindowsFileIdentity parent_identity;
  WindowsFileIdentity stage_parent_identity;
  WindowsFileIdentity target_identity;
  WindowsFileIdentity stage_identity;
  WindowsVerifiedPayloadIdentity expected_payload_identity;
  WindowsTransactionState state = WindowsTransactionState::kPrepared;

  std::string EncodeCanonical() const;
  static WindowsTransactionJournal DecodeStrict(const std::string& json);
};

UniqueWindowsHandle OpenRelativeNoReparse(
    HANDLE RootDirectory,
    const std::wstring& relative_path,
    ACCESS_MASK desired_access,
    ULONG share_access,
    ULONG create_disposition,
    ULONG create_options,
    ULONG file_attributes = FILE_ATTRIBUTE_NORMAL);

WindowsFileIdentity ReadWindowsFileIdentity(HANDLE handle);
void ValidateWindowsLinkCount(bool directory, DWORD NumberOfLinks);
bool ExistsRelativeNoReparse(HANDLE parent, const std::wstring& relative_path);
std::string ReadUtf8FileRelative(HANDLE parent,
                                 const std::wstring& relative_path,
                                 std::size_t maximum_bytes);
void RenameHandleRelative(HANDLE source,
                          HANDLE RootDirectory,
                          const std::wstring& destination,
                          bool replace_existing);
void DeleteHandleExact(HANDLE handle);
void DeleteTreeRelative(HANDLE parent,
                        const std::wstring& leaf,
                        const WindowsFileIdentity& expected_identity);
void FlushWindowsDirectory(HANDLE directory);

class DurableWindowsTransactionJournalStore {
 public:
  DurableWindowsTransactionJournalStore(
      HANDLE parent,
      WindowsTransactionPaths paths,
      WindowsTransactionFaultInjector* fault_injector = nullptr);

  std::optional<WindowsTransactionJournal> Load() const;
  void Persist(const WindowsTransactionJournal& journal);
  void Remove();

 private:
  std::pair<WindowsTransactionFaultPoint, WindowsTransactionFaultPoint>
  FaultPoints(WindowsTransactionState state) const;

  HANDLE parent_;
  WindowsTransactionPaths paths_;
  NoWindowsTransactionFaultInjector no_faults_;
  WindowsTransactionFaultInjector* fault_injector_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_TRANSACTION_JOURNAL_H_
