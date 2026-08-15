#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_INNO_TRANSACTION_JOURNAL_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_INNO_TRANSACTION_JOURNAL_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>

#include "windows_inno_policy.h"

namespace desktop_updater::helper {

class WindowsInnoTransactionJournalError : public std::runtime_error {
 public:
  explicit WindowsInnoTransactionJournalError(const std::string& detail)
      : std::runtime_error(detail) {}
};

// Immutable, signed-input-derived authority for one protected Inno handoff.
// Mutable execution state belongs to the installer-protected persistent index;
// this journal is the reservation digest returned to the application.
struct ProtectedWindowsInnoJournal {
  static constexpr std::int64_t kSchemaVersion = 1;

  std::int64_t schema_version = kSchemaVersion;
  std::string transaction_id;
  std::string package_id;
  std::filesystem::path target_path;
  std::wstring installer_leaf;
  std::string installer_sha256;
  std::int64_t installer_length = 0;
  std::string descriptor_sha256;
  std::string provenance_sha256;
  std::string current_version;
  std::int64_t current_build_number = 0;
  std::string current_executable_sha256;
  std::string desired_version;
  std::int64_t desired_build_number = 0;
  ProtectedWindowsInnoExecutionPolicy execution;
  DWORD owner_process_id = 0;
  std::uint64_t owner_process_start_identity = 0;

  std::string EncodeCanonical() const;
  static ProtectedWindowsInnoJournal DecodeStrict(
      const std::string& canonical_json);
  ProtectedWindowsInnoExpectation BuildExpectation() const;
};

enum class ProtectedWindowsInnoRecoveryDecision {
  kRecoveryRequired,
  kCompleted,
  kRolledBack,
  kManualActionRequired,
};

ProtectedWindowsInnoRecoveryDecision DecideProtectedWindowsInnoRecovery(
    bool exact_owner_alive,
    bool desired_install_verified,
    bool old_install_verified);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_INNO_TRANSACTION_JOURNAL_H_
