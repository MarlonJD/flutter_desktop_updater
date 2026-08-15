#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_POLICY_WINDOWS_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_POLICY_WINDOWS_H_

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace desktop_updater::helper {

struct WindowsReleaseRootPublicKey {
  std::string key_id;
  std::string algorithm;
  std::string public_key_base64;
};

struct WindowsAllowedInstallStrategy {
  std::string strategy;
  std::string provider;
};

class WindowsHelperPolicyError : public std::runtime_error {
 public:
  enum class Code {
    kInvalidPolicy,
    kPolicyDigestMismatch,
    kPortableElevationRejected,
  };

  WindowsHelperPolicyError(Code code, const std::string& detail);

  Code code() const noexcept { return code_; }

 private:
  Code code_;
};

class WindowsHelperPolicy {
 public:
  static WindowsHelperPolicy Load(
      const std::string& canonical_json,
      const std::string& sealed_policy_sha256,
      const std::string& expected_application_package_id,
      const std::string& sealed_helper_sha256);

  static WindowsHelperPolicy ForTesting(
      std::string application_package_id,
      std::string application_publisher,
      std::string helper_publisher,
      std::string helper_sha256,
      std::vector<std::wstring> allowed_install_roots);

  static WindowsHelperPolicy ForProtectedInnoTesting(
      std::string application_package_id,
      std::string application_publisher,
      std::string helper_publisher,
      std::string helper_sha256,
      std::vector<std::wstring> allowed_install_roots);

  static WindowsHelperPolicy ForPortableTesting(
      std::string application_package_id,
      std::string application_sha256,
      std::string helper_sha256);

  static WindowsHelperPolicyError::Code PortableElevationErrorForTesting();

  const std::string& application_package_id() const {
    return application_package_id_;
  }
  const std::string& policy_id() const { return policy_id_; }
  const std::string& helper_service_id() const { return helper_service_id_; }
  const std::string& application_publisher() const {
    return application_signer_identity_;
  }
  const std::string& helper_publisher() const {
    return helper_signer_identity_;
  }
  const std::string& application_signer_kind() const {
    return application_signer_kind_;
  }
  const std::string& application_signer_identity() const {
    return application_signer_identity_;
  }
  const std::string& helper_signer_kind() const {
    return helper_signer_kind_;
  }
  const std::string& helper_signer_identity() const {
    return helper_signer_identity_;
  }
  const std::string& helper_sha256() const { return helper_sha256_; }
  bool is_portable() const { return portable_; }
  const std::vector<std::wstring>& allowed_install_roots() const {
    return allowed_install_roots_;
  }
  const std::vector<std::string>& allowed_target_classes() const {
    return allowed_target_classes_;
  }
  const std::vector<WindowsReleaseRootPublicKey>&
  release_root_public_keys() const {
    return release_root_public_keys_;
  }
  const std::vector<WindowsAllowedInstallStrategy>& allowed_strategies()
      const {
    return allowed_strategies_;
  }
  std::int64_t minimum_helper_protocol_version() const {
    return minimum_helper_protocol_version_;
  }

  bool AllowsRequest(std::int64_t protocol_version,
                     const std::string& target_class,
                     const std::string& strategy,
                     const std::string& provider) const;

 private:
  WindowsHelperPolicy(std::string policy_id,
                      std::string application_package_id,
                      std::string helper_service_id,
                      std::string application_signer_kind,
                      std::string application_signer_identity,
                      std::string helper_signer_kind,
                      std::string helper_signer_identity,
                      std::string helper_sha256,
                      std::vector<std::wstring> allowed_install_roots,
                      std::vector<std::string> allowed_target_classes,
                      std::vector<WindowsReleaseRootPublicKey>
                          release_root_public_keys,
                      std::vector<WindowsAllowedInstallStrategy>
                          allowed_strategies,
                      std::int64_t minimum_helper_protocol_version);

  std::string policy_id_;
  std::string application_package_id_;
  std::string helper_service_id_;
  std::string application_signer_kind_;
  std::string application_signer_identity_;
  std::string helper_signer_kind_;
  std::string helper_signer_identity_;
  std::string helper_sha256_;
  bool portable_ = false;
  std::vector<std::wstring> allowed_install_roots_;
  std::vector<std::string> allowed_target_classes_;
  std::vector<WindowsReleaseRootPublicKey> release_root_public_keys_;
  std::vector<WindowsAllowedInstallStrategy> allowed_strategies_;
  std::int64_t minimum_helper_protocol_version_ = 0;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_POLICY_WINDOWS_H_
