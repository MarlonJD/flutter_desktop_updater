#include "install_helper_contract.h"

#include <stdexcept>
#include <string>
#include <utility>

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

RecoveryDecision Manual(std::string reason) {
  return RecoveryDecision(RecoveryOutcome::kManualActionRequired,
                          RecoveryAction::kNone, false, std::move(reason));
}

RecoveryDecision VerifiedOld(RecoveryAction action, std::string reason) {
  return RecoveryDecision(RecoveryOutcome::kVerifiedOldTarget, action, true,
                          std::move(reason));
}

RecoveryDecision VerifiedNew(RecoveryAction action, std::string reason) {
  return RecoveryDecision(RecoveryOutcome::kVerifiedNewTarget, action, true,
                          std::move(reason));
}

RecoveryDecision DecideSwapRecovery(const JournalV1& journal,
                                    const ObservedState& observed) {
  switch (journal.state) {
    case JournalState::kPrepared:
      if (observed.target == IdentityObservation::kVerifiedOld &&
          observed.backup == IdentityObservation::kMissing &&
          (observed.prepared == IdentityObservation::kVerifiedNew ||
           observed.prepared == IdentityObservation::kMissing)) {
        const RecoveryAction action =
            observed.prepared == IdentityObservation::kVerifiedNew
                ? RecoveryAction::kDiscardPrepared
                : RecoveryAction::kNone;
        return VerifiedOld(action, "preparedTargetAuthoritative");
      }
      return Manual("preparedStateUnverified");

    case JournalState::kBackupCreated:
      if (observed.target == IdentityObservation::kMissing &&
          observed.backup == IdentityObservation::kVerifiedOld) {
        return VerifiedOld(RecoveryAction::kRestoreBackup,
                           "backupReadyToRestore");
      }
      if (observed.target == IdentityObservation::kVerifiedOld &&
          (observed.backup == IdentityObservation::kMissing ||
           observed.backup == IdentityObservation::kVerifiedOld)) {
        return VerifiedOld(RecoveryAction::kNone, "backupAlreadyRestored");
      }
      return Manual("backupStateUnverified");

    case JournalState::kTargetActivated:
      if (observed.target == IdentityObservation::kVerifiedNew &&
          (observed.backup == IdentityObservation::kVerifiedOld ||
           observed.backup == IdentityObservation::kMissing)) {
        return VerifiedNew(RecoveryAction::kAcceptActivated,
                           "activatedTargetVerified");
      }
      if ((observed.target == IdentityObservation::kMissing ||
           observed.target == IdentityObservation::kUnknown) &&
          observed.backup == IdentityObservation::kVerifiedOld) {
        return VerifiedOld(RecoveryAction::kRestoreBackup,
                           "activatedTargetRejected");
      }
      if (observed.target == IdentityObservation::kVerifiedOld) {
        return VerifiedOld(RecoveryAction::kNone,
                           "activatedTargetAlreadyRolledBack");
      }
      return Manual("activatedStateUnverified");

    case JournalState::kCompleted:
      if (observed.target == IdentityObservation::kVerifiedNew) {
        return VerifiedNew(RecoveryAction::kNone, "completedTargetVerified");
      }
      return Manual("completedTargetUnverified");

    case JournalState::kRolledBack:
      if (observed.target == IdentityObservation::kVerifiedOld) {
        return VerifiedOld(RecoveryAction::kNone, "rollbackVerified");
      }
      return Manual("rollbackUnverified");

    case JournalState::kManualActionRequired:
      return Manual("journalRequiresManualAction");

    case JournalState::kManagerStarted:
    case JournalState::kVerificationPending:
      return Manual("strategyStateMismatch");
  }
  return Manual("unknownJournalState");
}

RecoveryDecision DecideManagerRecovery(const JournalV1& journal,
                                       const ObservedState& observed) {
  switch (journal.state) {
    case JournalState::kPrepared:
      if (observed.manager == ManagerObservation::kVerifiedOld) {
        return VerifiedOld(RecoveryAction::kNone, "managerOldStateVerified");
      }
      return Manual("managerPreparedStateUnverified");

    case JournalState::kManagerStarted:
    case JournalState::kVerificationPending:
      if (observed.manager == ManagerObservation::kVerifiedNew) {
        return VerifiedNew(RecoveryAction::kAcceptManagerState,
                           "managerNewStateVerified");
      }
      if (observed.manager == ManagerObservation::kVerifiedOld) {
        return VerifiedOld(RecoveryAction::kAcceptManagerState,
                           "managerOldStateVerified");
      }
      if (observed.manager == ManagerObservation::kPending) {
        return Manual("managerVerificationPending");
      }
      return Manual("managerStateUnknown");

    case JournalState::kCompleted:
      if (observed.manager == ManagerObservation::kVerifiedNew) {
        return VerifiedNew(RecoveryAction::kNone,
                           "completedManagerStateVerified");
      }
      return Manual("completedManagerStateUnverified");

    case JournalState::kManualActionRequired:
      return Manual("journalRequiresManualAction");

    case JournalState::kBackupCreated:
    case JournalState::kTargetActivated:
    case JournalState::kRolledBack:
      return Manual("strategyStateMismatch");
  }
  return Manual("unknownJournalState");
}

}  // namespace

JournalV1::JournalV1(std::int64_t schema_version,
                     JournalMachine machine,
                     JournalState state,
                     std::int64_t owner_generation,
                     bool envelope_valid)
    : schema_version(schema_version),
      machine(machine),
      state(state),
      owner_generation(owner_generation),
      envelope_valid(envelope_valid) {}

ObservedState::ObservedState(bool journal_durable,
                             bool directory_flush_succeeded,
                             bool owner_live,
                             std::int64_t observed_owner_generation,
                             bool sibling_names_match,
                             bool observations_unambiguous,
                             IdentityObservation target,
                             IdentityObservation prepared,
                             IdentityObservation backup,
                             ManagerObservation manager)
    : journal_durable(journal_durable),
      directory_flush_succeeded(directory_flush_succeeded),
      owner_live(owner_live),
      observed_owner_generation(observed_owner_generation),
      sibling_names_match(sibling_names_match),
      observations_unambiguous(observations_unambiguous),
      target(target),
      prepared(prepared),
      backup(backup),
      manager(manager) {}

RecoveryDecision::RecoveryDecision(RecoveryOutcome outcome,
                                   RecoveryAction action,
                                   bool cleanup_authorized,
                                   std::string reason)
    : outcome(outcome),
      action(action),
      cleanup_authorized(cleanup_authorized),
      reason(std::move(reason)) {}

TransitionResult::TransitionResult(bool allowed, std::string reason)
    : allowed(allowed), reason(std::move(reason)) {}

JournalMachine ParseJournalMachine(const std::string& value) {
  if (value == "swap") return JournalMachine::kSwap;
  if (value == "manager") return JournalMachine::kManager;
  throw std::invalid_argument("unknown journal machine");
}

JournalState ParseJournalState(const std::string& value) {
  if (value == "prepared") return JournalState::kPrepared;
  if (value == "backupCreated") return JournalState::kBackupCreated;
  if (value == "targetActivated") return JournalState::kTargetActivated;
  if (value == "managerStarted") return JournalState::kManagerStarted;
  if (value == "verificationPending") {
    return JournalState::kVerificationPending;
  }
  if (value == "completed") return JournalState::kCompleted;
  if (value == "rolledBack") return JournalState::kRolledBack;
  if (value == "manualActionRequired") {
    return JournalState::kManualActionRequired;
  }
  throw std::invalid_argument("unknown journal state");
}

IdentityObservation ParseIdentityObservation(const std::string& value) {
  if (value == "missing") return IdentityObservation::kMissing;
  if (value == "verifiedOld") return IdentityObservation::kVerifiedOld;
  if (value == "verifiedNew") return IdentityObservation::kVerifiedNew;
  if (value == "unknown") return IdentityObservation::kUnknown;
  throw std::invalid_argument("unknown identity observation");
}

ManagerObservation ParseManagerObservation(const std::string& value) {
  if (value == "notApplicable") return ManagerObservation::kNotApplicable;
  if (value == "verifiedOld") return ManagerObservation::kVerifiedOld;
  if (value == "verifiedNew") return ManagerObservation::kVerifiedNew;
  if (value == "pending") return ManagerObservation::kPending;
  if (value == "unknown") return ManagerObservation::kUnknown;
  throw std::invalid_argument("unknown manager observation");
}

std::string RecoveryOutcomeName(RecoveryOutcome value) {
  switch (value) {
    case RecoveryOutcome::kVerifiedOldTarget:
      return "verifiedOldTarget";
    case RecoveryOutcome::kVerifiedNewTarget:
      return "verifiedNewTarget";
    case RecoveryOutcome::kManualActionRequired:
      return "manualActionRequired";
  }
  throw std::invalid_argument("unknown recovery outcome");
}

std::string RecoveryActionName(RecoveryAction value) {
  switch (value) {
    case RecoveryAction::kNone:
      return "none";
    case RecoveryAction::kDiscardPrepared:
      return "discardPrepared";
    case RecoveryAction::kRestoreBackup:
      return "restoreBackup";
    case RecoveryAction::kAcceptActivated:
      return "acceptActivated";
    case RecoveryAction::kAcceptManagerState:
      return "acceptManagerState";
  }
  throw std::invalid_argument("unknown recovery action");
}

TransitionResult ValidateTransition(JournalState from, JournalState to) {
  const bool allowed =
      (from == JournalState::kPrepared &&
       (to == JournalState::kBackupCreated ||
        to == JournalState::kManagerStarted ||
        to == JournalState::kRolledBack ||
        to == JournalState::kManualActionRequired)) ||
      (from == JournalState::kBackupCreated &&
       (to == JournalState::kTargetActivated ||
        to == JournalState::kRolledBack ||
        to == JournalState::kManualActionRequired)) ||
      (from == JournalState::kTargetActivated &&
       (to == JournalState::kCompleted ||
        to == JournalState::kRolledBack ||
        to == JournalState::kManualActionRequired)) ||
      (from == JournalState::kManagerStarted &&
       (to == JournalState::kVerificationPending ||
        to == JournalState::kManualActionRequired)) ||
      (from == JournalState::kVerificationPending &&
       (to == JournalState::kCompleted ||
        to == JournalState::kManualActionRequired));
  return TransitionResult(allowed,
                          allowed ? "transitionAllowed" : "transitionDenied");
}

RecoveryDecision DecideRecovery(const JournalV1& journal,
                                const ObservedState& observed) {
  if (!journal.envelope_valid) return Manual("journalCorrupt");
  if (journal.schema_version != 1) return Manual("unsupportedJournalVersion");
  if (!observed.journal_durable) return Manual("journalNotDurable");
  if (!observed.directory_flush_succeeded) {
    return Manual("journalDirectoryFlushFailed");
  }
  if (observed.owner_live) return Manual("transactionBusy");
  if (observed.observed_owner_generation != journal.owner_generation) {
    return Manual("ownerGenerationMismatch");
  }
  if (!observed.sibling_names_match) return Manual("siblingNameMismatch");
  if (!observed.observations_unambiguous) {
    return Manual("ambiguousObservedState");
  }
  return journal.machine == JournalMachine::kSwap
             ? DecideSwapRecovery(journal, observed)
             : DecideManagerRecovery(journal, observed);
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
