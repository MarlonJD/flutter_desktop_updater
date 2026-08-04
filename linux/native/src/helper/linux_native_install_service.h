#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_NATIVE_INSTALL_SERVICE_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_NATIVE_INSTALL_SERVICE_H_

#include <filesystem>
#include <string>

#include "native_install_service_runtime.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {

void ProveAuthenticatedLinuxInstallTarget(
    const LinuxPeerBinding& peer,
    const desktop_updater::runtime::internal::
        NativeInstallTransactionRequestV1& request,
    int retained_target_root);

void RunLinuxNativeInstallService(
    desktop_updater::runtime::internal::NativeInstallWireChannelV1& channel,
    const LinuxPeerBinding& peer,
    const std::filesystem::path& helper_executable,
    bool broker_mode,
    const std::string& canonical_request);

void RunLinuxNativeInstallControlService(
    desktop_updater::runtime::internal::NativeInstallWireChannelV1& channel,
    const LinuxPeerBinding& peer,
    const std::filesystem::path& helper_executable,
    bool broker_mode,
    const std::string& canonical_request);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_NATIVE_INSTALL_SERVICE_H_
