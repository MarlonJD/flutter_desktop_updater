#ifndef DESKTOP_UPDATER_LINUX_HELPER_INSTALL_STRATEGY_H_
#define DESKTOP_UPDATER_LINUX_HELPER_INSTALL_STRATEGY_H_

#include <sys/types.h>

#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "linux_file_transaction.h"

namespace desktop_updater::helper {

struct LinuxStrategyCapability {
  std::string strategy;
  std::string provider;

  bool operator==(const LinuxStrategyCapability& other) const {
    return strategy == other.strategy && provider == other.provider;
  }
};

struct LinuxStrategyRequest {
  std::string strategy;
  std::string provider;
  bool broker_authenticated = false;
  bool root_owned_target = false;
  std::vector<std::string> caller_arguments;
  bool direct_revision_mutation = false;
  bool dangerous_sideload = false;
};

class LinuxInstallStrategyError : public std::runtime_error {
 public:
  explicit LinuxInstallStrategyError(const std::string& detail)
      : std::runtime_error(detail) {}
};

LinuxStrategyCapability SelectLinuxInstallStrategy(
    const std::vector<LinuxStrategyCapability>& policy_capabilities,
    const std::vector<LinuxStrategyCapability>& protocol_capabilities,
    const LinuxStrategyRequest& request);

LinuxFileTransactionResult ExecuteLinuxDirectoryReplace(
    LinuxFileTransaction& transaction);

struct LinuxSingleFileReplaceRequest {
  std::filesystem::path target_path;
  std::filesystem::path stage_path;
  std::string transaction_id;
  pid_t owner_process_id = 0;
  LinuxVerifiedPayloadIdentity expected_payload_identity;
  std::string expected_architecture;
  std::string verified_architecture;
  bool root_owned_target = false;
  bool broker_authenticated = false;
};

LinuxFileTransactionResult ExecuteLinuxSingleFileReplace(
    const LinuxSingleFileReplaceRequest& request,
    LinuxInstallPayloadVerifier& verifier,
    LinuxTransactionFaultInjector* fault_injector = nullptr);

struct LinuxProviderCommand {
  std::string executable;
  std::vector<std::string> arguments;
  std::string provider;
  std::string package_id;
  std::string expected_version_or_revision;
  std::string expected_architecture;
  std::string provider_scope;
  std::string repository_or_remote_identity;
  std::filesystem::path source_artifact_path;
  std::string source_artifact_sha256;
};

enum class LinuxProviderTransactionState {
  kPrepared,
  kManagerStarted,
  kVerificationPending,
  kCompleted,
  kManualActionRequired,
};

struct LinuxProviderTransaction {
  std::string provider;
  std::string package_id;
  std::string transaction_identity;
  LinuxProviderTransactionState state =
      LinuxProviderTransactionState::kPrepared;
  std::string expected_architecture;
  std::string provider_scope;
  std::string provider_authority;
};

struct LinuxProviderStateObservation {
  LinuxProviderTransactionState state =
      LinuxProviderTransactionState::kVerificationPending;
  std::string transaction_identity;
};

struct LinuxProviderProcessResult {
  int exit_code = -1;
  std::string standard_output;
  std::string transaction_identity;
};

class LinuxProviderProcessExecutor {
 public:
  virtual ~LinuxProviderProcessExecutor() = default;
  virtual LinuxProviderProcessResult Run(
      const std::string& executable,
      const std::vector<std::string>& arguments) = 0;
};

class PosixLinuxProviderProcessExecutor final
    : public LinuxProviderProcessExecutor {
 public:
  LinuxProviderProcessResult Run(
      const std::string& executable,
      const std::vector<std::string>& arguments) override;
};

class LinuxProviderRunner {
 public:
  virtual ~LinuxProviderRunner() = default;
  virtual std::string StartFixed(const LinuxProviderCommand& command) = 0;
  virtual LinuxProviderStateObservation QueryInstalledState(
      const LinuxProviderTransaction& transaction,
      const std::string& expected_version_or_revision) = 0;
};

// Production runner for the fixed APT, DNF, Flatpak, and Snap templates. It
// executes exact argv vectors directly (never through a shell), verifies a
// local deb/rpm payload by retained identity and SHA-256 before invoking the
// provider, and queries provider-owned installed state during recovery.
class LinuxFixedProviderRunner final : public LinuxProviderRunner {
 public:
  explicit LinuxFixedProviderRunner(LinuxProviderProcessExecutor& executor);

  std::string StartFixed(const LinuxProviderCommand& command) override;
  LinuxProviderStateObservation QueryInstalledState(
      const LinuxProviderTransaction& transaction,
      const std::string& expected_version_or_revision) override;

 private:
  LinuxProviderProcessExecutor& executor_;
};

class LinuxProviderJournalError : public std::runtime_error {
 public:
  explicit LinuxProviderJournalError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct LinuxProviderJournalRecord {
  static constexpr std::int64_t kSchemaVersion = 1;

  std::int64_t schema_version = kSchemaVersion;
  std::string transaction_id;
  LinuxProviderTransaction transaction;
  std::string expected_version_or_revision;
  std::string command_sha256;
};

class LinuxProviderJournal {
 public:
  LinuxProviderJournal(std::filesystem::path directory, uid_t uid, gid_t gid);
  ~LinuxProviderJournal();
  LinuxProviderJournal(const LinuxProviderJournal&) = delete;
  LinuxProviderJournal& operator=(const LinuxProviderJournal&) = delete;

  void Persist(const LinuxProviderJournalRecord& record) const;
  std::optional<LinuxProviderJournalRecord> Load(
      const std::string& transaction_id) const;

 private:
  std::filesystem::path directory_;
  uid_t uid_ = 0;
  gid_t gid_ = 0;
  int directory_fd_ = -1;
  std::uint64_t directory_device_ = 0;
  std::uint64_t directory_inode_ = 0;
};

struct LinuxSystemPackageRequest {
  std::string provider;
  std::string package_id;
  std::string version;
  std::string architecture;
  std::string repository_identity;
  std::string source_artifact_sha256;
  std::vector<std::string> caller_arguments;
  std::filesystem::path source_artifact_path;
};

LinuxProviderCommand BuildLinuxSystemPackageCommand(
    const LinuxSystemPackageRequest& request);
std::string Sha256LinuxProviderCommand(const LinuxProviderCommand& command);
LinuxProviderTransaction StartLinuxSystemPackageTransaction(
    const LinuxSystemPackageRequest& request,
    LinuxProviderRunner& runner);
LinuxProviderTransaction RecoverLinuxSystemPackageTransaction(
    LinuxProviderTransaction transaction,
    const std::string& expected_version,
    LinuxProviderRunner& runner);
LinuxProviderTransaction StartDurableLinuxSystemPackageTransaction(
    const std::string& transaction_id,
    const LinuxSystemPackageRequest& request,
    LinuxProviderRunner& runner,
    LinuxProviderJournal& journal);
LinuxProviderTransaction RecoverDurableLinuxSystemPackageTransaction(
    const std::string& transaction_id,
    LinuxProviderRunner& runner,
    LinuxProviderJournal& journal);

struct LinuxExternalRefreshRequest {
  std::string provider;
  std::string package_id;
  std::string branch_or_channel;
  std::string remote_identity;
  std::string expected_revision;
  bool signed_remote = false;
  bool public_or_brand_store = false;
  bool dangerous_sideload = false;
  bool direct_revision_mutation = false;
  std::vector<std::string> caller_arguments;
};

LinuxProviderCommand BuildLinuxExternalRefreshCommand(
    const LinuxExternalRefreshRequest& request);
LinuxProviderTransaction StartLinuxExternalManagedRefresh(
    const LinuxExternalRefreshRequest& request,
    LinuxProviderRunner& runner);
LinuxProviderTransaction RecoverLinuxExternalManagedRefresh(
    LinuxProviderTransaction transaction,
    const std::string& expected_revision,
    LinuxProviderRunner& runner);
LinuxProviderTransaction StartDurableLinuxExternalManagedRefresh(
    const std::string& transaction_id,
    const LinuxExternalRefreshRequest& request,
    LinuxProviderRunner& runner,
    LinuxProviderJournal& journal);
LinuxProviderTransaction RecoverDurableLinuxExternalManagedRefresh(
    const std::string& transaction_id,
    LinuxProviderRunner& runner,
    LinuxProviderJournal& journal);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_INSTALL_STRATEGY_H_
