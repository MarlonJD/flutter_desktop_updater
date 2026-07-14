#include "install_strategy.h"

#include <algorithm>
#include <set>
#include <utility>

namespace desktop_updater::helper {
namespace {

const std::set<std::pair<std::string, std::string>> kWindowsCapabilities = {
    {"directoryReplace", "platformDirectory"},
    {"verifiedInstallerHandoff", "windowsInno"},
};

}  // namespace

WindowsStrategyCapability SelectWindowsInstallStrategy(
    const std::vector<WindowsStrategyCapability>& policy_capabilities,
    const std::vector<WindowsStrategyCapability>& protocol_capabilities,
    const WindowsStrategyRequest& request) {
  const std::pair<std::string, std::string> requested{request.strategy,
                                                      request.provider};
  if (kWindowsCapabilities.count(requested) == 0) {
    throw WindowsInstallStrategyError("unsupported strategy/provider pair");
  }
  if (!request.caller_arguments.empty()) {
    throw WindowsInstallStrategyError("caller_arguments rejected");
  }
  if (request.direct_revision_mutation || request.dangerous_sideload) {
    throw WindowsInstallStrategyError("managed revision mutation rejected");
  }
  const auto policy = std::find_if(
      policy_capabilities.begin(), policy_capabilities.end(),
      [&](const auto& capability) {
        return capability.strategy == request.strategy &&
               capability.provider == request.provider;
      });
  if (policy == policy_capabilities.end()) {
    throw WindowsInstallStrategyError("sealed policy denied capability");
  }
  const WindowsStrategyCapability capability{request.strategy,
                                               request.provider};
  if (std::find(protocol_capabilities.begin(), protocol_capabilities.end(),
                capability) == protocol_capabilities.end()) {
    throw WindowsInstallStrategyError("protocol capability missing");
  }
  return capability;
}

WindowsFileTransactionResult ExecuteWindowsDirectoryReplace(
    WindowsFileTransaction& transaction) {
  return transaction.Execute();
}

}  // namespace desktop_updater::helper
