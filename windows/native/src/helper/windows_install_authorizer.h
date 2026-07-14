#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_INSTALL_AUTHORIZER_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_INSTALL_AUTHORIZER_H_

#include <memory>
#include <string>

#include "helper_policy_windows.h"
#include "native_install_authorization.h"
#include "native_install_session.h"
#include "stage_provenance.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

desktop_updater::runtime::internal::NativeInstallAuthorizationPolicyV1
BuildWindowsNativeInstallAuthorizationPolicy(
    const WindowsHelperPolicy& policy);

WindowsVerifiedPayloadIdentity BuildWindowsExpectedPayloadIdentity(
    const desktop_updater::runtime::internal::
        NativeInstallTransactionRequestV1& request,
    const desktop_updater::runtime::internal::StageProvenanceMarker& marker,
    const WindowsHelperPolicy& policy);

class WindowsNativeInstallAuthorizer final
    : public desktop_updater::runtime::internal::
          NativeInstallRequestAuthorizerV1 {
 public:
  explicit WindowsNativeInstallAuthorizer(WindowsHelperPolicy policy);

  const std::string& helper_endpoint_identity_sha256() const override;
  std::unique_ptr<desktop_updater::runtime::internal::
                      NativeInstallPreparedTransactionV1>
  Authorize(const desktop_updater::runtime::internal::
                NativeInstallTransactionRequestV1& request) override;

 private:
  WindowsHelperPolicy policy_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_INSTALL_AUTHORIZER_H_
