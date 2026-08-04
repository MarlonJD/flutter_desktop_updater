#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_HELPER_DIAGNOSTICS_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_HELPER_DIAGNOSTICS_H_

#include <string>

#include "native_install_request.h"

namespace desktop_updater::helper {

void EmitLinuxHelperDiagnostic(
    bool broker_mode,
    const desktop_updater::runtime::internal::NativeInstallTransactionRequestV1&
        request,
    const std::string& journal_state,
    const std::string& event,
    const std::string& detail_code) noexcept;

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_HELPER_DIAGNOSTICS_H_
