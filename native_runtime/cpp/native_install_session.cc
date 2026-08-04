#include "native_install_session.h"

#include <limits>
#include <utility>

namespace desktop_updater {
namespace runtime {
namespace internal {

NativeInstallOneShotSessionV1::NativeInstallOneShotSessionV1(
    NativeInstallRequestAuthorizerV1& authorizer,
    ReadyTokenGenerator ready_token_generator,
    Sha256Function sha256,
    Clock now_unix_milliseconds,
    std::int64_t reservation_lifetime_milliseconds)
    : authorizer_(authorizer),
      ready_token_generator_(std::move(ready_token_generator)),
      sha256_(std::move(sha256)),
      now_unix_milliseconds_(std::move(now_unix_milliseconds)),
      reservation_lifetime_milliseconds_(
          reservation_lifetime_milliseconds) {
  if (!ready_token_generator_ || !sha256_ || !now_unix_milliseconds_ ||
      reservation_lifetime_milliseconds_ <= 0) {
    throw NativeInstallSessionError("invalid one-shot session dependencies");
  }
}

NativeInstallOneShotSessionV1::~NativeInstallOneShotSessionV1() {
  if (transaction_ != nullptr &&
      (state_ == State::kPrepared || state_ == State::kCommitAccepted)) {
    try {
      transaction_->CancelPrepared();
    } catch (...) {
    }
  }
}

void NativeInstallOneShotSessionV1::RequireState(State expected) const {
  if (state_ != expected) {
    throw NativeInstallSessionError("invalid one-shot session state");
  }
}

NativeInstallReservationV1 NativeInstallOneShotSessionV1::Prepare(
    const std::string& canonical_request) {
  RequireState(State::kInitial);
  state_ = State::kPreparing;
  bool durable_prepared = false;
  try {
    const NativeInstallTransactionRequestV1 request =
        ParseNativeInstallTransactionRequestV1(canonical_request);
    transaction_ = authorizer_.Authorize(request);
    if (transaction_ == nullptr ||
        transaction_->transaction_id() != request.transaction_id) {
      throw NativeInstallSessionError("authorized transaction binding mismatch");
    }
    const std::string journal = transaction_->PrepareDurableJournal();
    durable_prepared = true;
    const std::string journal_sha256 = sha256_(journal);
    const std::int64_t now = now_unix_milliseconds_();
    if (now < 0 || now > std::numeric_limits<std::int64_t>::max() -
                             reservation_lifetime_milliseconds_) {
      throw NativeInstallSessionError("reservation expiry overflow");
    }
    reservation_ = {
        1,
        request.transaction_id,
        ready_token_generator_(),
        journal_sha256,
        authorizer_.helper_endpoint_identity_sha256(),
        now + reservation_lifetime_milliseconds_,
    };
    (void)EncodeNativeInstallReservationV1(reservation_);
    state_ = State::kPrepared;
    return reservation_;
  } catch (...) {
    if (durable_prepared && transaction_ != nullptr) {
      try {
        transaction_->CancelPrepared();
        state_ = State::kCancelled;
      } catch (...) {
        state_ = State::kRecoveryRequired;
      }
    } else {
      state_ = transaction_ == nullptr ? State::kCancelled
                                       : State::kRecoveryRequired;
    }
    throw;
  }
}

void NativeInstallOneShotSessionV1::RequireBinding(
    const NativeInstallWireCommandV1& command,
    const std::string& operation) const {
  if (command.operation != operation ||
      command.protocol_version != reservation_.protocol_version ||
      command.transaction_id != reservation_.transaction_id ||
      command.ready_token != reservation_.ready_token ||
      command.journal_sha256 != reservation_.journal_sha256 ||
      command.helper_endpoint_identity_sha256 !=
          reservation_.helper_endpoint_identity_sha256) {
    throw NativeInstallSessionError("reservation binding mismatch");
  }
}

NativeInstallReservationV1 NativeInstallOneShotSessionV1::AcceptCommit(
    const std::string& canonical_command) {
  RequireState(State::kPrepared);
  const NativeInstallWireCommandV1 command =
      ParseNativeInstallWireCommandV1(canonical_command);
  RequireBinding(command, "commitAfterExit");
  if (now_unix_milliseconds_() >
      reservation_.expires_at_unix_milliseconds) {
    (void)CancelPreparedState(State::kPrepared);
    throw NativeInstallSessionError("reservation expired before commit");
  }
  transaction_->MarkCommitAccepted();
  state_ = State::kCommitAccepted;
  return reservation_;
}

NativeInstallTransactionStatusV1
NativeInstallOneShotSessionV1::ExecuteAfterCallerExit() {
  RequireState(State::kCommitAccepted);
  state_ = State::kExecuting;
  try {
    transaction_->ExecuteAfterCallerExit();
    state_ = State::kCompleted;
    return {1, reservation_.transaction_id, "completed", "completed",
            reservation_.journal_sha256};
  } catch (...) {
    state_ = State::kRecoveryRequired;
    throw;
  }
}

NativeInstallRecoveryResultV1 NativeInstallOneShotSessionV1::Cancel(
    const std::string& canonical_command) {
  RequireState(State::kPrepared);
  const NativeInstallWireCommandV1 command =
      ParseNativeInstallWireCommandV1(canonical_command);
  RequireBinding(command, "cancelReservation");
  return CancelPreparedState(State::kPrepared);
}

NativeInstallRecoveryResultV1
NativeInstallOneShotSessionV1::CancelBeforeCommitOnCallerExit() {
  return CancelPreparedState(State::kPrepared);
}

NativeInstallRecoveryResultV1
NativeInstallOneShotSessionV1::CancelCommitAwaitingCallerExit() {
  return CancelPreparedState(State::kCommitAccepted);
}

NativeInstallRecoveryResultV1
NativeInstallOneShotSessionV1::CancelPreparedState(State expected) {
  RequireState(expected);
  state_ = State::kCancelling;
  try {
    transaction_->CancelPrepared();
    state_ = State::kCancelled;
    return {1, reservation_.transaction_id, "rolledBack", "oldTarget",
            reservation_.journal_sha256};
  } catch (...) {
    state_ = State::kRecoveryRequired;
    throw;
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
