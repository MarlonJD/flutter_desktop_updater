#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_PERSISTENT_RECOVERY_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_PERSISTENT_RECOVERY_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>

#include "helper_policy_windows.h"
#include "native_install_wire.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

class WindowsProcessLauncher;
class WindowsPortableTransactionStore;

class WindowsPersistentRecoveryError : public std::runtime_error {
 public:
  explicit WindowsPersistentRecoveryError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct WindowsPersistentTransactionRecord {
  static constexpr std::int64_t kSchemaVersion = 4;

  std::int64_t schema_version = kSchemaVersion;
  std::string transaction_id;
  // directoryReplace | windowsInno
  std::string transaction_kind;
  std::string policy_id;
  std::string package_id;
  std::string helper_endpoint_identity_sha256;
  std::int64_t executor_process_id = 0;
  std::int64_t executor_process_start_identity = 0;
  std::int64_t caller_process_id = 0;
  std::int64_t caller_process_start_identity = 0;
  std::string recovery_ready_nonce;
  std::filesystem::path target_path_hint;
  std::string record_state;
  std::string verified_outcome;
  // notRequested | launchPending | launchAttempting | launched | launchFailed
  std::string relaunch_state;
  std::string journal_canonical;
  std::string journal_sha256;

  std::string EncodeCanonical() const;
  static WindowsPersistentTransactionRecord DecodeStrict(
      const std::string& canonical_json);
};

struct WindowsPersistentResolverClaim {
  static constexpr std::int64_t kSchemaVersion = 1;

  std::int64_t schema_version = kSchemaVersion;
  std::string transaction_id;
  std::int64_t resolver_process_id = 0;
  std::int64_t resolver_process_start_identity = 0;
  std::int64_t caller_process_id = 0;
  std::int64_t caller_process_start_identity = 0;
  std::string claim_nonce;
  std::string state;

  bool operator==(const WindowsPersistentResolverClaim& other) const;
  std::string EncodeCanonical() const;
  static WindowsPersistentResolverClaim DecodeStrict(
      const std::string& canonical_json);
};

enum class WindowsResolverClaimDecision {
  kOwn,
  kFollow,
  kConsumed,
};

enum class WindowsAtMostOnceRelaunchOutcome {
  kNotOwned,
  kLaunched,
  kFailed,
};

enum class WindowsTerminalRelaunchDecision {
  kNotRequested,
  kAttempt,
  kAlreadyLaunched,
  kFailClosed,
};

WindowsTerminalRelaunchDecision DecideWindowsTerminalRelaunch(
    const std::string& relaunch_state);

// Consumes one durable attempt claim, persists launchAttempting before the OS
// call, and persists launched/launchFailed afterward. It never retries a
// consumed claim and therefore makes no exactly-once launch claim.
WindowsAtMostOnceRelaunchOutcome RunWindowsAtMostOnceRelaunch(
    std::function<bool()> consume_attempt_claim,
    std::function<void()> persist_attempting,
    std::function<void()> launch,
    std::function<void(bool)> persist_outcome);

desktop_updater::runtime::internal::NativeInstallTransactionStatusV1
StatusFromWindowsPersistentTerminalRecord(
    const WindowsPersistentTransactionRecord& record);

WindowsResolverClaimDecision DecideWindowsResolverClaim(
    const std::optional<WindowsPersistentResolverClaim>& existing,
    const WindowsPersistentResolverClaim& candidate, bool existing_owner_alive);

struct WindowsPersistentRecoveryAttempt {
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1 recovery;
  bool exact_owner_active = false;
};

struct WindowsResolveAfterExitCoordination {
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1 recovery;
  bool should_relaunch = false;
};

WindowsResolveAfterExitCoordination CoordinateWindowsResolveAfterExit(
    std::function<WindowsPersistentRecoveryAttempt()> attempt_recovery,
    std::function<bool()> wait_for_exact_owner,
    std::function<bool()> consume_relaunch_claim);

enum class WindowsAutonomousRecoveryAuthorityDecision {
  kPortableStableUser,
  kProtectedSystem,
  kReject,
};

WindowsAutonomousRecoveryAuthorityDecision
DecideWindowsAutonomousRecoveryAuthority(bool portable_policy,
                                         bool local_system,
                                         bool elevated,
                                         bool stable_host_verified);

enum class WindowsPersistentInnoRecoveryAction {
  kRecoveryRequired,
  kComplete,
  kRollBack,
  kManualActionRequired,
};

WindowsPersistentInnoRecoveryAction DecideWindowsPersistentInnoRecovery(
    const std::string& record_state,
    bool exact_owner_alive,
    bool desired_install_verified,
    bool old_install_verified);

class WindowsPersistentTransactionIndex {
 public:
  WindowsPersistentTransactionIndex(const WindowsHelperPolicy& policy,
                                    HANDLE caller_process,
                                    bool create_if_missing = true);
  ~WindowsPersistentTransactionIndex();
  WindowsPersistentTransactionIndex(const WindowsPersistentTransactionIndex&) =
      delete;
  WindowsPersistentTransactionIndex& operator=(
      const WindowsPersistentTransactionIndex&) = delete;

  void PersistPreparing(const std::string& transaction_id,
                        const std::string& transaction_kind,
                        const std::filesystem::path& target_path,
                        const std::string& journal_canonical,
                        DWORD executor_process_id,
                        std::uint64_t executor_process_start_identity,
                        DWORD caller_process_id,
                        std::uint64_t caller_process_start_identity,
                        const std::string& recovery_ready_nonce);
  void PersistActive(const std::string& transaction_id,
                     const std::string& journal_canonical);
  void MarkCommitAccepted(const std::string& transaction_id);
  void MarkCancelling(const std::string& transaction_id);
  void MarkRelaunchPending(const std::string& transaction_id);
  void MarkRelaunchAttempting(const std::string& transaction_id);
  void PersistRelaunchOutcome(const std::string& transaction_id,
                              bool launched);
  void PersistCleanupPending(const std::string& transaction_id,
                             const std::string& state,
                             const std::string& verified_outcome);
  void PersistTerminal(const std::string& transaction_id,
                       const std::string& state,
                       const std::string& verified_outcome);
  std::optional<WindowsPersistentTransactionRecord> Load(
      const std::string& transaction_id) const;
  WindowsResolverClaimDecision ClaimResolver(
      const WindowsPersistentResolverClaim& candidate);
  bool ConsumeResolverClaim(const WindowsPersistentResolverClaim& candidate);

 private:
  void PersistNew(const WindowsPersistentTransactionRecord& record);
  void Persist(const WindowsPersistentTransactionRecord& record);

  HKEY key_ = nullptr;
  std::unique_ptr<WindowsPortableTransactionStore> portable_store_;
  HANDLE caller_process_ = nullptr;
  bool portable_ = false;
  std::string policy_id_;
  std::string package_id_;
  std::string helper_endpoint_identity_sha256_;
};

class WindowsPersistentRecoveryService {
 public:
  WindowsPersistentRecoveryService(const WindowsHelperPolicy& policy,
                                   HANDLE caller_process);
  explicit WindowsPersistentRecoveryService(const WindowsHelperPolicy& policy);

  desktop_updater::runtime::internal::NativeInstallTransactionStatusV1 Query(
      const std::string& transaction_id);
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1 Recover(
      const std::string& transaction_id);
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
  RecoverAutonomously(const std::string& transaction_id,
                      std::function<void(const std::string&)> signal_ready);
  desktop_updater::runtime::internal::NativeInstallTransactionStatusV1
  ResolvePendingInstallAfterCallerExit(
      const std::string& transaction_id,
      std::function<void(const desktop_updater::runtime::internal::
                             NativeInstallTransactionStatusV1&)>
          acknowledge,
      WindowsProcessLauncher& launcher);

 private:
  void AuthenticateCaller() const;
  void AuthenticateAutonomousHost() const;
  void AuthenticateCallerForRecord(
      const WindowsPersistentTransactionRecord& record) const;
  void EnsureIndex();
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
  RecoverBound(const std::string& transaction_id, bool authenticate_caller,
               HANDLE proof_caller_process, bool* exact_owner_active = nullptr);
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
  RecoverActive(const WindowsPersistentTransactionRecord& record,
                HANDLE proof_caller_process, bool* exact_owner_active);
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
  RecoverPreparingWithoutJournal(
      const WindowsPersistentTransactionRecord& record,
      HANDLE proof_caller_process, bool* exact_owner_active);
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
  RecoverCleanupPending(const WindowsPersistentTransactionRecord& record,
                        bool* exact_owner_active);
  desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
  RecoverTerminal(const WindowsPersistentTransactionRecord& record,
                  HANDLE proof_caller_process);

  const WindowsHelperPolicy& policy_;
  HANDLE caller_process_;
  std::unique_ptr<WindowsPersistentTransactionIndex> index_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_PERSISTENT_RECOVERY_H_
