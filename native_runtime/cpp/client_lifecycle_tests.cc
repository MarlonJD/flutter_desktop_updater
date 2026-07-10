#include "client_lifecycle_tests.h"

#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "client_lifecycle.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

class Barrier {
 public:
  explicit Barrier(std::size_t parties) : parties_(parties) {}

  void ArriveAndWait() {
    std::unique_lock<std::mutex> lock(mutex_);
    ++arrivals_;
    if (arrivals_ == parties_) {
      condition_.notify_all();
      return;
    }
    condition_.wait(lock, [this] { return arrivals_ == parties_; });
  }

 private:
  const std::size_t parties_;
  std::size_t arrivals_ = 0;
  std::mutex mutex_;
  std::condition_variable condition_;
};

class SchedulerGate {
 public:
  void EnterAndWait() {
    std::unique_lock<std::mutex> lock(mutex_);
    entered_ = true;
    condition_.notify_all();
    condition_.wait(lock, [this] { return released_; });
  }

  void WaitUntilEntered() {
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait(lock, [this] { return entered_; });
  }

  void Release() {
    std::lock_guard<std::mutex> lock(mutex_);
    released_ = true;
    condition_.notify_all();
  }

 private:
  bool entered_ = false;
  bool released_ = false;
  std::mutex mutex_;
  std::condition_variable condition_;
};

void Require(bool condition, const char* message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}

ClientCheckResult AvailableCheck() {
  ClientCheckResult result;
  result.outcome = "updateAvailable";
  result.message = "verified";
  result.has_descriptor = true;
  return result;
}

void PrepareStage(ClientLifecycleState* state, const std::string& path) {
  const CheckLease check = state->BeginCheck();
  Require(check.status == ClientLifecycleStatus::kAllowed,
          "Check lease was rejected.");
  Require(state->PublishCheck(check, AvailableCheck()),
          "Check result was not published.");
  const StageLease stage = state->BeginStage();
  Require(stage.status == ClientLifecycleStatus::kAllowed,
          "Stage lease was rejected.");
  Require(state->PublishStage(stage, path),
          "Staged result was not published.");
}

void ConcurrentInstallIsOneShot() {
  ClientLifecycleState state;
  PrepareStage(&state, "/tmp/stage-concurrent");
  Barrier barrier(2);
  std::mutex results_mutex;
  std::vector<ClientLifecycleStatus> statuses;
  std::vector<std::thread> workers;
  for (int index = 0; index < 2; ++index) {
    workers.emplace_back([&] {
      barrier.ArriveAndWait();
      const InstallHandoff handoff = state.BeginInstall();
      {
        std::lock_guard<std::mutex> lock(results_mutex);
        statuses.push_back(handoff.status);
      }
      if (handoff.status == ClientLifecycleStatus::kAllowed) {
        SchedulingRollbackGuard guard(&state, handoff);
        guard.Confirm();
      }
    });
  }
  for (std::thread& worker : workers) {
    worker.join();
  }
  std::size_t allowed = 0;
  std::size_t rejected = 0;
  for (ClientLifecycleStatus status : statuses) {
    allowed += status == ClientLifecycleStatus::kAllowed ? 1 : 0;
    rejected += status == ClientLifecycleStatus::kInstallInProgress ? 1 : 0;
  }
  Require(allowed == 1 && rejected == 1,
          "Concurrent installs did not schedule exactly one handoff.");
}

void LatestStageAttemptOwnsPublication() {
  ClientLifecycleState state;
  const CheckLease check = state.BeginCheck();
  Require(state.PublishCheck(check, AvailableCheck()),
          "Check result was not published.");

  const StageLease slow_a = state.BeginStage();
  const StageLease failed_b = state.BeginStage();
  Require(failed_b.status == ClientLifecycleStatus::kAllowed,
          "Later failed stage did not get a lease.");
  Require(!state.PublishStage(slow_a, "/tmp/stage-a"),
          "Slow stage A resurrected after stage B failed.");
  Require(state.Snapshot().staged_path.empty(),
          "Failed latest stage left staged state behind.");

  const StageLease slow_c = state.BeginStage();
  const StageLease successful_d = state.BeginStage();
  Require(state.PublishStage(successful_d, "/tmp/stage-d"),
          "Latest successful stage was not published.");
  Require(!state.PublishStage(slow_c, "/tmp/stage-c"),
          "Slow stage C replaced later successful stage D.");
  Require(state.Snapshot().staged_path == "/tmp/stage-d",
          "Latest successful stage does not own staged state.");
}

void FailedCheckInvalidatesPreviousStage() {
  ClientLifecycleState state;
  PrepareStage(&state, "/tmp/stage-before-check");
  const CheckLease failed_check = state.BeginCheck();
  Require(failed_check.status == ClientLifecycleStatus::kAllowed,
          "Failed check did not start.");
  // Simulate CheckForUpdateCore throwing before PublishCheck.
  const StageLease stage = state.BeginStage();
  const LifecycleSnapshot snapshot = state.Snapshot();
  Require(stage.status == ClientLifecycleStatus::kInvalidGeneration,
          "Stage accepted selection from a failed check.");
  Require(snapshot.check_generation == 0 && snapshot.staged_path.empty(),
          "Failed check retained previous check or stage state.");
}

void SchedulerFailureRestoresMatchingHandoff() {
  ClientLifecycleState state;
  PrepareStage(&state, "/tmp/stage-restore");
  try {
    const InstallHandoff handoff = state.BeginInstall();
    Require(handoff.status == ClientLifecycleStatus::kAllowed,
            "Install handoff was rejected.");
    InstallHandoff mismatched = handoff;
    ++mismatched.token;
    Require(!state.RollbackInstall(mismatched) &&
                state.Snapshot().install_in_progress,
            "Mismatched handoff token restored staged state.");
    SchedulingRollbackGuard guard(&state, handoff);
    throw std::runtime_error("injected scheduler throw");
  } catch (const std::runtime_error&) {
  }
  const LifecycleSnapshot snapshot = state.Snapshot();
  Require(!snapshot.install_in_progress &&
              snapshot.staged_path == "/tmp/stage-restore",
          "Scheduler throw did not restore matching staged state.");
}

void SchedulerReturnedFailureRestoresMatchingHandoff() {
  ClientLifecycleState state;
  PrepareStage(&state, "/tmp/stage-returned-failure");
  {
    const InstallHandoff handoff = state.BeginInstall();
    Require(handoff.status == ClientLifecycleStatus::kAllowed,
            "Install handoff was rejected.");
    SchedulingRollbackGuard guard(&state, handoff);
    const bool scheduler_ok = false;
    Require(!scheduler_ok, "Injected scheduler failure was not active.");
  }
  const LifecycleSnapshot snapshot = state.Snapshot();
  Require(!snapshot.install_in_progress &&
              snapshot.staged_path == "/tmp/stage-returned-failure",
          "Returned scheduler failure did not restore staged state.");
}

void RejectedCheckDuringSchedulingPreventsRollbackRestore() {
  ClientLifecycleState state;
  PrepareStage(&state, "/tmp/stage-rejected-check");
  SchedulerGate gate;
  const InstallHandoff handoff = state.BeginInstall();
  Require(handoff.status == ClientLifecycleStatus::kAllowed,
          "Install handoff was rejected.");
  std::thread scheduler([&] {
    SchedulingRollbackGuard guard(&state, handoff);
    gate.EnterAndWait();
    // Returning without confirmation simulates scheduler failure.
  });
  gate.WaitUntilEntered();

  const CheckLease rejected_check = state.BeginCheck();

  Require(rejected_check.status == ClientLifecycleStatus::kInstallInProgress,
          "Concurrent check was not rejected during scheduling.");
  gate.Release();
  scheduler.join();
  const LifecycleSnapshot snapshot = state.Snapshot();
  Require(!snapshot.install_in_progress && snapshot.staged_path.empty(),
          "Rejected check allowed scheduler rollback to restore old stage.");
  Require(snapshot.check_generation == 0,
          "Rejected check retained the old check identity.");
}

void RejectedStageDuringSchedulingPreventsRollbackRestore() {
  ClientLifecycleState state;
  PrepareStage(&state, "/tmp/stage-rejected-stage");
  SchedulerGate gate;
  const InstallHandoff handoff = state.BeginInstall();
  Require(handoff.status == ClientLifecycleStatus::kAllowed,
          "Install handoff was rejected.");
  std::thread scheduler([&] {
    SchedulingRollbackGuard guard(&state, handoff);
    gate.EnterAndWait();
    // Returning without confirmation simulates scheduler failure.
  });
  gate.WaitUntilEntered();

  const StageLease rejected_stage = state.BeginStage();

  Require(rejected_stage.status == ClientLifecycleStatus::kInstallInProgress,
          "Concurrent stage was not rejected during scheduling.");
  gate.Release();
  scheduler.join();
  const LifecycleSnapshot snapshot = state.Snapshot();
  Require(!snapshot.install_in_progress && snapshot.staged_path.empty(),
          "Rejected stage allowed scheduler rollback to restore old stage.");
}

void ConfirmedSchedulingNeverRestores() {
  ClientLifecycleState state;
  PrepareStage(&state, "/tmp/stage-confirmed");
  try {
    const InstallHandoff handoff = state.BeginInstall();
    Require(handoff.status == ClientLifecycleStatus::kAllowed,
            "Install handoff was rejected.");
    SchedulingRollbackGuard guard(&state, handoff);
    guard.Confirm();
    throw std::runtime_error("injected result construction failure");
  } catch (const std::runtime_error&) {
  }
  const LifecycleSnapshot snapshot = state.Snapshot();
  Require(snapshot.install_in_progress && snapshot.staged_path.empty(),
          "Confirmed scheduling restored a reusable stage.");
  Require(state.BeginInstall().status ==
              ClientLifecycleStatus::kInstallInProgress,
          "Confirmed scheduling allowed a second install.");
}

void NativeStagePathSurvivesLifecycle() {
  ClientLifecycleState state;
  const CheckLease check = state.BeginCheck();
  Require(state.PublishCheck(check, AvailableCheck()),
          "Check result was not published.");
  const StageLease stage = state.BeginStage();
  const std::filesystem::path native_path =
      std::filesystem::temp_directory_path() /
      std::filesystem::u8path(u8"güncelleme-日本") / "stage";
  Require(state.PublishFilesystemStage(stage, native_path, std::string(64, '1')),
          "Native staged path was not published.");
  const LifecycleSnapshot snapshot = state.Snapshot();
  Require(snapshot.staged_filesystem_path == native_path,
          "Snapshot did not retain the native staged path.");
  const InstallHandoff handoff = state.BeginInstall(snapshot);
  Require(handoff.status == ClientLifecycleStatus::kAllowed &&
              handoff.staged_filesystem_path == native_path,
          "Install handoff did not retain the native staged path.");
}

}  // namespace

void RunClientLifecycleTests() {
  ConcurrentInstallIsOneShot();
  LatestStageAttemptOwnsPublication();
  FailedCheckInvalidatesPreviousStage();
  SchedulerFailureRestoresMatchingHandoff();
  SchedulerReturnedFailureRestoresMatchingHandoff();
  RejectedStageDuringSchedulingPreventsRollbackRestore();
  RejectedCheckDuringSchedulingPreventsRollbackRestore();
  ConfirmedSchedulingNeverRestores();
  NativeStagePathSurvivesLifecycle();
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
