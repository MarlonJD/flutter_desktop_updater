#ifndef DESKTOP_UPDATER_NATIVE_INTERNAL_H_
#define DESKTOP_UPDATER_NATIVE_INTERNAL_H_

#include <cstdint>
#include <string>

#include "desktop_updater_native.h"

namespace desktop_updater {
namespace native {
namespace internal {

InstallResult BuildInstallScriptForTesting(
    const InstallRequest& request,
    const std::string& running_executable,
    int64_t process_identifier,
    std::string* script);

}  // namespace internal
}  // namespace native
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_INTERNAL_H_
