#ifndef DESKTOP_UPDATER_RUNTIME_INSTALL_HELPER_CONTRACT_H_
#define DESKTOP_UPDATER_RUNTIME_INSTALL_HELPER_CONTRACT_H_

#include <cstdint>
#include <string>

namespace desktop_updater {
namespace runtime {
namespace internal {

enum class JournalMachine {
  kSwap,
  kManager,
};

enum class JournalState {
  kPrepared,
  kBackupCreated,
  kTargetActivated,
  kManagerStarted,
  kVerificationPending,
  kCompleted,
  kRolledBack,
  kManualActionRequired,
};

enum class IdentityObservation {
  kMissing,
  kVerifiedOld,
  kVerifiedNew,
  kUnknown,
};

enum class ManagerObservation {
  kNotApplicable,
  kVerifiedOld,
  kVerifiedNew,
  kPending,
  kUnknown,
};

enum class RecoveryOutcome {
  kVerifiedOldTarget,
  kVerifiedNewTarget,
  kManualActionRequired,
};

enum class RecoveryAction {
  kNone,
  kDiscardPrepared,
  kRestoreBackup,
  kAcceptActivated,
  kAcceptManagerState,
};

struct JournalV1 {
  JournalV1(std::int64_t schema_version,
            JournalMachine machine,
            JournalState state,
            std::int64_t owner_generation,
            bool envelope_valid);

  const std::int64_t schema_version;
  const JournalMachine machine;
  const JournalState state;
  const std::int64_t owner_generation;
  const bool envelope_valid;
};

struct ObservedState {
  ObservedState(bool journal_durable,
                bool directory_flush_succeeded,
                bool owner_live,
                std::int64_t observed_owner_generation,
                bool sibling_names_match,
                bool observations_unambiguous,
                IdentityObservation target,
                IdentityObservation prepared,
                IdentityObservation backup,
                ManagerObservation manager);

  const bool journal_durable;
  const bool directory_flush_succeeded;
  const bool owner_live;
  const std::int64_t observed_owner_generation;
  const bool sibling_names_match;
  const bool observations_unambiguous;
  const IdentityObservation target;
  const IdentityObservation prepared;
  const IdentityObservation backup;
  const ManagerObservation manager;
};

struct RecoveryDecision {
  RecoveryDecision(RecoveryOutcome outcome,
                   RecoveryAction action,
                   bool cleanup_authorized,
                   std::string reason);

  const RecoveryOutcome outcome;
  const RecoveryAction action;
  const bool cleanup_authorized;
  const std::string reason;
};

struct TransitionResult {
  TransitionResult(bool allowed, std::string reason);

  const bool allowed;
  const std::string reason;
};

JournalMachine ParseJournalMachine(const std::string& value);
JournalState ParseJournalState(const std::string& value);
IdentityObservation ParseIdentityObservation(const std::string& value);
ManagerObservation ParseManagerObservation(const std::string& value);

std::string RecoveryOutcomeName(RecoveryOutcome value);
std::string RecoveryActionName(RecoveryAction value);

TransitionResult ValidateTransition(JournalState from, JournalState to);
RecoveryDecision DecideRecovery(const JournalV1& journal,
                                const ObservedState& observed);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_INSTALL_HELPER_CONTRACT_H_
