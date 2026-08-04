#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_ARCHIVE_RESTAGE_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_ARCHIVE_RESTAGE_H_

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "stage_provenance.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

enum class WindowsArchiveRestageAuthority {
  kInstallerProtected,
  kPortableExactCaller,
};

struct WindowsArchiveRestageLimits {
  std::int64_t maximum_archive_entries = 100000;
  std::int64_t maximum_uncompressed_bytes = INT64_C(8) * 1024 * 1024 * 1024;
  std::int64_t maximum_single_entry_bytes =
      INT64_C(4) * 1024 * 1024 * 1024;
  std::size_t maximum_payload_path_bytes = 64 * 1024 * 1024;
  std::size_t maximum_payload_seal_bytes = 64 * 1024 * 1024;
  std::size_t maximum_recovery_depth = 256;
  std::size_t maximum_recovery_work_units = 1000000;
};

enum class WindowsArchiveRestageFaultPoint {
  kAfterControlFileCreate,
  kAfterControlFileFlushBeforeRename,
  kAfterControlRenameBeforeDirectoryFlush,
  kAfterArchiveFileCreate,
  kDuringArchiveCopy,
  kAfterArchiveCopyBeforePreflight,
  kAfterPayloadRootDirectoryCreate,
  kAfterPayloadDirectoryCreate,
  kAfterPayloadFileCreate,
  kDuringExtraction,
  kBeforePayloadSeal,
  kAfterExtractionBeforeTransactionJournal,
  kDuringPostJournalControlCleanup,
};

class WindowsArchiveRestageFaultInjector {
 public:
  virtual ~WindowsArchiveRestageFaultInjector() = default;
  virtual void Hit(WindowsArchiveRestageFaultPoint point) = 0;
};

struct WindowsPayloadSeal {
  std::vector<desktop_updater::runtime::internal::StageProvenanceEntry>
      entries;
  std::string sha256;
};

class WindowsArchiveRestageError : public std::runtime_error {
 public:
  explicit WindowsArchiveRestageError(const std::string& detail)
      : std::runtime_error(detail) {}
};

class WindowsVerifiedArchiveRestage {
 public:
  struct Impl;

  WindowsVerifiedArchiveRestage(WindowsVerifiedArchiveRestage&&) noexcept;
  WindowsVerifiedArchiveRestage& operator=(
      WindowsVerifiedArchiveRestage&&) noexcept;
  ~WindowsVerifiedArchiveRestage();

  WindowsVerifiedArchiveRestage(
      const WindowsVerifiedArchiveRestage&) = delete;
  WindowsVerifiedArchiveRestage& operator=(
      const WindowsVerifiedArchiveRestage&) = delete;

  const std::filesystem::path& path() const;
  const desktop_updater::runtime::internal::StageProvenanceMarker&
  provenance() const;
  const std::string& payload_seal_sha256() const;
  HANDLE parent_handle() const;
  HANDLE root_handle() const;
  void ReleaseToTransaction();

 private:
  explicit WindowsVerifiedArchiveRestage(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;

  friend WindowsVerifiedArchiveRestage RestageVerifiedWindowsZip(
      const std::filesystem::path&,
      const std::filesystem::path&,
      const std::string&,
      const std::string&,
      const std::string&,
      const std::string&,
      std::int64_t,
      const std::string&,
      WindowsArchiveRestageAuthority,
      HANDLE,
      const WindowsArchiveRestageLimits&,
      WindowsArchiveRestageFaultInjector*);
};

WindowsVerifiedArchiveRestage RestageVerifiedWindowsZip(
    const std::filesystem::path& caller_stage,
    const std::filesystem::path& target_parent,
    const std::string& transaction_id,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    std::int64_t artifact_length,
    const std::string& canonical_release_manifest,
    WindowsArchiveRestageAuthority authority,
    HANDLE caller_process,
    const WindowsArchiveRestageLimits& limits = {},
    WindowsArchiveRestageFaultInjector* fault_injector = nullptr);

WindowsPayloadSeal SealWindowsPayloadTree(
    HANDLE parent,
    const std::wstring& bundle_leaf,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    std::vector<UniqueWindowsHandle>* retained_handles);

void VerifyWindowsArchiveRestageSecurity(
    HANDLE object,
    WindowsArchiveRestageAuthority authority,
    HANDLE caller_process);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_ARCHIVE_RESTAGE_H_
