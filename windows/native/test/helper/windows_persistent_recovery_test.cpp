#include "windows_persistent_recovery.h"

#include <gtest/gtest.h>

#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include "helper_authenticode.h"
#include "windows_helper_bootstrap.h"
#include "windows_inno_transaction_journal.h"
#include "windows_portable_transaction_index.h"
#include "windows_recovery_transport.h"

namespace desktop_updater::helper {
namespace {

std::string FrozenPersistentRecordBytes() {
  const std::filesystem::path path =
      std::filesystem::path(DESKTOP_UPDATER_DURABLE_STATE_FIXTURE_DIRECTORY) /
      "persistent-record-schema3.json";
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    throw std::runtime_error("could not read frozen persistent record");
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

WindowsPersistentRecoveryRequestV1 Request() {
  return {
      "queryTransaction",
      1,
      "com.example.desktop-updater.privileged",
      "com.example.app",
      "00000000-0000-4000-8000-000000000025",
      "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
  };
}

WindowsPersistentTransactionRecord
Record(const std::string &state, const std::string &outcome,
       const std::string &relaunch_state = "notRequested") {
  const std::string transaction_id = "00000000-0000-4000-8000-000000000025";
  const WindowsTransactionPaths paths =
      WindowsTransactionPaths::Create(L"Example.app", transaction_id);
  WindowsFileIdentity parent;
  parent.volume_serial = 7;
  parent.file_id.fill(1);
  parent.attributes = FILE_ATTRIBUTE_DIRECTORY;
  parent.number_of_links = 1;
  parent.directory = true;
  WindowsFileIdentity target = parent;
  target.file_id.fill(2);
  WindowsFileIdentity stage_parent = parent;
  stage_parent.file_id.fill(3);
  WindowsFileIdentity stage = parent;
  stage.file_id.fill(4);

  WindowsTransactionJournal journal;
  journal.transaction_id = transaction_id;
  journal.owner_process_id = 42;
  journal.owner_process_start_identity = 43;
  journal.target_name = paths.target_name;
  journal.original_stage_parent_path = L"C:\\ProgramData\\Example\\Stage";
  journal.original_stage_name = L"Stage.app";
  journal.prepared_name = paths.prepared_name;
  journal.backup_name = paths.backup_name;
  journal.lock_name = paths.lock_name;
  journal.parent_identity = parent;
  journal.stage_parent_identity = stage_parent;
  journal.target_identity = target;
  journal.stage_identity = stage;
  journal.expected_payload_identity = {
      "com.example.app",    "Example Software LLC", std::string(64, 'a'),
      std::string(64, 'b'), std::string(64, 'c'),   L"bin\\example.exe",
      std::string(64, 'd'), std::string(64, 'e')};
  journal.state = WindowsTransactionState::kPrepared;
  const std::string canonical = journal.EncodeCanonical();
  return {WindowsPersistentTransactionRecord::kSchemaVersion,
          transaction_id,
          "directoryReplace",
          "com.example.desktop-updater.privileged",
          "com.example.app",
          std::string(64, 'e'),
          42,
          43,
          44,
          45,
          std::string(43, 'A'),
          std::filesystem::path(L"C:\\Program Files\\Example.app"),
          state,
          outcome,
          relaunch_state,
          canonical,
          WindowsHelperSha256Hex(canonical)};
}

WindowsPersistentTransactionRecord
InnoRecord(bool relaunch_after_install, const std::string &state = "prepared",
           const std::string &outcome = "none",
           const std::string &relaunch_state = "notRequested") {
  const std::string transaction_id = "00000000-0000-4000-8000-000000000025";
  ProtectedWindowsInnoJournal journal;
  journal.transaction_id = transaction_id;
  journal.package_id = "com.example.app";
  journal.target_path = L"C:\\Program Files\\Example.app";
  journal.installer_leaf =
      L".desktop-updater-inno-00000000-0000-4000-8000-000000000025.exe";
  journal.installer_sha256 = std::string(64, 'a');
  journal.installer_length = 42;
  journal.descriptor_sha256 = std::string(64, 'b');
  journal.provenance_sha256 = std::string(64, 'c');
  journal.current_version = "3.1.2";
  journal.current_build_number = 312;
  journal.current_executable_sha256 = std::string(64, 'd');
  journal.desired_version = "3.1.3";
  journal.desired_build_number = 313;
  journal.execution.silent_arguments = {L"/VERYSILENT", L"/NORESTART"};
  journal.execution.inherit_install_directory = true;
  journal.execution.relaunch_after_install = relaunch_after_install;
  journal.execution.installed_executable_relative_path = L"bin\\example.exe";
  journal.execution.installed_executable_sha256 = std::string(64, 'e');
  journal.execution.log_file_name = L"desktop-updater-inno.log";
  journal.execution.signer_certificate_sha256 = {std::string(64, 'f')};
  journal.owner_process_id = 42;
  journal.owner_process_start_identity = 43;
  const std::string canonical = journal.EncodeCanonical();
  return {WindowsPersistentTransactionRecord::kSchemaVersion,
          transaction_id,
          "windowsInno",
          "com.example.desktop-updater.privileged",
          "com.example.app",
          std::string(64, 'e'),
          42,
          43,
          44,
          45,
          std::string(43, 'A'),
          std::filesystem::path(L"C:\\Program Files\\Example.app"),
          state,
          outcome,
          relaunch_state,
          canonical,
          WindowsHelperSha256Hex(canonical)};
}

WindowsPersistentResolverClaim
ResolverClaim(std::int64_t resolver_process_id, const std::string &claim_nonce,
              const std::string &state = "claimed") {
  return {WindowsPersistentResolverClaim::kSchemaVersion,
          "00000000-0000-4000-8000-000000000025",
          resolver_process_id,
          resolver_process_id + 100,
          44,
          45,
          claim_nonce,
          state};
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
RecoveryResult(const std::string &result_code,
               const std::string &verified_outcome) {
  return {1, "00000000-0000-4000-8000-000000000025", result_code,
          verified_outcome, std::string(64, 'f')};
}

TEST(windows_persistent_recovery, CanonicalRequestRoundTrips) {
  const auto request = Request();
  const std::string encoded = EncodeWindowsPersistentRecoveryRequestV1(request);

  EXPECT_EQ(request, ParseWindowsPersistentRecoveryRequestV1(encoded));
  EXPECT_EQ('{', encoded.front());
  EXPECT_EQ('}', encoded.back());
}

TEST(windows_persistent_recovery,
     PortableAndProtectedLookupCollisionFailsClosed) {
  EXPECT_EQ(WindowsTransactionLookupDecision::kPortable,
            DecideWindowsTransactionLookup(
                WindowsPortableTransactionProbe::kPresent, false));
  EXPECT_EQ(WindowsTransactionLookupDecision::kProtected,
            DecideWindowsTransactionLookup(
                WindowsPortableTransactionProbe::kAbsent, true));
  EXPECT_EQ(WindowsTransactionLookupDecision::kUnavailable,
            DecideWindowsTransactionLookup(
                WindowsPortableTransactionProbe::kAbsent, false));
  EXPECT_EQ(WindowsTransactionLookupDecision::kBindingMismatch,
            DecideWindowsTransactionLookup(
                WindowsPortableTransactionProbe::kBindingMismatch, false));
  EXPECT_EQ(WindowsTransactionLookupDecision::kBindingMismatch,
            DecideWindowsTransactionLookup(
                WindowsPortableTransactionProbe::kPresent, true));
}

TEST(windows_persistent_recovery,
     AutonomousRecoveryAuthoritySeparatesPortableAndProtectedHosts) {
  EXPECT_EQ(WindowsAutonomousRecoveryAuthorityDecision::kPortableStableUser,
            DecideWindowsAutonomousRecoveryAuthority(true, false, false, true));
  EXPECT_EQ(WindowsAutonomousRecoveryAuthorityDecision::kProtectedSystem,
            DecideWindowsAutonomousRecoveryAuthority(false, true, true, false));

  EXPECT_EQ(WindowsAutonomousRecoveryAuthorityDecision::kReject,
            DecideWindowsAutonomousRecoveryAuthority(true, true, false, true));
  EXPECT_EQ(WindowsAutonomousRecoveryAuthorityDecision::kReject,
            DecideWindowsAutonomousRecoveryAuthority(true, false, true, true));
  EXPECT_EQ(
      WindowsAutonomousRecoveryAuthorityDecision::kReject,
      DecideWindowsAutonomousRecoveryAuthority(true, false, false, false));
  EXPECT_EQ(
      WindowsAutonomousRecoveryAuthorityDecision::kReject,
      DecideWindowsAutonomousRecoveryAuthority(false, false, false, true));
}

TEST(windows_persistent_recovery,
     PortableIndexRejectsAnotherSealedHelperAndApplicationGeneration) {
  const WindowsHelperPolicy before = WindowsHelperPolicy::ForPortableTesting(
      "com.example.app", std::string(64, 'a'), std::string(64, 'b'));
  const WindowsHelperPolicy after = WindowsHelperPolicy::ForPortableTesting(
      "com.example.app", std::string(64, 'c'), std::string(64, 'd'));

  EXPECT_NE(WindowsPortableIndexBindingKey(before),
            WindowsPortableIndexBindingKey(after));
  EXPECT_EQ(64U, WindowsPortableIndexBindingKey(before).size());
}

TEST(windows_persistent_recovery,
     PortableDurableIndexRepairsOnlyExactCrashArtifacts) {
  EXPECT_EQ(WindowsPortableDurableFileDecision::kUseFinal,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kExactValid,
                WindowsPortableDurableFileProbe::kMissing));
  EXPECT_EQ(WindowsPortableDurableFileDecision::kUseFinalAndDiscardNext,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kExactValid,
                WindowsPortableDurableFileProbe::kExactInvalid));
  EXPECT_EQ(WindowsPortableDurableFileDecision::kReconcileValidPair,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kExactValid,
                WindowsPortableDurableFileProbe::kExactValid));
  EXPECT_EQ(WindowsPortableDurableFileDecision::kPromoteNext,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kMissing,
                WindowsPortableDurableFileProbe::kExactValid));
  EXPECT_EQ(WindowsPortableDurableFileDecision::kReject,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kExactInvalid,
                WindowsPortableDurableFileProbe::kExactValid));
  EXPECT_EQ(WindowsPortableDurableFileDecision::kReject,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kExactEmpty,
                WindowsPortableDurableFileProbe::kExactValid));
  EXPECT_EQ(WindowsPortableDurableFileDecision::kUnavailable,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kMissing,
                WindowsPortableDurableFileProbe::kMissing));
  EXPECT_EQ(WindowsPortableDurableFileDecision::kDiscardNextAndUnavailable,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kMissing,
                WindowsPortableDurableFileProbe::kExactEmpty));
  EXPECT_EQ(WindowsPortableDurableFileDecision::kReject,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kUnsafe,
                WindowsPortableDurableFileProbe::kExactValid));
  EXPECT_EQ(WindowsPortableDurableFileDecision::kReject,
            DecideWindowsPortableDurableFileRecovery(
                WindowsPortableDurableFileProbe::kExactInvalid,
                WindowsPortableDurableFileProbe::kUnsafe));
}

TEST(windows_persistent_recovery, RejectsUnknownAuthorityFields) {
  const std::string encoded =
      EncodeWindowsPersistentRecoveryRequestV1(Request());
  const std::string injected =
      encoded.substr(0, encoded.size() - 1) + ",\"allowedInstallRoots\":[]}\n";

  EXPECT_THROW(ParseWindowsPersistentRecoveryRequestV1(injected),
               NamedPipeTransportError);
}

TEST(windows_persistent_recovery, RejectsUnboundOperationAndNonce) {
  auto request = Request();
  request.operation = "commitAfterExit";
  EXPECT_THROW(EncodeWindowsPersistentRecoveryRequestV1(request),
               NamedPipeTransportError);

  request = Request();
  request.request_nonce = "caller-controlled";
  EXPECT_THROW(EncodeWindowsPersistentRecoveryRequestV1(request),
               NamedPipeTransportError);
}

TEST(windows_persistent_recovery,
     PersistentRecordRoundTripsWithFrozenJournalAuthority) {
  const WindowsPersistentTransactionRecord record =
      Record("commitAccepted", "none", "launchPending");
  const std::string encoded = record.EncodeCanonical();

  const WindowsPersistentTransactionRecord decoded =
      WindowsPersistentTransactionRecord::DecodeStrict(encoded);
  EXPECT_EQ(record.transaction_id, decoded.transaction_id);
  EXPECT_EQ("directoryReplace", decoded.transaction_kind);
  EXPECT_EQ(record.helper_endpoint_identity_sha256,
            decoded.helper_endpoint_identity_sha256);
  EXPECT_EQ(record.executor_process_id, decoded.executor_process_id);
  EXPECT_EQ(record.executor_process_start_identity,
            decoded.executor_process_start_identity);
  EXPECT_EQ(record.caller_process_id, decoded.caller_process_id);
  EXPECT_EQ(record.caller_process_start_identity,
            decoded.caller_process_start_identity);
  EXPECT_EQ(record.recovery_ready_nonce, decoded.recovery_ready_nonce);
  EXPECT_EQ(record.relaunch_state, decoded.relaunch_state);
  EXPECT_EQ(record.journal_sha256, decoded.journal_sha256);
  EXPECT_EQ(record.journal_canonical, decoded.journal_canonical);
}

TEST(windows_persistent_recovery,
     SchemaThreeDirectoryRecordDecodesByteExactlyAndUpgradesToFour) {
  const std::string frozen = FrozenPersistentRecordBytes();
  WindowsPersistentTransactionRecord decoded =
      WindowsPersistentTransactionRecord::DecodeStrict(frozen);

  EXPECT_EQ(3, decoded.schema_version);
  EXPECT_EQ("directoryReplace", decoded.transaction_kind);
  EXPECT_EQ(frozen, decoded.EncodeCanonical());

  decoded.schema_version = WindowsPersistentTransactionRecord::kSchemaVersion;
  const std::string upgraded = decoded.EncodeCanonical();
  EXPECT_NE(frozen, upgraded);
  EXPECT_NE(std::string::npos,
            upgraded.find("\"transactionKind\":\"directoryReplace\""));

  WindowsPersistentTransactionRecord legacy_inno = InnoRecord(false);
  legacy_inno.schema_version = 3;
  EXPECT_THROW(legacy_inno.EncodeCanonical(), WindowsPersistentRecoveryError);
}

TEST(windows_persistent_recovery,
     SchemaFourDispatchesStrictProtectedInnoJournalAuthority) {
  const WindowsPersistentTransactionRecord relaunch =
      InnoRecord(true, "commitAccepted", "none", "launchPending");
  const auto decoded = WindowsPersistentTransactionRecord::DecodeStrict(
      relaunch.EncodeCanonical());
  EXPECT_EQ(4, decoded.schema_version);
  EXPECT_EQ("windowsInno", decoded.transaction_kind);

  EXPECT_NO_THROW(InnoRecord(false, "commitAccepted").EncodeCanonical());
  EXPECT_THROW(InnoRecord(false, "commitAccepted", "none", "launchPending")
                   .EncodeCanonical(),
               WindowsPersistentRecoveryError);
  auto mismatched = relaunch;
  mismatched.transaction_kind = "directoryReplace";
  EXPECT_THROW(mismatched.EncodeCanonical(), WindowsPersistentRecoveryError);
}

TEST(windows_persistent_recovery,
     ProtectedInnoRecoveryRequiresCommitForDesiredAndRollsBackOld) {
  EXPECT_EQ(
      WindowsPersistentInnoRecoveryAction::kRecoveryRequired,
      DecideWindowsPersistentInnoRecovery("commitAccepted", true, false, true));
  EXPECT_EQ(WindowsPersistentInnoRecoveryAction::kComplete,
            DecideWindowsPersistentInnoRecovery("commitAccepted", false, true,
                                                false));
  EXPECT_EQ(
      WindowsPersistentInnoRecoveryAction::kManualActionRequired,
      DecideWindowsPersistentInnoRecovery("prepared", false, true, false));
  EXPECT_EQ(
      WindowsPersistentInnoRecoveryAction::kRollBack,
      DecideWindowsPersistentInnoRecovery("prepared", false, false, true));
  EXPECT_EQ(WindowsPersistentInnoRecoveryAction::kRollBack,
            DecideWindowsPersistentInnoRecovery("commitAccepted", false, false,
                                                true));
  EXPECT_EQ(
      WindowsPersistentInnoRecoveryAction::kManualActionRequired,
      DecideWindowsPersistentInnoRecovery("commitAccepted", false, true, true));
  EXPECT_EQ(WindowsPersistentInnoRecoveryAction::kManualActionRequired,
            DecideWindowsPersistentInnoRecovery("commitAccepted", false, false,
                                                false));
}

TEST(windows_persistent_recovery,
     PersistentRecordRejectsFalseRelaunchStateTransitions) {
  EXPECT_THROW(Record("commitAccepted", "none").EncodeCanonical(),
               WindowsPersistentRecoveryError);
  EXPECT_THROW(
      Record("completed", "newTarget", "notRequested").EncodeCanonical(),
      WindowsPersistentRecoveryError);
  EXPECT_NO_THROW(
      Record("rolledBack", "oldTarget", "notRequested").EncodeCanonical());
  EXPECT_NO_THROW(
      Record("completed", "newTarget", "launchPending").EncodeCanonical());
  EXPECT_NO_THROW(
      Record("completed", "newTarget", "launchAttempting").EncodeCanonical());
  EXPECT_NO_THROW(
      Record("completed", "newTarget", "launchFailed").EncodeCanonical());
  EXPECT_NO_THROW(
      Record("completed", "newTarget", "launched").EncodeCanonical());
}

TEST(windows_persistent_recovery,
     TerminalStatusNeverReportsRelaunchSuccessBeforeDurableLaunchProof) {
  EXPECT_EQ("relaunchFailure",
            StatusFromWindowsPersistentTerminalRecord(
                Record("completed", "newTarget", "launchPending"))
                .result_code);
  EXPECT_EQ("relaunchFailure",
            StatusFromWindowsPersistentTerminalRecord(
                Record("completed", "newTarget", "launchAttempting"))
                .result_code);
  EXPECT_EQ("relaunchFailure",
            StatusFromWindowsPersistentTerminalRecord(
                Record("completed", "newTarget", "launchFailed"))
                .result_code);
  EXPECT_EQ("completed", StatusFromWindowsPersistentTerminalRecord(
                             Record("completed", "newTarget", "launched"))
                             .result_code);
  EXPECT_EQ("rolledBack", StatusFromWindowsPersistentTerminalRecord(
                              Record("rolledBack", "oldTarget", "notRequested"))
                              .result_code);
}

TEST(windows_persistent_recovery,
     TerminalRelaunchDecisionNeverRetriesAnUncertainOrFailedAttempt) {
  EXPECT_EQ(WindowsTerminalRelaunchDecision::kAttempt,
            DecideWindowsTerminalRelaunch("launchPending"));
  EXPECT_EQ(WindowsTerminalRelaunchDecision::kFailClosed,
            DecideWindowsTerminalRelaunch("launchAttempting"));
  EXPECT_EQ(WindowsTerminalRelaunchDecision::kFailClosed,
            DecideWindowsTerminalRelaunch("launchFailed"));
  EXPECT_EQ(WindowsTerminalRelaunchDecision::kAlreadyLaunched,
            DecideWindowsTerminalRelaunch("launched"));
  EXPECT_EQ(WindowsTerminalRelaunchDecision::kNotRequested,
            DecideWindowsTerminalRelaunch("notRequested"));
  EXPECT_THROW(DecideWindowsTerminalRelaunch("retryable"),
               WindowsPersistentRecoveryError);
}

TEST(windows_persistent_recovery,
     AtMostOnceRelaunchPersistsAttemptBeforeCallingLauncher) {
  std::vector<std::string> events;
  const WindowsAtMostOnceRelaunchOutcome outcome = RunWindowsAtMostOnceRelaunch(
      [&]() {
        events.push_back("claimConsumed");
        return true;
      },
      [&]() { events.push_back("launchAttempting"); },
      [&]() { events.push_back("launcherCalled"); },
      [&](bool launched) {
        events.push_back(launched ? "launched" : "launchFailed");
      });

  EXPECT_EQ(WindowsAtMostOnceRelaunchOutcome::kLaunched, outcome);
  EXPECT_EQ((std::vector<std::string>{"claimConsumed", "launchAttempting",
                                      "launcherCalled", "launched"}),
            events);
}

TEST(windows_persistent_recovery,
     AtMostOnceRelaunchDoesNotLaunchWithoutDurableAttemptState) {
  int launches = 0;
  EXPECT_THROW(
      RunWindowsAtMostOnceRelaunch(
          []() { return true; },
          []() { throw WindowsPersistentRecoveryError("persistence failed"); },
          [&]() { ++launches; }, [](bool) {}),
      WindowsPersistentRecoveryError);
  EXPECT_EQ(0, launches);
}

TEST(windows_persistent_recovery,
     AtMostOnceRelaunchPersistsFailureAndNeverRetriesConsumedClaim) {
  int launches = 0;
  bool persisted_failure = false;
  EXPECT_EQ(WindowsAtMostOnceRelaunchOutcome::kFailed,
            RunWindowsAtMostOnceRelaunch(
                []() { return true; }, []() {},
                [&]() {
                  ++launches;
                  throw WindowsPersistentRecoveryError("launch failed");
                },
                [&](bool launched) { persisted_failure = !launched; }));
  EXPECT_TRUE(persisted_failure);
  EXPECT_EQ(1, launches);

  EXPECT_EQ(WindowsAtMostOnceRelaunchOutcome::kNotOwned,
            RunWindowsAtMostOnceRelaunch([]() { return false; }, []() {},
                                         [&]() { ++launches; }, [](bool) {}));
  EXPECT_EQ(1, launches);
}

TEST(windows_persistent_recovery,
     PersistentRecordRejectsFalseTerminalOutcomePairs) {
  EXPECT_THROW(Record("completed", "oldTarget").EncodeCanonical(),
               WindowsPersistentRecoveryError);
  EXPECT_THROW(Record("rolledBack", "newTarget").EncodeCanonical(),
               WindowsPersistentRecoveryError);
  EXPECT_THROW(Record("completedCleanupPending", "oldTarget").EncodeCanonical(),
               WindowsPersistentRecoveryError);
  EXPECT_THROW(
      Record("rolledBackCleanupPending", "newTarget").EncodeCanonical(),
      WindowsPersistentRecoveryError);
  EXPECT_THROW(Record("prepared", "newTarget").EncodeCanonical(),
               WindowsPersistentRecoveryError);
  EXPECT_NO_THROW(
      Record("completed", "newTarget", "launchPending").EncodeCanonical());
  EXPECT_NO_THROW(Record("rolledBack", "oldTarget").EncodeCanonical());
  EXPECT_NO_THROW(
      Record("completedCleanupPending", "newTarget", "launchPending")
          .EncodeCanonical());
  EXPECT_NO_THROW(
      Record("rolledBackCleanupPending", "oldTarget").EncodeCanonical());
}

TEST(windows_persistent_recovery,
     ResolverFollowsSystemRecoveryWinnerAndClaimsOneRelaunchAttempt) {
  int recovery_attempts = 0;
  int system_recoveries = 0;
  int relaunch_claims = 0;
  const WindowsResolveAfterExitCoordination coordinated =
      CoordinateWindowsResolveAfterExit(
          [&]() {
            ++recovery_attempts;
            if (recovery_attempts == 1) {
              return WindowsPersistentRecoveryAttempt{
                  RecoveryResult("recoveryRequired", "none"), true};
            }
            return WindowsPersistentRecoveryAttempt{
                RecoveryResult("completed", "newTarget"), false};
          },
          [&]() {
            ++system_recoveries;
            return true;
          },
          [&]() {
            ++relaunch_claims;
            return true;
          });

  EXPECT_EQ("completed", coordinated.recovery.result_code);
  EXPECT_TRUE(coordinated.should_relaunch);
  EXPECT_EQ(2, recovery_attempts);
  EXPECT_EQ(1, system_recoveries);
  EXPECT_EQ(1, relaunch_claims);
}

TEST(windows_persistent_recovery,
     ResolverDoesNotRetryUnownedRecoveryRequiredResult) {
  int recovery_attempts = 0;
  int waits = 0;
  int relaunch_claims = 0;
  const WindowsResolveAfterExitCoordination coordinated =
      CoordinateWindowsResolveAfterExit(
          [&]() {
            ++recovery_attempts;
            return WindowsPersistentRecoveryAttempt{
                RecoveryResult("recoveryRequired", "none"), false};
          },
          [&]() {
            ++waits;
            return true;
          },
          [&]() {
            ++relaunch_claims;
            return true;
          });

  EXPECT_EQ("recoveryRequired", coordinated.recovery.result_code);
  EXPECT_FALSE(coordinated.should_relaunch);
  EXPECT_EQ(1, recovery_attempts);
  EXPECT_EQ(0, waits);
  EXPECT_EQ(0, relaunch_claims);
}

TEST(windows_persistent_recovery,
     ResolverClaimRoundTripsAndRejectsReuseAfterConsumption) {
  const WindowsPersistentResolverClaim claim =
      ResolverClaim(101, std::string(43, 'B'));
  const WindowsPersistentResolverClaim decoded =
      WindowsPersistentResolverClaim::DecodeStrict(claim.EncodeCanonical());
  EXPECT_EQ(claim, decoded);

  WindowsPersistentResolverClaim consumed = claim;
  consumed.state = "consumed";
  EXPECT_EQ(WindowsResolverClaimDecision::kConsumed,
            DecideWindowsResolverClaim(consumed, claim, false));
  EXPECT_EQ(WindowsResolverClaimDecision::kOwn,
            DecideWindowsResolverClaim(
                claim, ResolverClaim(102, std::string(43, 'C')), false));
}

TEST(windows_persistent_recovery,
     DuplicateResolversShareOnePreAcknowledgementRelaunchClaim) {
  const WindowsPersistentResolverClaim first =
      ResolverClaim(101, std::string(43, 'B'));
  const WindowsPersistentResolverClaim duplicate =
      ResolverClaim(102, std::string(43, 'C'));
  EXPECT_EQ(WindowsResolverClaimDecision::kOwn,
            DecideWindowsResolverClaim(std::nullopt, first, false));
  EXPECT_EQ(WindowsResolverClaimDecision::kFollow,
            DecideWindowsResolverClaim(first, duplicate, true));

  bool relaunch_claim_consumed = false;
  int recovery_winners = 0;
  const auto consume_once = [&]() {
    if (relaunch_claim_consumed)
      return false;
    relaunch_claim_consumed = true;
    return true;
  };
  const WindowsResolveAfterExitCoordination winner =
      CoordinateWindowsResolveAfterExit(
          [&]() {
            ++recovery_winners;
            return WindowsPersistentRecoveryAttempt{
                RecoveryResult("completed", "newTarget"), false};
          },
          []() { return true; }, consume_once);
  int loser_attempts = 0;
  const WindowsResolveAfterExitCoordination loser =
      CoordinateWindowsResolveAfterExit(
          [&]() {
            ++loser_attempts;
            return WindowsPersistentRecoveryAttempt{
                RecoveryResult(loser_attempts == 1 ? "recoveryRequired"
                                                   : "completed",
                               loser_attempts == 1 ? "none" : "newTarget"),
                loser_attempts == 1};
          },
          []() { return true; }, consume_once);

  EXPECT_EQ(1, recovery_winners);
  EXPECT_EQ(2, loser_attempts);
  EXPECT_TRUE(winner.should_relaunch);
  EXPECT_FALSE(loser.should_relaunch);
  EXPECT_EQ(1, static_cast<int>(winner.should_relaunch) +
                   static_cast<int>(loser.should_relaunch));
}

} // namespace
} // namespace desktop_updater::helper
