#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_HELPER_POLICY_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_HELPER_POLICY_H_

#include <sys/stat.h>
#include <sys/types.h>

#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

namespace desktop_updater::helper {

class LinuxHelperPolicyError : public std::runtime_error {
 public:
  explicit LinuxHelperPolicyError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct LinuxFileSecurity {
  uid_t uid;
  gid_t gid;
  mode_t mode;
  bool symbolic_link;
  bool writable_ancestor;
};

struct LinuxVerifiedFile {
  std::filesystem::path path;
  std::uint64_t device;
  std::uint64_t inode;
  std::string sha256;
  LinuxFileSecurity security;
};

class LinuxHelperPolicy {
 public:
  static LinuxHelperPolicy Load(const std::filesystem::path& policy_path,
                                const std::string& package_id);
  static LinuxHelperPolicy ForTesting(
      std::string package_id,
      std::string application_signer,
      std::string helper_sha256,
      std::filesystem::path broker_path,
      std::vector<std::filesystem::path> allowed_install_roots);

  const std::string& package_id() const { return package_id_; }
  const std::string& application_signer() const { return application_signer_; }
  const std::string& helper_sha256() const { return helper_sha256_; }
  const std::filesystem::path& broker_path() const { return broker_path_; }
  const std::vector<std::filesystem::path>& allowed_install_roots() const {
    return allowed_install_roots_;
  }
  const std::string& canonical_policy_json() const {
    return canonical_policy_json_;
  }

 private:
  LinuxHelperPolicy(std::string package_id,
                    std::string application_signer,
                    std::string helper_sha256,
                    std::filesystem::path broker_path,
                    std::vector<std::filesystem::path> allowed_install_roots,
                    std::string canonical_policy_json = {});

  std::string package_id_;
  std::string application_signer_;
  std::string helper_sha256_;
  std::filesystem::path broker_path_;
  std::vector<std::filesystem::path> allowed_install_roots_;
  std::string canonical_policy_json_;
};

void ValidateProtectedFileSecurity(const LinuxFileSecurity& security,
                                   const std::string& label);
LinuxVerifiedFile VerifyProtectedLinuxFile(
    const std::filesystem::path& path);
void ValidateLinuxBrokerIdentity(const LinuxVerifiedFile& broker,
                                 const LinuxHelperPolicy& policy);
void VerifyLinuxPeerExecutable(pid_t pid,
                               std::uint64_t expected_start_identity,
                               const std::string& expected_sha256);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_HELPER_POLICY_H_
