#include "desktop_updater_native_c.h"

/* Keep the diagnostic focused on the removed entry point, not removed types. */
int ScheduleLegacyInstall(
    const desktop_updater_install_request_abi2* request) {
  return desktop_updater_schedule_install_and_relaunch_v1(request);
}
