#include "desktop_updater_native.h"

desktop_updater::native::InstallResult ScheduleLegacyInstall(
    const desktop_updater::native::InstallRequest& request) {
  return desktop_updater::native::ScheduleInstallAndRelaunch(request);
}
