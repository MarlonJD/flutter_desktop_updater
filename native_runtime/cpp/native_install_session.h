#ifndef DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_SESSION_H_
#define DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_SESSION_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>

#include "native_install_request.h"
#include "native_install_wire.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

class NativeInstallSessionError : public std::runtime_error {
 public:
  explicit NativeInstallSessionError(const std::string& detail)
      : std::runtime_error(detail) {}
};

class NativeInstallPreparedTransactionV1 {
 public:
  virtual ~NativeInstallPreparedTransactionV1() = default;
  virtual const std::string& transaction_id() const = 0;
  virtual std::string PrepareDurableJournal() = 0;
  virtual void ExecuteAfterCallerExit() = 0;
  virtual void CancelPrepared() = 0;
};

class NativeInstallRequestAuthorizerV1 {
 public:
  virtual ~NativeInstallRequestAuthorizerV1() = default;
  virtual const std::string& helper_endpoint_identity_sha256() const = 0;
  virtual std::unique_ptr<NativeInstallPreparedTransactionV1> Authorize(
      const NativeInstallTransactionRequestV1& request) = 0;
};

class NativeInstallOneShotSessionV1 {
 public:
  using ReadyTokenGenerator = std::function<std::string()>;
  using Sha256Function = std::function<std::string(const std::string&)>;
  using Clock = std::function<std::int64_t()>;

  NativeInstallOneShotSessionV1(
      NativeInstallRequestAuthorizerV1& authorizer,
      ReadyTokenGenerator ready_token_generator,
      Sha256Function sha256,
      Clock now_unix_milliseconds,
      std::int64_t reservation_lifetime_milliseconds);
  ~NativeInstallOneShotSessionV1();

  NativeInstallReservationV1 Prepare(
      const std::string& canonical_request);
  NativeInstallReservationV1 AcceptCommit(
      const std::string& canonical_command);
  NativeInstallTransactionStatusV1 ExecuteAfterCallerExit();
  NativeInstallRecoveryResultV1 Cancel(
      const std::string& canonical_command);
  NativeInstallRecoveryResultV1 CancelBeforeCommitOnCallerExit();
  NativeInstallRecoveryResultV1 CancelCommitAwaitingCallerExit();

 private:
  enum class State {
    kInitial,
    kPreparing,
    kPrepared,
    kCommitAccepted,
    kExecuting,
    kCancelling,
    kCancelled,
    kCompleted,
    kRecoveryRequired,
  };

  void RequireState(State expected) const;
  void RequireBinding(const NativeInstallWireCommandV1& command,
                      const std::string& operation) const;
  NativeInstallRecoveryResultV1 CancelPreparedState(State expected);

  NativeInstallRequestAuthorizerV1& authorizer_;
  ReadyTokenGenerator ready_token_generator_;
  Sha256Function sha256_;
  Clock now_unix_milliseconds_;
  std::int64_t reservation_lifetime_milliseconds_;
  State state_ = State::kInitial;
  std::unique_ptr<NativeInstallPreparedTransactionV1> transaction_;
  NativeInstallReservationV1 reservation_;
};

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_SESSION_H_
