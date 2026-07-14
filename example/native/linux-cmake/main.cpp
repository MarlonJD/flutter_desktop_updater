#include "desktop_updater_native.h"
#include "desktop_updater_version.h"

int main() {
  if (DESKTOP_UPDATER_NATIVE_VERSION_STRING[0] == '\0') {
    return 1;
  }
  const std::string transaction_id =
      "00000000-0000-4000-8000-000000000012";
  const auto queried =
      desktop_updater::native::QueryTransaction(transaction_id);
  if (queried.result_code != desktop_updater::native::
                                 InstallTransactionResultCode::
                                     kEndpointUnavailable) {
    return 1;
  }
  const auto recovered =
      desktop_updater::native::RecoverPendingInstall(transaction_id);
  if (recovered.result_code != desktop_updater::native::
                                   InstallTransactionResultCode::
                                       kEndpointUnavailable) {
    return 1;
  }
  const desktop_updater::native::InstallRequest request = {
      desktop_updater::native::LinuxInstallOperation::kInstall,
      "/tmp/desktop_updater_consumer_staging",
      "/usr/bin",
      "desktop-updater-consumer",
      "com.example.desktop-updater-consumer",
      {},
      "",
  };
  const auto result =
      desktop_updater::native::ValidateInstallRequest(request);
  if (result.ok || result.error.find("protected") == std::string::npos) {
    return 1;
  }
  return 0;
}
