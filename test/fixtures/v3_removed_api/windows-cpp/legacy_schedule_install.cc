#include "desktop_updater_native_c.h"
#include <cstdint>

int ScheduleLegacyInstall(
    const desktop_updater_install_request_abi2* request) {
  (void)request;
  return static_cast<int>(reinterpret_cast<std::uintptr_t>(
      &desktop_updater_schedule_install_and_relaunch_v1));
}
