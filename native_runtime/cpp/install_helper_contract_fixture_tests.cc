#include <gtest/gtest.h>

#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

#include "install_helper_contract.h"
#include "json_value.h"

#ifndef DESKTOP_UPDATER_JOURNAL_FIXTURE_PATH
#error "DESKTOP_UPDATER_JOURNAL_FIXTURE_PATH must name journal-transitions.json"
#endif

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

std::string ReadJournalFixtures() {
  std::ifstream input(DESKTOP_UPDATER_JOURNAL_FIXTURE_PATH, std::ios::binary);
  if (!input) {
    throw std::runtime_error("Unable to read journal fixture file.");
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

RecoveryDecision DecisionForEntry(const JsonValue& entry) {
  const JsonValue& journal_value = entry.at("journal");
  const JournalV1 journal(
      journal_value.at("schemaVersion").integer(),
      ParseJournalMachine(journal_value.at("machine").string()),
      ParseJournalState(journal_value.at("state").string()),
      journal_value.at("ownerGeneration").integer(),
      journal_value.at("envelopeValid").boolean());
  const JsonValue& observed_value = entry.at("observed");
  const ObservedState observed(
      observed_value.at("journalDurable").boolean(),
      observed_value.at("directoryFlushSucceeded").boolean(),
      observed_value.at("ownerLive").boolean(),
      observed_value.at("observedOwnerGeneration").integer(),
      observed_value.at("siblingNamesMatch").boolean(),
      observed_value.at("observationsUnambiguous").boolean(),
      ParseIdentityObservation(observed_value.at("target").string()),
      ParseIdentityObservation(observed_value.at("prepared").string()),
      ParseIdentityObservation(observed_value.at("backup").string()),
      ParseManagerObservation(observed_value.at("manager").string()));
  return DecideRecovery(journal, observed);
}

TEST(install_helper_contract, ValidatesNormativeTransitions) {
  const JsonValue fixture = ParseJson(ReadJournalFixtures());
  for (const JsonValue& entry : fixture.at("validTransitions").array()) {
    const TransitionResult result = ValidateTransition(
        ParseJournalState(entry.at("from").string()),
        ParseJournalState(entry.at("to").string()));
    EXPECT_TRUE(result.allowed);
  }
  for (const JsonValue& entry : fixture.at("invalidTransitions").array()) {
    const TransitionResult result = ValidateTransition(
        ParseJournalState(entry.at("from").string()),
        ParseJournalState(entry.at("to").string()));
    EXPECT_FALSE(result.allowed) << entry.at("name").string();
  }
}

TEST(install_helper_contract, GeneratedRecoveryCasesMatchReferenceModel) {
  const JsonValue fixture = ParseJson(ReadJournalFixtures());
  std::size_t case_count = 0;
  for (const JsonValue& entry : fixture.at("recoveryCases").array()) {
    const RecoveryDecision decision = DecisionForEntry(entry);
    const JsonValue& expected = entry.at("expected");
    EXPECT_EQ(RecoveryOutcomeName(decision.outcome),
              expected.at("outcome").string())
        << entry.at("name").string();
    EXPECT_EQ(RecoveryActionName(decision.action),
              expected.at("action").string())
        << entry.at("name").string();
    EXPECT_EQ(decision.cleanup_authorized,
              expected.at("cleanupAuthorized").boolean())
        << entry.at("name").string();
    EXPECT_EQ(decision.reason, expected.at("reason").string())
        << entry.at("name").string();
    ++case_count;
  }
  EXPECT_GE(case_count, 28u);
}

TEST(install_helper_contract, RepeatedRecoveryIsIdempotent) {
  const JsonValue fixture = ParseJson(ReadJournalFixtures());
  std::size_t repeated_count = 0;
  for (const JsonValue& entry : fixture.at("recoveryCases").array()) {
    if (entry.at("name").string().find("repeated recovery") != 0) {
      continue;
    }
    const RecoveryDecision first = DecisionForEntry(entry);
    const RecoveryDecision second = DecisionForEntry(entry);
    EXPECT_EQ(first.outcome, second.outcome);
    EXPECT_EQ(first.action, second.action);
    EXPECT_EQ(first.cleanup_authorized, second.cleanup_authorized);
    EXPECT_EQ(first.reason, second.reason);
    ++repeated_count;
  }
  EXPECT_EQ(repeated_count, 2u);
}

TEST(install_helper_contract, ClosedCasesNeverAuthorizeCleanup) {
  const JsonValue fixture = ParseJson(ReadJournalFixtures());
  for (const JsonValue& entry : fixture.at("recoveryCases").array()) {
    const JsonValue& expected = entry.at("expected");
    if (expected.at("outcome").string() != "manualActionRequired") {
      continue;
    }
    EXPECT_FALSE(expected.at("cleanupAuthorized").boolean())
        << entry.at("name").string();
  }
}

}  // namespace
}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
