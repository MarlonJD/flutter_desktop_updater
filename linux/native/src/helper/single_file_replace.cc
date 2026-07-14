#include "install_strategy.h"

#include <regex>

namespace desktop_updater::helper {

LinuxFileTransactionResult ExecuteLinuxSingleFileReplace(
    const LinuxSingleFileReplaceRequest& request,
    LinuxInstallPayloadVerifier& verifier,
    LinuxTransactionFaultInjector* fault_injector) {
  static const std::regex architecture("^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$");
  if (!std::regex_match(request.expected_architecture, architecture) ||
      request.verified_architecture != request.expected_architecture) {
    throw LinuxInstallStrategyError("AppImage architecture proof mismatch");
  }
  if (request.root_owned_target && !request.broker_authenticated) {
    throw LinuxInstallStrategyError(
        "root-owned AppImage requires authenticated broker");
  }
  LinuxFileTransaction transaction(
      request.target_path, request.stage_path, request.transaction_id,
      request.owner_process_id, request.expected_payload_identity, verifier,
      fault_injector);
  return transaction.Execute();
}

}  // namespace desktop_updater::helper
