#include "linux_helper_policy.h"

#include <fcntl.h>
#include <openssl/sha.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <iomanip>
#include <regex>
#include <set>
#include <sstream>
#include <utility>

#include "install_helper_policy.h"
#include "json_value.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseHelperPolicyV1;
using desktop_updater::runtime::internal::ParseJson;

const std::regex kSha256("^[0-9a-f]{64}$");

class ScopedFd {
 public:
  explicit ScopedFd(int fd = -1) : fd_(fd) {}
  ~ScopedFd() {
    if (fd_ >= 0) close(fd_);
  }
  int get() const { return fd_; }

 private:
  int fd_;
};

void RequireKeys(const JsonValue& value,
                 const std::set<std::string>& expected) {
  const auto& object = value.object();
  if (object.size() != expected.size()) {
    throw LinuxHelperPolicyError("sealed policy wrapper fields rejected");
  }
  for (const std::string& key : expected) {
    if (object.find(key) == object.end()) {
      throw LinuxHelperPolicyError("sealed policy wrapper fields rejected");
    }
  }
}

std::string ReadAll(int fd, std::size_t maximum) {
  std::string result;
  std::array<char, 4096> buffer{};
  for (;;) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if (count == 0) return result;
    if (count < 0 || result.size() + static_cast<std::size_t>(count) > maximum) {
      throw LinuxHelperPolicyError("protected file read failed");
    }
    result.append(buffer.data(), static_cast<std::size_t>(count));
  }
}

std::string Sha256File(int fd) {
  if (lseek(fd, 0, SEEK_SET) < 0) {
    throw LinuxHelperPolicyError("protected file seek failed");
  }
  SHA256_CTX context{};
  SHA256_Init(&context);
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if (count == 0) break;
    if (count < 0) throw LinuxHelperPolicyError("protected file hash failed");
    SHA256_Update(&context, buffer.data(), static_cast<std::size_t>(count));
  }
  std::array<unsigned char, SHA256_DIGEST_LENGTH> digest{};
  SHA256_Final(digest.data(), &context);
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (unsigned char byte : digest) {
    output << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return output.str();
}

bool HasWritableAncestor(std::filesystem::path path) {
  path = std::filesystem::absolute(path).lexically_normal().parent_path();
  while (!path.empty()) {
    struct stat status {};
    if (lstat(path.c_str(), &status) != 0 || status.st_uid != 0 ||
        (status.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
        S_ISLNK(status.st_mode)) {
      return true;
    }
    const auto parent = path.parent_path();
    if (parent == path) break;
    path = parent;
  }
  return false;
}

}  // namespace

void ValidateProtectedFileSecurity(const LinuxFileSecurity& security,
                                   const std::string& label) {
  if (security.uid != 0 || !S_ISREG(security.mode) || security.symbolic_link ||
      security.writable_ancestor ||
      (security.mode & (S_IWGRP | S_IWOTH)) != 0) {
    throw LinuxHelperPolicyError(label + " is not root-owned and sealed");
  }
}

LinuxVerifiedFile VerifyProtectedLinuxFile(
    const std::filesystem::path& path) {
  struct stat path_status {};
  if (lstat(path.c_str(), &path_status) != 0 || S_ISLNK(path_status.st_mode)) {
    throw LinuxHelperPolicyError("protected file path is missing or symlinked");
  }
  ScopedFd fd(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  struct stat status {};
  if (fd.get() < 0 || fstat(fd.get(), &status) != 0 ||
      path_status.st_dev != status.st_dev || path_status.st_ino != status.st_ino) {
    throw LinuxHelperPolicyError("protected file identity changed");
  }
  LinuxFileSecurity security{status.st_uid, status.st_gid, status.st_mode,
                             false, HasWritableAncestor(path)};
  ValidateProtectedFileSecurity(security, "protected file");
  return {path, static_cast<std::uint64_t>(status.st_dev),
          static_cast<std::uint64_t>(status.st_ino), Sha256File(fd.get()),
          security};
}

LinuxHelperPolicy::LinuxHelperPolicy(
    std::string package_id,
    std::string application_signer,
    std::string helper_sha256,
    std::filesystem::path broker_path,
    std::vector<std::filesystem::path> allowed_install_roots,
    std::string canonical_policy_json)
    : package_id_(std::move(package_id)),
      application_signer_(std::move(application_signer)),
      helper_sha256_(std::move(helper_sha256)),
      broker_path_(std::move(broker_path)),
      allowed_install_roots_(std::move(allowed_install_roots)),
      canonical_policy_json_(std::move(canonical_policy_json)) {
  if (package_id_.empty() || application_signer_.empty() ||
      !std::regex_match(helper_sha256_, kSha256) ||
      broker_path_ != "/usr/libexec/desktop-updater-helper" ||
      allowed_install_roots_.empty()) {
    throw LinuxHelperPolicyError("portable or unsealed elevation rejected");
  }
  for (const auto& root : allowed_install_roots_) {
    if (!root.is_absolute() || root == "/") {
      throw LinuxHelperPolicyError("privileged install root rejected");
    }
  }
}

LinuxHelperPolicy LinuxHelperPolicy::ForTesting(
    std::string package_id,
    std::string application_signer,
    std::string helper_sha256,
    std::filesystem::path broker_path,
    std::vector<std::filesystem::path> allowed_install_roots) {
  return LinuxHelperPolicy(
      std::move(package_id), std::move(application_signer),
      std::move(helper_sha256), std::move(broker_path),
      std::move(allowed_install_roots));
}

LinuxHelperPolicy LinuxHelperPolicy::Load(
    const std::filesystem::path& policy_path,
    const std::string& package_id) {
  const LinuxVerifiedFile policy_file = VerifyProtectedLinuxFile(policy_path);
  ScopedFd fd(open(policy_path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  if (fd.get() < 0) throw LinuxHelperPolicyError("policy reopen failed");
  const JsonValue wrapper = ParseJson(ReadAll(fd.get(), 128 * 1024));
  RequireKeys(wrapper,
              {"applicationPackageId", "brokerPath", "canonicalPolicyJson",
               "canonicalPolicySha256", "helperSha256"});
  if (wrapper.at("applicationPackageId").string() != package_id) {
    throw LinuxHelperPolicyError("exact package policy mismatch");
  }
  const auto parsed = ParseHelperPolicyV1(
      wrapper.at("canonicalPolicyJson").string(), package_id, 1);
  if (parsed.canonical_sha256 !=
          wrapper.at("canonicalPolicySha256").string() ||
      parsed.allowed_application_signer.kind != "sha256" ||
      parsed.allowed_helper_signer.kind != "sha256" ||
      parsed.allowed_helper_signer.value != wrapper.at("helperSha256").string()) {
    throw LinuxHelperPolicyError("sealed policy digest or signer mismatch");
  }
  std::vector<std::filesystem::path> roots;
  for (const auto& root : parsed.allowed_install_roots) roots.emplace_back(root);
  (void)policy_file;
  return LinuxHelperPolicy(
      package_id, parsed.allowed_application_signer.value,
      wrapper.at("helperSha256").string(), wrapper.at("brokerPath").string(),
      std::move(roots), parsed.canonical_json);
}

void ValidateLinuxBrokerIdentity(const LinuxVerifiedFile& broker,
                                 const LinuxHelperPolicy& policy) {
  ValidateProtectedFileSecurity(broker.security, "broker");
  if (broker.path != policy.broker_path() ||
      broker.sha256 != policy.helper_sha256() || broker.device == 0 ||
      broker.inode == 0) {
    throw LinuxHelperPolicyError("broker path, inode, or helperSha256 mismatch");
  }
}

void VerifyLinuxPeerExecutable(pid_t pid,
                               std::uint64_t expected_start_identity,
                               const std::string& expected_sha256) {
  const auto start_before = LinuxProcessStartIdentity(pid);
  if (start_before != expected_start_identity) {
    throw LinuxHelperPolicyError("caller process identity changed");
  }
  const std::filesystem::path proc_exe =
      "/proc/" + std::to_string(pid) + "/exe";
  ScopedFd fd(open(proc_exe.c_str(), O_RDONLY | O_CLOEXEC));
  if (fd.get() < 0 || Sha256File(fd.get()) != expected_sha256 ||
      LinuxProcessStartIdentity(pid) != expected_start_identity) {
    throw LinuxHelperPolicyError("caller executable digest mismatch");
  }
}

}  // namespace desktop_updater::helper
