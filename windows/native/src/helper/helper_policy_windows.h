#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_POLICY_WINDOWS_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_POLICY_WINDOWS_H_

#include <stdexcept>
#include <string>
#include <vector>

namespace desktop_updater::helper {

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
  const std::string& application_publisher() const {
    return application_publisher_;
  }
  const std::string& helper_publisher() const { return helper_publisher_; }
  const std::string& helper_sha256() const { return helper_sha256_; }
  const std::vector<std::wstring>& allowed_install_roots() const {
    return allowed_install_roots_;
  }

 private:
  WindowsHelperPolicy(std::string application_package_id,
                      std::string application_publisher,
                      std::string helper_publisher,
                      std::string helper_sha256,
                      std::vector<std::wstring> allowed_install_roots);

  std::string application_package_id_;
  std::string application_publisher_;
  std::string helper_publisher_;
  std::string helper_sha256_;
  std::vector<std::wstring> allowed_install_roots_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_POLICY_WINDOWS_H_
