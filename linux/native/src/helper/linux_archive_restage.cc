#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "linux_archive_restage.h"

#include <dirent.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <openssl/evp.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <exception>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <utility>
#include <vector>

#define MINIZ_NO_ZLIB_APIS
#include "miniz.h"

#include "json_value.h"
#include "linux_transaction_journal.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

using runtime::internal::EncodeCanonicalJson;
using runtime::internal::JsonValue;
using runtime::internal::StageProvenanceEntry;
using runtime::internal::StageProvenanceMarker;

constexpr std::int64_t kMaximumEntries = 100000;
constexpr std::int64_t kMaximumExpandedBytes = 8LL * 1024LL * 1024LL * 1024LL;
constexpr std::int64_t kMaximumSingleEntryBytes =
    4LL * 1024LL * 1024LL * 1024LL;
constexpr std::size_t kMaximumManifestBytes = 1024 * 1024;
constexpr std::size_t kMaximumSealBytes = 64 * 1024 * 1024;
constexpr std::size_t kMaximumRecoveryRecordBytes = 128 * 1024;
constexpr std::size_t kMaximumInventoryDepth = 128;
constexpr std::size_t kInventorySealEntryOverhead = 256;

struct ScopedEvpDigest {
  ScopedEvpDigest() : value(EVP_MD_CTX_new()) {
    if (value == nullptr || EVP_DigestInit_ex(value, EVP_sha256(), nullptr) != 1) {
      throw LinuxArchiveRestageError("SHA-256 initialization failed");
    }
  }
  ~ScopedEvpDigest() { EVP_MD_CTX_free(value); }
  EVP_MD_CTX* value;
};

std::string Hex(const unsigned char* bytes, std::size_t length) {
  static constexpr char digits[] = "0123456789abcdef";
  std::string result;
  result.reserve(length * 2);
  for (std::size_t index = 0; index < length; ++index) {
    result.push_back(digits[bytes[index] >> 4]);
    result.push_back(digits[bytes[index] & 0x0f]);
  }
  return result;
}

std::string FinalDigest(ScopedEvpDigest* digest) {
  std::array<unsigned char, EVP_MAX_MD_SIZE> bytes{};
  unsigned int length = 0;
  if (EVP_DigestFinal_ex(digest->value, bytes.data(), &length) != 1 ||
      length != 32) {
    throw LinuxArchiveRestageError("SHA-256 finalization failed");
  }
  return Hex(bytes.data(), length);
}

std::string Sha256Fd(int fd, std::int64_t* length = nullptr) {
  if (lseek(fd, 0, SEEK_SET) < 0) {
    throw LinuxArchiveRestageError("protected file seek failed");
  }
  ScopedEvpDigest digest;
  std::int64_t total = 0;
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    ssize_t count = -1;
    do {
      count = read(fd, buffer.data(), buffer.size());
    } while (count < 0 && errno == EINTR);
    if (count == 0) break;
    if (count < 0 || total > INT64_MAX - count ||
        EVP_DigestUpdate(digest.value, buffer.data(),
                         static_cast<std::size_t>(count)) != 1) {
      throw LinuxArchiveRestageError("protected file hash failed");
    }
    total += count;
  }
  if (length != nullptr) *length = total;
  return FinalDigest(&digest);
}

void WriteAll(int fd, const void* bytes, std::size_t length) {
  const auto* cursor = static_cast<const unsigned char*>(bytes);
  std::size_t offset = 0;
  while (offset < length) {
    ssize_t count = -1;
    do {
      count = write(fd, cursor + offset, length - offset);
    } while (count < 0 && errno == EINTR);
    if (count <= 0) {
      throw LinuxArchiveRestageError("protected file write failed");
    }
    offset += static_cast<std::size_t>(count);
  }
}

void RequireRegularExactOwner(int fd,
                              uid_t uid,
                              gid_t gid,
                              const char* detail) {
  struct stat status {};
  if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
    throw LinuxArchiveRestageError(detail);
  }
}

void SetProtectedMode(int fd,
                      uid_t uid,
                      gid_t gid,
                      mode_t requested,
                      bool directory,
                      bool broker_mode) {
  mode_t mode = requested & 0777;
  if (mode == 0) mode = directory ? 0755 : 0644;
  mode &= ~(S_IWGRP | S_IWOTH);
  if (broker_mode || geteuid() == 0) {
    if (fchown(fd, uid, gid) != 0) {
      throw LinuxArchiveRestageError("protected payload ownership failed");
    }
  }
  if (fchmod(fd, mode) != 0) {
    throw LinuxArchiveRestageError("protected payload mode failed");
  }
}

void SyncDirectory(int fd) {
  UniqueLinuxFd readable(openat(fd, ".",
                                O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                    O_CLOEXEC));
  if (!readable.valid() || fsync(readable.get()) != 0) {
    throw LinuxArchiveRestageError("protected directory fsync failed");
  }
}

UniqueLinuxFd OpenReadableDirectoryAt(int parent, const std::string& leaf) {
  return OpenLinuxRelativeNoFollow(parent, leaf, O_RDONLY | O_DIRECTORY);
}

UniqueLinuxFd CreateDirectoryAt(int parent,
                                const std::string& leaf,
                                uid_t uid,
                                gid_t gid,
                                mode_t mode,
                                bool broker_mode) {
  ValidateLinuxLeaf(leaf);
  if (mkdirat(parent, leaf.c_str(), 0700) != 0) {
    throw LinuxArchiveRestageError("exclusive helper directory creation failed");
  }
  UniqueLinuxFd directory;
  try {
    directory = OpenReadableDirectoryAt(parent, leaf);
    SetProtectedMode(directory.get(), uid, gid, mode, true, broker_mode);
    SyncDirectory(parent);
    return directory;
  } catch (...) {
    unlinkat(parent, leaf.c_str(), AT_REMOVEDIR);
    throw;
  }
}

UniqueLinuxFd CreateFileAt(int parent,
                           const std::string& leaf,
                           uid_t uid,
                           gid_t gid,
                           mode_t mode,
                           bool broker_mode) {
  ValidateLinuxLeaf(leaf);
  UniqueLinuxFd file(openat(parent, leaf.c_str(),
                            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                            0600));
  if (!file.valid()) {
    throw LinuxArchiveRestageError("exclusive helper file creation failed");
  }
  try {
    SetProtectedMode(file.get(), uid, gid, mode, false, broker_mode);
    return file;
  } catch (...) {
    file.reset();
    unlinkat(parent, leaf.c_str(), 0);
    throw;
  }
}

UniqueLinuxFd CreateRecoverableDirectoryAt(
    int parent,
    const std::string& leaf,
    const std::string& cleanup_cookie,
    uid_t uid,
    gid_t gid,
    bool broker_mode,
    LinuxArchiveRestageFaultInjector* fault_injector,
    LinuxArchiveRestageFaultPoint after_mkdir_fault) {
  ValidateLinuxLeaf(leaf);
  if (mkdirat(parent, leaf.c_str(), 0700) != 0) {
    throw LinuxArchiveRestageError("exclusive helper directory creation failed");
  }
  // This is intentionally the first operation after mkdirat. A process death
  // here leaves a markerless, empty, derived directory; the recovery record
  // can remove only that exact pristine topology with AT_REMOVEDIR.
  if (fault_injector != nullptr) {
    fault_injector->OnLinuxArchiveRestageFault(after_mkdir_fault);
  }
  UniqueLinuxFd directory;
  LinuxFileIdentity identity;
  bool retained_identity = false;
  try {
    directory = OpenReadableDirectoryAt(parent, leaf);
    SetProtectedMode(directory.get(), uid, gid, 0700, true, broker_mode);
    identity = ReadLinuxFileIdentity(directory.get());
    retained_identity = true;
    auto marker = CreateFileAt(directory.get(), kLinuxRestageOwnerName, uid,
                               gid, 0600, broker_mode);
    WriteAll(marker.get(), cleanup_cookie.data(), cleanup_cookie.size());
    if (fsync(marker.get()) != 0) {
      throw LinuxArchiveRestageError("restage owner marker sync failed");
    }
    SyncDirectory(directory.get());
    SyncDirectory(parent);
    return directory;
  } catch (...) {
    if (retained_identity) {
      try {
        RemoveLinuxTreeExact(parent, leaf, identity);
        SyncDirectory(parent);
      } catch (...) {
      }
    } else {
      (void)unlinkat(parent, leaf.c_str(), AT_REMOVEDIR);
    }
    throw;
  }
}

void RemoveCleanupCookie(int directory,
                         const std::string& cleanup_cookie,
                         uid_t uid,
                         gid_t gid) {
  auto marker = OpenLinuxRelativeNoFollow(
      directory, kLinuxRestageOwnerName, O_RDONLY);
  struct stat status {};
  std::array<char, 65> bytes{};
  ssize_t count = -1;
  do {
    count = read(marker.get(), bytes.data(), bytes.size());
  } while (count < 0 && errno == EINTR);
  if (fstat(marker.get(), &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & 07777) != 0600 ||
      count != static_cast<ssize_t>(cleanup_cookie.size()) ||
      std::string(bytes.data(), static_cast<std::size_t>(count)) !=
          cleanup_cookie) {
    throw LinuxArchiveRestageError("restage owner marker changed");
  }
  marker.reset();
  if (unlinkat(directory, kLinuxRestageOwnerName, 0) != 0) {
    throw LinuxArchiveRestageError("restage owner marker cleanup failed");
  }
  SyncDirectory(directory);
}

std::string CopyArtifact(int source,
                         int destination,
                         std::int64_t expected_length) {
  if (lseek(source, 0, SEEK_SET) < 0) {
    throw LinuxArchiveRestageError("retained artifact seek failed");
  }
  ScopedEvpDigest digest;
  std::int64_t total = 0;
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    ssize_t count = -1;
    do {
      count = read(source, buffer.data(), buffer.size());
    } while (count < 0 && errno == EINTR);
    if (count == 0) break;
    if (count < 0 || total > expected_length - count ||
        EVP_DigestUpdate(digest.value, buffer.data(),
                         static_cast<std::size_t>(count)) != 1) {
      throw LinuxArchiveRestageError("retained artifact copy rejected");
    }
    WriteAll(destination, buffer.data(), static_cast<std::size_t>(count));
    total += count;
  }
  if (total != expected_length || fsync(destination) != 0) {
    throw LinuxArchiveRestageError("retained artifact length or fsync rejected");
  }
  return FinalDigest(&digest);
}

struct RestageRecoveryRecord {
  std::string transaction_id;
  std::string target_name;
  std::string package_id;
  std::string descriptor_sha256;
  std::string artifact_sha256;
  std::int64_t artifact_length = 0;
  uid_t payload_uid = 0;
  gid_t payload_gid = 0;
  bool broker_mode = false;
  pid_t owner_process_id = 0;
  std::uint64_t owner_process_start_identity = 0;
  std::string payload_leaf;
  std::string control_leaf;
  std::string cleanup_cookie;
  std::optional<LinuxFileIdentity> payload_identity;
  std::optional<LinuxFileIdentity> control_identity;
};

JsonValue EncodeIdentity(const std::optional<LinuxFileIdentity>& identity) {
  if (!identity.has_value()) return JsonValue();
  JsonValue::Object value;
  value.emplace("device", JsonValue(std::to_string(identity->device)));
  value.emplace("changeTimeNanoseconds",
                JsonValue(identity->change_time_nanoseconds));
  value.emplace("changeTimeSeconds", JsonValue(identity->change_time_seconds));
  value.emplace("directory", JsonValue(identity->directory));
  value.emplace("gid", JsonValue(static_cast<std::int64_t>(identity->gid)));
  value.emplace("inode", JsonValue(std::to_string(identity->inode)));
  value.emplace("linkCount", JsonValue(std::to_string(identity->link_count)));
  value.emplace("mode", JsonValue(static_cast<std::int64_t>(identity->mode)));
  value.emplace("mountId", JsonValue(std::to_string(identity->mount_id)));
  value.emplace("uid", JsonValue(static_cast<std::int64_t>(identity->uid)));
  return JsonValue(std::move(value));
}

std::uint64_t ParseCanonicalUint64(const std::string& value) {
  if (value.empty() || (value.size() > 1 && value.front() == '0') ||
      !std::all_of(value.begin(), value.end(), [](unsigned char byte) {
        return byte >= '0' && byte <= '9';
      })) {
    throw LinuxArchiveRestageError("restage recovery integer rejected");
  }
  try {
    const std::uint64_t parsed = std::stoull(value);
    if (std::to_string(parsed) != value) throw std::invalid_argument("value");
    return parsed;
  } catch (...) {
    throw LinuxArchiveRestageError("restage recovery integer rejected");
  }
}

std::optional<LinuxFileIdentity> DecodeIdentity(const JsonValue& value) {
  if (value.type() == JsonValue::Type::kNull) return std::nullopt;
  if (value.type() != JsonValue::Type::kObject || value.object().size() != 10) {
    throw LinuxArchiveRestageError("restage recovery identity rejected");
  }
  LinuxFileIdentity identity;
  identity.device = ParseCanonicalUint64(value.at("device").string());
  identity.inode = ParseCanonicalUint64(value.at("inode").string());
  identity.mount_id = ParseCanonicalUint64(value.at("mountId").string());
  identity.change_time_seconds = value.at("changeTimeSeconds").integer();
  identity.change_time_nanoseconds =
      value.at("changeTimeNanoseconds").integer();
  const std::int64_t mode = value.at("mode").integer();
  const std::int64_t uid = value.at("uid").integer();
  const std::int64_t gid = value.at("gid").integer();
  identity.link_count =
      ParseCanonicalUint64(value.at("linkCount").string());
  identity.directory = value.at("directory").boolean();
  if (mode < 0 || mode > UINT32_MAX || uid < 0 || uid > UINT32_MAX ||
      gid < 0 || gid > UINT32_MAX || identity.change_time_seconds <= 0 ||
      identity.change_time_nanoseconds < 0 ||
      identity.change_time_nanoseconds >= 1'000'000'000 ||
      identity.device == 0 || identity.inode == 0 || identity.mount_id == 0 ||
      !identity.directory) {
    throw LinuxArchiveRestageError("restage recovery identity rejected");
  }
  identity.mode = static_cast<std::uint32_t>(mode);
  identity.uid = static_cast<std::uint32_t>(uid);
  identity.gid = static_cast<std::uint32_t>(gid);
  return identity;
}

std::string EncodeRecoveryRecord(const RestageRecoveryRecord& record) {
  JsonValue::Object value;
  value.emplace("artifactLength", JsonValue(record.artifact_length));
  value.emplace("artifactSha256", JsonValue(record.artifact_sha256));
  value.emplace("brokerMode", JsonValue(record.broker_mode));
  value.emplace("controlIdentity", EncodeIdentity(record.control_identity));
  value.emplace("controlLeaf", JsonValue(record.control_leaf));
  value.emplace("cleanupCookie", JsonValue(record.cleanup_cookie));
  value.emplace("descriptorSha256", JsonValue(record.descriptor_sha256));
  value.emplace("ownerProcessId",
                JsonValue(static_cast<std::int64_t>(record.owner_process_id)));
  value.emplace("ownerProcessStartIdentity",
                JsonValue(std::to_string(record.owner_process_start_identity)));
  value.emplace("packageId", JsonValue(record.package_id));
  value.emplace("payloadGid",
                JsonValue(static_cast<std::int64_t>(record.payload_gid)));
  value.emplace("payloadIdentity", EncodeIdentity(record.payload_identity));
  value.emplace("payloadLeaf", JsonValue(record.payload_leaf));
  value.emplace("payloadUid",
                JsonValue(static_cast<std::int64_t>(record.payload_uid)));
  value.emplace("schemaVersion", JsonValue(std::int64_t{2}));
  value.emplace("targetName", JsonValue(record.target_name));
  value.emplace("transactionId", JsonValue(record.transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(value)));
}

RestageRecoveryRecord DecodeRecoveryRecord(const std::string& bytes) {
  try {
    const JsonValue value = runtime::internal::ParseJson(bytes);
    if (EncodeCanonicalJson(value) != bytes || value.object().size() != 17 ||
        value.at("schemaVersion").integer() != 2) {
      throw LinuxArchiveRestageError("restage recovery record rejected");
    }
    const std::int64_t owner = value.at("ownerProcessId").integer();
    const std::int64_t uid = value.at("payloadUid").integer();
    const std::int64_t gid = value.at("payloadGid").integer();
    RestageRecoveryRecord record;
    record.transaction_id = value.at("transactionId").string();
    record.target_name = value.at("targetName").string();
    record.package_id = value.at("packageId").string();
    record.descriptor_sha256 = value.at("descriptorSha256").string();
    record.artifact_sha256 = value.at("artifactSha256").string();
    record.artifact_length = value.at("artifactLength").integer();
    record.broker_mode = value.at("brokerMode").boolean();
    record.owner_process_id = static_cast<pid_t>(owner);
    record.owner_process_start_identity = ParseCanonicalUint64(
        value.at("ownerProcessStartIdentity").string());
    record.payload_leaf = value.at("payloadLeaf").string();
    record.control_leaf = value.at("controlLeaf").string();
    record.cleanup_cookie = value.at("cleanupCookie").string();
    record.payload_identity = DecodeIdentity(value.at("payloadIdentity"));
    record.control_identity = DecodeIdentity(value.at("controlIdentity"));
    if (owner <= 0 || owner > INT32_MAX || uid < 0 || uid > UINT32_MAX ||
        gid < 0 || gid > UINT32_MAX || record.artifact_length <= 0 ||
        record.cleanup_cookie.size() != 64 ||
        !std::all_of(record.cleanup_cookie.begin(),
                     record.cleanup_cookie.end(), [](unsigned char byte) {
                       return (byte >= '0' && byte <= '9') ||
                              (byte >= 'a' && byte <= 'f');
                     })) {
      throw LinuxArchiveRestageError("restage recovery record rejected");
    }
    record.payload_uid = static_cast<uid_t>(uid);
    record.payload_gid = static_cast<gid_t>(gid);
    ValidateLinuxLeaf(record.transaction_id);
    ValidateLinuxLeaf(record.target_name);
    ValidateLinuxLeaf(record.payload_leaf);
    ValidateLinuxLeaf(record.control_leaf);
    return record;
  } catch (const LinuxArchiveRestageError&) {
    throw;
  } catch (...) {
    throw LinuxArchiveRestageError("restage recovery record rejected");
  }
}

void RequireRecoveryRecordFile(int fd, uid_t uid, gid_t gid) {
  struct stat status {};
  if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & 0777) != 0600 ||
      (status.st_mode & (S_ISUID | S_ISGID | S_ISVTX)) != 0) {
    throw LinuxArchiveRestageError("restage recovery file identity rejected");
  }
}

std::string ReadRecoveryRecordFile(int fd) {
  std::string bytes;
  std::array<char, 8192> buffer{};
  for (;;) {
    ssize_t count = -1;
    do {
      count = read(fd, buffer.data(), buffer.size());
    } while (count < 0 && errno == EINTR);
    if (count == 0) return bytes;
    if (count < 0 || bytes.size() + static_cast<std::size_t>(count) >
                         kMaximumRecoveryRecordBytes) {
      throw LinuxArchiveRestageError("restage recovery file read rejected");
    }
    bytes.append(buffer.data(), static_cast<std::size_t>(count));
  }
}

void ReconcileRecoveryRecordTemporary(int parent,
                                      const std::string& temporary,
                                      uid_t uid,
                                      gid_t gid) {
  if (!LinuxRelativeExistsNoFollow(parent, temporary)) return;
  auto file = OpenLinuxRelativeNoFollow(parent, temporary, O_RDONLY);
  RequireRecoveryRecordFile(file.get(), uid, gid);
  const LinuxFileIdentity identity = ReadLinuxFileIdentity(file.get());
  file.reset();
  if (ReadLinuxRelativeIdentity(parent, temporary) != identity ||
      unlinkat(parent, temporary.c_str(), 0) != 0) {
    throw LinuxArchiveRestageError(
        "stale restage recovery next cleanup failed");
  }
  SyncDirectory(parent);
}

LinuxFileIdentity PersistRecoveryRecord(
    int parent,
    const std::string& leaf,
    const RestageRecoveryRecord& record,
    bool create,
    const LinuxArchiveRestageRequest& request) {
  const std::string bytes = EncodeRecoveryRecord(record);
  const std::string temporary = leaf + ".next";
  ReconcileRecoveryRecordTemporary(parent, temporary, record.payload_uid,
                                   record.payload_gid);
  UniqueLinuxFd file;
#ifdef O_TMPFILE
  if (!request.disable_recovery_record_o_tmpfile_for_testing) {
    file.reset(openat(parent, ".", O_TMPFILE | O_RDWR | O_CLOEXEC, 0600));
  }
#endif
  bool named_temporary = false;
  if (!file.valid()) {
    file.reset(openat(parent, temporary.c_str(),
                      O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                      0600));
    named_temporary = file.valid();
  }
  if (!file.valid()) {
    throw LinuxArchiveRestageError("restage recovery file creation failed");
  }
  try {
    SetProtectedMode(file.get(), record.payload_uid, record.payload_gid, 0600,
                     false, request.broker_mode);
    WriteAll(file.get(), bytes.data(), bytes.size());
    if (fdatasync(file.get()) != 0) {
      throw LinuxArchiveRestageError("restage recovery file sync failed");
    }
    if (!named_temporary &&
        linkat(file.get(), "", parent, temporary.c_str(), AT_EMPTY_PATH) != 0) {
      throw LinuxArchiveRestageError("restage recovery file link failed");
    }
    named_temporary = true;
    SyncDirectory(parent);
    if (request.fault_injector != nullptr) {
      request.fault_injector->OnLinuxArchiveRestageFault(
          LinuxArchiveRestageFaultPoint::
              kAfterRecoveryRecordNextSyncBeforeRename);
    }
    if (create) {
      if (renameat2(parent, temporary.c_str(), parent, leaf.c_str(),
                    RENAME_NOREPLACE) != 0) {
        throw LinuxArchiveRestageError(
            "exclusive restage recovery record creation failed");
      }
    } else if (renameat(parent, temporary.c_str(), parent, leaf.c_str()) != 0) {
      throw LinuxArchiveRestageError("restage recovery record replace failed");
    }
    named_temporary = false;
    SyncDirectory(parent);
    auto retained = OpenLinuxRelativeNoFollow(parent, leaf, O_RDONLY);
    RequireRecoveryRecordFile(retained.get(), record.payload_uid,
                              record.payload_gid);
    return ReadLinuxFileIdentity(retained.get());
  } catch (...) {
    if (named_temporary) {
      try {
        ReconcileRecoveryRecordTemporary(parent, temporary,
                                         record.payload_uid,
                                         record.payload_gid);
      } catch (...) {
      }
    }
    throw;
  }
}

void RemoveRecoveryRecordExact(int parent,
                               const std::string& leaf,
                               const LinuxFileIdentity& expected,
                               int retained) {
  if (retained < 0 ||
      !HasExactLinuxIdentity(ReadLinuxFileIdentity(retained), expected)) {
    throw LinuxArchiveRestageError("retained restage recovery identity changed");
  }
  const LinuxFileIdentity observed = ReadLinuxRelativeIdentity(parent, leaf);
  if (!HasExactLinuxIdentity(observed, expected) || observed.directory ||
      observed.link_count != 1) {
    throw LinuxArchiveRestageError("restage recovery identity changed");
  }
  if (unlinkat(parent, leaf.c_str(), 0) != 0) {
    throw LinuxArchiveRestageError("restage recovery cleanup failed");
  }
  SyncDirectory(parent);
}

bool OwnerProcessIsLive(const RestageRecoveryRecord& record) {
  try {
    return LinuxProcessStartIdentity(record.owner_process_id) ==
           record.owner_process_start_identity;
  } catch (...) {
    return false;
  }
}

void ValidateRecoveryBindings(const RestageRecoveryRecord& record,
                              const LinuxArchiveRestageRequest& expected,
                              const std::string& payload_leaf,
                              const std::string& control_leaf) {
  if (record.transaction_id != expected.transaction_id ||
      record.target_name != expected.target_name ||
      record.package_id != expected.package_id ||
      record.descriptor_sha256 != expected.descriptor_sha256 ||
      record.artifact_sha256 != expected.artifact_sha256 ||
      record.artifact_length != expected.artifact_length ||
      record.payload_uid != expected.payload_uid ||
      record.payload_gid != expected.payload_gid ||
      record.broker_mode != expected.broker_mode ||
      record.payload_leaf != payload_leaf || record.control_leaf != control_leaf) {
    throw LinuxArchiveRestageError("restage recovery binding changed");
  }
}

std::string RandomCleanupCookie() {
  std::array<unsigned char, 32> bytes{};
  UniqueLinuxFd source(open("/dev/urandom", O_RDONLY | O_CLOEXEC));
  std::size_t offset = 0;
  while (source.valid() && offset < bytes.size()) {
    ssize_t count = -1;
    do {
      count = read(source.get(), bytes.data() + offset, bytes.size() - offset);
    } while (count < 0 && errno == EINTR);
    if (count <= 0) break;
    offset += static_cast<std::size_t>(count);
  }
  if (offset != bytes.size()) {
    throw LinuxArchiveRestageError("restage cleanup entropy unavailable");
  }
  return Hex(bytes.data(), bytes.size());
}

LinuxFileIdentity VerifyCleanupCookieDirectory(
    int parent,
    const std::string& leaf,
    const std::string& cleanup_cookie,
    const LinuxArchiveRestageRequest& expected) {
  auto directory = OpenReadableDirectoryAt(parent, leaf);
  const LinuxFileIdentity observed = ReadLinuxFileIdentity(directory.get());
  const LinuxFileIdentity parent_identity = ReadLinuxFileIdentity(parent);
  if (!observed.directory || observed.uid != expected.payload_uid ||
      observed.gid != expected.payload_gid || (observed.mode & 07777) != 0700 ||
      observed.device != parent_identity.device ||
      observed.mount_id != parent_identity.mount_id) {
    throw LinuxArchiveRestageError(
        "restage cleanup cookie directory rejected");
  }
  auto marker = OpenLinuxRelativeNoFollow(
      directory.get(), kLinuxRestageOwnerName, O_RDONLY);
  struct stat marker_status {};
  std::array<char, 65> marker_bytes{};
  const ssize_t count = read(marker.get(), marker_bytes.data(),
                             marker_bytes.size());
  if (fstat(marker.get(), &marker_status) != 0 ||
      !S_ISREG(marker_status.st_mode) || marker_status.st_nlink != 1 ||
      marker_status.st_uid != expected.payload_uid ||
      marker_status.st_gid != expected.payload_gid ||
      (marker_status.st_mode & 07777) != 0600 ||
      count != static_cast<ssize_t>(cleanup_cookie.size()) ||
      std::string(marker_bytes.data(), static_cast<std::size_t>(count)) !=
          cleanup_cookie) {
    throw LinuxArchiveRestageError("restage cleanup cookie changed");
  }
  const int scan_fd = openat(directory.get(), ".",
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  DIR* stream = scan_fd < 0 ? nullptr : fdopendir(scan_fd);
  if (stream == nullptr) {
    if (scan_fd >= 0) close(scan_fd);
    throw LinuxArchiveRestageError("restage cleanup scan failed");
  }
  bool marker_seen = false;
  bool unexpected = false;
  for (;;) {
    errno = 0;
    dirent* entry = readdir(stream);
    if (entry == nullptr) {
      if (errno != 0) unexpected = true;
      break;
    }
    const std::string name(entry->d_name);
    if (name == "." || name == "..") continue;
    if (name == kLinuxRestageOwnerName && !marker_seen) {
      marker_seen = true;
    } else {
      unexpected = true;
    }
  }
  closedir(stream);
  if (!marker_seen || unexpected) {
    throw LinuxArchiveRestageError(
        "restage cleanup cookie directory is not pristine");
  }
  return observed;
}

LinuxFileIdentity VerifyPristineEmptyDirectory(
    int parent,
    const std::string& leaf,
    const LinuxArchiveRestageRequest& expected) {
  auto directory = OpenReadableDirectoryAt(parent, leaf);
  const LinuxFileIdentity observed = ReadLinuxFileIdentity(directory.get());
  const LinuxFileIdentity parent_identity = ReadLinuxFileIdentity(parent);
  if (!observed.directory || observed.uid != expected.payload_uid ||
      observed.gid != expected.payload_gid || (observed.mode & 07777) != 0700 ||
      observed.device != parent_identity.device ||
      observed.mount_id != parent_identity.mount_id) {
    throw LinuxArchiveRestageError(
        "markerless restage directory identity rejected");
  }
  const int scan_fd = openat(directory.get(), ".",
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  DIR* stream = scan_fd < 0 ? nullptr : fdopendir(scan_fd);
  if (stream == nullptr) {
    if (scan_fd >= 0) close(scan_fd);
    throw LinuxArchiveRestageError("markerless restage directory scan failed");
  }
  bool empty = true;
  for (;;) {
    errno = 0;
    dirent* entry = readdir(stream);
    if (entry == nullptr) {
      if (errno != 0) empty = false;
      break;
    }
    const std::string name(entry->d_name);
    if (name != "." && name != "..") empty = false;
  }
  closedir(stream);
  if (!empty) {
    throw LinuxArchiveRestageError(
        "markerless restage directory is not pristine and empty");
  }
  return observed;
}

void RemoveRecordedDirectory(int parent,
                             const std::string& leaf,
                             const std::optional<LinuxFileIdentity>& identity,
                             const RestageRecoveryRecord& record,
                             const LinuxArchiveRestageRequest& expected) {
  if (!LinuxRelativeExistsNoFollow(parent, leaf)) return;
  if (identity.has_value()) {
    const LinuxFileIdentity observed = ReadLinuxRelativeIdentity(parent, leaf);
    if (HasExactLinuxIdentity(observed, *identity)) {
      RemoveLinuxTreeExact(parent, leaf, observed);
      return;
    }
    try {
      const LinuxFileIdentity owned = VerifyCleanupCookieDirectory(
          parent, leaf, record.cleanup_cookie, expected);
      RemoveLinuxTreeExact(parent, leaf, owned);
      return;
    } catch (...) {
      throw LinuxArchiveRestageError(
          "restage recovery replacement identity rejected");
    }
  }
  try {
    const LinuxFileIdentity observed = VerifyCleanupCookieDirectory(
        parent, leaf, record.cleanup_cookie, expected);
    RemoveLinuxTreeExact(parent, leaf, observed);
    return;
  } catch (const LinuxMountGuardError&) {
    // A SIGKILL can land immediately after mkdirat and before the owner marker
    // exists. Only a strictly owned, exact-mode, completely empty directory is
    // eligible for non-recursive cleanup in this state.
  }
  const LinuxFileIdentity observed =
      VerifyPristineEmptyDirectory(parent, leaf, expected);
  if (ReadLinuxRelativeIdentity(parent, leaf) != observed ||
      unlinkat(parent, leaf.c_str(), AT_REMOVEDIR) != 0) {
    throw LinuxArchiveRestageError(
        "markerless restage directory cleanup failed");
  }
  SyncDirectory(parent);
}

void ReconcileRecoveryRecord(int parent,
                             const std::string& record_leaf,
                             const LinuxArchiveRestageRequest& expected,
                             const std::string& payload_leaf,
                             const std::string& control_leaf) {
  ReconcileRecoveryRecordTemporary(parent, record_leaf + ".next",
                                   expected.payload_uid,
                                   expected.payload_gid);
  if (!LinuxRelativeExistsNoFollow(parent, record_leaf)) return;
  auto file = OpenLinuxRelativeNoFollow(parent, record_leaf, O_RDONLY);
  RequireRecoveryRecordFile(file.get(), expected.payload_uid,
                            expected.payload_gid);
  const LinuxFileIdentity record_identity = ReadLinuxFileIdentity(file.get());
  const RestageRecoveryRecord record =
      DecodeRecoveryRecord(ReadRecoveryRecordFile(file.get()));
  ValidateRecoveryBindings(record, expected, payload_leaf, control_leaf);
  if (OwnerProcessIsLive(record)) {
    throw LinuxArchiveRestageError("restage recovery owner is still live");
  }
  try {
    RemoveRecordedDirectory(parent, payload_leaf, record.payload_identity,
                            record, expected);
    RemoveRecordedDirectory(parent, control_leaf, record.control_identity,
                            record, expected);
  } catch (const LinuxArchiveManualCleanupRequiredError&) {
    throw;
  } catch (...) {
    throw LinuxArchiveManualCleanupRequiredError(
        payload_leaf, control_leaf, record_leaf);
  }
  SyncDirectory(parent);
  file.reset();
  auto retained = OpenLinuxRelativeNoFollow(parent, record_leaf, O_RDONLY);
  RemoveRecoveryRecordExact(parent, record_leaf, record_identity,
                            retained.get());
}

void HitRestageFault(const LinuxArchiveRestageRequest& request,
                     LinuxArchiveRestageFaultPoint point) {
  if (request.fault_injector != nullptr) {
    request.fault_injector->OnLinuxArchiveRestageFault(point);
  }
}

bool ValidUtf8(const std::string& value) {
  for (std::size_t index = 0; index < value.size();) {
    const unsigned char first = static_cast<unsigned char>(value[index]);
    std::size_t width = 0;
    std::uint32_t scalar = 0;
    if (first <= 0x7f) {
      width = 1;
      scalar = first;
    } else if (first >= 0xc2 && first <= 0xdf) {
      width = 2;
      scalar = first & 0x1f;
    } else if (first >= 0xe0 && first <= 0xef) {
      width = 3;
      scalar = first & 0x0f;
    } else if (first >= 0xf0 && first <= 0xf4) {
      width = 4;
      scalar = first & 0x07;
    } else {
      return false;
    }
    if (index + width > value.size()) return false;
    for (std::size_t offset = 1; offset < width; ++offset) {
      const unsigned char continuation =
          static_cast<unsigned char>(value[index + offset]);
      if ((continuation & 0xc0) != 0x80) return false;
      scalar = (scalar << 6) | (continuation & 0x3f);
    }
    if ((width == 2 && scalar < 0x80) ||
        (width == 3 && scalar < 0x800) ||
        (width == 4 && scalar < 0x10000) ||
        (scalar >= 0xd800 && scalar <= 0xdfff) || scalar > 0x10ffff) {
      return false;
    }
    index += width;
  }
  return true;
}

bool IsControlRoot(const std::string& value) {
  static const std::set<std::string> names = {
      kLinuxRetainedArtifactName,
      kLinuxReleaseManifestName,
      kLinuxStageProvenanceName,
      kLinuxPayloadSealName,
      kLinuxRestageOwnerName,
  };
  return names.find(value) != names.end();
}

struct ArchiveEntry {
  mz_uint index = 0;
  std::string path;
  std::vector<std::string> segments;
  bool directory = false;
  mode_t mode = 0;
  std::int64_t length = 0;
};

std::vector<std::string> StrictArchiveSegments(const std::string& input,
                                               bool directory) {
  if (input.empty() || input.size() > 4096 || input.front() == '/' ||
      input.find('\\') != std::string::npos || !ValidUtf8(input)) {
    throw LinuxArchiveRestageError("unsafe ZIP entry path rejected");
  }
  std::string path = input;
  if (directory) {
    if (path.back() != '/') {
      throw LinuxArchiveRestageError("ZIP directory marker rejected");
    }
    path.pop_back();
  } else if (path.back() == '/') {
    throw LinuxArchiveRestageError("ZIP file marker rejected");
  }
  std::vector<std::string> segments;
  std::size_t start = 0;
  while (start <= path.size()) {
    const std::size_t separator = path.find('/', start);
    const std::string segment = path.substr(
        start, separator == std::string::npos ? std::string::npos
                                              : separator - start);
    if (segment.empty() || segment == "." || segment == ".." ||
        segment.size() > 255) {
      throw LinuxArchiveRestageError("unsafe ZIP traversal rejected");
    }
    segments.push_back(segment);
    if (separator == std::string::npos) break;
    start = separator + 1;
  }
  if (segments.empty() || segments.size() > kMaximumInventoryDepth ||
      IsControlRoot(segments.front())) {
    throw LinuxArchiveRestageError("ZIP control-plane entry rejected");
  }
  return segments;
}

std::string Join(const std::vector<std::string>& segments) {
  std::string result;
  for (const auto& segment : segments) {
    if (!result.empty()) result.push_back('/');
    result += segment;
  }
  return result;
}

void CheckEntryConflict(const std::string& path,
                        bool directory,
                        std::map<std::string, bool>* entries) {
  const std::string& key = path;
  if (entries->find(key) != entries->end()) {
    throw LinuxArchiveRestageError("duplicate ZIP entry rejected");
  }
  std::size_t separator = key.find('/');
  while (separator != std::string::npos) {
    const auto parent = entries->find(key.substr(0, separator));
    if (parent != entries->end() && !parent->second) {
      throw LinuxArchiveRestageError("ZIP file/directory conflict rejected");
    }
    separator = key.find('/', separator + 1);
  }
  if (!directory) {
    const std::string prefix = key + "/";
    const auto child = entries->lower_bound(prefix);
    if (child != entries->end() && child->first.rfind(prefix, 0) == 0) {
      throw LinuxArchiveRestageError("ZIP file/directory conflict rejected");
    }
  }
  entries->emplace(key, directory);
}

std::vector<ArchiveEntry> PreflightArchive(mz_zip_archive* archive) {
  const mz_uint count = mz_zip_reader_get_num_files(archive);
  if (count == 0 || count > static_cast<mz_uint64>(kMaximumEntries)) {
    throw LinuxArchiveRestageError("ZIP entry limit rejected");
  }
  std::int64_t total = 0;
  std::map<std::string, bool> paths;
  std::vector<ArchiveEntry> result;
  result.reserve(count);
  for (mz_uint index = 0; index < count; ++index) {
    mz_zip_archive_file_stat status{};
    const mz_uint filename_bytes =
        mz_zip_reader_get_filename(archive, index, nullptr, 0);
    if (!mz_zip_reader_file_stat(archive, index, &status) ||
        status.m_is_encrypted || !status.m_is_supported ||
        (status.m_method != 0 && status.m_method != MZ_DEFLATED) ||
        filename_bytes == 0 ||
        std::strlen(status.m_filename) + 1 != filename_bytes) {
      throw LinuxArchiveRestageError("unsupported ZIP entry rejected");
    }
    const bool directory = status.m_is_directory != 0;
    const std::uint32_t unix_mode = status.m_external_attr >> 16;
    const std::uint32_t type = unix_mode & S_IFMT;
    if ((directory && type != 0 && type != S_IFDIR) ||
        (!directory && type != 0 && type != S_IFREG)) {
      throw LinuxArchiveRestageError(
          "ZIP symlink, hardlink, or special entry rejected");
    }
    if (status.m_uncomp_size >
            static_cast<mz_uint64>(kMaximumSingleEntryBytes) ||
        status.m_uncomp_size >
            static_cast<mz_uint64>(kMaximumExpandedBytes - total)) {
      throw LinuxArchiveRestageError("ZIP expanded-size limit rejected");
    }
    total += static_cast<std::int64_t>(status.m_uncomp_size);
    auto segments = StrictArchiveSegments(status.m_filename, directory);
    const std::string path = Join(segments);
    CheckEntryConflict(path, directory, &paths);
    result.push_back({index, path, std::move(segments), directory,
                      static_cast<mode_t>(unix_mode & 0777),
                      static_cast<std::int64_t>(status.m_uncomp_size)});
  }
  return result;
}

UniqueLinuxFd EnsureDirectoryChain(int root,
                                   const std::vector<std::string>& segments,
                                   std::size_t count,
                                   uid_t uid,
                                   gid_t gid,
                                   bool broker_mode) {
  UniqueLinuxFd current(dup(root));
  if (!current.valid()) {
    throw LinuxArchiveRestageError("payload directory duplication failed");
  }
  for (std::size_t index = 0; index < count; ++index) {
    const std::string& segment = segments[index];
    if (mkdirat(current.get(), segment.c_str(), 0700) != 0 && errno != EEXIST) {
      throw LinuxArchiveRestageError("payload directory creation failed");
    }
    auto child = OpenReadableDirectoryAt(current.get(), segment);
    SetProtectedMode(child.get(), uid, gid, 0700, true, broker_mode);
    SyncDirectory(current.get());
    current = std::move(child);
  }
  return current;
}

UniqueLinuxFd OpenDirectoryChain(
    int root,
    const std::vector<std::string>& segments,
    std::size_t count) {
  UniqueLinuxFd current(dup(root));
  if (!current.valid()) {
    throw LinuxArchiveRestageError("payload directory duplication failed");
  }
  for (std::size_t index = 0; index < count; ++index) {
    current = OpenLinuxRelativeNoFollow(
        current.get(), segments[index], O_RDONLY | O_DIRECTORY);
  }
  return current;
}

struct SealEntry {
  std::string path;
  std::string kind;
  std::int64_t length = 0;
  std::string sha256;
  std::uint32_t mode = 0;
  std::uint32_t uid = 0;
  std::uint32_t gid = 0;
};

bool Utf8Less(const std::string& first, const std::string& second) {
  return std::lexicographical_compare(
      first.begin(), first.end(), second.begin(), second.end(),
      [](char left, char right) {
        return static_cast<unsigned char>(left) <
               static_cast<unsigned char>(right);
      });
}

mode_t ProtectedPayloadMode(mode_t requested, bool directory) {
  mode_t mode = requested & 0777;
  if (mode == 0) mode = directory ? 0755 : 0644;
  return mode & ~(S_IWGRP | S_IWOTH);
}

struct ExtractionSink {
  int fd = -1;
  mz_uint64 next_offset = 0;
  ScopedEvpDigest* digest = nullptr;
};

size_t WriteExtracted(void* opaque,
                      mz_uint64 offset,
                      const void* bytes,
                      size_t length) {
  auto* sink = static_cast<ExtractionSink*>(opaque);
  if (sink == nullptr || sink->fd < 0 || sink->digest == nullptr ||
      offset != sink->next_offset) {
    return 0;
  }
  try {
    WriteAll(sink->fd, bytes, length);
    if (EVP_DigestUpdate(sink->digest->value, bytes, length) != 1) return 0;
    sink->next_offset += static_cast<mz_uint64>(length);
    return length;
  } catch (...) {
    return 0;
  }
}

std::vector<SealEntry> ExtractArchive(
    mz_zip_archive* archive,
    const std::vector<ArchiveEntry>& entries,
    int payload_root,
    uid_t uid,
    gid_t gid,
    bool broker_mode,
    const LinuxArchiveRestageRequest& request,
    const std::function<void()>& before_first_entry_fault) {
  struct DirectoryMode {
    std::vector<std::string> segments;
    mode_t mode = 0755;
  };
  std::map<std::string, DirectoryMode> directory_modes;
  std::vector<SealEntry> expected_inventory;
  bool extracted_file = false;
  for (const auto& entry : entries) {
    const std::size_t parent_count =
        entry.directory ? entry.segments.size() : entry.segments.size() - 1;
    for (std::size_t count = 1; count <= parent_count; ++count) {
      std::vector<std::string> prefix(entry.segments.begin(),
                                      entry.segments.begin() + count);
      const std::string path = Join(prefix);
      directory_modes.try_emplace(path,
                                  DirectoryMode{std::move(prefix), 0755});
    }
    if (entry.directory) {
      directory_modes.at(entry.path).mode = entry.mode;
    }
    auto parent = EnsureDirectoryChain(payload_root, entry.segments,
                                       parent_count, uid, gid, broker_mode);
    if (entry.directory) {
      continue;
    }
    const std::string& leaf = entry.segments.back();
    auto output = CreateFileAt(parent.get(), leaf, uid, gid, 0600, broker_mode);
    ScopedEvpDigest extracted_digest;
    ExtractionSink sink{output.get(), 0, &extracted_digest};
    if (!mz_zip_reader_extract_to_callback(archive, entry.index,
                                           WriteExtracted, &sink, 0) ||
        sink.next_offset != static_cast<mz_uint64>(entry.length)) {
      throw LinuxArchiveRestageError("ZIP extraction failed");
    }
    SetProtectedMode(output.get(), uid, gid, entry.mode, false, broker_mode);
    if (fsync(output.get()) != 0) {
      throw LinuxArchiveRestageError("extracted payload fsync failed");
    }
    SyncDirectory(parent.get());
    expected_inventory.push_back(
        {entry.path, "file", entry.length, FinalDigest(&extracted_digest),
         static_cast<std::uint32_t>(ProtectedPayloadMode(entry.mode, false)),
         static_cast<std::uint32_t>(uid), static_cast<std::uint32_t>(gid)});
    if (!extracted_file) {
      extracted_file = true;
      before_first_entry_fault();
      HitRestageFault(request,
                      LinuxArchiveRestageFaultPoint::kAfterFirstExtractedEntry);
    }
  }
  std::vector<DirectoryMode> final_directories;
  final_directories.reserve(directory_modes.size());
  for (auto& entry : directory_modes) {
    final_directories.push_back(std::move(entry.second));
  }
  std::sort(final_directories.begin(), final_directories.end(),
            [](const DirectoryMode& first, const DirectoryMode& second) {
              if (first.segments.size() != second.segments.size()) {
                return first.segments.size() > second.segments.size();
              }
              return Join(first.segments) > Join(second.segments);
            });
  for (const auto& directory : final_directories) {
    auto retained = OpenDirectoryChain(payload_root, directory.segments,
                                       directory.segments.size());
    SetProtectedMode(retained.get(), uid, gid, directory.mode, true,
                     broker_mode);
    SyncDirectory(retained.get());
    expected_inventory.push_back(
        {Join(directory.segments), "directory", 0, "",
         static_cast<std::uint32_t>(
             ProtectedPayloadMode(directory.mode, true)),
         static_cast<std::uint32_t>(uid), static_cast<std::uint32_t>(gid)});
  }
  SyncDirectory(payload_root);
  std::sort(expected_inventory.begin(), expected_inventory.end(),
            [](const SealEntry& first, const SealEntry& second) {
              return Utf8Less(first.path, second.path);
            });
  return expected_inventory;
}

struct InventoryBudget {
  std::size_t entries = 0;
  std::size_t seal_path_bytes = 0;
  std::size_t maximum_seal_bytes = 0;
};

void ReserveInventoryEntry(const std::string& prefix,
                           const std::string& name,
                           std::size_t depth,
                           InventoryBudget* budget) {
  const std::size_t path_size =
      prefix.empty() ? name.size() : prefix.size() + 1 + name.size();
  if (depth > kMaximumInventoryDepth || name.size() > 255 ||
      !ValidUtf8(name) || path_size > 4096 ||
      budget->entries >= static_cast<std::size_t>(kMaximumEntries) ||
      path_size > SIZE_MAX - kInventorySealEntryOverhead) {
    throw LinuxArchiveRestageError("payload inventory budget rejected");
  }
  const std::size_t cost = path_size + kInventorySealEntryOverhead;
  if (cost > budget->maximum_seal_bytes ||
      budget->seal_path_bytes > budget->maximum_seal_bytes - cost) {
    throw LinuxArchiveRestageError("payload inventory budget rejected");
  }
  ++budget->entries;
  budget->seal_path_bytes += cost;
}

void InventoryDirectory(int directory,
                        const std::string& prefix,
                        std::size_t depth,
                        uid_t uid,
                        gid_t gid,
                        bool broker_mode,
                        InventoryBudget* budget,
                        std::vector<SealEntry>* result) {
  if (depth > kMaximumInventoryDepth) {
    throw LinuxArchiveRestageError("payload inventory depth rejected");
  }
  const int scan_fd = openat(directory, ".",
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  DIR* stream = scan_fd < 0 ? nullptr : fdopendir(scan_fd);
  if (stream == nullptr) {
    if (scan_fd >= 0) close(scan_fd);
    throw LinuxArchiveRestageError("payload inventory scan failed");
  }
  std::vector<std::string> names;
  try {
    for (;;) {
      errno = 0;
      dirent* entry = readdir(stream);
      if (entry == nullptr) {
        if (errno != 0) {
          throw LinuxArchiveRestageError("payload inventory scan failed");
        }
        break;
      }
      const std::string name(entry->d_name);
      if (name != "." && name != "..") {
        ValidateLinuxLeaf(name);
        ReserveInventoryEntry(prefix, name, depth + 1, budget);
        names.push_back(name);
      }
    }
    closedir(stream);
    stream = nullptr;
  } catch (...) {
    if (stream != nullptr) closedir(stream);
    throw;
  }
  std::sort(names.begin(), names.end(), Utf8Less);
  for (const auto& name : names) {
    auto child = OpenLinuxRelativeNoFollow(directory, name, O_RDONLY);
    struct stat status {};
    if (fstat(child.get(), &status) != 0 || status.st_uid != uid ||
        status.st_gid != gid || (status.st_mode & (S_ISUID | S_ISGID | S_ISVTX)) != 0 ||
        (broker_mode && (status.st_mode & (S_IWGRP | S_IWOTH)) != 0)) {
      throw LinuxArchiveRestageError("payload ownership or mode rejected");
    }
    const std::string path = prefix.empty() ? name : prefix + "/" + name;
    if (S_ISDIR(status.st_mode)) {
      auto child_directory = OpenLinuxRelativeNoFollow(
          directory, name, O_RDONLY | O_DIRECTORY);
      result->push_back({path, "directory", 0, "",
                         static_cast<std::uint32_t>(status.st_mode & 0777),
                         static_cast<std::uint32_t>(status.st_uid),
                         static_cast<std::uint32_t>(status.st_gid)});
      InventoryDirectory(child_directory.get(), path, depth + 1, uid, gid,
                         broker_mode, budget, result);
    } else if (S_ISREG(status.st_mode) && status.st_nlink == 1) {
      std::int64_t length = 0;
      const std::string digest = Sha256Fd(child.get(), &length);
      result->push_back({path, "file", length, digest,
                         static_cast<std::uint32_t>(status.st_mode & 0777),
                         static_cast<std::uint32_t>(status.st_uid),
                         static_cast<std::uint32_t>(status.st_gid)});
    } else {
      throw LinuxArchiveRestageError(
          "payload symlink, hardlink, or special file rejected");
    }
  }
}

std::vector<SealEntry> PayloadInventory(int root,
                                        uid_t uid,
                                        gid_t gid,
                                        bool broker_mode,
                                        std::size_t maximum_seal_bytes) {
  std::vector<SealEntry> result;
  InventoryBudget budget{0, 0, maximum_seal_bytes};
  InventoryDirectory(root, "", 0, uid, gid, broker_mode, &budget, &result);
  if (result.empty() || result.size() > static_cast<std::size_t>(kMaximumEntries)) {
    throw LinuxArchiveRestageError("payload inventory entry limit rejected");
  }
  return result;
}

bool SamePayloadInventory(const std::vector<SealEntry>& expected,
                          const std::vector<SealEntry>& observed) {
  if (expected.size() != observed.size()) return false;
  for (std::size_t index = 0; index < expected.size(); ++index) {
    const SealEntry& left = expected[index];
    const SealEntry& right = observed[index];
    if (left.path != right.path || left.kind != right.kind ||
        left.length != right.length || left.sha256 != right.sha256 ||
        left.mode != right.mode || left.uid != right.uid ||
        left.gid != right.gid) {
      return false;
    }
  }
  return true;
}

JsonValue SealJson(const LinuxArchiveRestageRequest& request,
                   const std::vector<SealEntry>& entries) {
  JsonValue::Array encoded_entries;
  for (const auto& entry : entries) {
    JsonValue::Object encoded;
    encoded.emplace("gid", JsonValue(static_cast<std::int64_t>(entry.gid)));
    encoded.emplace("kind", JsonValue(entry.kind));
    encoded.emplace("length", JsonValue(entry.length));
    encoded.emplace("mode", JsonValue(static_cast<std::int64_t>(entry.mode)));
    encoded.emplace("path", JsonValue(entry.path));
    if (entry.kind == "file") {
      encoded.emplace("sha256", JsonValue(entry.sha256));
    }
    encoded.emplace("uid", JsonValue(static_cast<std::int64_t>(entry.uid)));
    encoded_entries.emplace_back(JsonValue(std::move(encoded)));
  }
  JsonValue::Object seal;
  seal.emplace("artifactLength", JsonValue(request.artifact_length));
  seal.emplace("artifactSha256", JsonValue(request.artifact_sha256));
  seal.emplace("descriptorSha256", JsonValue(request.descriptor_sha256));
  seal.emplace("entries", JsonValue(std::move(encoded_entries)));
  seal.emplace("packageId", JsonValue(request.package_id));
  seal.emplace("activationRootMode",
               JsonValue(static_cast<std::int64_t>(
                   request.activation_root_mode & 0777)));
  seal.emplace("schemaVersion", JsonValue(std::int64_t{1}));
  seal.emplace("transactionId", JsonValue(request.transaction_id));
  return JsonValue(std::move(seal));
}

std::string ReadBounded(int parent,
                        const std::string& leaf,
                        std::size_t maximum,
                        uid_t uid,
                        gid_t gid) {
  auto file = OpenLinuxRelativeNoFollow(parent, leaf, O_RDONLY);
  struct stat status {};
  if (fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_size < 0 ||
      status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & 0777) != 0600 ||
      (status.st_mode & (S_ISUID | S_ISGID | S_ISVTX)) != 0 ||
      static_cast<std::uint64_t>(status.st_size) > maximum) {
    throw LinuxArchiveRestageError("protected control file rejected");
  }
  std::string bytes(static_cast<std::size_t>(status.st_size), '\0');
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    ssize_t count = -1;
    do {
      count = read(file.get(), bytes.data() + offset, bytes.size() - offset);
    } while (count < 0 && errno == EINTR);
    if (count <= 0) {
      throw LinuxArchiveRestageError("protected control file read failed");
    }
    offset += static_cast<std::size_t>(count);
  }
  char extra = 0;
  if (read(file.get(), &extra, 1) != 0) {
    throw LinuxArchiveRestageError("protected control file length changed");
  }
  return bytes;
}

void WriteControlFile(int control,
                      const std::string& leaf,
                      const std::string& bytes,
                      uid_t uid,
                      gid_t gid,
                      bool broker_mode) {
  auto file = CreateFileAt(control, leaf, uid, gid, 0600, broker_mode);
  WriteAll(file.get(), bytes.data(), bytes.size());
  if (fsync(file.get()) != 0) {
    throw LinuxArchiveRestageError("protected control file fsync failed");
  }
  SyncDirectory(control);
}

std::string PayloadLeaf(const std::string& transaction_id) {
  ValidateLinuxLeaf(transaction_id);
  return std::string("desktop_updater_stage_") + transaction_id;
}

std::vector<std::string> SafeExecutableSegments(const std::string& path) {
  return StrictArchiveSegments(path, false);
}

void RequireExecutable(int root,
                       const std::string& relative,
                       uid_t uid,
                       gid_t gid) {
  const auto segments = SafeExecutableSegments(relative);
  auto parent = OpenDirectoryChain(root, segments, segments.size() - 1);
  auto executable = OpenLinuxRelativeNoFollow(parent.get(), segments.back(),
                                               O_RDONLY);
  struct stat status {};
  if (fstat(executable.get(), &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & S_IXUSR) == 0) {
    throw LinuxArchiveRestageError("signed ZIP executable rejected");
  }
}

}  // namespace

std::string LinuxArchiveControlLeaf(const std::string& target_name,
                                    const std::string& transaction_id) {
  ValidateLinuxLeaf(target_name);
  ValidateLinuxLeaf(transaction_id);
  return "." + target_name + ".desktop-updater-" + transaction_id +
         ".control";
}

std::string LinuxArchiveRestageRecordLeaf(const std::string& transaction_id) {
  ValidateLinuxLeaf(transaction_id);
  return ".desktop-updater-restage-" + transaction_id + ".json";
}

LinuxArchiveRestagedPayload::LinuxArchiveRestagedPayload(
    std::filesystem::path path,
    std::filesystem::path control_path,
    std::string payload_leaf,
    std::string control_leaf,
    std::string payload_seal_sha256,
    std::string artifact_sha256,
    UniqueLinuxFd target_parent,
    LinuxFileIdentity payload_identity,
    LinuxFileIdentity control_identity,
    std::string recovery_record_leaf,
    LinuxFileIdentity recovery_record_identity,
    UniqueLinuxFd recovery_record)
    : path_(std::move(path)),
      control_path_(std::move(control_path)),
      payload_leaf_(std::move(payload_leaf)),
      control_leaf_(std::move(control_leaf)),
      payload_seal_sha256_(std::move(payload_seal_sha256)),
      artifact_sha256_(std::move(artifact_sha256)),
      target_parent_(std::move(target_parent)),
      payload_identity_(payload_identity),
      control_identity_(control_identity),
      recovery_record_leaf_(std::move(recovery_record_leaf)),
      recovery_record_identity_(recovery_record_identity),
      recovery_record_(std::move(recovery_record)) {}

LinuxArchiveRestagedPayload::~LinuxArchiveRestagedPayload() {
  if (automatic_cleanup_) {
    const bool payload_clean = CleanupPayloadNoThrow();
    const bool control_clean = CleanupControlNoThrow();
    if (payload_clean && control_clean) {
      (void)CleanupRecoveryRecordNoThrow();
    }
  }
}

void LinuxArchiveRestagedPayload::ArmForRecovery() {
  // The transaction journal already exists when this is called. Transfer
  // cleanup ownership before touching the pre-journal record so any failure
  // preserves the journal-referenced payload and control trees.
  automatic_cleanup_ = false;
  if (!CleanupRecoveryRecordNoThrow()) {
    throw LinuxArchiveRestageError(
        "pre-journal restage recovery record cleanup failed");
  }
}

bool LinuxArchiveRestagedPayload::CleanupPayloadNoThrow() {
  if (!payload_present_) return true;
  try {
    if (LinuxRelativeExistsNoFollow(target_parent_.get(), payload_leaf_)) {
      RemoveLinuxTreeExact(target_parent_.get(), payload_leaf_,
                           payload_identity_);
      SyncLinuxDirectory(target_parent_.get());
    }
    payload_present_ = false;
    return true;
  } catch (...) {
    return false;
  }
}

bool LinuxArchiveRestagedPayload::CleanupControlNoThrow() {
  if (!control_present_) return true;
  try {
    if (LinuxRelativeExistsNoFollow(target_parent_.get(), control_leaf_)) {
      RemoveLinuxTreeExact(target_parent_.get(), control_leaf_,
                           control_identity_);
      SyncLinuxDirectory(target_parent_.get());
    }
    control_present_ = false;
    return true;
  } catch (...) {
    return false;
  }
}

bool LinuxArchiveRestagedPayload::CleanupRecoveryRecordNoThrow() {
  if (!recovery_record_present_) return true;
  try {
    if (LinuxRelativeExistsNoFollow(target_parent_.get(),
                                    recovery_record_leaf_)) {
      RemoveRecoveryRecordExact(target_parent_.get(), recovery_record_leaf_,
                                recovery_record_identity_,
                                recovery_record_.get());
    }
    recovery_record_present_ = false;
    return true;
  } catch (...) {
    return false;
  }
}

void LinuxArchiveRestagedPayload::CleanupCancelled() {
  const bool payload_clean = CleanupPayloadNoThrow();
  const bool control_clean = CleanupControlNoThrow();
  if (!payload_clean || !control_clean ||
      !CleanupRecoveryRecordNoThrow()) {
    automatic_cleanup_ = false;
    throw LinuxArchiveRestageError(
        "cancelled restage cleanup requires recovery");
  }
  automatic_cleanup_ = false;
}

void LinuxArchiveRestagedPayload::CleanupCompleted() {
  // The payload leaf was atomically renamed into the target by the
  // transaction. Only protected control state is now disposable.
  payload_present_ = false;
  if (!CleanupControlNoThrow() || !CleanupRecoveryRecordNoThrow()) {
    automatic_cleanup_ = false;
    throw LinuxArchiveRestageError(
        "completed restage cleanup requires recovery");
  }
  automatic_cleanup_ = false;
}

void LinuxArchiveRestagedPayload::PreserveControlForRecovery() {
  payload_present_ = false;
  automatic_cleanup_ = false;
}

std::unique_ptr<LinuxArchiveRestagedPayload> RestageLinuxSignedZip(
    const LinuxArchiveRestageRequest& request) {
  if (request.source_stage_fd < 0 ||
      request.target_parent_fd < 0 || request.target_parent_path.empty() ||
      request.target_name.empty() || request.transaction_id.empty() ||
      request.package_id.empty() || request.artifact_length <= 0 ||
      request.canonical_release_manifest.empty() ||
      request.maximum_payload_seal_bytes == 0 ||
      request.maximum_payload_seal_bytes > kMaximumSealBytes ||
      Sha256LinuxBytes(request.canonical_release_manifest) !=
          request.descriptor_sha256 ||
      (request.broker_mode &&
       (request.payload_uid != 0 || request.payload_gid != 0)) ||
      (request.activation_root_mode & ~0777) != 0 ||
      (request.activation_root_mode & S_IXUSR) == 0 ||
      (request.activation_root_mode & (S_IWGRP | S_IWOTH)) != 0) {
    throw LinuxArchiveRestageError("archive restage request rejected");
  }
  const LinuxFileIdentity source_identity =
      ReadLinuxFileIdentity(request.source_stage_fd);
  if (!source_identity.directory || source_identity.uid != request.source_uid ||
      source_identity.gid != request.source_gid ||
      (source_identity.mode & (S_IWGRP | S_IWOTH)) != 0) {
    throw LinuxArchiveRestageError("caller stage ownership rejected");
  }
  auto target_path_handle = OpenLinuxDirectory(request.target_parent_path.string());
  if (ReadLinuxFileIdentity(target_path_handle.get()) !=
      ReadLinuxFileIdentity(request.target_parent_fd)) {
    throw LinuxArchiveRestageError("target parent locator changed");
  }

  auto source_archive = OpenLinuxRelativeNoFollow(
      request.source_stage_fd, kLinuxRetainedArtifactName, O_RDONLY);
  RequireRegularExactOwner(source_archive.get(), request.source_uid,
                           request.source_gid,
                           "retained ZIP ownership rejected");
  const std::string payload_leaf = PayloadLeaf(request.transaction_id);
  const std::string control_leaf =
      LinuxArchiveControlLeaf(request.target_name, request.transaction_id);
  const std::string recovery_record_leaf =
      LinuxArchiveRestageRecordLeaf(request.transaction_id);
  const LinuxTransactionPaths transaction_paths = LinuxTransactionPaths::Create(
      request.target_name, request.transaction_id);
  if (LinuxRelativeExistsNoFollow(request.target_parent_fd,
                                  transaction_paths.journal_name) ||
      LinuxRelativeExistsNoFollow(request.target_parent_fd,
                                  transaction_paths.journal_next_name)) {
    throw LinuxArchiveRestageError(
        "durable transaction recovery takes precedence over restage retry");
  }
  ReconcileRecoveryRecord(request.target_parent_fd, recovery_record_leaf,
                          request, payload_leaf, control_leaf);

  RestageRecoveryRecord recovery_record;
  recovery_record.transaction_id = request.transaction_id;
  recovery_record.target_name = request.target_name;
  recovery_record.package_id = request.package_id;
  recovery_record.descriptor_sha256 = request.descriptor_sha256;
  recovery_record.artifact_sha256 = request.artifact_sha256;
  recovery_record.artifact_length = request.artifact_length;
  recovery_record.payload_uid = request.payload_uid;
  recovery_record.payload_gid = request.payload_gid;
  recovery_record.broker_mode = request.broker_mode;
  recovery_record.owner_process_id = getpid();
  recovery_record.owner_process_start_identity =
      LinuxProcessStartIdentity(getpid());
  recovery_record.payload_leaf = payload_leaf;
  recovery_record.control_leaf = control_leaf;
  recovery_record.cleanup_cookie = RandomCleanupCookie();
  UniqueLinuxFd payload;
  UniqueLinuxFd control;
  LinuxFileIdentity payload_identity;
  LinuxFileIdentity control_identity;
  LinuxFileIdentity recovery_record_identity;
  bool payload_created = false;
  bool control_created = false;
  bool recovery_record_created = false;
  try {
    recovery_record_identity = PersistRecoveryRecord(
        request.target_parent_fd, recovery_record_leaf, recovery_record, true,
        request);
    recovery_record_created = true;
    HitRestageFault(request,
                    LinuxArchiveRestageFaultPoint::kAfterRecoveryRecord);

    payload = CreateRecoverableDirectoryAt(
        request.target_parent_fd, payload_leaf,
        recovery_record.cleanup_cookie, request.payload_uid,
        request.payload_gid, request.broker_mode, request.fault_injector,
        LinuxArchiveRestageFaultPoint::
            kAfterPayloadDirectoryMkdirBeforeCookie);
    payload_created = true;
    payload_identity = ReadLinuxFileIdentity(payload.get());
    HitRestageFault(
        request, LinuxArchiveRestageFaultPoint::kAfterPayloadDirectoryCreate);
    recovery_record.payload_identity = payload_identity;
    recovery_record_identity = PersistRecoveryRecord(
        request.target_parent_fd, recovery_record_leaf, recovery_record, false,
        request);
    control = CreateRecoverableDirectoryAt(
        request.target_parent_fd, control_leaf,
        recovery_record.cleanup_cookie, request.payload_uid,
        request.payload_gid, request.broker_mode, request.fault_injector,
        LinuxArchiveRestageFaultPoint::
            kAfterControlDirectoryMkdirBeforeCookie);
    control_created = true;
    control_identity = ReadLinuxFileIdentity(control.get());
    HitRestageFault(
        request, LinuxArchiveRestageFaultPoint::kAfterControlDirectoryCreate);
    recovery_record.control_identity = control_identity;
    recovery_record_identity = PersistRecoveryRecord(
        request.target_parent_fd, recovery_record_leaf, recovery_record, false,
        request);

    auto protected_archive = CreateFileAt(
        control.get(), kLinuxRetainedArtifactName, request.payload_uid,
        request.payload_gid, 0600, request.broker_mode);
    const std::string copied_sha = CopyArtifact(
        source_archive.get(), protected_archive.get(), request.artifact_length);
    if (copied_sha != request.artifact_sha256) {
      throw LinuxArchiveRestageError("signed ZIP SHA-256 mismatch");
    }
    SyncDirectory(control.get());
    payload_identity = ReadLinuxFileIdentity(payload.get());
    control_identity = ReadLinuxFileIdentity(control.get());
    recovery_record.payload_identity = payload_identity;
    recovery_record.control_identity = control_identity;
    recovery_record_identity = PersistRecoveryRecord(
        request.target_parent_fd, recovery_record_leaf, recovery_record, false,
        request);
    HitRestageFault(request,
                    LinuxArchiveRestageFaultPoint::kAfterProtectedCopy);

    if (lseek(protected_archive.get(), 0, SEEK_SET) < 0) {
      throw LinuxArchiveRestageError("protected ZIP seek failed");
    }
    FILE* archive_file = fdopen(dup(protected_archive.get()), "rb");
    if (archive_file == nullptr) {
      throw LinuxArchiveRestageError("protected ZIP stream failed");
    }
    mz_zip_archive archive{};
    std::vector<SealEntry> expected_inventory;
    if (!mz_zip_reader_init_cfile(&archive, archive_file,
                                  request.artifact_length, 0)) {
      fclose(archive_file);
      throw LinuxArchiveRestageError("protected ZIP open failed");
    }
    try {
      const auto entries = PreflightArchive(&archive);
      HitRestageFault(request,
                      LinuxArchiveRestageFaultPoint::kAfterArchivePreflight);
      expected_inventory = ExtractArchive(
          &archive, entries, payload.get(), request.payload_uid,
          request.payload_gid, request.broker_mode, request, [&]() {
            payload_identity = ReadLinuxFileIdentity(payload.get());
            control_identity = ReadLinuxFileIdentity(control.get());
            recovery_record.payload_identity = payload_identity;
            recovery_record.control_identity = control_identity;
            recovery_record_identity = PersistRecoveryRecord(
                request.target_parent_fd, recovery_record_leaf,
                recovery_record, false, request);
          });
      mz_zip_reader_end(&archive);
      fclose(archive_file);
    } catch (...) {
      mz_zip_reader_end(&archive);
      fclose(archive_file);
      throw;
    }

    RemoveCleanupCookie(payload.get(), recovery_record.cleanup_cookie,
                        request.payload_uid, request.payload_gid);
    RemoveCleanupCookie(control.get(), recovery_record.cleanup_cookie,
                        request.payload_uid, request.payload_gid);

    RequireExecutable(payload.get(), request.executable_relative_path,
                      request.payload_uid, request.payload_gid);
    const auto inventory = PayloadInventory(
        payload.get(), request.payload_uid, request.payload_gid,
        request.broker_mode, request.maximum_payload_seal_bytes);
    if (!SamePayloadInventory(expected_inventory, inventory)) {
      throw LinuxArchiveRestageError(
          "extracted payload differs from signed ZIP inventory");
    }
    WriteControlFile(control.get(), kLinuxReleaseManifestName,
                     request.canonical_release_manifest, request.payload_uid,
                     request.payload_gid, request.broker_mode);
    const std::string seal =
        EncodeCanonicalJson(SealJson(request, inventory));
    if (seal.size() > request.maximum_payload_seal_bytes) {
      throw LinuxArchiveRestageError("helper payload seal size rejected");
    }
    WriteControlFile(control.get(), kLinuxPayloadSealName, seal,
                     request.payload_uid, request.payload_gid,
                     request.broker_mode);
    const std::string seal_sha = Sha256LinuxBytes(seal);
    SyncDirectory(payload.get());
    SyncDirectory(control.get());
    SyncLinuxDirectory(request.target_parent_fd);
    payload_identity = ReadLinuxFileIdentity(payload.get());
    control_identity = ReadLinuxFileIdentity(control.get());
    recovery_record.payload_identity = payload_identity;
    recovery_record.control_identity = control_identity;
    recovery_record_identity = PersistRecoveryRecord(
        request.target_parent_fd, recovery_record_leaf, recovery_record, false,
        request);
    HitRestageFault(request,
                    LinuxArchiveRestageFaultPoint::kAfterPayloadSeal);

    auto target_parent = UniqueLinuxFd(dup(request.target_parent_fd));
    if (!target_parent.valid()) {
      throw LinuxArchiveRestageError("restage descriptor duplication failed");
    }
    auto retained_recovery_record = OpenLinuxRelativeNoFollow(
        request.target_parent_fd, recovery_record_leaf, O_RDONLY);
    RequireRecoveryRecordFile(retained_recovery_record.get(),
                              request.payload_uid, request.payload_gid);
    if (!HasExactLinuxIdentity(
            ReadLinuxFileIdentity(retained_recovery_record.get()),
            recovery_record_identity)) {
      throw LinuxArchiveRestageError("restage recovery identity changed");
    }
    return std::unique_ptr<LinuxArchiveRestagedPayload>(
        new LinuxArchiveRestagedPayload(
            request.target_parent_path / payload_leaf,
            request.target_parent_path / control_leaf, payload_leaf,
            control_leaf, seal_sha, copied_sha, std::move(target_parent),
            payload_identity, control_identity, recovery_record_leaf,
            recovery_record_identity, std::move(retained_recovery_record)));
  } catch (...) {
    const std::exception_ptr original_error = std::current_exception();
    bool payload_clean = !payload_created;
    bool control_clean = !control_created;
    if (payload_created) {
      try {
        if (LinuxRelativeExistsNoFollow(request.target_parent_fd,
                                        payload_leaf)) {
          payload_identity = ReadLinuxFileIdentity(payload.get());
          RemoveLinuxTreeExact(request.target_parent_fd, payload_leaf,
                               payload_identity);
        }
        payload_clean = true;
      } catch (...) {
      }
    }
    if (control_created) {
      try {
        if (LinuxRelativeExistsNoFollow(request.target_parent_fd,
                                        control_leaf)) {
          control_identity = ReadLinuxFileIdentity(control.get());
          RemoveLinuxTreeExact(request.target_parent_fd, control_leaf,
                               control_identity);
        }
        control_clean = true;
      } catch (...) {
      }
    }
    if (recovery_record_created && payload_clean && control_clean) {
      try {
        if (LinuxRelativeExistsNoFollow(request.target_parent_fd,
                                        recovery_record_leaf)) {
          auto retained = OpenLinuxRelativeNoFollow(
              request.target_parent_fd, recovery_record_leaf, O_RDONLY);
          RemoveRecoveryRecordExact(request.target_parent_fd,
                                    recovery_record_leaf,
                                    recovery_record_identity,
                                    retained.get());
        }
      } catch (...) {
      }
    }
    try {
      SyncLinuxDirectory(request.target_parent_fd);
    } catch (...) {
    }
    if (!payload_clean || !control_clean) {
      throw LinuxArchiveManualCleanupRequiredError(
          payload_leaf, control_leaf, recovery_record_leaf);
    }
    std::rethrow_exception(original_error);
  }
}

LinuxArchivePayloadVerification VerifyLinuxArchivePayload(
    int target_parent_fd,
    const std::string& payload_leaf,
    const std::string& control_leaf,
    const LinuxArchiveRestageRequest& expected,
    const std::string& expected_payload_seal_sha256) {
  auto payload = OpenReadableDirectoryAt(target_parent_fd, payload_leaf);
  auto control = OpenReadableDirectoryAt(target_parent_fd, control_leaf);
  const LinuxFileIdentity control_identity =
      ReadLinuxFileIdentity(control.get());
  if (!control_identity.directory ||
      control_identity.uid != expected.payload_uid ||
      control_identity.gid != expected.payload_gid ||
      (control_identity.mode & 0777) != 0700 ||
      (control_identity.mode & (S_ISUID | S_ISGID | S_ISVTX)) != 0) {
    throw LinuxArchiveRestageError("protected control ownership changed");
  }
  const auto inventory = PayloadInventory(
      payload.get(), expected.payload_uid, expected.payload_gid,
      expected.broker_mode, expected.maximum_payload_seal_bytes);
  const std::string seal = ReadBounded(
      control.get(), kLinuxPayloadSealName, kMaximumSealBytes,
      expected.payload_uid, expected.payload_gid);
  if (Sha256LinuxBytes(seal) != expected_payload_seal_sha256 ||
      EncodeCanonicalJson(SealJson(expected, inventory)) != seal) {
    throw LinuxArchiveRestageError("helper payload seal changed");
  }
  const std::string manifest = ReadBounded(
      control.get(), kLinuxReleaseManifestName, kMaximumManifestBytes,
      expected.payload_uid, expected.payload_gid);
  if (manifest != expected.canonical_release_manifest ||
      Sha256LinuxBytes(manifest) != expected.descriptor_sha256) {
    throw LinuxArchiveRestageError("protected release manifest changed");
  }
  auto archive = OpenLinuxRelativeNoFollow(
      control.get(), kLinuxRetainedArtifactName, O_RDONLY);
  RequireRegularExactOwner(archive.get(), expected.payload_uid,
                           expected.payload_gid,
                           "protected signed ZIP ownership changed");
  struct stat archive_status {};
  if (fstat(archive.get(), &archive_status) != 0 ||
      (archive_status.st_mode & 0777) != 0600) {
    throw LinuxArchiveRestageError("protected signed ZIP mode changed");
  }
  std::int64_t archive_length = 0;
  const std::string archive_sha = Sha256Fd(archive.get(), &archive_length);
  if (archive_sha != expected.artifact_sha256 ||
      archive_length != expected.artifact_length) {
    throw LinuxArchiveRestageError("protected signed ZIP changed");
  }
  const auto segments = SafeExecutableSegments(
      expected.executable_relative_path);
  auto executable_parent =
      OpenDirectoryChain(payload.get(), segments, segments.size() - 1);
  auto executable = OpenLinuxRelativeNoFollow(
      executable_parent.get(), segments.back(), O_RDONLY);
  struct stat status {};
  if (fstat(executable.get(), &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_uid != expected.payload_uid ||
      status.st_gid != expected.payload_gid || (status.st_mode & S_IXUSR) == 0) {
    throw LinuxArchiveRestageError("verified executable changed");
  }
  return {expected_payload_seal_sha256,
          archive_sha,
          expected.descriptor_sha256,
          Sha256Fd(executable.get()),
          static_cast<std::uint32_t>(status.st_mode),
          static_cast<std::uint32_t>(status.st_uid),
          static_cast<std::uint32_t>(status.st_gid)};
}

namespace {

bool SameIdentityExceptMode(const LinuxFileIdentity& current,
                            const LinuxFileIdentity& staged) {
  return current.device == staged.device && current.inode == staged.inode &&
         current.mount_id == staged.mount_id && current.uid == staged.uid &&
         current.gid == staged.gid && current.link_count == staged.link_count &&
         current.directory == staged.directory &&
         (current.mode & S_IFMT) == (staged.mode & S_IFMT);
}

}  // namespace

bool LinuxArchiveActivatedRootMatches(
    int target_parent_fd,
    const std::string& payload_leaf,
    const LinuxFileIdentity& staged_identity,
    const LinuxArchiveRestageRequest& expected) {
  if (!LinuxRelativeExistsNoFollow(target_parent_fd, payload_leaf)) return false;
  const LinuxFileIdentity current =
      ReadLinuxRelativeIdentity(target_parent_fd, payload_leaf);
  const std::uint32_t final_mode =
      static_cast<std::uint32_t>((staged_identity.mode & S_IFMT) |
                                 (expected.activation_root_mode & 0777));
  return SameIdentityExceptMode(current, staged_identity) &&
         (current.mode == staged_identity.mode || current.mode == final_mode);
}

void FinalizeLinuxArchiveActivatedRoot(
    int target_parent_fd,
    const std::string& payload_leaf,
    const LinuxFileIdentity& staged_identity,
    const LinuxArchiveRestageRequest& expected) {
  if (!LinuxArchiveActivatedRootMatches(target_parent_fd, payload_leaf,
                                        staged_identity, expected)) {
    throw LinuxArchiveRestageError("activated payload root identity changed");
  }
  auto root = OpenReadableDirectoryAt(target_parent_fd, payload_leaf);
  if (fchmod(root.get(), expected.activation_root_mode & 0777) != 0) {
    throw LinuxArchiveRestageError("activated payload root mode failed");
  }
  SyncDirectory(root.get());
  SyncLinuxDirectory(target_parent_fd);
  if (!LinuxArchiveActivatedRootMatches(target_parent_fd, payload_leaf,
                                        staged_identity, expected)) {
    throw LinuxArchiveRestageError("activated payload root mode changed");
  }
}

std::string ReadLinuxArchiveControlManifest(
    int target_parent_fd,
    const std::string& control_leaf,
    const LinuxArchiveRestageRequest& expected) {
  auto control = OpenReadableDirectoryAt(target_parent_fd, control_leaf);
  const LinuxFileIdentity identity = ReadLinuxFileIdentity(control.get());
  if (!identity.directory || identity.uid != expected.payload_uid ||
      identity.gid != expected.payload_gid || (identity.mode & 0777) != 0700) {
    throw LinuxArchiveRestageError("protected control ownership changed");
  }
  return ReadBounded(control.get(), kLinuxReleaseManifestName,
                     kMaximumManifestBytes, expected.payload_uid,
                     expected.payload_gid);
}

mode_t ReadLinuxArchiveActivationRootMode(
    int target_parent_fd,
    const std::string& control_leaf,
    uid_t expected_uid,
    gid_t expected_gid,
    const std::string& expected_payload_seal_sha256) {
  auto control = OpenReadableDirectoryAt(target_parent_fd, control_leaf);
  const LinuxFileIdentity identity = ReadLinuxFileIdentity(control.get());
  if (!identity.directory || identity.uid != expected_uid ||
      identity.gid != expected_gid || (identity.mode & 0777) != 0700) {
    throw LinuxArchiveRestageError("protected control ownership changed");
  }
  const std::string seal = ReadBounded(
      control.get(), kLinuxPayloadSealName, kMaximumSealBytes,
      expected_uid, expected_gid);
  const JsonValue parsed = runtime::internal::ParseJson(seal);
  if (Sha256LinuxBytes(seal) != expected_payload_seal_sha256 ||
      EncodeCanonicalJson(parsed) != seal ||
      parsed.at("schemaVersion").integer() != 1) {
    throw LinuxArchiveRestageError("protected payload seal changed");
  }
  const std::int64_t mode = parsed.at("activationRootMode").integer();
  if (mode <= 0 || mode > 0777 || (mode & S_IXUSR) == 0 ||
      (mode & (S_IWGRP | S_IWOTH)) != 0) {
    throw LinuxArchiveRestageError("activation root mode rejected");
  }
  return static_cast<mode_t>(mode);
}

void CleanupLinuxArchiveControl(
    int target_parent_fd,
    const std::string& control_leaf,
    const LinuxArchiveRestageRequest& expected,
    const std::string& expected_payload_seal_sha256) {
  auto control = OpenReadableDirectoryAt(target_parent_fd, control_leaf);
  const LinuxFileIdentity identity = ReadLinuxFileIdentity(control.get());
  if (!identity.directory || identity.uid != expected.payload_uid ||
      identity.gid != expected.payload_gid || (identity.mode & 0777) != 0700) {
    throw LinuxArchiveRestageError("control cleanup ownership changed");
  }
  const std::string seal = ReadBounded(
      control.get(), kLinuxPayloadSealName, kMaximumSealBytes,
      expected.payload_uid, expected.payload_gid);
  if (Sha256LinuxBytes(seal) != expected_payload_seal_sha256) {
    throw LinuxArchiveRestageError("control cleanup seal changed");
  }
  control.reset();
  RemoveLinuxTreeExact(target_parent_fd, control_leaf, identity);
  SyncLinuxDirectory(target_parent_fd);
}

void CleanupLinuxArchiveRestageRecord(
    int target_parent_fd,
    const LinuxArchiveRestageRequest& expected) {
  const std::string record_leaf =
      LinuxArchiveRestageRecordLeaf(expected.transaction_id);
  if (!LinuxRelativeExistsNoFollow(target_parent_fd, record_leaf)) return;
  auto file = OpenLinuxRelativeNoFollow(target_parent_fd, record_leaf, O_RDONLY);
  RequireRecoveryRecordFile(file.get(), expected.payload_uid,
                            expected.payload_gid);
  const LinuxFileIdentity identity = ReadLinuxFileIdentity(file.get());
  const RestageRecoveryRecord record =
      DecodeRecoveryRecord(ReadRecoveryRecordFile(file.get()));
  ValidateRecoveryBindings(
      record, expected, PayloadLeaf(expected.transaction_id),
      LinuxArchiveControlLeaf(expected.target_name, expected.transaction_id));
  if (LinuxRelativeExistsNoFollow(target_parent_fd, record.payload_leaf) ||
      LinuxRelativeExistsNoFollow(target_parent_fd, record.control_leaf)) {
    throw LinuxArchiveManualCleanupRequiredError(
        record.payload_leaf, record.control_leaf, record_leaf);
  }
  file.reset();
  auto retained =
      OpenLinuxRelativeNoFollow(target_parent_fd, record_leaf, O_RDONLY);
  RemoveRecoveryRecordExact(target_parent_fd, record_leaf, identity,
                            retained.get());
}

}  // namespace desktop_updater::helper
