#include "client_lifecycle.h"

#include <utility>

namespace desktop_updater {
namespace runtime {
namespace internal {

void ClientLifecycleState::IncrementNonzero(std::uint64_t* value) {
  ++(*value);
  if (*value == 0) {
    ++(*value);
  }
}

void ClientLifecycleState::ClearStage() {
  staged_path_.clear();
  stage_provenance_sha256_.clear();
  staged_generation_ = 0;
  staged_attempt_ = 0;
}

CheckLease ClientLifecycleState::BeginCheck() {
  std::lock_guard<std::mutex> lock(mutex_);
  IncrementNonzero(&selection_generation_);
  check_ = ClientCheckResult();
  check_generation_ = 0;
  IncrementNonzero(&stage_attempt_);
  ClearStage();
  if (install_in_progress_) {
    return {ClientLifecycleStatus::kInstallInProgress, selection_generation_};
  }
  return {ClientLifecycleStatus::kAllowed, selection_generation_};
}

bool ClientLifecycleState::PublishCheck(const CheckLease& lease,
                                        ClientCheckResult check) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (lease.status != ClientLifecycleStatus::kAllowed ||
      install_in_progress_ || lease.generation != selection_generation_) {
    return false;
  }
  check_ = std::move(check);
  check_generation_ = lease.generation;
  return true;
}

StageLease ClientLifecycleState::BeginStage() {
  std::lock_guard<std::mutex> lock(mutex_);
  IncrementNonzero(&stage_attempt_);
  ClearStage();
  if (install_in_progress_) {
    StageLease lease;
    lease.status = ClientLifecycleStatus::kInstallInProgress;
    return lease;
  }
  if (selection_generation_ == 0 || check_generation_ == 0 ||
      check_generation_ != selection_generation_) {
    StageLease lease;
    lease.status = ClientLifecycleStatus::kInvalidGeneration;
    return lease;
  }
  StageLease lease;
  lease.status = ClientLifecycleStatus::kAllowed;
  lease.generation = selection_generation_;
  lease.attempt = stage_attempt_;
  lease.check = check_;
  return lease;
}

bool ClientLifecycleState::PublishStage(const StageLease& lease,
                                        std::string staged_path,
                                        std::string stage_provenance_sha256) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (lease.status != ClientLifecycleStatus::kAllowed ||
      install_in_progress_ || lease.generation != selection_generation_ ||
      lease.generation != check_generation_ ||
      lease.attempt != stage_attempt_) {
    return false;
  }
  staged_path_ = std::move(staged_path);
  stage_provenance_sha256_ = std::move(stage_provenance_sha256);
  staged_generation_ = lease.generation;
  staged_attempt_ = lease.attempt;
  return true;
}

InstallHandoff ClientLifecycleState::BeginInstall() {
  std::lock_guard<std::mutex> lock(mutex_);
  return BeginInstallLocked();
}

InstallHandoff ClientLifecycleState::BeginInstall(
    const LifecycleSnapshot& expected) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (expected.staged_path != staged_path_ ||
      expected.stage_provenance_sha256 != stage_provenance_sha256_ ||
      expected.selection_generation != selection_generation_ ||
      expected.check_generation != check_generation_ ||
      expected.stage_attempt != stage_attempt_ ||
      expected.staged_generation != staged_generation_ ||
      expected.staged_attempt != staged_attempt_) {
    return InstallHandoff();
  }
  return BeginInstallLocked();
}

InstallHandoff ClientLifecycleState::BeginInstallLocked() {
  if (install_in_progress_) {
    InstallHandoff handoff;
    handoff.status = ClientLifecycleStatus::kInstallInProgress;
    return handoff;
  }
  if (staged_path_.empty() || staged_generation_ == 0 ||
      staged_generation_ != selection_generation_ ||
      staged_generation_ != check_generation_ ||
      staged_attempt_ != stage_attempt_) {
    return InstallHandoff();
  }
  IncrementNonzero(&next_handoff_token_);
  install_in_progress_ = true;
  active_handoff_token_ = next_handoff_token_;
  scheduling_confirmed_ = false;
  InstallHandoff handoff;
  handoff.status = ClientLifecycleStatus::kAllowed;
  handoff.token = active_handoff_token_;
  handoff.generation = staged_generation_;
  handoff.stage_attempt = staged_attempt_;
  handoff.staged_path = std::move(staged_path_);
  handoff.stage_provenance_sha256 =
      std::move(stage_provenance_sha256_);
  ClearStage();
  return handoff;
}

bool ClientLifecycleState::RollbackInstall(const InstallHandoff& handoff) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!install_in_progress_ || scheduling_confirmed_ || handoff.token == 0 ||
      handoff.token != active_handoff_token_) {
    return false;
  }
  const bool can_restore =
      handoff.generation == selection_generation_ &&
      handoff.generation == check_generation_ &&
      handoff.stage_attempt == stage_attempt_;
  install_in_progress_ = false;
  active_handoff_token_ = 0;
  if (can_restore) {
    staged_path_ = handoff.staged_path;
    stage_provenance_sha256_ = handoff.stage_provenance_sha256;
    staged_generation_ = handoff.generation;
    staged_attempt_ = handoff.stage_attempt;
  }
  return can_restore;
}

bool ClientLifecycleState::ConfirmInstall(const InstallHandoff& handoff) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!install_in_progress_ || scheduling_confirmed_ || handoff.token == 0 ||
      handoff.token != active_handoff_token_) {
    return false;
  }
  scheduling_confirmed_ = true;
  return true;
}

LifecycleSnapshot ClientLifecycleState::Snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  LifecycleSnapshot snapshot;
  snapshot.check = check_;
  snapshot.staged_path = staged_path_;
  snapshot.stage_provenance_sha256 = stage_provenance_sha256_;
  snapshot.selection_generation = selection_generation_;
  snapshot.check_generation = check_generation_;
  snapshot.stage_attempt = stage_attempt_;
  snapshot.staged_generation = staged_generation_;
  snapshot.staged_attempt = staged_attempt_;
  snapshot.install_in_progress = install_in_progress_;
  return snapshot;
}

SchedulingRollbackGuard::SchedulingRollbackGuard(
    ClientLifecycleState* state,
    InstallHandoff handoff)
    : state_(state), handoff_(std::move(handoff)) {}

SchedulingRollbackGuard::~SchedulingRollbackGuard() {
  if (active_ && state_ != nullptr) {
    state_->RollbackInstall(handoff_);
  }
}

bool SchedulingRollbackGuard::Confirm() {
  if (!active_ || state_ == nullptr || !state_->ConfirmInstall(handoff_)) {
    return false;
  }
  active_ = false;
  return true;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
