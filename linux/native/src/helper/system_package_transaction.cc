#include "install_strategy.h"

#include <regex>
#include <utility>

namespace desktop_updater::helper {
namespace {

const std::regex kPackage("^[a-z0-9][a-z0-9+.-]{0,127}$");
const std::regex kVersion("^[A-Za-z0-9][A-Za-z0-9.+:~_-]{0,127}$");
const std::regex kArchitecture("^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$");
const std::regex kSha256("^[0-9a-f]{64}$");

void Validate(const LinuxSystemPackageRequest& request) {
  if ((request.provider != "apt" && request.provider != "dnf") ||
      !std::regex_match(request.package_id, kPackage) ||
      !std::regex_match(request.version, kVersion) ||
      !std::regex_match(request.architecture, kArchitecture) ||
      request.repository_identity.empty() ||
      !std::regex_match(request.source_artifact_sha256, kSha256) ||
      !request.caller_arguments.empty()) {
    throw LinuxInstallStrategyError(
        "system package request or caller_arguments rejected");
  }
}

}  // namespace

LinuxProviderCommand BuildLinuxSystemPackageCommand(
    const LinuxSystemPackageRequest& request) {
  Validate(request);
  if (request.provider == "apt") {
    return {"/usr/bin/apt-get",
            {"install", "--yes", "--only-upgrade",
             request.package_id + "=" + request.version}};
  }
  return {"/usr/bin/dnf",
          {"upgrade", "-y", "--",
           request.package_id + "-" + request.version + "." +
               request.architecture}};
}

LinuxProviderTransaction StartLinuxSystemPackageTransaction(
    const LinuxSystemPackageRequest& request,
    LinuxProviderRunner& runner) {
  const auto command = BuildLinuxSystemPackageCommand(request);
  std::string identity = runner.StartFixed(command);
  if (identity.empty()) {
    throw LinuxInstallStrategyError("package manager transaction ID missing");
  }
  return {request.provider, request.package_id, std::move(identity),
          LinuxProviderTransactionState::kManagerStarted};
}

LinuxProviderTransaction RecoverLinuxSystemPackageTransaction(
    LinuxProviderTransaction transaction,
    const std::string& expected_version,
    LinuxProviderRunner& runner) {
  if (transaction.transaction_identity.empty()) {
    transaction.state = LinuxProviderTransactionState::kManualActionRequired;
    return transaction;
  }
  transaction.state = runner.QueryInstalledState(
      transaction.provider, transaction.transaction_identity,
      transaction.package_id, expected_version);
  return transaction;
}

}  // namespace desktop_updater::helper
