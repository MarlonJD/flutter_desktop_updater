#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_INNO_RESTAGE_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_INNO_RESTAGE_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>

#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

class WindowsInnoRestageError : public std::runtime_error {
public:
  explicit WindowsInnoRestageError(const std::string &detail)
      : std::runtime_error(detail) {}
};

// Retains the installer-protected parent with only the rights required to
// create, inspect, and durably flush the exact helper-owned installer child.
UniqueWindowsHandle
OpenProtectedWindowsInnoParentDirectory(const std::filesystem::path &path);

// A helper-owned, installer-protected copy that outlives deletion of the
// caller's controller stage after commit acceptance. The exact file handle is
// retained until terminal cleanup; a process crash leaves the identity-bound
// file for persistent recovery rather than following a replaceable path.
class ProtectedWindowsInnoRestage {
public:
  struct Impl;

  ProtectedWindowsInnoRestage(ProtectedWindowsInnoRestage &&) noexcept;
  ProtectedWindowsInnoRestage &
  operator=(ProtectedWindowsInnoRestage &&) noexcept;
  ~ProtectedWindowsInnoRestage();

  ProtectedWindowsInnoRestage(const ProtectedWindowsInnoRestage &) = delete;
  ProtectedWindowsInnoRestage &
  operator=(const ProtectedWindowsInnoRestage &) = delete;

  const std::filesystem::path &path() const;
  const std::wstring &leaf() const;
  const WindowsFileIdentity &identity() const;
  HANDLE parent_handle() const;
  // Leaves the exact protected copy for the persistent recovery host if this
  // process dies. RemoveExact remains authoritative for normal completion.
  void PreserveForRecovery();
  void RemoveExact();

private:
  explicit ProtectedWindowsInnoRestage(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;

  friend ProtectedWindowsInnoRestage RestageProtectedWindowsInnoInstaller(
      const std::filesystem::path &, const std::filesystem::path &,
      const std::string &, const std::string &, std::int64_t, HANDLE);
};

ProtectedWindowsInnoRestage RestageProtectedWindowsInnoInstaller(
    const std::filesystem::path &source_installer,
    const std::filesystem::path &target_parent,
    const std::string &transaction_id, const std::string &expected_sha256,
    std::int64_t expected_length, HANDLE caller_process);

// Removes only the exact hash-, length-, signature-, ACL-, and handle-bound
// protected copy retained by a crashed transaction. Absence is idempotent.
void RemoveRecoveredProtectedWindowsInnoInstaller(
    const std::filesystem::path &installer_path,
    const std::string &expected_sha256, std::int64_t expected_length);

} // namespace desktop_updater::helper

#endif // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_INNO_RESTAGE_H_
