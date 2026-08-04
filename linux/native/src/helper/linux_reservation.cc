#include "linux_reservation.h"

#include <fcntl.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <regex>
#include <utility>

#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

bool IsNonce(const std::string& nonce) {
  return nonce.size() == 43 &&
         std::all_of(nonce.begin(), nonce.end(), [](unsigned char character) {
           return (character >= 'A' && character <= 'Z') ||
                  (character >= 'a' && character <= 'z') ||
                  (character >= '0' && character <= '9') || character == '-' ||
                  character == '_';
         });
}

void ValidateLeaf(const std::string& leaf) {
  if (leaf.empty() || leaf == "." || leaf == ".." ||
      leaf.find('/') != std::string::npos ||
      leaf.find('\0') != std::string::npos) {
    throw LinuxReservationError("target leaf must be one path component");
  }
}

std::string GenerateReadyToken() {
  std::array<unsigned char, 32> bytes{};
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const ssize_t count = getrandom(bytes.data() + offset,
                                    bytes.size() - offset, 0);
    if (count <= 0) {
      throw LinuxReservationError("ready token generation failed");
    }
    offset += static_cast<std::size_t>(count);
  }
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::string output;
  output.reserve(43);
  std::uint32_t buffer = 0;
  int bits = 0;
  for (unsigned char byte : bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      output.push_back(alphabet[(buffer >> bits) & 0x3f]);
    }
  }
  if (bits > 0) output.push_back(alphabet[(buffer << (6 - bits)) & 0x3f]);
  return output;
}

void WriteAll(int fd, const std::string& contents) {
  std::size_t offset = 0;
  while (offset < contents.size()) {
    const ssize_t count =
        write(fd, contents.data() + offset, contents.size() - offset);
    if (count <= 0) throw LinuxReservationError("journal write failed");
    offset += static_cast<std::size_t>(count);
  }
}

}  // namespace

class LinuxReservation::OwnedFd {
 public:
  explicit OwnedFd(int fd = -1) : fd_(fd) {}
  ~OwnedFd() {
    if (fd_ >= 0) close(fd_);
  }
  int get() const { return fd_; }
  bool valid() const { return fd_ >= 0; }
  void reset() {
    if (fd_ >= 0) close(fd_);
    fd_ = -1;
  }

 private:
  int fd_;
};

LinuxReservation::LinuxReservation(
    std::string transaction_id,
    std::string nonce,
    std::string target_key,
    std::string ready_token,
    std::int64_t expires_epoch_millis,
    std::string lock_name,
    std::string journal_name,
    std::unique_ptr<OwnedFd> parent,
    std::unique_ptr<OwnedFd> stage,
    std::unique_ptr<OwnedFd> lock,
    std::unique_ptr<OwnedFd> journal,
    std::unique_ptr<OwnedFd> pidfd,
    std::uint64_t process_start_identity)
    : transaction_id_(std::move(transaction_id)),
      nonce_(std::move(nonce)),
      target_key_(std::move(target_key)),
      ready_token_(std::move(ready_token)),
      expires_epoch_millis_(expires_epoch_millis),
      lock_name_(std::move(lock_name)),
      journal_name_(std::move(journal_name)),
      parent_(std::move(parent)),
      stage_(std::move(stage)),
      lock_(std::move(lock)),
      journal_(std::move(journal)),
      pidfd_(std::move(pidfd)),
      process_start_identity_(process_start_identity) {}

LinuxReservation::~LinuxReservation() {
  if (state_ == LinuxReservationState::kPrepared) DeleteDerivedState();
}

bool LinuxReservation::has_target_parent_fd() const {
  return parent_ && parent_->valid();
}
bool LinuxReservation::has_stage_fd() const {
  return stage_ && stage_->valid();
}
bool LinuxReservation::has_lock_fd() const {
  return lock_ && lock_->valid();
}
bool LinuxReservation::has_journal_fd() const {
  return journal_ && journal_->valid();
}
bool LinuxReservation::has_pidfd_or_start_identity() const {
  return (pidfd_ && pidfd_->valid()) || process_start_identity_ != 0;
}

void LinuxReservation::DeleteDerivedState() {
  if (parent_ && parent_->valid()) {
    struct stat observed {};
    struct stat retained {};
    if (journal_ && journal_->valid() && fstat(journal_->get(), &retained) == 0 &&
        fstatat(parent_->get(), journal_name_.c_str(), &observed,
                AT_SYMLINK_NOFOLLOW) == 0 &&
        observed.st_dev == retained.st_dev && observed.st_ino == retained.st_ino) {
      unlinkat(parent_->get(), journal_name_.c_str(), 0);
    }
    if (lock_ && lock_->valid() && fstat(lock_->get(), &retained) == 0 &&
        fstatat(parent_->get(), lock_name_.c_str(), &observed,
                AT_SYMLINK_NOFOLLOW) == 0 &&
        observed.st_dev == retained.st_dev && observed.st_ino == retained.st_ino) {
      unlinkat(parent_->get(), lock_name_.c_str(), 0);
    }
  }
  journal_.reset();
  lock_.reset();
  stage_.reset();
  pidfd_.reset();
  parent_.reset();
}

void LinuxReservation::Finish(LinuxReservationState state) {
  if (state_ != LinuxReservationState::kPrepared) {
    throw LinuxReservationError("reservation is terminal");
  }
  state_ = state;
  DeleteDerivedState();
}

LinuxReservationStore::~LinuxReservationStore() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto& entry : reservations_) {
    if (entry.second->state_ == LinuxReservationState::kPrepared) {
      entry.second->Finish(LinuxReservationState::kCancelled);
    }
  }
}

std::shared_ptr<LinuxReservation> LinuxReservationStore::Prepare(
    const LinuxReservationRequest& request) {
  if (!std::regex_match(request.transaction_id, kTransactionId) ||
      !IsNonce(request.nonce) || request.expires_epoch_millis <= 0) {
    throw LinuxReservationError("reservation envelope rejected");
  }
  ValidateLeaf(request.target_leaf);
  ValidateLeaf(request.staged_path.filename().string());
  if (request.staged_path.parent_path().lexically_normal() !=
      request.target_parent.lexically_normal()) {
    throw LinuxReservationError("stage must be a target-parent sibling");
  }
  if (request.root_owned_target && !broker_authenticated_) {
    throw LinuxReservationError("root-owned AppImage requires installed broker");
  }

  const int parent_fd = open(request.target_parent.c_str(),
                             O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (parent_fd < 0) throw LinuxReservationError("target parent pin failed");
  auto parent = std::make_unique<LinuxReservation::OwnedFd>(parent_fd);
  struct stat parent_status {};
  if (fstat(parent_fd, &parent_status) != 0 ||
      !S_ISDIR(parent_status.st_mode) || S_ISLNK(parent_status.st_mode)) {
    throw LinuxReservationError("target parent is not a pinned directory");
  }
  const int stage_fd = openat(parent_fd, request.staged_path.filename().c_str(),
                              O_PATH | O_NOFOLLOW | O_CLOEXEC);
  if (stage_fd < 0) throw LinuxReservationError("stage pin failed");
  auto stage = std::make_unique<LinuxReservation::OwnedFd>(stage_fd);
  struct stat stage_status {};
  if (fstat(stage_fd, &stage_status) != 0 || S_ISLNK(stage_status.st_mode)) {
    throw LinuxReservationError("stage symlink pin rejected");
  }
  const int sync_fd =
      openat(parent_fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (sync_fd < 0) throw LinuxReservationError("parent sync fd failed");
  LinuxReservation::OwnedFd sync_parent(sync_fd);

  std::unique_ptr<LinuxReservation::OwnedFd> pidfd;
  const int raw_pidfd = OpenLinuxPidfd(request.caller_process_id);
  std::uint64_t start_identity = 0;
  if (raw_pidfd >= 0) {
    pidfd = std::make_unique<LinuxReservation::OwnedFd>(raw_pidfd);
  } else {
    start_identity = LinuxProcessStartIdentity(request.caller_process_id);
  }

  const std::string target_key =
      request.target_parent.lexically_normal().string() + "/" +
      request.target_leaf;
  const std::string lock_name =
      "." + request.target_leaf + ".desktop-updater.lock";
  const std::string journal_name =
      "." + request.target_leaf + ".desktop-updater-" +
      request.transaction_id + ".journal.json";

  std::lock_guard<std::mutex> guard(mutex_);
  if (reservations_.count(request.transaction_id) != 0 ||
      active_targets_.count(target_key) != 0 ||
      consumed_nonces_.count(request.nonce) != 0) {
    throw LinuxReservationError("transaction, target, or nonce already reserved");
  }
  const int lock_fd = openat(parent_fd, lock_name.c_str(),
                             O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                             0600);
  if (lock_fd < 0) throw LinuxReservationError("target lock acquisition failed");
  auto target_lock = std::make_unique<LinuxReservation::OwnedFd>(lock_fd);
  const int journal_fd =
      openat(parent_fd, journal_name.c_str(),
             O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (journal_fd < 0) {
    unlinkat(parent_fd, lock_name.c_str(), 0);
    throw LinuxReservationError("initial journal creation failed");
  }
  auto journal = std::make_unique<LinuxReservation::OwnedFd>(journal_fd);
  try {
    WriteAll(journal_fd,
             "{\"schemaVersion\":1,\"state\":\"prepared\",\"transactionId\":\"" +
                 request.transaction_id + "\"}\n");
    if (fsync(journal_fd) != 0 || fsync(sync_fd) != 0) {
      throw LinuxReservationError("initial journal durability failed");
    }
    const bool readyTokenAfterDurableJournal = true;
    std::string ready_token = GenerateReadyToken();
    if (!readyTokenAfterDurableJournal) {
      throw LinuxReservationError("ready token ordering failed");
    }

    auto reservation = std::shared_ptr<LinuxReservation>(new LinuxReservation(
        request.transaction_id, request.nonce, target_key,
        std::move(ready_token), request.expires_epoch_millis, lock_name,
        journal_name, std::move(parent), std::move(stage),
        std::move(target_lock), std::move(journal), std::move(pidfd),
        start_identity));
    reservations_.emplace(request.transaction_id, reservation);
    active_targets_.insert(target_key);
    consumed_nonces_.insert(request.nonce);
    return reservation;
  } catch (...) {
    unlinkat(parent_fd, journal_name.c_str(), 0);
    unlinkat(parent_fd, lock_name.c_str(), 0);
    throw;
  }
}

std::shared_ptr<LinuxReservation> LinuxReservationStore::FindPrepared(
    const std::string& transaction_id,
    const std::string& ready_token) {
  const auto found = reservations_.find(transaction_id);
  if (found == reservations_.end() ||
      found->second->state_ != LinuxReservationState::kPrepared ||
      found->second->ready_token_ != ready_token) {
    throw LinuxReservationError("unknown or terminal reservation");
  }
  return found->second;
}

void LinuxReservationStore::ReleaseTarget(
    const std::shared_ptr<LinuxReservation>& reservation) {
  active_targets_.erase(reservation->target_key_);
}

void LinuxReservationStore::Commit(const std::string& transaction_id,
                                   const std::string& ready_token,
                                   std::int64_t now_epoch_millis) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto reservation = FindPrepared(transaction_id, ready_token);
  if (now_epoch_millis > reservation->expires_epoch_millis_) {
    reservation->Finish(LinuxReservationState::kExpired);
    ReleaseTarget(reservation);
    throw LinuxReservationError("reservation expired before mutation");
  }
  reservation->Finish(LinuxReservationState::kCompleted);
  ReleaseTarget(reservation);
}

void LinuxReservationStore::Cancel(const std::string& transaction_id,
                                   const std::string& ready_token) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto reservation = FindPrepared(transaction_id, ready_token);
  reservation->Finish(LinuxReservationState::kCancelled);
  ReleaseTarget(reservation);
}

void LinuxReservationStore::CallerExited(const std::string& transaction_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = reservations_.find(transaction_id);
  if (found == reservations_.end() ||
      found->second->state_ != LinuxReservationState::kPrepared) {
    throw LinuxReservationError("unknown or terminal reservation");
  }
  found->second->Finish(LinuxReservationState::kCancelled);
  ReleaseTarget(found->second);
}

}  // namespace desktop_updater::helper
