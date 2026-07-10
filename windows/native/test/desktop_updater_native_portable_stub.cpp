#if !defined(_WIN32)

#include "desktop_updater_native.h"

namespace desktop_updater {
namespace native {

InstallResult ScheduleInstallAndRelaunch(const InstallRequest&) {
  return {false, "Windows target-host scheduler is unavailable."};
}

}  // namespace native
}  // namespace desktop_updater

#endif
