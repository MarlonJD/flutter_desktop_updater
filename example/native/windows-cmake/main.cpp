#include <cstring>

#include "desktop_updater_native_c.h"

int main() {
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
  return 0;
}
