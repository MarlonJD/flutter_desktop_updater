#ifndef DESKTOP_UPDATER_RUNTIME_INSTALL_HELPER_POLICY_H_
#define DESKTOP_UPDATER_RUNTIME_INSTALL_HELPER_POLICY_H_

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {

struct HelperPolicySigner {
  std::string kind;
  std::string value;
};

struct HelperPolicyReleaseRootPublicKey {
  std::string key_id;
  std::string algorithm;
  std::string public_key_base64;
};

struct HelperPolicyAllowedStrategy {
  std::string strategy;
  std::string provider;
};

struct HelperPolicyV1 {
  HelperPolicyV1(
      std::int64_t policy_version,
      std::string policy_id,
      std::string application_package_id,
      std::string helper_service_id,
      HelperPolicySigner allowed_application_signer,
      HelperPolicySigner allowed_helper_signer,
      std::vector<std::string> allowed_target_classes,
      std::vector<std::string> allowed_install_roots,
      std::vector<HelperPolicyReleaseRootPublicKey> release_root_public_keys,
      std::vector<HelperPolicyAllowedStrategy> allowed_strategies,
      std::int64_t minimum_helper_protocol_version,
      std::string canonical_json,
      std::string canonical_sha256);

  const std::int64_t policy_version;
  const std::string policy_id;
  const std::string application_package_id;
  const std::string helper_service_id;
  const HelperPolicySigner allowed_application_signer;
  const HelperPolicySigner allowed_helper_signer;
  const std::vector<std::string> allowed_target_classes;
  const std::vector<std::string> allowed_install_roots;
  const std::vector<HelperPolicyReleaseRootPublicKey> release_root_public_keys;
  const std::vector<HelperPolicyAllowedStrategy> allowed_strategies;
  const std::int64_t minimum_helper_protocol_version;
  const std::string canonical_json;
  const std::string canonical_sha256;
};

class HelperPolicyError : public std::runtime_error {
 public:
  explicit HelperPolicyError(std::string code);

  const std::string& code() const { return code_; }

 private:
  std::string code_;
};

HelperPolicyV1 ParseHelperPolicyV1(
    const std::string& json,
    const std::string& expected_application_package_id,
    std::int64_t minimum_accepted_policy_version);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_INSTALL_HELPER_POLICY_H_
