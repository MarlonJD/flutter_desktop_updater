#ifndef DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_AUTHORIZATION_H_
#define DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_AUTHORIZATION_H_

#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

#include "native_install_request.h"
#include "release_contract.h"
#include "stage_provenance.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

class NativeInstallAuthorizationError : public std::runtime_error {
 public:
  explicit NativeInstallAuthorizationError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct NativeInstallAuthorizationReleaseKeyV1 {
  std::string key_id;
  std::string algorithm;
  std::string public_key_base64;
};

struct NativeInstallAuthorizationStrategyV1 {
  std::string strategy;
  std::string provider;
};

struct NativeInstallAuthorizationPolicyV1 {
  std::string policy_id;
  std::string application_package_id;
  std::vector<std::string> allowed_target_classes;
  std::vector<NativeInstallAuthorizationReleaseKeyV1>
      release_root_public_keys;
  std::vector<NativeInstallAuthorizationStrategyV1> allowed_strategies;
  std::int64_t minimum_helper_protocol_version = 0;
};

struct AuthorizedNativeInstallRequestV1 {
  ReleaseDescriptor descriptor;
};

using NativeInstallAuthorizationSha256 =
    std::function<std::string(const std::string& bytes)>;

AuthorizedNativeInstallRequestV1 AuthorizeNativeInstallTransactionRequestV1(
    const NativeInstallTransactionRequestV1& request,
    const NativeInstallAuthorizationPolicyV1& policy,
    const std::string& expected_platform,
    const std::string& release_manifest_json,
    const StageProvenanceMarker& marker,
    const std::string& marker_sha256,
    const NativeInstallAuthorizationSha256& sha256);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_AUTHORIZATION_H_
