#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_INSTALL_AUTHORIZER_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_INSTALL_AUTHORIZER_H_

#include <memory>
#include <filesystem>
#include <string>

#include "helper_policy_windows.h"
#include "native_install_authorization.h"
#include "native_install_session.h"
#include "stage_provenance.h"
#include "windows_archive_restage.h"
#include "windows_portable_recovery_host.h"
#include "windows_protected_helper_locator.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

desktop_updater::runtime::internal::NativeInstallAuthorizationPolicyV1
BuildWindowsNativeInstallAuthorizationPolicy(
    const WindowsHelperPolicy& policy);

WindowsVerifiedPayloadIdentity BuildWindowsExpectedPayloadIdentity(
    const desktop_updater::runtime::internal::
        NativeInstallTransactionRequestV1& request,
    const desktop_updater::runtime::internal::StageProvenanceMarker& marker,
    const std::string& payload_seal_sha256,
    const WindowsHelperPolicy& policy);

void ValidatePortableWindowsTargetAuthorityFacts(
    const std::wstring& target,
    const std::wstring& caller_executable,
    bool target_writable,
    bool parent_writable);

class WindowsNativeInstallAuthorizer final
    : public desktop_updater::runtime::internal::
          NativeInstallRequestAuthorizerV1 {
 public:
  WindowsNativeInstallAuthorizer(WindowsHelperPolicy policy,
                                 ProtectedWindowsHelperEndpointV1 endpoint,
                                 HANDLE caller_process);

  const std::string& helper_endpoint_identity_sha256() const override;
  std::unique_ptr<desktop_updater::runtime::internal::
                      NativeInstallPreparedTransactionV1>
  Authorize(const desktop_updater::runtime::internal::
                NativeInstallTransactionRequestV1& request) override;

 private:
  WindowsHelperPolicy policy_;
  ProtectedWindowsHelperEndpointV1 endpoint_;
  HANDLE caller_process_;
};

class WindowsPortableInstallAuthorizer final
    : public desktop_updater::runtime::internal::
          NativeInstallRequestAuthorizerV1 {
 public:
  WindowsPortableInstallAuthorizer(WindowsHelperPolicy policy,
                                   PortableWindowsRecoveryHostEndpointV1 endpoint,
                                   HANDLE caller_process);

  const std::string& helper_endpoint_identity_sha256() const override;
  std::unique_ptr<desktop_updater::runtime::internal::
                      NativeInstallPreparedTransactionV1>
  Authorize(const desktop_updater::runtime::internal::
                NativeInstallTransactionRequestV1& request) override;

 private:
  WindowsHelperPolicy policy_;
  PortableWindowsRecoveryHostEndpointV1 endpoint_;
  HANDLE caller_process_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_INSTALL_AUTHORIZER_H_
