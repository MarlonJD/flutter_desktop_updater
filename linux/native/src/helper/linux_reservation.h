#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_RESERVATION_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_RESERVATION_H_

#include <sys/types.h>

#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>

namespace desktop_updater::helper {

class LinuxReservationError : public std::runtime_error {
 public:
  explicit LinuxReservationError(const std::string& detail)
      : std::runtime_error(detail) {}
};

enum class LinuxReservationState {
  kPrepared,
  kCompleted,
  kCancelled,
  kExpired,
};

struct LinuxReservationRequest {
  std::string transaction_id;
  std::filesystem::path target_parent;
  std::string target_leaf;
  std::filesystem::path staged_path;
  pid_t caller_process_id;
  std::string nonce;
  std::int64_t expires_epoch_millis;
  bool root_owned_target;
};

class LinuxReservation {
 public:
  class OwnedFd;

  ~LinuxReservation();
  LinuxReservation(const LinuxReservation&) = delete;
  LinuxReservation& operator=(const LinuxReservation&) = delete;

  const std::string& transaction_id() const { return transaction_id_; }
  const std::string& ready_token() const { return ready_token_; }
  LinuxReservationState state() const { return state_; }
  bool ready_token_after_durable_journal() const {
    return ready_token_after_durable_journal_;
  }
  bool has_target_parent_fd() const;
  bool has_stage_fd() const;
  bool has_lock_fd() const;
  bool has_journal_fd() const;
  bool has_pidfd_or_start_identity() const;

 private:
  friend class LinuxReservationStore;
  LinuxReservation(std::string transaction_id,
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
                   std::uint64_t process_start_identity);

  void Finish(LinuxReservationState state);
  void DeleteDerivedState();

  std::string transaction_id_;
  std::string nonce_;
  std::string target_key_;
  std::string ready_token_;
  std::int64_t expires_epoch_millis_;
  std::string lock_name_;
  std::string journal_name_;
  LinuxReservationState state_ = LinuxReservationState::kPrepared;
  bool ready_token_after_durable_journal_ = true;
  std::unique_ptr<OwnedFd> parent_;
  std::unique_ptr<OwnedFd> stage_;
  std::unique_ptr<OwnedFd> lock_;
  std::unique_ptr<OwnedFd> journal_;
  std::unique_ptr<OwnedFd> pidfd_;
  std::uint64_t process_start_identity_;
};

class LinuxReservationStore {
 public:
  explicit LinuxReservationStore(bool broker_authenticated = false)
      : broker_authenticated_(broker_authenticated) {}
  ~LinuxReservationStore();

  std::shared_ptr<LinuxReservation> Prepare(
      const LinuxReservationRequest& request);
  void Commit(const std::string& transaction_id,
              const std::string& ready_token,
              std::int64_t now_epoch_millis);
  void Cancel(const std::string& transaction_id,
              const std::string& ready_token);
  void CallerExited(const std::string& transaction_id);

 private:
  std::shared_ptr<LinuxReservation> FindPrepared(
      const std::string& transaction_id,
      const std::string& ready_token);
  void ReleaseTarget(const std::shared_ptr<LinuxReservation>& reservation);

  bool broker_authenticated_;
  std::mutex mutex_;
  std::map<std::string, std::shared_ptr<LinuxReservation>> reservations_;
  std::set<std::string> active_targets_;
  std::set<std::string> consumed_nonces_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_RESERVATION_H_
