#include "linux_transaction_registry.h"

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <openssl/evp.h>

#include <array>
#include <cerrno>
#include <cstdlib>
#include <filesystem>
#include <iomanip>
#include <set>
#include <sstream>
#include <string>
#include <utility>

#include "json_value.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

namespace fs = std::filesystem;
using runtime::internal::EncodeCanonicalJson;
using runtime::internal::JsonValue;
using runtime::internal::ParseJson;

bool IsUuid(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-' || value[14] != '4' ||
      std::string("89ab").find(value[19]) == std::string::npos) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const unsigned char byte = value[index];
    if (!((byte >= '0' && byte <= '9') ||
          (byte >= 'a' && byte <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool IsSha256(const std::string& value) {
  if (value.size() != 64) return false;
  for (unsigned char byte : value) {
    if (!((byte >= '0' && byte <= '9') ||
          (byte >= 'a' && byte <= 'f'))) {
      return false;
    }
  }
  return true;
}

void RequireKeys(const JsonValue& value,
                 const std::set<std::string>& expected) {
  if (value.object().size() != expected.size()) {
    throw LinuxTransactionRegistryError("transaction index fields rejected");
  }
  for (const std::string& key : expected) {
    if (value.find(key) == nullptr) {
      throw LinuxTransactionRegistryError(
          "transaction index fields rejected");
    }
  }
}

void ValidatePayload(const LinuxVerifiedPayloadIdentity& value) {
  if (value.package_id.empty() || value.signer_identity.empty() ||
      !IsSha256(value.package_identity_sha256) ||
      !IsSha256(value.stage_provenance_sha256) ||
      !IsSha256(value.artifact_sha256) ||
      value.executable_relative_path.empty() ||
      !IsSha256(value.executable_sha256) || value.executable_mode == 0) {
    throw LinuxTransactionRegistryError(
        "transaction payload identity rejected");
  }
}

void ValidateRecord(const LinuxTransactionRegistryRecord& value) {
  static const std::set<std::string> states = {
      "preparing", "prepared", "commitAccepted", "completed", "rolledBack",
      "recoveryRequired", "manualActionRequired", "launchPending",
      "launchAttempting", "launched", "launchFailed"};
  static const std::set<std::string> result_codes = {
      "recoveryRequired", "completed", "rolledBack",
      "manualActionRequired", "relaunchFailure"};
  const bool state_result_match =
      ((value.state == "preparing" || value.state == "prepared" ||
        value.state == "commitAccepted" ||
        value.state == "recoveryRequired" || value.state == "launchPending") &&
       value.result_code == "recoveryRequired") ||
      ((value.state == "completed" || value.state == "launched") &&
       value.result_code == "completed") ||
      (value.state == "rolledBack" && value.result_code == "rolledBack") ||
      (value.state == "manualActionRequired" &&
       value.result_code == "manualActionRequired") ||
      ((value.state == "launchAttempting" || value.state == "launchFailed") &&
       value.result_code == "relaunchFailure");
  if (value.schema_version != LinuxTransactionRegistryRecord::kSchemaVersion ||
      !IsUuid(value.transaction_id) || value.package_id.empty() ||
      value.policy_id.empty() ||
      !IsSha256(value.helper_endpoint_identity_sha256) ||
      (value.recovery_authority_kind != "fixedBroker" &&
       value.recovery_authority_kind != "retainedPortable") ||
      !IsSha256(value.recovery_authority_generation_sha256) ||
      !IsSha256(value.recovery_policy_identity_sha256) ||
      value.recovery_authority_generation_sha256 !=
          LinuxRecoveryAuthorityGenerationSha256(
              value.transaction_id, value.recovery_authority_kind,
              value.helper_endpoint_identity_sha256,
              value.recovery_policy_identity_sha256) ||
      !fs::path(value.target_path).is_absolute() ||
      value.canonical_request.empty() || states.count(value.state) == 0 ||
      result_codes.count(value.result_code) == 0 ||
      !state_result_match ||
      !IsSha256(value.journal_sha256)) {
    throw LinuxTransactionRegistryError("transaction index record rejected");
  }
  ValidatePayload(value.expected_payload_identity);
}

JsonValue EncodePayload(const LinuxVerifiedPayloadIdentity& payload) {
  JsonValue::Object value;
  value.emplace("artifactSha256", JsonValue(payload.artifact_sha256));
  value.emplace("executableGid",
                JsonValue(static_cast<std::int64_t>(payload.executable_gid)));
  value.emplace("executableMode",
                JsonValue(static_cast<std::int64_t>(payload.executable_mode)));
  value.emplace("executableRelativePath",
                JsonValue(payload.executable_relative_path));
  value.emplace("executableSha256", JsonValue(payload.executable_sha256));
  value.emplace("executableUid",
                JsonValue(static_cast<std::int64_t>(payload.executable_uid)));
  value.emplace("packageId", JsonValue(payload.package_id));
  value.emplace("packageIdentitySha256",
                JsonValue(payload.package_identity_sha256));
  value.emplace("signerIdentity", JsonValue(payload.signer_identity));
  // ABI compatibility keeps this legacy field name. On Linux it contains the
  // helper-authored payload seal SHA-256, never the caller stage marker hash.
  value.emplace("stageProvenanceSha256",
                JsonValue(payload.stage_provenance_sha256));
  return JsonValue(std::move(value));
}

LinuxVerifiedPayloadIdentity DecodePayload(const JsonValue& value) {
  RequireKeys(value,
              {"artifactSha256", "executableGid", "executableMode",
               "executableRelativePath", "executableSha256",
               "executableUid", "packageId", "packageIdentitySha256",
               "signerIdentity", "stageProvenanceSha256"});
  LinuxVerifiedPayloadIdentity payload{
      value.at("packageId").string(),
      value.at("signerIdentity").string(),
      value.at("packageIdentitySha256").string(),
      value.at("stageProvenanceSha256").string(),
      value.at("artifactSha256").string(),
      value.at("executableRelativePath").string(),
      value.at("executableSha256").string(),
      static_cast<std::uint32_t>(value.at("executableMode").integer()),
      static_cast<std::uint32_t>(value.at("executableUid").integer()),
      static_cast<std::uint32_t>(value.at("executableGid").integer())};
  ValidatePayload(payload);
  return payload;
}

void VerifySecureDirectory(const fs::path& path, uid_t uid, gid_t gid) {
  struct stat status {};
  if (lstat(path.c_str(), &status) != 0 || !S_ISDIR(status.st_mode) ||
      S_ISLNK(status.st_mode) || status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & 07777) != 0700) {
    throw LinuxTransactionRegistryError(
        "transaction state directory is not private");
  }
}

void RequireSecureAncestorDirectory(int fd, uid_t uid, gid_t gid) {
  struct stat status {};
  if (fstat(fd, &status) != 0 || !S_ISDIR(status.st_mode) ||
      status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
    throw LinuxTransactionRegistryError(
        "transaction state ancestor security rejected");
  }
}

void RequirePrivateRegistryDirectory(int fd, uid_t uid, gid_t gid) {
  struct stat status {};
  if (fstat(fd, &status) != 0 || !S_ISDIR(status.st_mode) ||
      status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & 07777) != 0700) {
    throw LinuxTransactionRegistryError(
        "transaction state directory is not private");
  }
}

fs::path EnsurePortableDirectory() {
  const char* encoded = std::getenv("XDG_STATE_HOME");
  fs::path state_home;
  if (encoded != nullptr && encoded[0] != '\0') {
    state_home = encoded;
  } else {
    const char* home = std::getenv("HOME");
    if (home == nullptr || home[0] == '\0') {
      throw LinuxTransactionRegistryError("state home is unavailable");
    }
    state_home = fs::path(home) / ".local" / "state";
  }
  state_home = state_home.lexically_normal();
  if (!state_home.is_absolute()) {
    throw LinuxTransactionRegistryError("state home locator rejected");
  }
  const bool state_home_existed = fs::exists(state_home);
  std::error_code error;
  fs::create_directories(state_home, error);
  if (error || (!state_home_existed && chmod(state_home.c_str(), 0700) != 0)) {
    throw LinuxTransactionRegistryError("state home creation failed");
  }
  VerifySecureDirectory(state_home, geteuid(), getegid());
  fs::path current = state_home;
  for (const char* leaf : {"desktop-updater", "transactions"}) {
    current /= leaf;
    bool created = false;
    if (mkdir(current.c_str(), 0700) == 0) {
      created = true;
    } else if (errno != EEXIST) {
      throw LinuxTransactionRegistryError(
          "transaction state directory creation failed");
    }
    if (created && chmod(current.c_str(), 0700) != 0) {
      throw LinuxTransactionRegistryError(
          "transaction state directory chmod failed");
    }
    VerifySecureDirectory(current, geteuid(), getegid());
  }
  return current;
}

void RequireRegistryFileIdentity(int fd, uid_t uid, gid_t gid) {
  struct stat status {};
  if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & 07777) != 0600) {
    throw LinuxTransactionRegistryError("transaction index identity rejected");
  }
}

std::string ReadAll(int fd);

void RequireAuthorityFileIdentity(int fd,
                                  uid_t uid,
                                  gid_t gid,
                                  mode_t mode) {
  struct stat status {};
  if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & 07777) != mode) {
    throw LinuxTransactionRegistryError(
        "recovery authority file identity rejected");
  }
}

void CopyBoundedFile(int source, int destination) {
  constexpr std::size_t kMaximumAuthorityFile = 128 * 1024 * 1024;
  std::array<char, 64 * 1024> buffer{};
  std::size_t total = 0;
  for (;;) {
    ssize_t count = -1;
    do {
      count = read(source, buffer.data(), buffer.size());
    } while (count < 0 && errno == EINTR);
    if (count == 0) return;
    if (count < 0 || total + static_cast<std::size_t>(count) >
                         kMaximumAuthorityFile) {
      throw LinuxTransactionRegistryError(
          "recovery authority source read rejected");
    }
    std::size_t offset = 0;
    while (offset < static_cast<std::size_t>(count)) {
      ssize_t written = -1;
      do {
        written = write(destination, buffer.data() + offset,
                        static_cast<std::size_t>(count) - offset);
      } while (written < 0 && errno == EINTR);
      if (written <= 0) {
        throw LinuxTransactionRegistryError(
            "recovery authority copy failed");
      }
      offset += static_cast<std::size_t>(written);
    }
    total += static_cast<std::size_t>(count);
  }
}

std::string Sha256RetainedFile(int file) {
  EVP_MD_CTX* context = EVP_MD_CTX_new();
  if (context == nullptr ||
      EVP_DigestInit_ex(context, EVP_sha256(), nullptr) != 1) {
    EVP_MD_CTX_free(context);
    throw LinuxTransactionRegistryError(
        "recovery authority hash setup failed");
  }
  std::array<char, 64 * 1024> buffer{};
  off_t offset = 0;
  for (;;) {
    ssize_t count = -1;
    do {
      count = pread(file, buffer.data(), buffer.size(), offset);
    } while (count < 0 && errno == EINTR);
    if (count == 0) break;
    if (count < 0 ||
        EVP_DigestUpdate(context, buffer.data(),
                         static_cast<std::size_t>(count)) != 1) {
      EVP_MD_CTX_free(context);
      throw LinuxTransactionRegistryError(
          "recovery authority hash failed");
    }
    offset += count;
  }
  std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
  unsigned int digest_length = 0;
  const bool finalized =
      EVP_DigestFinal_ex(context, digest.data(), &digest_length) == 1;
  EVP_MD_CTX_free(context);
  if (!finalized || digest_length != 32) {
    throw LinuxTransactionRegistryError(
        "recovery authority hash failed");
  }
  std::ostringstream encoded;
  encoded << std::hex << std::setfill('0');
  for (unsigned int index = 0; index < digest_length; ++index) {
    encoded << std::setw(2) << static_cast<unsigned int>(digest[index]);
  }
  return encoded.str();
}

std::string CanonicalPolicySha256(int policy) {
  if (lseek(policy, 0, SEEK_SET) < 0) {
    throw LinuxTransactionRegistryError(
        "recovery authority policy seek failed");
  }
  std::string canonical = ReadAll(policy);
  if (!canonical.empty() && canonical.back() == '\n') canonical.pop_back();
  return Sha256LinuxBytes(canonical);
}

UniqueLinuxFd OpenRetainedRegistryDirectory(
    const fs::path& path,
    int retained_directory,
    uid_t uid,
    gid_t gid,
    const LinuxFileIdentity& expected) {
  VerifySecureDirectory(path, uid, gid);
  struct stat located {};
  if (lstat(path.c_str(), &located) != 0 ||
      static_cast<std::uint64_t>(located.st_dev) != expected.device ||
      static_cast<std::uint64_t>(located.st_ino) != expected.inode) {
    throw LinuxTransactionRegistryError(
        "transaction state directory locator changed");
  }
  UniqueLinuxFd directory(openat(retained_directory, ".",
                                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                     O_CLOEXEC));
  if (!directory.valid()) {
    throw LinuxTransactionRegistryError(
        "transaction state directory open failed");
  }
  if (!HasStableLinuxIdentity(ReadLinuxFileIdentity(directory.get()),
                              expected)) {
    throw LinuxTransactionRegistryError(
        "transaction state directory identity changed");
  }
  return directory;
}

void WriteAll(int fd, const std::string& bytes) {
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    ssize_t count = -1;
    do {
      count = write(fd, bytes.data() + offset, bytes.size() - offset);
    } while (count < 0 && errno == EINTR);
    if (count <= 0) {
      throw LinuxTransactionRegistryError("transaction index write failed");
    }
    offset += static_cast<std::size_t>(count);
  }
}

std::string ReadAll(int fd) {
  std::string bytes;
  std::array<char, 8192> buffer{};
  for (;;) {
    ssize_t count = -1;
    do {
      count = read(fd, buffer.data(), buffer.size());
    } while (count < 0 && errno == EINTR);
    if (count == 0) return bytes;
    if (count < 0 || bytes.size() + static_cast<std::size_t>(count) >
                         2 * 1024 * 1024) {
      throw LinuxTransactionRegistryError("transaction index read failed");
    }
    bytes.append(buffer.data(), static_cast<std::size_t>(count));
  }
}

std::optional<LinuxTransactionRegistryRecord> ReadRecordIfPresent(
    int directory,
    const std::string& leaf,
    uid_t uid,
    gid_t gid) {
  UniqueLinuxFd file(openat(directory, leaf.c_str(),
                            O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  if (!file.valid()) {
    if (errno == ENOENT) return std::nullopt;
    throw LinuxTransactionRegistryError("transaction index open failed");
  }
  RequireRegistryFileIdentity(file.get(), uid, gid);
  return LinuxTransactionRegistryRecord::DecodeStrict(ReadAll(file.get()));
}

bool SameImmutableBinding(const LinuxTransactionRegistryRecord& first,
                          const LinuxTransactionRegistryRecord& second) {
  return first.schema_version == second.schema_version &&
         first.transaction_id == second.transaction_id &&
         first.package_id == second.package_id &&
         first.policy_id == second.policy_id &&
         first.helper_endpoint_identity_sha256 ==
             second.helper_endpoint_identity_sha256 &&
         first.recovery_authority_kind == second.recovery_authority_kind &&
         first.recovery_authority_generation_sha256 ==
             second.recovery_authority_generation_sha256 &&
         first.recovery_policy_identity_sha256 ==
             second.recovery_policy_identity_sha256 &&
         first.target_path == second.target_path &&
         first.canonical_request == second.canonical_request &&
         first.expected_payload_identity == second.expected_payload_identity;
}

bool AllowedStateTransition(const std::string& from, const std::string& to) {
  if (from == to) return true;
  if (from == "preparing") {
    return to == "prepared" || to == "rolledBack" ||
           to == "recoveryRequired" || to == "manualActionRequired";
  }
  if (from == "prepared") {
    return to == "commitAccepted" || to == "rolledBack" ||
           to == "recoveryRequired" || to == "completed" ||
           to == "manualActionRequired";
  }
  if (from == "commitAccepted") {
    return to == "recoveryRequired" || to == "completed" ||
           to == "launchPending" || to == "manualActionRequired";
  }
  if (from == "recoveryRequired") {
    return to == "completed" || to == "rolledBack" ||
           to == "launchPending" || to == "manualActionRequired";
  }
  if (from == "launchPending") {
    return to == "launchAttempting" || to == "launchFailed";
  }
  if (from == "launchAttempting") {
    return to == "launched" || to == "launchFailed";
  }
  return false;
}

void ValidateTransition(const LinuxTransactionRegistryRecord& from,
                        const LinuxTransactionRegistryRecord& to) {
  const bool journal_progress =
      from.journal_sha256 == to.journal_sha256 ||
      (from.journal_sha256 == std::string(64, '0') &&
       to.journal_sha256 != std::string(64, '0'));
  if (!SameImmutableBinding(from, to) ||
      !AllowedStateTransition(from.state, to.state) || !journal_progress) {
    throw LinuxTransactionRegistryError(
        "transaction index transition rejected");
  }
}

std::optional<LinuxTransactionRegistryRecord> ReconcileTornNext(
    int directory,
    const std::string& transaction_id,
    uid_t uid,
    gid_t gid) {
  const std::string leaf = transaction_id + ".json";
  const std::string next = leaf + ".next";
  auto current = ReadRecordIfPresent(directory, leaf, uid, gid);
  if (!LinuxRelativeExistsNoFollow(directory, next)) return current;

  auto next_file = OpenLinuxRelativeNoFollow(directory, next, O_RDONLY);
  RequireRegistryFileIdentity(next_file.get(), uid, gid);
  const LinuxFileIdentity next_identity = ReadLinuxFileIdentity(next_file.get());
  std::optional<LinuxTransactionRegistryRecord> candidate;
  try {
    candidate = LinuxTransactionRegistryRecord::DecodeStrict(
        ReadAll(next_file.get()));
  } catch (const LinuxTransactionRegistryError&) {
    next_file.reset();
    if (ReadLinuxRelativeIdentity(directory, next) != next_identity ||
        unlinkat(directory, next.c_str(), 0) != 0 || fsync(directory) != 0) {
      throw LinuxTransactionRegistryError(
          "invalid transaction next cleanup failed");
    }
    return current;
  }
  if (candidate->transaction_id != transaction_id) {
    throw LinuxTransactionRegistryError(
        "transaction next binding rejected");
  }
  if (current.has_value()) ValidateTransition(*current, *candidate);
  next_file.reset();
  if (ReadLinuxRelativeIdentity(directory, next) != next_identity ||
      renameat(directory, next.c_str(), directory, leaf.c_str()) != 0 ||
      fsync(directory) != 0) {
    throw LinuxTransactionRegistryError(
        "transaction next promotion failed");
  }
  return candidate;
}

}  // namespace

std::string LinuxRecoveryAuthorityGenerationSha256(
    const std::string& transaction_id,
    const std::string& authority_kind,
    const std::string& helper_sha256,
    const std::string& policy_sha256) {
  return Sha256LinuxBytes(
      "desktop-updater-linux-recovery-authority-v1\n" + transaction_id +
      "\n" + authority_kind + "\n" + helper_sha256 + "\n" + policy_sha256);
}

UniqueLinuxFd OpenSecureLinuxRegistryDirectoryTree(
    int root_directory,
    const std::vector<std::string>& components,
    std::size_t required_ancestor_count,
    uid_t uid,
    gid_t gid) {
  if (root_directory < 0 || components.empty() ||
      required_ancestor_count > components.size()) {
    throw LinuxTransactionRegistryError(
        "transaction state directory chain rejected");
  }
  UniqueLinuxFd current(openat(root_directory, ".",
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                   O_CLOEXEC));
  if (!current.valid()) {
    throw LinuxTransactionRegistryError(
        "transaction state root directory open failed");
  }
  RequireSecureAncestorDirectory(current.get(), uid, gid);
  for (std::size_t index = 0; index < components.size(); ++index) {
    const std::string& leaf = components[index];
    ValidateLinuxLeaf(leaf);
    bool created = false;
    if (index >= required_ancestor_count) {
      if (mkdirat(current.get(), leaf.c_str(), 0700) == 0) {
        created = true;
      } else if (errno != EEXIST) {
        throw LinuxTransactionRegistryError(
            "transaction state directory creation failed");
      }
    }
    UniqueLinuxFd child(openat(current.get(), leaf.c_str(),
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                   O_CLOEXEC));
    if (!child.valid()) {
      throw LinuxTransactionRegistryError(
          "transaction state directory component rejected");
    }
    if (created) {
      if ((geteuid() == 0 && fchown(child.get(), uid, gid) != 0) ||
          fchmod(child.get(), 0700) != 0 || fsync(child.get()) != 0 ||
          fsync(current.get()) != 0) {
        throw LinuxTransactionRegistryError(
            "transaction state directory initialization failed");
      }
    }
    if (index < required_ancestor_count) {
      RequireSecureAncestorDirectory(child.get(), uid, gid);
    } else {
      RequirePrivateRegistryDirectory(child.get(), uid, gid);
    }
    current = std::move(child);
  }
  return current;
}

std::string LinuxTransactionRegistryRecord::EncodeCanonical() const {
  ValidateRecord(*this);
  JsonValue::Object value;
  value.emplace("canonicalRequest", JsonValue(canonical_request));
  value.emplace("expectedPayloadIdentity",
                EncodePayload(expected_payload_identity));
  value.emplace("helperEndpointIdentitySha256",
                JsonValue(helper_endpoint_identity_sha256));
  value.emplace("journalSha256", JsonValue(journal_sha256));
  value.emplace("packageId", JsonValue(package_id));
  value.emplace("policyId", JsonValue(policy_id));
  value.emplace("recoveryAuthorityGenerationSha256",
                JsonValue(recovery_authority_generation_sha256));
  value.emplace("recoveryAuthorityKind",
                JsonValue(recovery_authority_kind));
  value.emplace("recoveryPolicyIdentitySha256",
                JsonValue(recovery_policy_identity_sha256));
  value.emplace("resultCode", JsonValue(result_code));
  value.emplace("schemaVersion", JsonValue(schema_version));
  value.emplace("state", JsonValue(state));
  value.emplace("targetPath", JsonValue(target_path));
  value.emplace("transactionId", JsonValue(transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(value)));
}

LinuxTransactionRegistryRecord LinuxTransactionRegistryRecord::DecodeStrict(
    const std::string& canonical_json) {
  try {
    const JsonValue value = ParseJson(canonical_json);
    if (EncodeCanonicalJson(value) != canonical_json) {
      throw LinuxTransactionRegistryError(
          "transaction index is not canonical");
    }
    RequireKeys(value,
                {"canonicalRequest", "expectedPayloadIdentity",
                 "helperEndpointIdentitySha256", "journalSha256",
                 "packageId", "policyId",
                 "recoveryAuthorityGenerationSha256",
                 "recoveryAuthorityKind", "recoveryPolicyIdentitySha256",
                 "resultCode", "schemaVersion", "state", "targetPath",
                 "transactionId"});
    LinuxTransactionRegistryRecord record;
    record.schema_version = value.at("schemaVersion").integer();
    record.transaction_id = value.at("transactionId").string();
    record.package_id = value.at("packageId").string();
    record.policy_id = value.at("policyId").string();
    record.helper_endpoint_identity_sha256 =
        value.at("helperEndpointIdentitySha256").string();
    record.recovery_authority_kind =
        value.at("recoveryAuthorityKind").string();
    record.recovery_authority_generation_sha256 =
        value.at("recoveryAuthorityGenerationSha256").string();
    record.recovery_policy_identity_sha256 =
        value.at("recoveryPolicyIdentitySha256").string();
    record.target_path = value.at("targetPath").string();
    record.canonical_request = value.at("canonicalRequest").string();
    record.state = value.at("state").string();
    record.result_code = value.at("resultCode").string();
    record.journal_sha256 = value.at("journalSha256").string();
    record.expected_payload_identity =
        DecodePayload(value.at("expectedPayloadIdentity"));
    ValidateRecord(record);
    return record;
  } catch (const LinuxTransactionRegistryError&) {
    throw;
  } catch (const std::exception&) {
    throw LinuxTransactionRegistryError("transaction index decode failed");
  }
}

LinuxTransactionRegistry::LinuxTransactionRegistry(
    bool broker_mode,
    LinuxTransactionRegistryFaultInjector* fault_injector)
    : broker_mode_(broker_mode), fault_injector_(fault_injector) {
  if (broker_mode) {
    uid_ = 0;
    gid_ = 0;
    directory_ = "/var/lib/desktop-updater/transactions";
    UniqueLinuxFd root(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                    O_CLOEXEC));
    if (!root.valid()) {
      throw LinuxTransactionRegistryError(
          "broker transaction state directory unavailable");
    }
    directory_fd_ = OpenSecureLinuxRegistryDirectoryTree(
        root.get(), {"var", "lib", "desktop-updater", "transactions"}, 2,
        uid_, gid_);
  } else {
    uid_ = geteuid();
    gid_ = getegid();
    directory_ = EnsurePortableDirectory();
    directory_fd_.reset(open(directory_.c_str(),
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                 O_CLOEXEC));
    if (!directory_fd_.valid()) {
      throw LinuxTransactionRegistryError(
          "transaction state directory open failed");
    }
  }
  VerifySecureDirectory(directory_, uid_, gid_);
  RequirePrivateRegistryDirectory(directory_fd_.get(), uid_, gid_);
  directory_identity_ = ReadLinuxFileIdentity(directory_fd_.get());
}

void LinuxTransactionRegistry::Persist(
    const LinuxTransactionRegistryRecord& record) const {
  const std::string bytes = record.EncodeCanonical();
  UniqueLinuxFd directory = OpenRetainedRegistryDirectory(
      directory_, directory_fd_.get(), uid_, gid_, directory_identity_);
  if (flock(directory.get(), LOCK_EX) != 0) {
    throw LinuxTransactionRegistryError("transaction index lock failed");
  }
  const std::string leaf = record.transaction_id + ".json";
  const std::string next = leaf + ".next";
  const auto current = ReconcileTornNext(
      directory.get(), record.transaction_id, uid_, gid_);
  if (current.has_value()) {
    ValidateTransition(*current, record);
    if (current->EncodeCanonical() == bytes) return;
  }
  UniqueLinuxFd file(openat(directory.get(), next.c_str(),
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW |
                                O_CLOEXEC,
                            0600));
  if (!directory.valid() || !file.valid()) {
    throw LinuxTransactionRegistryError("transaction index open failed");
  }
  try {
    if (fchown(file.get(), uid_, gid_) != 0 ||
        fchmod(file.get(), 0600) != 0) {
      throw LinuxTransactionRegistryError(
          "transaction index ownership failed");
    }
    RequireRegistryFileIdentity(file.get(), uid_, gid_);
    if (fsync(directory.get()) != 0) {
      throw LinuxTransactionRegistryError(
          "transaction index create sync failed");
    }
    if (fault_injector_ != nullptr) {
      fault_injector_->OnLinuxTransactionRegistryFault(
          LinuxTransactionRegistryFaultPoint::kAfterNextCreate);
    }
    WriteAll(file.get(), bytes);
    if (fdatasync(file.get()) != 0) {
      throw LinuxTransactionRegistryError(
          "transaction index fdatasync failed");
    }
    if (fault_injector_ != nullptr) {
      fault_injector_->OnLinuxTransactionRegistryFault(
          LinuxTransactionRegistryFaultPoint::kAfterNextFileSync);
    }
    file.reset();
    if (renameat(directory.get(), next.c_str(), directory.get(),
                 leaf.c_str()) != 0) {
      throw LinuxTransactionRegistryError(
          "transaction index atomic replace failed");
    }
    if (fault_injector_ != nullptr) {
      fault_injector_->OnLinuxTransactionRegistryFault(
          LinuxTransactionRegistryFaultPoint::kAfterNextRename);
    }
    if (fsync(directory.get()) != 0) {
      throw LinuxTransactionRegistryError(
          "transaction index directory sync failed");
    }
  } catch (...) {
    file.reset();
    throw;
  }
}

std::optional<LinuxTransactionRegistryRecord> LinuxTransactionRegistry::Load(
    const std::string& transaction_id) const {
  if (!IsUuid(transaction_id)) {
    throw LinuxTransactionRegistryError("transaction ID rejected");
  }
  UniqueLinuxFd directory = OpenRetainedRegistryDirectory(
      directory_, directory_fd_.get(), uid_, gid_, directory_identity_);
  if (flock(directory.get(), LOCK_EX) != 0) {
    throw LinuxTransactionRegistryError("transaction index lock failed");
  }
  return ReconcileTornNext(directory.get(), transaction_id, uid_, gid_);
}

fs::path LinuxTransactionRegistry::PortableRecoveryAuthorityHelperPath(
    const std::string& transaction_id) const {
  if (broker_mode_ || !IsUuid(transaction_id)) {
    throw LinuxTransactionRegistryError(
        "portable recovery authority locator rejected");
  }
  return directory_ / (transaction_id + ".authority") /
         "desktop-updater-helper";
}

void LinuxTransactionRegistry::PreservePortableRecoveryAuthority(
    const fs::path& helper_executable,
    const fs::path& policy_file,
    LinuxTransactionRegistryRecord* record) const {
  if (broker_mode_ || record == nullptr || !IsUuid(record->transaction_id) ||
      !IsSha256(record->helper_endpoint_identity_sha256)) {
    throw LinuxTransactionRegistryError(
        "portable recovery authority request rejected");
  }
  UniqueLinuxFd source_helper(
      open(helper_executable.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  UniqueLinuxFd source_policy(
      open(policy_file.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  struct stat helper_status {};
  struct stat policy_status {};
  struct stat helper_path_status {};
  struct stat policy_path_status {};
  if (!source_helper.valid() || !source_policy.valid() ||
      fstat(source_helper.get(), &helper_status) != 0 ||
      fstat(source_policy.get(), &policy_status) != 0 ||
      lstat(helper_executable.c_str(), &helper_path_status) != 0 ||
      lstat(policy_file.c_str(), &policy_path_status) != 0 ||
      !S_ISREG(helper_status.st_mode) || !S_ISREG(policy_status.st_mode) ||
      S_ISLNK(helper_path_status.st_mode) ||
      S_ISLNK(policy_path_status.st_mode) ||
      helper_path_status.st_dev != helper_status.st_dev ||
      helper_path_status.st_ino != helper_status.st_ino ||
      policy_path_status.st_dev != policy_status.st_dev ||
      policy_path_status.st_ino != policy_status.st_ino ||
      helper_status.st_uid != uid_ || policy_status.st_uid != uid_ ||
      (helper_status.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
      (policy_status.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
      Sha256RetainedFile(source_helper.get()) !=
          record->helper_endpoint_identity_sha256) {
    throw LinuxTransactionRegistryError(
        "portable recovery authority source rejected");
  }
  record->recovery_authority_kind = "retainedPortable";
  const std::string source_policy_sha256 =
      CanonicalPolicySha256(source_policy.get());
  if (!record->recovery_policy_identity_sha256.empty() &&
      record->recovery_policy_identity_sha256 != source_policy_sha256) {
    throw LinuxTransactionRegistryError(
        "portable recovery policy generation changed");
  }
  record->recovery_policy_identity_sha256 = source_policy_sha256;
  record->recovery_authority_generation_sha256 =
      LinuxRecoveryAuthorityGenerationSha256(
          record->transaction_id, record->recovery_authority_kind,
          record->helper_endpoint_identity_sha256,
          record->recovery_policy_identity_sha256);

  UniqueLinuxFd directory = OpenRetainedRegistryDirectory(
      directory_, directory_fd_.get(), uid_, gid_, directory_identity_);
  if (flock(directory.get(), LOCK_EX) != 0) {
    throw LinuxTransactionRegistryError(
        "recovery authority registry lock failed");
  }
  const std::string authority_leaf = record->transaction_id + ".authority";
  const std::string next_leaf = authority_leaf + ".next";
  struct stat existing {};
  if (fstatat(directory.get(), authority_leaf.c_str(), &existing,
              AT_SYMLINK_NOFOLLOW) == 0) {
    VerifyRecoveryAuthority(*record,
                            PortableRecoveryAuthorityHelperPath(
                                record->transaction_id));
    return;
  }
  if (errno != ENOENT ||
      mkdirat(directory.get(), next_leaf.c_str(), 0700) != 0) {
    throw LinuxTransactionRegistryError(
        "recovery authority directory creation failed");
  }

  UniqueLinuxFd authority;
  UniqueLinuxFd retained_helper;
  UniqueLinuxFd retained_policy;
  try {
    authority = OpenLinuxRelativeNoFollow(
        directory.get(), next_leaf, O_RDONLY | O_DIRECTORY);
    if (fchown(authority.get(), uid_, gid_) != 0 ||
        fchmod(authority.get(), 0700) != 0) {
      throw LinuxTransactionRegistryError(
          "recovery authority directory ownership failed");
    }
    RequirePrivateRegistryDirectory(authority.get(), uid_, gid_);
    retained_helper.reset(openat(authority.get(), "desktop-updater-helper",
                                 O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW |
                                     O_CLOEXEC,
                                 0500));
    retained_policy.reset(openat(
        authority.get(), "desktop-updater-helper.policy.json",
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0400));
    if (!retained_helper.valid() || !retained_policy.valid() ||
        fchown(retained_helper.get(), uid_, gid_) != 0 ||
        fchown(retained_policy.get(), uid_, gid_) != 0 ||
        fchmod(retained_helper.get(), 0500) != 0 ||
        fchmod(retained_policy.get(), 0400) != 0) {
      throw LinuxTransactionRegistryError(
          "recovery authority file creation failed");
    }
    CopyBoundedFile(source_helper.get(), retained_helper.get());
    if (lseek(source_policy.get(), 0, SEEK_SET) < 0) {
      throw LinuxTransactionRegistryError(
          "recovery authority policy seek failed");
    }
    CopyBoundedFile(source_policy.get(), retained_policy.get());
    if (fdatasync(retained_helper.get()) != 0 ||
        fdatasync(retained_policy.get()) != 0 ||
        fsync(authority.get()) != 0) {
      throw LinuxTransactionRegistryError(
          "recovery authority sync failed");
    }
    RequireAuthorityFileIdentity(retained_helper.get(), uid_, gid_, 0500);
    RequireAuthorityFileIdentity(retained_policy.get(), uid_, gid_, 0400);
    if (Sha256RetainedFile(retained_helper.get()) !=
        record->helper_endpoint_identity_sha256) {
      throw LinuxTransactionRegistryError(
          "recovery authority helper copy changed");
    }
    retained_helper.reset();
    retained_policy.reset();
    authority.reset();
    if (renameat(directory.get(), next_leaf.c_str(), directory.get(),
                 authority_leaf.c_str()) != 0 ||
        fsync(directory.get()) != 0) {
      throw LinuxTransactionRegistryError(
          "recovery authority publication failed");
    }
  } catch (...) {
    retained_helper.reset();
    retained_policy.reset();
    authority.reset();
    UniqueLinuxFd cleanup;
    try {
      cleanup = OpenLinuxRelativeNoFollow(
          directory.get(), next_leaf, O_RDONLY | O_DIRECTORY);
      (void)unlinkat(cleanup.get(), "desktop-updater-helper", 0);
      (void)unlinkat(cleanup.get(),
                     "desktop-updater-helper.policy.json", 0);
    } catch (...) {
    }
    cleanup.reset();
    (void)unlinkat(directory.get(), next_leaf.c_str(), AT_REMOVEDIR);
    throw;
  }
  VerifyRecoveryAuthority(
      *record, PortableRecoveryAuthorityHelperPath(record->transaction_id));
}

void LinuxTransactionRegistry::VerifyRecoveryAuthority(
    const LinuxTransactionRegistryRecord& record,
    const fs::path& helper_executable) const {
  if (!IsUuid(record.transaction_id) ||
      !IsSha256(record.helper_endpoint_identity_sha256) ||
      !IsSha256(record.recovery_policy_identity_sha256) ||
      record.recovery_authority_generation_sha256 !=
          LinuxRecoveryAuthorityGenerationSha256(
              record.transaction_id, record.recovery_authority_kind,
              record.helper_endpoint_identity_sha256,
              record.recovery_policy_identity_sha256)) {
    throw LinuxTransactionRegistryError(
        "recovery authority generation rejected");
  }
  if (record.recovery_authority_kind == "fixedBroker") {
    if (!broker_mode_ ||
        helper_executable != fs::path("/usr/libexec/desktop-updater-helper") ||
        Sha256LinuxFile(helper_executable) !=
            record.helper_endpoint_identity_sha256) {
      throw LinuxTransactionRegistryError(
          "fixed recovery broker generation rejected");
    }
    return;
  }
  if (broker_mode_ || record.recovery_authority_kind != "retainedPortable") {
    throw LinuxTransactionRegistryError(
        "portable recovery authority kind rejected");
  }
  const fs::path expected_helper =
      PortableRecoveryAuthorityHelperPath(record.transaction_id);
  if (helper_executable.lexically_normal() != helper_executable ||
      helper_executable != expected_helper) {
    throw LinuxTransactionRegistryError(
        "transaction recovery helper locator rejected");
  }
  UniqueLinuxFd directory = OpenRetainedRegistryDirectory(
      directory_, directory_fd_.get(), uid_, gid_, directory_identity_);
  auto authority = OpenLinuxRelativeNoFollow(
      directory.get(), record.transaction_id + ".authority",
      O_RDONLY | O_DIRECTORY);
  RequirePrivateRegistryDirectory(authority.get(), uid_, gid_);
  auto helper = OpenLinuxRelativeNoFollow(
      authority.get(), "desktop-updater-helper", O_RDONLY);
  auto policy = OpenLinuxRelativeNoFollow(
      authority.get(), "desktop-updater-helper.policy.json", O_RDONLY);
  RequireAuthorityFileIdentity(helper.get(), uid_, gid_, 0500);
  RequireAuthorityFileIdentity(policy.get(), uid_, gid_, 0400);
  const LinuxFileIdentity helper_identity = ReadLinuxFileIdentity(helper.get());
  const LinuxFileIdentity policy_identity = ReadLinuxFileIdentity(policy.get());
  if (Sha256RetainedFile(helper.get()) !=
          record.helper_endpoint_identity_sha256 ||
      CanonicalPolicySha256(policy.get()) !=
          record.recovery_policy_identity_sha256 ||
      ReadLinuxRelativeIdentity(authority.get(), "desktop-updater-helper") !=
          helper_identity ||
      ReadLinuxRelativeIdentity(
          authority.get(), "desktop-updater-helper.policy.json") !=
          policy_identity) {
    throw LinuxTransactionRegistryError(
        "transaction recovery authority identity changed");
  }
}

}  // namespace desktop_updater::helper
