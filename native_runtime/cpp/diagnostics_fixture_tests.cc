#include "diagnostics_fixture_tests.h"

#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

#include "diagnostics.h"
#include "json_value.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

JsonValue ReadFixture(const std::string& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("Diagnostics fixture is missing.");
  return ParseJson(std::string(std::istreambuf_iterator<char>(input),
                               std::istreambuf_iterator<char>()));
}

}  // namespace

void RunDiagnosticsFixtureTests(const std::string& fixture_root) {
  const JsonValue diagnostics = ReadFixture(
      fixture_root + "/diagnostics-redaction-cases.json");
  for (const JsonValue& value : diagnostics.at("cases").array()) {
    const JsonValue* error = value.find("error");
    DiagnosticEntry entry{
        value.at("timestamp").string(),
        value.at("stage").string(),
        value.at("level").string(),
        value.at("message").string(),
        error == nullptr || error->type() == JsonValue::Type::kNull
            ? ""
            : "FormatException: " + error->string(),
    };
    if (RedactedDiagnosticLogLine(entry) !=
        value.at("expectedLogLine").string()) {
      throw std::runtime_error(
          "Native diagnostic redaction differs from Dart.");
    }
  }

  DiagnosticsRecorder recorder;
  for (int index = 0; index < 82; ++index) {
    recorder.Record({"2026-07-10T12:00:00.000Z", "download", "info",
                     "entry " + std::to_string(index), ""});
  }
  if (recorder.entries().size() != kMaximumDiagnosticEntries ||
      recorder.entries().front().message != "entry 2" ||
      recorder.entries().back().message != "entry 81" ||
      recorder.omitted_entry_count() != 2) {
    throw std::runtime_error("Native diagnostics count bound differs from Dart.");
  }
  const std::string private_key =
      RedactDiagnosticText("privateKeyMaterial=value access_token=secret");
  if (private_key.find("value") != std::string::npos ||
      private_key.find("secret") != std::string::npos) {
    throw std::runtime_error("Native diagnostics retained private key material.");
  }

  const JsonValue helper = ReadFixture(fixture_root + "/helper-events.json");
  std::vector<std::string> expected;
  for (const JsonValue& value : helper.at("events").array()) {
    expected.push_back(value.string());
  }
  if (expected != CanonicalHelperRecoveryEvents()) {
    throw std::runtime_error("Native helper recovery events differ from Dart.");
  }
  const HelperRecoverySummary success = SummarizeHelperRecoveryEvents(
      {"helper scheduled", "backup success", "move success",
       "cleanup success", "relaunch attempt"});
  if (!success.install_succeeded || !success.cleanup_succeeded ||
      success.rollback_attempted || !success.relaunch_attempted) {
    throw std::runtime_error("Native helper success summary is invalid.");
  }
  const HelperRecoverySummary failure = SummarizeHelperRecoveryEvents(
      {"backup success", "move failure", "rollback start",
       "rollback success"});
  if (failure.install_succeeded || !failure.rollback_attempted ||
      !failure.backup_restored) {
    throw std::runtime_error("Native helper rollback summary is invalid.");
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
