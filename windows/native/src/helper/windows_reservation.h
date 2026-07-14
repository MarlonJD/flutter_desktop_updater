#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RESERVATION_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RESERVATION_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>

namespace desktop_updater::helper {

class WindowsReservationError : public std::runtime_error {
 public:
  explicit WindowsReservationError(const std::string& detail)
      : std::runtime_error(detail) {}
};

enum class WindowsReservationState {
  kPrepared,
  kCompleted,
  kCancelled,
  kExpired,
};

struct WindowsReservationRequest {
  std::string transaction_id;
  std::filesystem::path target_parent;
  std::wstring target_leaf;
  std::filesystem::path staged_path;
  DWORD caller_process_id;
  std::string nonce;
  std::int64_t expires_epoch_millis;
};

class WindowsReservation {
 public:
  class OwnedHandle;

  ~WindowsReservation();
  WindowsReservation(const WindowsReservation&) = delete;
  WindowsReservation& operator=(const WindowsReservation&) = delete;

  const std::string& transaction_id() const { return transaction_id_; }
  const std::string& ready_token() const { return ready_token_; }
  WindowsReservationState state() const { return state_; }
  bool journal_durable_before_ready_token() const {
    return journal_durable_before_ready_token_;
  }
  bool has_caller_process_handle() const;
  bool has_target_parent_handle() const;
  bool has_stage_handle() const;
  bool has_target_lock_handle() const;
  bool has_journal_handle() const;

 private:
  friend class WindowsReservationStore;

  WindowsReservation(std::string transaction_id,
                     std::string nonce,
                     std::wstring target_key,
                     std::string ready_token,
                     std::int64_t expires_epoch_millis,
                     std::filesystem::path lock_path,
                     std::filesystem::path journal_path,
                     std::unique_ptr<OwnedHandle> caller_process,
                     std::unique_ptr<OwnedHandle> target_parent,
                     std::unique_ptr<OwnedHandle> stage,
                     std::unique_ptr<OwnedHandle> target_lock,
                     std::unique_ptr<OwnedHandle> journal);

  void Finish(WindowsReservationState state);
  void DeletePreparedState();

  std::string transaction_id_;
  std::string nonce_;
  std::wstring target_key_;
  std::string ready_token_;
  std::int64_t expires_epoch_millis_;
  WindowsReservationState state_ = WindowsReservationState::kPrepared;
  bool journal_durable_before_ready_token_ = true;
  std::filesystem::path lock_path_;
  std::filesystem::path journal_path_;
  std::unique_ptr<OwnedHandle> caller_process_;
  std::unique_ptr<OwnedHandle> target_parent_;
  std::unique_ptr<OwnedHandle> stage_;
  std::unique_ptr<OwnedHandle> target_lock_;
  std::unique_ptr<OwnedHandle> journal_;
};

class WindowsReservationStore {
 public:
  ~WindowsReservationStore();

  std::shared_ptr<WindowsReservation> Prepare(
      const WindowsReservationRequest& request);
  void Commit(const std::string& transaction_id,
              const std::string& ready_token,
              std::int64_t now_epoch_millis);
  void Cancel(const std::string& transaction_id,
              const std::string& ready_token);
  void CallerExited(const std::string& transaction_id);

 private:
  std::shared_ptr<WindowsReservation> FindPrepared(
      const std::string& transaction_id,
      const std::string& ready_token);
  void ReleaseTarget(const std::shared_ptr<WindowsReservation>& reservation);

  std::mutex mutex_;
  std::map<std::string, std::shared_ptr<WindowsReservation>> reservations_;
  std::set<std::wstring> active_targets_;
  std::set<std::string> consumed_nonces_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_RESERVATION_H_
