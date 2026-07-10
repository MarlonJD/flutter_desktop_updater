#ifndef DESKTOP_UPDATER_NATIVE_INTERNAL_H_
#define DESKTOP_UPDATER_NATIVE_INTERNAL_H_

#include <cstdint>
#include <string>
#include <sys/types.h>

#include "desktop_updater_native.h"

namespace desktop_updater {
namespace native {
namespace internal {

InstallResult BuildInstallScriptForTesting(
    const InstallRequest& request,
    const std::string& running_executable,
    int64_t process_identifier,
    std::string* script);

std::string DecodeMountInfoPath(const std::string& encoded);
InstallResult RejectNestedMountsForTesting(
    const std::string& target,
    const std::string& stage,
    const std::string& mount_info);
bool RemoveTreeAtForRecovery(int parent_fd,
                             const std::string& name,
                             dev_t root_device);

}  // namespace internal
}  // namespace native
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_INTERNAL_H_
