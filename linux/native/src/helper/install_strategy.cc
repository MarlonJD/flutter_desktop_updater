#include "install_strategy.h"

#include <algorithm>
#include <set>
#include <utility>

namespace desktop_updater::helper {
namespace {

const std::set<std::pair<std::string, std::string>> kLinuxCapabilities = {
    {"directoryReplace", "platformDirectory"},
    {"singleFileReplace", "platformFile"},
    {"systemPackageTransaction", "apt"},
    {"systemPackageTransaction", "dnf"},
    {"externalManagedRefresh", "flatpak"},
    {"externalManagedRefresh", "snap"},
};

}  // namespace

LinuxStrategyCapability SelectLinuxInstallStrategy(
    const std::vector<LinuxStrategyCapability>& policy_capabilities,
    const std::vector<LinuxStrategyCapability>& protocol_capabilities,
    const LinuxStrategyRequest& request) {
  const std::pair<std::string, std::string> requested{request.strategy,
                                                      request.provider};
  if (kLinuxCapabilities.count(requested) == 0) {
    throw LinuxInstallStrategyError("unsupported strategy/provider pair");
  }
  if (!request.caller_arguments.empty()) {
    throw LinuxInstallStrategyError("caller_arguments are never executable");
  }
  if (request.direct_revision_mutation) {
    throw LinuxInstallStrategyError("direct managed revision mutation rejected");
  }
  if (request.dangerous_sideload) {
    throw LinuxInstallStrategyError("production dangerous sideload rejected");
  }
  if (request.strategy == "singleFileReplace" && request.root_owned_target &&
      !request.broker_authenticated) {
    throw LinuxInstallStrategyError(
        "root-owned AppImage requires authenticated installed broker");
  }
  const auto policy = std::find_if(
      policy_capabilities.begin(), policy_capabilities.end(),
      [&](const auto& capability) {
        return capability.strategy == request.strategy &&
               capability.provider == request.provider;
      });
  if (policy == policy_capabilities.end()) {
    throw LinuxInstallStrategyError("sealed policy denied capability");
  }
  const LinuxStrategyCapability capability{request.strategy, request.provider};
  if (std::find(protocol_capabilities.begin(), protocol_capabilities.end(),
                capability) == protocol_capabilities.end()) {
    throw LinuxInstallStrategyError("protocol capability missing");
  }
  return capability;
}

LinuxFileTransactionResult ExecuteLinuxDirectoryReplace(
    LinuxFileTransaction& transaction) {
  return transaction.Execute();
}

}  // namespace desktop_updater::helper
