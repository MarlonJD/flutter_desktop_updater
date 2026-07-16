#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_TRANSACTION_REGISTRY_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_TRANSACTION_REGISTRY_H_

#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "linux_transaction_journal.h"

namespace desktop_updater::helper {

class LinuxTransactionRegistryError : public std::runtime_error {
 public:
  explicit LinuxTransactionRegistryError(const std::string& detail)
      : std::runtime_error(detail) {}
};

enum class LinuxTransactionRegistryFaultPoint {
  kAfterNextCreate,
  kAfterNextFileSync,
  kAfterNextRename,
};

class LinuxTransactionRegistryFaultInjector {
 public:
  virtual ~LinuxTransactionRegistryFaultInjector() = default;
  virtual void OnLinuxTransactionRegistryFault(
      LinuxTransactionRegistryFaultPoint point) = 0;
};

struct LinuxTransactionRegistryRecord {
  static constexpr std::int64_t kSchemaVersion = 2;

  std::int64_t schema_version = kSchemaVersion;
  std::string transaction_id;
  std::string package_id;
  std::string policy_id;
  std::string helper_endpoint_identity_sha256;
  std::string recovery_authority_kind;
  std::string recovery_authority_generation_sha256;
  std::string recovery_policy_identity_sha256;
  std::string target_path;
  std::string canonical_request;
  std::string state;
  std::string result_code;
  std::string journal_sha256;
  LinuxVerifiedPayloadIdentity expected_payload_identity;

  std::string EncodeCanonical() const;
  static LinuxTransactionRegistryRecord DecodeStrict(
      const std::string& canonical_json);
};

std::string LinuxRecoveryAuthorityGenerationSha256(
    const std::string& transaction_id,
    const std::string& authority_kind,
    const std::string& helper_sha256,
    const std::string& policy_sha256);

// Opens a security-sensitive directory chain without following any component.
// The first [required_ancestor_count] components must already exist and be
// owned by [uid]:[gid] without group/world write bits. Remaining components
// are created or verified as exact private 0700 directories.
UniqueLinuxFd OpenSecureLinuxRegistryDirectoryTree(
    int root_directory,
    const std::vector<std::string>& components,
    std::size_t required_ancestor_count,
    uid_t uid,
    gid_t gid);

class LinuxTransactionRegistry {
 public:
  explicit LinuxTransactionRegistry(
      bool broker_mode,
      LinuxTransactionRegistryFaultInjector* fault_injector = nullptr);

  void Persist(const LinuxTransactionRegistryRecord& record) const;
  std::optional<LinuxTransactionRegistryRecord> Load(
      const std::string& transaction_id) const;
  void PreservePortableRecoveryAuthority(
      const std::filesystem::path& helper_executable,
      const std::filesystem::path& policy_file,
      LinuxTransactionRegistryRecord* record) const;
  void VerifyRecoveryAuthority(
      const LinuxTransactionRegistryRecord& record,
      const std::filesystem::path& helper_executable) const;
  std::filesystem::path PortableRecoveryAuthorityHelperPath(
      const std::string& transaction_id) const;
  const std::filesystem::path& directory() const { return directory_; }

 private:
  std::filesystem::path directory_;
  uid_t uid_ = 0;
  gid_t gid_ = 0;
  bool broker_mode_ = false;
  UniqueLinuxFd directory_fd_;
  LinuxFileIdentity directory_identity_;
  LinuxTransactionRegistryFaultInjector* fault_injector_ = nullptr;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_TRANSACTION_REGISTRY_H_
