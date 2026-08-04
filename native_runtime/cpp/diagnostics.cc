#include "diagnostics.h"

#include <algorithm>
#include <regex>
#include <stdexcept>
#include <string>
#include <utility>

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

// Conformance fixtures: diagnostics-redaction-cases.json and
// helper-events.json. Flutter lifecycle diagnostics remain Dart-owned. This
// preview records native checks, downloads, verification, staging, and helper
// handoff evidence only.

const std::regex kAuthorizationHeaderPattern(
    R"(\b(authorization)\s*:\s*([^\r\n,;]+?)(?=\s+[A-Za-z0-9_-]*(?:token|signature|password|secret|credentials?|key)[A-Za-z0-9_-]*\s*[=:]|[\r\n,;]|$))",
    std::regex_constants::icase);
const std::regex kSecretAssignmentPattern(
    R"(\b([A-Za-z0-9_-]*(?:token|signature|password|secret|authorization|credentials?|key)[A-Za-z0-9_-]*)\s*([=:])\s*([^&\s,;]+))",
    std::regex_constants::icase);

bool Contains(const std::vector<std::string>& events,
              const std::string& value) {
  return std::find(events.begin(), events.end(), value) != events.end();
}

}  // namespace

std::string RedactDiagnosticText(const std::string& input) {
  const std::string without_authorization = std::regex_replace(
      input, kAuthorizationHeaderPattern, "$1: <redacted>");
  std::string output;
  std::size_t cursor = 0;
  for (std::sregex_iterator iterator(without_authorization.begin(),
                                     without_authorization.end(),
                                     kSecretAssignmentPattern),
       end;
       iterator != end; ++iterator) {
    const std::smatch& match = *iterator;
    const std::size_t position = static_cast<std::size_t>(match.position());
    output.append(without_authorization, cursor, position - cursor);
    output += match.str(1);
    output += match.str(2) == ":" ? ": <redacted>" : "=<redacted>";
    cursor = position + static_cast<std::size_t>(match.length());
  }
  output.append(without_authorization, cursor, std::string::npos);
  return output;
}

std::string RedactedDiagnosticLogLine(const DiagnosticEntry& entry) {
  std::string result = entry.timestamp + " " + entry.level + " " +
                       entry.stage + ": " +
                       RedactDiagnosticText(entry.message);
  if (!entry.error_description.empty()) {
    result += " Error: " + RedactDiagnosticText(entry.error_description);
  }
  return result;
}

DiagnosticsRecorder::DiagnosticsRecorder(std::size_t maximum_entries)
    : maximum_entries_(std::max<std::size_t>(1, maximum_entries)) {}

void DiagnosticsRecorder::Record(DiagnosticEntry entry) {
  if (entries_.size() == maximum_entries_) {
    entries_.erase(entries_.begin());
    ++omitted_entry_count_;
  }
  entries_.push_back(std::move(entry));
}

void DiagnosticsRecorder::Clear() {
  entries_.clear();
  omitted_entry_count_ = 0;
}

const std::vector<DiagnosticEntry>& DiagnosticsRecorder::entries() const {
  return entries_;
}

std::size_t DiagnosticsRecorder::omitted_entry_count() const {
  return omitted_entry_count_;
}

std::vector<std::string> DiagnosticsRecorder::RedactedLogLines() const {
  std::vector<std::string> result;
  result.reserve(entries_.size());
  for (const DiagnosticEntry& entry : entries_) {
    result.push_back(RedactedDiagnosticLogLine(entry));
  }
  return result;
}

const std::vector<std::string>& CanonicalHelperRecoveryEvents() {
  static const std::vector<std::string> events = {
      "helper scheduled",
      "waiting for parent process",
      "parent process exited",
      "staging path validation",
      "backup start",
      "backup success",
      "backup failure",
      "move start",
      "move success",
      "move failure",
      "rollback start",
      "rollback success",
      "rollback failure",
      "cleanup start",
      "cleanup success",
      "cleanup failure",
      "relaunch attempt",
  };
  return events;
}

HelperRecoverySummary SummarizeHelperRecoveryEvents(
    const std::vector<std::string>& events) {
  HelperRecoverySummary result;
  result.helper_scheduled = Contains(events, "helper scheduled");
  result.backup_succeeded = Contains(events, "backup success");
  result.install_succeeded = Contains(events, "move success") &&
                             !Contains(events, "move failure");
  result.rollback_attempted = Contains(events, "rollback start");
  result.backup_restored = Contains(events, "rollback success");
  result.cleanup_succeeded = Contains(events, "cleanup success");
  result.relaunch_attempted = Contains(events, "relaunch attempt");
  return result;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
