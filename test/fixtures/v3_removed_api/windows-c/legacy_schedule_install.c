#include "desktop_updater_native_c.h"
#include <stdint.h>

int schedule_legacy_install(
    const desktop_updater_install_request_abi2* request) {
  (void)request;
  return (int)(uintptr_t)&desktop_updater_schedule_install_and_relaunch_v1;
}
