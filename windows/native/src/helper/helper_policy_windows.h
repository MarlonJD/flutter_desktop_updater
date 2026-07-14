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

  static WindowsHelperPolicyError::Code PortableElevationErrorForTesting();

  const std::string& application_package_id() const {
    return application_package_id_;
  }
  const std::string& policy_id() const { return policy_id_; }
  const std::string& helper_service_id() const { return helper_service_id_; }
  const std::string& application_publisher() const {
    return application_publisher_;
  }
  const std::string& helper_publisher() const { return helper_publisher_; }
  const std::string& helper_sha256() const { return helper_sha256_; }
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
                      std::string application_publisher,
                      std::string helper_publisher,
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
  std::string application_publisher_;
  std::string helper_publisher_;
  std::string helper_sha256_;
  std::vector<std::wstring> allowed_install_roots_;
  std::vector<std::string> allowed_target_classes_;
  std::vector<WindowsReleaseRootPublicKey> release_root_public_keys_;
  std::vector<WindowsAllowedInstallStrategy> allowed_strategies_;
  std::int64_t minimum_helper_protocol_version_ = 0;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_POLICY_WINDOWS_H_
