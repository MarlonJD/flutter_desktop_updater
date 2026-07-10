#ifndef DESKTOP_UPDATER_NATIVE_C_INTERNAL_H_
#define DESKTOP_UPDATER_NATIVE_C_INTERNAL_H_

#include <functional>

#include "desktop_updater_native.h"
#include "desktop_updater_native_c.h"

namespace desktop_updater {
namespace native {
namespace internal {

using InstallScheduler =
    std::function<InstallResult(const InstallRequest& request)>;

desktop_updater_result_v1 ScheduleInstallAndRelaunchWith(
    const desktop_updater_install_request_v1* request,
    const InstallScheduler& scheduler);

}  // namespace internal
}  // namespace native
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_C_INTERNAL_H_
