#include "install_strategy.h"

#include <regex>
#include <utility>

namespace desktop_updater::helper {
namespace {

const std::regex kManagedId("^[A-Za-z0-9][A-Za-z0-9._-]{1,255}$");
const std::regex kTrack("^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$");

void ValidateBase(const LinuxExternalRefreshRequest& request) {
  if ((request.provider != "flatpak" && request.provider != "snap") ||
      !std::regex_match(request.package_id, kManagedId) ||
      !std::regex_match(request.branch_or_channel, kTrack) ||
      request.expected_revision.empty() || !request.caller_arguments.empty() ||
      request.dangerous_sideload || request.direct_revision_mutation) {
    throw LinuxInstallStrategyError(
        "managed refresh authority, caller_arguments, or revision target rejected");
  }
}

}  // namespace

LinuxProviderCommand BuildLinuxExternalRefreshCommand(
    const LinuxExternalRefreshRequest& request) {
  ValidateBase(request);
  if (request.provider == "flatpak") {
    if (!request.signed_remote && request.remote_identity != "flathub") {
      throw LinuxInstallStrategyError("Flatpak remote is not signed or Flathub");
    }
    return {"/usr/bin/flatpak",
            {"update", "--noninteractive", "--or-update",
             request.package_id + "//" + request.branch_or_channel}};
  }
  if (!request.public_or_brand_store) {
    throw LinuxInstallStrategyError(
        "Snap refresh requires public or Brand Store authority");
  }
  return {"/usr/bin/snap",
          {"refresh", request.package_id,
           "--channel=" + request.branch_or_channel}};
}

LinuxProviderTransaction StartLinuxExternalManagedRefresh(
    const LinuxExternalRefreshRequest& request,
    LinuxProviderRunner& runner) {
  const auto command = BuildLinuxExternalRefreshCommand(request);
  std::string identity = runner.StartFixed(command);
  if (identity.empty()) {
    throw LinuxInstallStrategyError("managed provider transaction ID missing");
  }
  return {request.provider, request.package_id, std::move(identity),
          LinuxProviderTransactionState::kManagerStarted};
}

LinuxProviderTransaction RecoverLinuxExternalManagedRefresh(
    LinuxProviderTransaction transaction,
    const std::string& expected_revision,
    LinuxProviderRunner& runner) {
  if (transaction.transaction_identity.empty()) {
    transaction.state = LinuxProviderTransactionState::kManualActionRequired;
    return transaction;
  }
  transaction.state = runner.QueryInstalledState(
      transaction.provider, transaction.transaction_identity,
      transaction.package_id, expected_revision);
  return transaction;
}

}  // namespace desktop_updater::helper
