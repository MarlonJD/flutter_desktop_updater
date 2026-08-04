#include "install_strategy.h"

#include <cstdlib>
#include <regex>
#include <utility>

namespace desktop_updater::helper {
namespace {

const std::regex kPackage("^[a-z0-9][a-z0-9+.-]{0,127}$");
const std::regex kVersion("^[A-Za-z0-9][A-Za-z0-9.+:~_-]{0,127}$");
const std::regex kArchitecture("^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$");
const std::regex kSha256("^[0-9a-f]{64}$");

bool HasExpectedExtension(const std::filesystem::path& path,
                          const std::string& extension) {
  return path.is_absolute() && path.lexically_normal() == path &&
         path.extension() == extension;
}

std::filesystem::path RepositoryConfigurationPath(
    const std::string& provider,
    const std::string& identity) {
  std::filesystem::path root;
#if defined(DESKTOP_UPDATER_NATIVE_TESTING)
  const char* override_root =
      std::getenv("DESKTOP_UPDATER_TEST_REPOSITORY_ROOT");
  if (override_root != nullptr && override_root[0] != '\0') {
    root = override_root;
  }
#endif
  if (root.empty()) {
    root = provider == "apt" ? "/etc/desktop-updater/repositories"
                             : "/etc/yum.repos.d";
  }
  return root /
         (provider == "apt" ? identity + ".sources"
                            : "desktop-updater-" + identity + ".repo");
}

void Validate(const LinuxSystemPackageRequest& request) {
  if ((request.provider != "apt" && request.provider != "dnf") ||
      !std::regex_match(request.package_id, kPackage) ||
      !std::regex_match(request.version, kVersion) ||
      !std::regex_match(request.architecture, kArchitecture) ||
      !std::regex_match(request.repository_identity, kSha256) ||
      !std::regex_match(request.source_artifact_sha256, kSha256) ||
      !request.caller_arguments.empty() ||
      !HasExpectedExtension(request.source_artifact_path,
                            request.provider == "apt" ? ".deb" : ".rpm")) {
    throw LinuxInstallStrategyError(
        "system package request or caller_arguments rejected");
  }
}

}  // namespace

LinuxProviderCommand BuildLinuxSystemPackageCommand(
    const LinuxSystemPackageRequest& request) {
  Validate(request);
  const std::string repository_configuration =
      RepositoryConfigurationPath(request.provider,
                                  request.repository_identity)
          .string();
  if (request.provider == "apt") {
    return {"/usr/bin/apt-get",
            {"-o",
             "Dir::Etc::sourcelist=" + repository_configuration,
             "-o", "Dir::Etc::sourceparts=-", "install", "--yes",
             "--only-upgrade", "--", request.source_artifact_path.string()},
            request.provider,
            request.package_id,
            request.version,
            request.architecture,
            "",
            request.repository_identity,
            request.source_artifact_path,
            request.source_artifact_sha256};
  }
  return {"/usr/bin/dnf",
          {"upgrade", "-y", "--disablerepo=*",
           "--enablerepo=desktop-updater-" + request.repository_identity,
           "--",
           request.source_artifact_path.string()},
          request.provider,
          request.package_id,
          request.version,
          request.architecture,
          "",
          request.repository_identity,
          request.source_artifact_path,
          request.source_artifact_sha256};
}

LinuxProviderTransaction StartLinuxSystemPackageTransaction(
    const LinuxSystemPackageRequest& request,
    LinuxProviderRunner& runner) {
  const auto command = BuildLinuxSystemPackageCommand(request);
  std::string identity = runner.StartFixed(command);
  if (identity.empty()) {
    throw LinuxInstallStrategyError("package manager transaction ID missing");
  }
  LinuxProviderTransaction transaction{
      request.provider, request.package_id, std::move(identity),
      LinuxProviderTransactionState::kManagerStarted};
  transaction.expected_architecture = request.architecture;
  transaction.provider_authority = request.repository_identity;
  return transaction;
}

LinuxProviderTransaction RecoverLinuxSystemPackageTransaction(
    LinuxProviderTransaction transaction,
    const std::string& expected_version,
    LinuxProviderRunner& runner) {
  if (transaction.transaction_identity.empty()) {
    transaction.state = LinuxProviderTransactionState::kManualActionRequired;
    return transaction;
  }
  const LinuxProviderStateObservation observation =
      runner.QueryInstalledState(transaction, expected_version);
  transaction.state = observation.state;
  if (!observation.transaction_identity.empty()) {
    transaction.transaction_identity = observation.transaction_identity;
  }
  return transaction;
}

LinuxProviderTransaction StartDurableLinuxSystemPackageTransaction(
    const std::string& transaction_id,
    const LinuxSystemPackageRequest& request,
    LinuxProviderRunner& runner,
    LinuxProviderJournal& journal) {
  const LinuxProviderCommand command = BuildLinuxSystemPackageCommand(request);
  LinuxProviderJournalRecord record;
  record.transaction_id = transaction_id;
  record.transaction = {
      request.provider, request.package_id,
      "pending-" + Sha256LinuxProviderCommand(command),
      LinuxProviderTransactionState::kPrepared};
  record.transaction.expected_architecture = request.architecture;
  record.transaction.provider_authority = request.repository_identity;
  record.expected_version_or_revision = request.version;
  record.command_sha256 = Sha256LinuxProviderCommand(command);
  journal.Persist(record);
  try {
    record.transaction.transaction_identity = runner.StartFixed(command);
    if (record.transaction.transaction_identity.empty()) {
      throw LinuxInstallStrategyError("package manager transaction ID missing");
    }
    record.transaction.state = LinuxProviderTransactionState::kManagerStarted;
    journal.Persist(record);
    return record.transaction;
  } catch (...) {
    record.transaction.state =
        LinuxProviderTransactionState::kVerificationPending;
    try {
      journal.Persist(record);
    } catch (...) {
    }
    throw;
  }
}

LinuxProviderTransaction RecoverDurableLinuxSystemPackageTransaction(
    const std::string& transaction_id,
    LinuxProviderRunner& runner,
    LinuxProviderJournal& journal) {
  const auto loaded = journal.Load(transaction_id);
  if (!loaded.has_value()) {
    throw LinuxProviderJournalError("provider transaction is not journaled");
  }
  LinuxProviderJournalRecord record = *loaded;
  if (record.transaction.provider != "apt" &&
      record.transaction.provider != "dnf") {
    throw LinuxProviderJournalError("provider journal strategy changed");
  }
  if (record.transaction.state == LinuxProviderTransactionState::kCompleted ||
      record.transaction.state ==
          LinuxProviderTransactionState::kManualActionRequired) {
    return record.transaction;
  }
  if (record.transaction.state == LinuxProviderTransactionState::kPrepared) {
    record.transaction.state =
        LinuxProviderTransactionState::kVerificationPending;
    journal.Persist(record);
  }
  record.transaction = RecoverLinuxSystemPackageTransaction(
      record.transaction, record.expected_version_or_revision, runner);
  journal.Persist(record);
  return record.transaction;
}

}  // namespace desktop_updater::helper
