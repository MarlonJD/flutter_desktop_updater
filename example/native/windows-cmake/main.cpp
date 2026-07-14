#include <cstring>

#include "desktop_updater_native.h"
#include "desktop_updater_native_c.h"

int main() {
  if (std::strcmp(DESKTOP_UPDATER_NATIVE_VERSION_STRING, "") == 0) {
    return 1;
  }
  desktop_updater_install_request_v1 request = {};
  request.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION + 1;
  request.struct_size = sizeof(request);

  desktop_updater_result_v1 result =
      desktop_updater_schedule_install_and_relaunch_v1(&request);
  const bool rejected =
      result.ok == 0 && result.error_message_utf8 != nullptr &&
      std::strstr(result.error_message_utf8, "ABI version") != nullptr;
  desktop_updater_result_free_v1(&result);
  if (!rejected) {
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
  return 0;
}
