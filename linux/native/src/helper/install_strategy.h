#ifndef DESKTOP_UPDATER_LINUX_HELPER_INSTALL_STRATEGY_H_
#define DESKTOP_UPDATER_LINUX_HELPER_INSTALL_STRATEGY_H_

#include <sys/types.h>

#include <filesystem>
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
};

class LinuxProviderRunner {
 public:
  virtual ~LinuxProviderRunner() = default;
  virtual std::string StartFixed(const LinuxProviderCommand& command) = 0;
  virtual LinuxProviderTransactionState QueryInstalledState(
      const std::string& provider,
      const std::string& transaction_identity,
      const std::string& package_id,
      const std::string& expected_version_or_revision) = 0;
};

struct LinuxSystemPackageRequest {
  std::string provider;
  std::string package_id;
  std::string version;
  std::string architecture;
  std::string repository_identity;
  std::string source_artifact_sha256;
  std::vector<std::string> caller_arguments;
};

LinuxProviderCommand BuildLinuxSystemPackageCommand(
    const LinuxSystemPackageRequest& request);
LinuxProviderTransaction StartLinuxSystemPackageTransaction(
    const LinuxSystemPackageRequest& request,
    LinuxProviderRunner& runner);
LinuxProviderTransaction RecoverLinuxSystemPackageTransaction(
    LinuxProviderTransaction transaction,
    const std::string& expected_version,
    LinuxProviderRunner& runner);

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

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_INSTALL_STRATEGY_H_
