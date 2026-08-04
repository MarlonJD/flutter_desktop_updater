#include "install_strategy.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <filesystem>
#include <optional>
#include <regex>
#include <set>
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

const std::regex kUuid(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-"
    "[0-9a-f]{12}$");
const std::regex kSha256("^[0-9a-f]{64}$");
const std::regex kIdentity("^[A-Za-z0-9][A-Za-z0-9._:+-]{0,255}$");
const std::regex kArchitecture("^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$");
const std::regex kScope("^$|^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$");
const std::regex kAuthority(
    "^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");

std::string StateName(LinuxProviderTransactionState state) {
  switch (state) {
    case LinuxProviderTransactionState::kPrepared: return "prepared";
    case LinuxProviderTransactionState::kManagerStarted:
      return "managerStarted";
    case LinuxProviderTransactionState::kVerificationPending:
      return "verificationPending";
    case LinuxProviderTransactionState::kCompleted: return "completed";
    case LinuxProviderTransactionState::kManualActionRequired:
      return "manualActionRequired";
  }
  throw LinuxProviderJournalError("provider journal state rejected");
}

LinuxProviderTransactionState ParseState(const std::string& state) {
  if (state == "prepared") return LinuxProviderTransactionState::kPrepared;
  if (state == "managerStarted") {
    return LinuxProviderTransactionState::kManagerStarted;
  }
  if (state == "verificationPending") {
    return LinuxProviderTransactionState::kVerificationPending;
  }
  if (state == "completed") return LinuxProviderTransactionState::kCompleted;
  if (state == "manualActionRequired") {
    return LinuxProviderTransactionState::kManualActionRequired;
  }
  throw LinuxProviderJournalError("provider journal state rejected");
}

void RequireKeys(const JsonValue& value,
                 const std::set<std::string>& expected) {
  if (value.object().size() != expected.size()) {
    throw LinuxProviderJournalError("provider journal fields rejected");
  }
  for (const std::string& key : expected) {
    if (value.find(key) == nullptr) {
      throw LinuxProviderJournalError("provider journal fields rejected");
    }
  }
}

void ValidateRecord(const LinuxProviderJournalRecord& record) {
  static const std::set<std::string> providers = {"apt", "dnf", "flatpak",
                                                   "snap"};
  if (record.schema_version != LinuxProviderJournalRecord::kSchemaVersion ||
      !std::regex_match(record.transaction_id, kUuid) ||
      providers.count(record.transaction.provider) == 0 ||
      record.transaction.package_id.empty() ||
      record.transaction.package_id.size() > 256 ||
      !std::regex_match(record.transaction.transaction_identity, kIdentity) ||
      record.expected_version_or_revision.empty() ||
      record.expected_version_or_revision.size() > 128 ||
      !std::regex_match(record.transaction.expected_architecture,
                        kArchitecture) ||
      !std::regex_match(record.transaction.provider_scope, kScope) ||
      !std::regex_match(record.transaction.provider_authority, kAuthority) ||
      !std::regex_match(record.command_sha256, kSha256)) {
    throw LinuxProviderJournalError("provider journal record rejected");
  }
  (void)StateName(record.transaction.state);
}

JsonValue Payload(const LinuxProviderJournalRecord& record) {
  JsonValue::Object payload;
  payload.emplace("commandSha256", JsonValue(record.command_sha256));
  payload.emplace("expectedVersionOrRevision",
                  JsonValue(record.expected_version_or_revision));
  payload.emplace("expectedArchitecture",
                  JsonValue(record.transaction.expected_architecture));
  payload.emplace("packageId", JsonValue(record.transaction.package_id));
  payload.emplace("provider", JsonValue(record.transaction.provider));
  payload.emplace("providerAuthority",
                  JsonValue(record.transaction.provider_authority));
  payload.emplace("providerScope",
                  JsonValue(record.transaction.provider_scope));
  payload.emplace("providerState", JsonValue(StateName(record.transaction.state)));
  payload.emplace("providerTransactionIdentity",
                  JsonValue(record.transaction.transaction_identity));
  payload.emplace("schemaVersion", JsonValue(record.schema_version));
  payload.emplace("transactionId", JsonValue(record.transaction_id));
  return JsonValue(std::move(payload));
}

std::string EncodeRecord(const LinuxProviderJournalRecord& record) {
  ValidateRecord(record);
  JsonValue payload = Payload(record);
  const std::string canonical_payload = EncodeCanonicalJson(payload);
  JsonValue::Object wrapper;
  wrapper.emplace("payload", std::move(payload));
  wrapper.emplace("recordSha256",
                  JsonValue(Sha256LinuxBytes(canonical_payload)));
  return EncodeCanonicalJson(JsonValue(std::move(wrapper)));
}

LinuxProviderJournalRecord DecodeRecord(const std::string& bytes) {
  try {
    const JsonValue wrapper = ParseJson(bytes);
    if (EncodeCanonicalJson(wrapper) != bytes) {
      throw LinuxProviderJournalError("provider journal is not canonical");
    }
    RequireKeys(wrapper, {"payload", "recordSha256"});
    const JsonValue& payload = wrapper.at("payload");
    RequireKeys(payload,
                {"commandSha256", "expectedArchitecture",
                 "expectedVersionOrRevision", "packageId", "provider",
                 "providerAuthority", "providerScope", "providerState",
                 "providerTransactionIdentity", "schemaVersion",
                 "transactionId"});
    const std::string canonical_payload = EncodeCanonicalJson(payload);
    if (wrapper.at("recordSha256").string() !=
        Sha256LinuxBytes(canonical_payload)) {
      throw LinuxProviderJournalError("provider journal digest changed");
    }
    LinuxProviderJournalRecord record;
    record.schema_version = payload.at("schemaVersion").integer();
    record.transaction_id = payload.at("transactionId").string();
    record.transaction.provider = payload.at("provider").string();
    record.transaction.package_id = payload.at("packageId").string();
    record.transaction.transaction_identity =
        payload.at("providerTransactionIdentity").string();
    record.transaction.state =
        ParseState(payload.at("providerState").string());
    record.transaction.expected_architecture =
        payload.at("expectedArchitecture").string();
    record.transaction.provider_scope = payload.at("providerScope").string();
    record.transaction.provider_authority =
        payload.at("providerAuthority").string();
    record.expected_version_or_revision =
        payload.at("expectedVersionOrRevision").string();
    record.command_sha256 = payload.at("commandSha256").string();
    ValidateRecord(record);
    return record;
  } catch (const LinuxProviderJournalError&) {
    throw;
  } catch (...) {
    throw LinuxProviderJournalError("provider journal JSON rejected");
  }
}

void VerifyDirectory(const fs::path& path,
                     int fd,
                     uid_t uid,
                     gid_t gid,
                     std::uint64_t device,
                     std::uint64_t inode) {
  struct stat located {};
  struct stat retained {};
  if (lstat(path.c_str(), &located) != 0 ||
      fstat(fd, &retained) != 0 || !S_ISDIR(located.st_mode) ||
      S_ISLNK(located.st_mode) || !S_ISDIR(retained.st_mode) ||
      located.st_dev != retained.st_dev || located.st_ino != retained.st_ino ||
      static_cast<std::uint64_t>(retained.st_dev) != device ||
      static_cast<std::uint64_t>(retained.st_ino) != inode ||
      retained.st_uid != uid || retained.st_gid != gid ||
      (retained.st_mode & 07777) != 0700) {
    throw LinuxProviderJournalError("provider journal directory changed");
  }
}

void RequireFile(int fd, uid_t uid, gid_t gid) {
  struct stat status {};
  if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_uid != uid || status.st_gid != gid ||
      (status.st_mode & 07777) != 0600) {
    throw LinuxProviderJournalError("provider journal file rejected");
  }
}

void WriteAll(int fd, const std::string& bytes) {
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    ssize_t count = -1;
    do {
      count = write(fd, bytes.data() + offset, bytes.size() - offset);
    } while (count < 0 && errno == EINTR);
    if (count <= 0) {
      throw LinuxProviderJournalError("provider journal write failed");
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
                         128 * 1024) {
      throw LinuxProviderJournalError("provider journal read failed");
    }
    bytes.append(buffer.data(), static_cast<std::size_t>(count));
  }
}

bool ImmutableFieldsMatch(const LinuxProviderJournalRecord& first,
                          const LinuxProviderJournalRecord& second) {
  return first.schema_version == second.schema_version &&
         first.transaction_id == second.transaction_id &&
         first.transaction.provider == second.transaction.provider &&
         first.transaction.package_id == second.transaction.package_id &&
         first.transaction.expected_architecture ==
             second.transaction.expected_architecture &&
         first.transaction.provider_scope ==
             second.transaction.provider_scope &&
         first.transaction.provider_authority ==
             second.transaction.provider_authority &&
         first.expected_version_or_revision ==
             second.expected_version_or_revision &&
         first.command_sha256 == second.command_sha256;
}

bool IdentityTransitionAllowed(const LinuxProviderJournalRecord& from,
                               const LinuxProviderJournalRecord& to) {
  if (from.transaction.transaction_identity ==
      to.transaction.transaction_identity) {
    return true;
  }
  const bool pending = from.transaction.transaction_identity ==
                       "pending-" + from.command_sha256;
  const bool start_captured =
      from.transaction.state == LinuxProviderTransactionState::kPrepared &&
      to.transaction.state == LinuxProviderTransactionState::kManagerStarted;
  const bool recovery_captured =
      from.transaction.state ==
          LinuxProviderTransactionState::kVerificationPending &&
      to.transaction.state == LinuxProviderTransactionState::kCompleted;
  return pending && (start_captured || recovery_captured) &&
         std::regex_match(to.transaction.transaction_identity, kIdentity);
}

bool IsAllowedTransition(LinuxProviderTransactionState from,
                         LinuxProviderTransactionState to) {
  if (from == to) return true;
  if (from == LinuxProviderTransactionState::kPrepared) {
    return to == LinuxProviderTransactionState::kManagerStarted ||
           to == LinuxProviderTransactionState::kVerificationPending ||
           to == LinuxProviderTransactionState::kManualActionRequired;
  }
  if (from == LinuxProviderTransactionState::kManagerStarted) {
    return to == LinuxProviderTransactionState::kVerificationPending ||
           to == LinuxProviderTransactionState::kCompleted ||
           to == LinuxProviderTransactionState::kManualActionRequired;
  }
  if (from == LinuxProviderTransactionState::kVerificationPending) {
    return to == LinuxProviderTransactionState::kCompleted ||
           to == LinuxProviderTransactionState::kManualActionRequired;
  }
  return false;
}

}  // namespace

LinuxProviderJournal::LinuxProviderJournal(fs::path directory,
                                           uid_t uid,
                                           gid_t gid)
    : directory_(std::move(directory)), uid_(uid), gid_(gid) {
  if (!directory_.is_absolute() || directory_.lexically_normal() != directory_) {
    throw LinuxProviderJournalError("provider journal path rejected");
  }
  directory_fd_ =
      open(directory_.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  struct stat status {};
  if (directory_fd_ < 0 || fstat(directory_fd_, &status) != 0 ||
      !S_ISDIR(status.st_mode) || status.st_uid != uid_ ||
      status.st_gid != gid_ || (status.st_mode & 07777) != 0700) {
    if (directory_fd_ >= 0) close(directory_fd_);
    directory_fd_ = -1;
    throw LinuxProviderJournalError("provider journal directory rejected");
  }
  directory_device_ = static_cast<std::uint64_t>(status.st_dev);
  directory_inode_ = static_cast<std::uint64_t>(status.st_ino);
  VerifyDirectory(directory_, directory_fd_, uid_, gid_, directory_device_,
                  directory_inode_);
}

LinuxProviderJournal::~LinuxProviderJournal() {
  if (directory_fd_ >= 0) close(directory_fd_);
}

std::optional<LinuxProviderJournalRecord> LinuxProviderJournal::Load(
    const std::string& transaction_id) const {
  if (!std::regex_match(transaction_id, kUuid)) {
    throw LinuxProviderJournalError("provider transaction ID rejected");
  }
  VerifyDirectory(directory_, directory_fd_, uid_, gid_, directory_device_,
                  directory_inode_);
  const std::string leaf = transaction_id + ".provider.json";
  UniqueLinuxFd file(openat(directory_fd_, leaf.c_str(),
                            O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  if (!file.valid()) {
    if (errno == ENOENT) return std::nullopt;
    throw LinuxProviderJournalError("provider journal open failed");
  }
  RequireFile(file.get(), uid_, gid_);
  LinuxProviderJournalRecord record = DecodeRecord(ReadAll(file.get()));
  if (record.transaction_id != transaction_id) {
    throw LinuxProviderJournalError("provider journal binding changed");
  }
  return record;
}

void LinuxProviderJournal::Persist(
    const LinuxProviderJournalRecord& record) const {
  ValidateRecord(record);
  const auto existing = Load(record.transaction_id);
  if (existing.has_value() &&
      (!ImmutableFieldsMatch(*existing, record) ||
       !IdentityTransitionAllowed(*existing, record) ||
       !IsAllowedTransition(existing->transaction.state,
                            record.transaction.state))) {
    throw LinuxProviderJournalError("provider journal transition rejected");
  }
  const std::string bytes = EncodeRecord(record);
  const std::string leaf = record.transaction_id + ".provider.json";
  const std::string temporary =
      "." + record.transaction_id + "." + std::to_string(getpid()) +
      ".provider.tmp";
  VerifyDirectory(directory_, directory_fd_, uid_, gid_, directory_device_,
                  directory_inode_);
  UniqueLinuxFd file(openat(
      directory_fd_, temporary.c_str(),
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
  if (!file.valid()) {
    throw LinuxProviderJournalError("provider journal create failed");
  }
  try {
    RequireFile(file.get(), uid_, gid_);
    WriteAll(file.get(), bytes);
    if (fsync(file.get()) != 0) {
      throw LinuxProviderJournalError("provider journal sync failed");
    }
    file.reset();
  } catch (...) {
    (void)unlinkat(directory_fd_, temporary.c_str(), 0);
    throw;
  }
  if (renameat(directory_fd_, temporary.c_str(), directory_fd_, leaf.c_str()) !=
          0 ||
      fsync(directory_fd_) != 0) {
    (void)unlinkat(directory_fd_, temporary.c_str(), 0);
    throw LinuxProviderJournalError("provider journal publish failed");
  }
}

}  // namespace desktop_updater::helper
