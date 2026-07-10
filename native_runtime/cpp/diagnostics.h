#ifndef DESKTOP_UPDATER_RUNTIME_DIAGNOSTICS_H_
#define DESKTOP_UPDATER_RUNTIME_DIAGNOSTICS_H_

#include <cstddef>
#include <string>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {

constexpr std::size_t kMaximumDiagnosticEntries = 80;

struct DiagnosticEntry {
  std::string timestamp;
  std::string stage;
  std::string level;
  std::string message;
  std::string error_description;
};

std::string RedactDiagnosticText(const std::string& input);
std::string RedactedDiagnosticLogLine(const DiagnosticEntry& entry);

class DiagnosticsRecorder {
 public:
  explicit DiagnosticsRecorder(
      std::size_t maximum_entries = kMaximumDiagnosticEntries);

  void Record(DiagnosticEntry entry);
  void Clear();
  const std::vector<DiagnosticEntry>& entries() const;
  std::size_t omitted_entry_count() const;
  std::vector<std::string> RedactedLogLines() const;

 private:
  std::size_t maximum_entries_;
  std::size_t omitted_entry_count_ = 0;
  std::vector<DiagnosticEntry> entries_;
};

struct HelperRecoverySummary {
  bool helper_scheduled = false;
  bool backup_succeeded = false;
  bool install_succeeded = false;
  bool rollback_attempted = false;
  bool backup_restored = false;
  bool cleanup_succeeded = false;
  bool relaunch_attempted = false;
};

const std::vector<std::string>& CanonicalHelperRecoveryEvents();
HelperRecoverySummary SummarizeHelperRecoveryEvents(
    const std::vector<std::string>& events);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_DIAGNOSTICS_H_
