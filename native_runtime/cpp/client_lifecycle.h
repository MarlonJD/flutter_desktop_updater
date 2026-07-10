#ifndef DESKTOP_UPDATER_NATIVE_RUNTIME_CLIENT_LIFECYCLE_H_
#define DESKTOP_UPDATER_NATIVE_RUNTIME_CLIENT_LIFECYCLE_H_

#include <cstdint>
#include <mutex>
#include <string>

#include "update_client_core.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

enum class ClientLifecycleStatus {
  kAllowed,
  kInstallInProgress,
  kInvalidGeneration,
  kNoStagedUpdate,
};

struct CheckLease {
  ClientLifecycleStatus status = ClientLifecycleStatus::kInvalidGeneration;
  std::uint64_t generation = 0;
};

struct StageLease {
  ClientLifecycleStatus status = ClientLifecycleStatus::kInvalidGeneration;
  std::uint64_t generation = 0;
  std::uint64_t attempt = 0;
  ClientCheckResult check;
};

struct InstallHandoff {
  ClientLifecycleStatus status = ClientLifecycleStatus::kNoStagedUpdate;
  std::uint64_t token = 0;
  std::uint64_t generation = 0;
  std::uint64_t stage_attempt = 0;
  std::string staged_path;
  std::string stage_provenance_sha256;
};

struct LifecycleSnapshot {
  ClientCheckResult check;
  std::string staged_path;
  std::string stage_provenance_sha256;
  std::uint64_t selection_generation = 0;
  std::uint64_t check_generation = 0;
  std::uint64_t stage_attempt = 0;
  std::uint64_t staged_generation = 0;
  std::uint64_t staged_attempt = 0;
  bool install_in_progress = false;
};

class ClientLifecycleState {
 public:
  CheckLease BeginCheck();
  bool PublishCheck(const CheckLease& lease, ClientCheckResult check);
  StageLease BeginStage();
  bool PublishStage(const StageLease& lease,
                    std::string staged_path,
                    std::string stage_provenance_sha256 = std::string());
  InstallHandoff BeginInstall();
  InstallHandoff BeginInstall(const LifecycleSnapshot& expected);
  bool RollbackInstall(const InstallHandoff& handoff);
  bool ConfirmInstall(const InstallHandoff& handoff);
  LifecycleSnapshot Snapshot() const;

 private:
  static void IncrementNonzero(std::uint64_t* value);
  void ClearStage();
  InstallHandoff BeginInstallLocked();

  mutable std::mutex mutex_;
  ClientCheckResult check_;
  std::string staged_path_;
  std::string stage_provenance_sha256_;
  std::uint64_t selection_generation_ = 0;
  std::uint64_t check_generation_ = 0;
  std::uint64_t stage_attempt_ = 0;
  std::uint64_t staged_generation_ = 0;
  std::uint64_t staged_attempt_ = 0;
  bool install_in_progress_ = false;
  std::uint64_t next_handoff_token_ = 0;
  std::uint64_t active_handoff_token_ = 0;
  bool scheduling_confirmed_ = false;
};

class SchedulingRollbackGuard {
 public:
  SchedulingRollbackGuard(ClientLifecycleState* state,
                          InstallHandoff handoff);
  ~SchedulingRollbackGuard();

  SchedulingRollbackGuard(const SchedulingRollbackGuard&) = delete;
  SchedulingRollbackGuard& operator=(const SchedulingRollbackGuard&) = delete;

  bool Confirm();

 private:
  ClientLifecycleState* state_;
  InstallHandoff handoff_;
  bool active_ = true;
};

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_RUNTIME_CLIENT_LIFECYCLE_H_
