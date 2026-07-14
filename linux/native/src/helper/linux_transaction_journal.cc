#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "linux_transaction_journal.h"

#include <dirent.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <regex>
#include <set>
#include <utility>

#include "json_value.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;

const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
const std::regex kSha256("^[0-9a-f]{64}$");
const std::regex kPackageId("^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$");

void RequireKeys(const JsonValue& value,
                 const std::set<std::string>& expected) {
  const auto& object = value.object();
  if (object.size() != expected.size()) {
    throw LinuxTransactionJournalError("journal has unknown or missing fields");
  }
  for (const auto& key : expected) {
    if (object.find(key) == object.end()) {
      throw LinuxTransactionJournalError(
          "journal has unknown or missing fields");
    }
  }
}

JsonValue EncodeIdentity(const LinuxFileIdentity& identity) {
  JsonValue::Object result;
  result.emplace("device", JsonValue(static_cast<std::int64_t>(identity.device)));
  result.emplace("directory", JsonValue(identity.directory));
  result.emplace("gid", JsonValue(static_cast<std::int64_t>(identity.gid)));
  result.emplace("inode", JsonValue(static_cast<std::int64_t>(identity.inode)));
  result.emplace("linkCount",
                 JsonValue(static_cast<std::int64_t>(identity.link_count)));
  result.emplace("mode", JsonValue(static_cast<std::int64_t>(identity.mode)));
  result.emplace("mountId",
                 JsonValue(static_cast<std::int64_t>(identity.mount_id)));
  result.emplace("uid", JsonValue(static_cast<std::int64_t>(identity.uid)));
  return JsonValue(std::move(result));
}

LinuxFileIdentity DecodeIdentity(const JsonValue& value) {
  RequireKeys(value, {"device", "directory", "gid", "inode", "linkCount",
                      "mode", "mountId", "uid"});
  LinuxFileIdentity identity{
      static_cast<std::uint64_t>(value.at("device").integer()),
      static_cast<std::uint64_t>(value.at("inode").integer()),
      static_cast<std::uint64_t>(value.at("mountId").integer()),
      static_cast<std::uint32_t>(value.at("mode").integer()),
      static_cast<std::uint32_t>(value.at("uid").integer()),
      static_cast<std::uint32_t>(value.at("gid").integer()),
      static_cast<std::uint64_t>(value.at("linkCount").integer()),
      value.at("directory").boolean(),
  };
  if (identity.inode == 0 || identity.mount_id == 0 ||
      identity.link_count == 0) {
    throw LinuxTransactionJournalError("invalid file identity");
  }
  return identity;
}

JsonValue EncodePayload(const LinuxVerifiedPayloadIdentity& identity) {
  JsonValue::Object result;
  result.emplace("artifactSha256", JsonValue(identity.artifact_sha256));
  result.emplace("executableGid",
                 JsonValue(static_cast<std::int64_t>(identity.executable_gid)));
  result.emplace("executableMode",
                 JsonValue(static_cast<std::int64_t>(identity.executable_mode)));
  result.emplace("executableRelativePath",
                 JsonValue(identity.executable_relative_path));
  result.emplace("executableSha256", JsonValue(identity.executable_sha256));
  result.emplace("executableUid",
                 JsonValue(static_cast<std::int64_t>(identity.executable_uid)));
  result.emplace("packageId", JsonValue(identity.package_id));
  result.emplace("packageIdentitySha256",
                 JsonValue(identity.package_identity_sha256));
  result.emplace("signerIdentity", JsonValue(identity.signer_identity));
  result.emplace("stageProvenanceSha256",
                 JsonValue(identity.stage_provenance_sha256));
  return JsonValue(std::move(result));
}

void ValidateSha256(const std::string& value) {
  if (!std::regex_match(value, kSha256)) {
    throw LinuxTransactionJournalError("invalid SHA-256 identity");
  }
}

LinuxVerifiedPayloadIdentity DecodePayload(const JsonValue& value) {
  RequireKeys(value,
              {"artifactSha256", "executableGid", "executableMode",
               "executableRelativePath", "executableSha256", "executableUid",
               "packageId", "packageIdentitySha256", "signerIdentity",
               "stageProvenanceSha256"});
  LinuxVerifiedPayloadIdentity result{
      value.at("packageId").string(),
      value.at("signerIdentity").string(),
      value.at("packageIdentitySha256").string(),
      value.at("stageProvenanceSha256").string(),
      value.at("artifactSha256").string(),
      value.at("executableRelativePath").string(),
      value.at("executableSha256").string(),
      static_cast<std::uint32_t>(value.at("executableMode").integer()),
      static_cast<std::uint32_t>(value.at("executableUid").integer()),
      static_cast<std::uint32_t>(value.at("executableGid").integer()),
  };
  if (!std::regex_match(result.package_id, kPackageId) ||
      result.signer_identity.empty() || result.executable_relative_path.empty() ||
      result.executable_relative_path.front() == '/' ||
      result.executable_relative_path.find("..") != std::string::npos) {
    throw LinuxTransactionJournalError("invalid payload identity");
  }
  ValidateSha256(result.package_identity_sha256);
  ValidateSha256(result.stage_provenance_sha256);
  ValidateSha256(result.artifact_sha256);
  ValidateSha256(result.executable_sha256);
  return result;
}

std::string StateName(LinuxTransactionState state) {
  switch (state) {
    case LinuxTransactionState::kPrepared:
      return "prepared";
    case LinuxTransactionState::kBackupCreated:
      return "backupCreated";
    case LinuxTransactionState::kTargetActivated:
      return "targetActivated";
    case LinuxTransactionState::kCompleted:
      return "completed";
    case LinuxTransactionState::kManualActionRequired:
      return "manualActionRequired";
  }
  return "manualActionRequired";
}

LinuxTransactionState ParseState(const std::string& state) {
  if (state == "prepared") return LinuxTransactionState::kPrepared;
  if (state == "backupCreated") return LinuxTransactionState::kBackupCreated;
  if (state == "targetActivated") {
    return LinuxTransactionState::kTargetActivated;
  }
  if (state == "completed") return LinuxTransactionState::kCompleted;
  if (state == "manualActionRequired") {
    return LinuxTransactionState::kManualActionRequired;
  }
  throw LinuxTransactionJournalError("unknown transaction state");
}

void WriteAll(int fd, const std::string& contents) {
  std::size_t offset = 0;
  while (offset < contents.size()) {
    const ssize_t count =
        write(fd, contents.data() + offset, contents.size() - offset);
    if (count <= 0) {
      throw LinuxTransactionJournalError("journal write failed or was short");
    }
    offset += static_cast<std::size_t>(count);
  }
}

long RenameAt2(int old_parent,
               const char* old_name,
               int new_parent,
               const char* new_name,
               unsigned int flags) {
  return syscall(SYS_renameat2, old_parent, old_name, new_parent, new_name,
                 flags);
}

void RemoveTree(int parent, const std::string& leaf) {
  auto retained = OpenLinuxRelativeNoFollow(parent, leaf, O_PATH);
  const LinuxFileIdentity identity = ReadLinuxFileIdentity(retained.get());
  if (!identity.directory) {
    if (identity.link_count != 1) {
      throw LinuxTransactionJournalError("hard-linked file cleanup rejected");
    }
    if (unlinkat(parent, leaf.c_str(), 0) != 0) {
      throw LinuxTransactionJournalError("unlinkat file cleanup failed");
    }
    return;
  }

  auto directory = OpenLinuxRelativeNoFollow(
      parent, leaf, O_RDONLY | O_DIRECTORY);
  DIR* stream = fdopendir(dup(directory.get()));
  if (stream == nullptr) {
    throw LinuxTransactionJournalError("fd-relative directory scan failed");
  }
  try {
    for (;;) {
      errno = 0;
      dirent* entry = readdir(stream);
      if (entry == nullptr) {
        if (errno != 0) {
          throw LinuxTransactionJournalError("directory scan failed");
        }
        break;
      }
      const std::string name(entry->d_name);
      if (name != "." && name != "..") RemoveTree(directory.get(), name);
    }
    closedir(stream);
    stream = nullptr;
    if (fsync(directory.get()) != 0) {
      throw LinuxTransactionJournalError("directory fsync failed");
    }
    if (unlinkat(parent, leaf.c_str(), AT_REMOVEDIR) != 0) {
      throw LinuxTransactionJournalError("unlinkat directory cleanup failed");
    }
  } catch (...) {
    if (stream != nullptr) closedir(stream);
    throw;
  }
}

}  // namespace

std::vector<LinuxTransactionFaultPoint> LinuxTransactionCrashInjectionPoints() {
  return {
      LinuxTransactionFaultPoint::kBeforePreparedJournalFlush,
      LinuxTransactionFaultPoint::kAfterPreparedJournalFlush,
      LinuxTransactionFaultPoint::kBeforeStageRename,
      LinuxTransactionFaultPoint::kAfterStageRenameBeforeDirectoryFlush,
      LinuxTransactionFaultPoint::kAfterStageRename,
      LinuxTransactionFaultPoint::kBeforeBackupRename,
      LinuxTransactionFaultPoint::kAfterBackupRenameBeforeDirectoryFlush,
      LinuxTransactionFaultPoint::kAfterBackupRename,
      LinuxTransactionFaultPoint::kBeforeBackupCreatedJournalFlush,
      LinuxTransactionFaultPoint::kAfterBackupCreatedJournalFlush,
      LinuxTransactionFaultPoint::kBeforeActivationRename,
      LinuxTransactionFaultPoint::kAfterActivationRenameBeforeDirectoryFlush,
      LinuxTransactionFaultPoint::kAfterActivationRename,
      LinuxTransactionFaultPoint::kBeforeTargetActivatedJournalFlush,
      LinuxTransactionFaultPoint::kAfterTargetActivatedJournalFlush,
      LinuxTransactionFaultPoint::kBeforeCompletedJournalFlush,
      LinuxTransactionFaultPoint::kAfterCompletedJournalFlush,
  };
}

bool LinuxVerifiedPayloadIdentity::operator==(
    const LinuxVerifiedPayloadIdentity& other) const {
  return package_id == other.package_id &&
         signer_identity == other.signer_identity &&
         package_identity_sha256 == other.package_identity_sha256 &&
         stage_provenance_sha256 == other.stage_provenance_sha256 &&
         artifact_sha256 == other.artifact_sha256 &&
         executable_relative_path == other.executable_relative_path &&
         executable_sha256 == other.executable_sha256 &&
         executable_mode == other.executable_mode &&
         executable_uid == other.executable_uid &&
         executable_gid == other.executable_gid;
}

LinuxTransactionPaths LinuxTransactionPaths::Create(
    const std::string& target_name,
    const std::string& transaction_id) {
  ValidateLinuxLeaf(target_name);
  if (!std::regex_match(transaction_id, kTransactionId)) {
    throw LinuxTransactionJournalError("invalid transaction ID");
  }
  const std::string prefix = "." + target_name + ".desktop-updater-" +
                             transaction_id;
  return {target_name,
          transaction_id,
          prefix + ".prepared",
          prefix + ".backup",
          prefix + ".journal.json",
          prefix + ".journal.json.next",
          "." + target_name + ".desktop-updater.lock",
          prefix + ".recovery.lock"};
}

std::string LinuxTransactionLockRecord::EncodeCanonical() const {
  JsonValue::Object result;
  result.emplace("ownerProcessId",
                 JsonValue(static_cast<std::int64_t>(owner_process_id)));
  result.emplace("ownerProcessStartIdentity",
                 JsonValue(static_cast<std::int64_t>(
                     owner_process_start_identity)));
  result.emplace("transactionId", JsonValue(transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(result)));
}

LinuxTransactionLockRecord LinuxTransactionLockRecord::DecodeStrict(
    const std::string& json) {
  JsonValue value;
  try {
    value = ParseJson(json);
  } catch (const std::exception&) {
    throw LinuxTransactionJournalError("invalid transaction lock record");
  }
  if (EncodeCanonicalJson(value) != json) {
    throw LinuxTransactionJournalError(
        "transaction lock record is not canonical JSON");
  }
  RequireKeys(value,
              {"ownerProcessId", "ownerProcessStartIdentity", "transactionId"});
  LinuxTransactionLockRecord result{
      value.at("transactionId").string(),
      static_cast<pid_t>(value.at("ownerProcessId").integer()),
      static_cast<std::uint64_t>(
          value.at("ownerProcessStartIdentity").integer()),
  };
  if (!std::regex_match(result.transaction_id, kTransactionId) ||
      result.owner_process_id <= 0 ||
      result.owner_process_start_identity == 0) {
    throw LinuxTransactionJournalError("invalid transaction lock identity");
  }
  return result;
}

std::string LinuxTransactionJournal::EncodeCanonical() const {
  JsonValue::Object result;
  result.emplace("backupName", JsonValue(backup_name));
  result.emplace("expectedPayloadIdentity",
                 EncodePayload(expected_payload_identity));
  result.emplace("lockName", JsonValue(lock_name));
  result.emplace("originalStageName", JsonValue(original_stage_name));
  result.emplace("ownerProcessId",
                 JsonValue(static_cast<std::int64_t>(owner_process_id)));
  result.emplace("ownerProcessStartIdentity",
                 JsonValue(static_cast<std::int64_t>(
                     owner_process_start_identity)));
  result.emplace("parentIdentity", EncodeIdentity(parent_identity));
  result.emplace("preparedName", JsonValue(prepared_name));
  result.emplace("schemaVersion", JsonValue(schema_version));
  result.emplace("stageIdentity", EncodeIdentity(stage_identity));
  result.emplace("state", JsonValue(StateName(state)));
  result.emplace("targetIdentity", EncodeIdentity(target_identity));
  result.emplace("targetName", JsonValue(target_name));
  result.emplace("transactionId", JsonValue(transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(result)));
}

LinuxTransactionJournal LinuxTransactionJournal::DecodeStrict(
    const std::string& json) {
  JsonValue value;
  try {
    value = ParseJson(json);
  } catch (const std::exception&) {
    throw LinuxTransactionJournalError("invalid or torn journal JSON");
  }
  if (EncodeCanonicalJson(value) != json) {
    throw LinuxTransactionJournalError("journal is not canonical JSON");
  }
  RequireKeys(value,
              {"backupName", "expectedPayloadIdentity", "lockName",
               "originalStageName", "ownerProcessId",
               "ownerProcessStartIdentity", "parentIdentity", "preparedName",
               "schemaVersion", "stageIdentity", "state", "targetIdentity",
               "targetName", "transactionId"});
  LinuxTransactionJournal result;
  result.schema_version = value.at("schemaVersion").integer();
  result.transaction_id = value.at("transactionId").string();
  result.owner_process_id =
      static_cast<pid_t>(value.at("ownerProcessId").integer());
  result.owner_process_start_identity = static_cast<std::uint64_t>(
      value.at("ownerProcessStartIdentity").integer());
  result.target_name = value.at("targetName").string();
  result.original_stage_name = value.at("originalStageName").string();
  result.prepared_name = value.at("preparedName").string();
  result.backup_name = value.at("backupName").string();
  result.lock_name = value.at("lockName").string();
  result.parent_identity = DecodeIdentity(value.at("parentIdentity"));
  result.target_identity = DecodeIdentity(value.at("targetIdentity"));
  result.stage_identity = DecodeIdentity(value.at("stageIdentity"));
  result.expected_payload_identity =
      DecodePayload(value.at("expectedPayloadIdentity"));
  result.state = ParseState(value.at("state").string());
  const auto paths =
      LinuxTransactionPaths::Create(result.target_name, result.transaction_id);
  if (result.schema_version != kSchemaVersion || result.owner_process_id <= 0 ||
      result.owner_process_start_identity == 0 ||
      result.prepared_name != paths.prepared_name ||
      result.backup_name != paths.backup_name ||
      result.lock_name != paths.lock_name) {
    throw LinuxTransactionJournalError("journal derivation mismatch");
  }
  ValidateLinuxLeaf(result.original_stage_name);
  return result;
}

void RenameLinuxRelative(int parent,
                         const std::string& source,
                         const std::string& destination,
                         bool replace_existing) {
  ValidateLinuxLeaf(source);
  ValidateLinuxLeaf(destination);
  const unsigned int flags = replace_existing ? 0 : RENAME_NOREPLACE;
  if (RenameAt2(parent, source.c_str(), parent, destination.c_str(), flags) == 0) {
    return;
  }
  if (errno == ENOSYS && replace_existing &&
      renameat(parent, source.c_str(), parent, destination.c_str()) == 0) {
    return;
  }
  throw LinuxTransactionJournalError("renameat2 relative swap failed");
}

void RemoveLinuxTreeExact(int parent,
                          const std::string& leaf,
                          const LinuxFileIdentity& expected_identity) {
  auto retained = OpenLinuxRelativeNoFollow(parent, leaf, O_PATH);
  if (ReadLinuxFileIdentity(retained.get()) != expected_identity) {
    throw LinuxTransactionJournalError("cleanup identity mismatch");
  }
  RemoveTree(parent, leaf);
  SyncLinuxDirectory(parent);
}

void SyncLinuxDirectory(int parent) {
  const int raw_directory =
      openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (raw_directory < 0) {
    throw LinuxTransactionJournalError("parent directory sync open failed");
  }
  UniqueLinuxFd directory(raw_directory);
  if (fsync(directory.get()) != 0) {
    throw LinuxTransactionJournalError("parent directory fsync failed");
  }
}

std::string ReadLinuxRelativeUtf8(int parent,
                                 const std::string& leaf,
                                 std::size_t maximum_bytes) {
  auto file = OpenLinuxRelativeNoFollow(parent, leaf, O_RDONLY);
  if (ReadLinuxFileIdentity(file.get()).directory) {
    throw LinuxTransactionJournalError("expected regular file");
  }
  std::string result;
  result.reserve(std::min<std::size_t>(maximum_bytes, 4096));
  char buffer[4096];
  for (;;) {
    const ssize_t count = read(file.get(), buffer, sizeof(buffer));
    if (count < 0) throw LinuxTransactionJournalError("relative read failed");
    if (count == 0) break;
    result.append(buffer, static_cast<std::size_t>(count));
    if (result.size() > maximum_bytes) {
      throw LinuxTransactionJournalError("relative file exceeds limit");
    }
  }
  return result;
}

DurableLinuxTransactionJournalStore::DurableLinuxTransactionJournalStore(
    int parent,
    LinuxTransactionPaths paths,
    LinuxTransactionFaultInjector* fault_injector)
    : parent_(parent),
      paths_(std::move(paths)),
      fault_injector_(fault_injector == nullptr ? &no_faults_ : fault_injector) {}

std::optional<LinuxTransactionJournal>
DurableLinuxTransactionJournalStore::Load() const {
  if (!LinuxRelativeExistsNoFollow(parent_, paths_.journal_name)) {
    return std::nullopt;
  }
  return LinuxTransactionJournal::DecodeStrict(
      ReadLinuxRelativeUtf8(parent_, paths_.journal_name, 1024 * 1024));
}

bool DurableLinuxTransactionJournalStore::HasAmbiguousNext() const {
  return LinuxRelativeExistsNoFollow(parent_, paths_.journal_next_name);
}

std::pair<LinuxTransactionFaultPoint, LinuxTransactionFaultPoint>
DurableLinuxTransactionJournalStore::FaultPoints(
    LinuxTransactionState state) const {
  switch (state) {
    case LinuxTransactionState::kPrepared:
      return {LinuxTransactionFaultPoint::kBeforePreparedJournalFlush,
              LinuxTransactionFaultPoint::kAfterPreparedJournalFlush};
    case LinuxTransactionState::kBackupCreated:
      return {LinuxTransactionFaultPoint::kBeforeBackupCreatedJournalFlush,
              LinuxTransactionFaultPoint::kAfterBackupCreatedJournalFlush};
    case LinuxTransactionState::kTargetActivated:
      return {LinuxTransactionFaultPoint::kBeforeTargetActivatedJournalFlush,
              LinuxTransactionFaultPoint::kAfterTargetActivatedJournalFlush};
    case LinuxTransactionState::kCompleted:
    case LinuxTransactionState::kManualActionRequired:
      return {LinuxTransactionFaultPoint::kBeforeCompletedJournalFlush,
              LinuxTransactionFaultPoint::kAfterCompletedJournalFlush};
  }
  return {LinuxTransactionFaultPoint::kBeforeCompletedJournalFlush,
          LinuxTransactionFaultPoint::kAfterCompletedJournalFlush};
}

void DurableLinuxTransactionJournalStore::Persist(
    const LinuxTransactionJournal& journal) {
  const auto points = FaultPoints(journal.state);
  fault_injector_->Hit(points.first);
  if (LinuxRelativeExistsNoFollow(parent_, paths_.journal_next_name)) {
    throw LinuxTransactionJournalError("ambiguous journal next file exists");
  }
  auto next = OpenLinuxRelativeNoFollow(
      parent_, paths_.journal_next_name,
      O_CREAT | O_EXCL | O_WRONLY, 0600);
  try {
    fault_injector_->Hit(LinuxTransactionFaultPoint::kDiskFull);
    fault_injector_->Hit(LinuxTransactionFaultPoint::kShortJournalWrite);
    WriteAll(next.get(), journal.EncodeCanonical());
    fault_injector_->Hit(LinuxTransactionFaultPoint::kFileFsyncFailure);
    if (fdatasync(next.get()) != 0) {
      throw LinuxTransactionJournalError("journal fdatasync failed");
    }
    next.reset();
    RenameLinuxRelative(parent_, paths_.journal_next_name, paths_.journal_name,
                        true);
    fault_injector_->Hit(LinuxTransactionFaultPoint::kDirectoryFsyncFailure);
    SyncLinuxDirectory(parent_);
    fault_injector_->Hit(points.second);
  } catch (...) {
    next.reset();
    throw;
  }
}

void DurableLinuxTransactionJournalStore::Remove() {
  if (LinuxRelativeExistsNoFollow(parent_, paths_.journal_name) &&
      unlinkat(parent_, paths_.journal_name.c_str(), 0) != 0) {
    throw LinuxTransactionJournalError("journal unlink failed");
  }
  if (LinuxRelativeExistsNoFollow(parent_, paths_.lock_name) &&
      unlinkat(parent_, paths_.lock_name.c_str(), 0) != 0) {
    throw LinuxTransactionJournalError("transaction lock unlink failed");
  }
  SyncLinuxDirectory(parent_);
}

}  // namespace desktop_updater::helper
