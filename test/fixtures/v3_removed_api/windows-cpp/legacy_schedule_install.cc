#include "desktop_updater_native_c.h"

desktop_updater_result_v1 ScheduleLegacyInstall(
    const desktop_updater_install_request_v1* request) {
  return desktop_updater_schedule_install_and_relaunch_v1(request);
}
