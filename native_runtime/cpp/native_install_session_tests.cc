#include <gtest/gtest.h>

#include <memory>
#include <string>

#include "native_install_request.h"
#include "native_install_session.h"
#include "native_install_wire.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

NativeInstallTransactionRequestV1 Request() {
  NativeInstallTransactionRequestV1 request;
  request.schema_version = 1;
  request.protocol_version = 1;
  request.transaction_id = "00000000-0000-4000-8000-000000000009";
  request.policy_id = "com.example.desktop-updater";
  request.package_id = "com.example.app";
  request.strategy = "directoryReplace";
  request.provider = "platformDirectory";
  request.target = {"applicationDirectory", "/opt/example", "example",
                    "bin/example", std::string(64, 'a')};
  request.current_identity = {"2.7.0", 270, std::string(64, 'b')};
  request.desired_identity = {"2.8.0", 280, std::string(64, 'c')};
  request.stage = {"/tmp/stage", std::string(64, 'd'),
                   std::string(64, 'e'), std::string(64, 'f'), 1234};
  request.signed_descriptor = {
      std::string(64, 'c'), "ed25519", "stable-2026",
      std::string(86, 'A') + "=="};
  request.caller = {4242, "linux:123", std::string(64, 'a'),
                    "com.example.app", "Example Publisher"};
  request.request_nonce =
      "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA";
  request.diagnostics_destination = {true, "platformLog", {}};
  return request;
}

struct TransactionState {
  bool prepared = false;
  bool executed = false;
  bool cancelled = false;
};

class FakeTransaction final : public NativeInstallPreparedTransactionV1 {
 public:
  FakeTransaction(std::string transaction_id,
                  std::shared_ptr<TransactionState> state)
      : transaction_id_(std::move(transaction_id)),
        state_(std::move(state)) {}

  const std::string& transaction_id() const override {
    return transaction_id_;
  }
  std::string PrepareDurableJournal() override {
    state_->prepared = true;
    return "canonical-journal";
  }
  void ExecuteAfterCallerExit() override { state_->executed = true; }
  void CancelPrepared() override { state_->cancelled = true; }

 private:
  std::string transaction_id_;
  std::shared_ptr<TransactionState> state_;
};

class FakeAuthorizer final : public NativeInstallRequestAuthorizerV1 {
 public:
  explicit FakeAuthorizer(std::shared_ptr<TransactionState> state)
      : state_(std::move(state)) {}

  const std::string& helper_endpoint_identity_sha256() const override {
    return endpoint_;
  }
  std::unique_ptr<NativeInstallPreparedTransactionV1> Authorize(
      const NativeInstallTransactionRequestV1& request) override {
    return std::make_unique<FakeTransaction>(request.transaction_id, state_);
  }

 private:
  std::shared_ptr<TransactionState> state_;
  std::string endpoint_ = std::string(64, 'b');
};

NativeInstallWireCommandV1 Command(
    const NativeInstallReservationV1& reservation,
    const std::string& operation) {
  return {operation,
          1,
          reservation.transaction_id,
          reservation.ready_token,
          reservation.journal_sha256,
          reservation.helper_endpoint_identity_sha256};
}

TEST(native_install_session, MutatesOnlyAfterBoundCommitAndCallerExit) {
  auto state = std::make_shared<TransactionState>();
  FakeAuthorizer authorizer(state);
  NativeInstallOneShotSessionV1 session(
      authorizer,
      [] { return std::string(43, 'A'); },
      [](const std::string&) { return std::string(64, 'a'); },
      [] { return std::int64_t{1000}; }, 300000);

  const NativeInstallReservationV1 reservation = session.Prepare(
      EncodeCanonicalNativeInstallTransactionRequestV1(Request()));
  EXPECT_TRUE(state->prepared);
  EXPECT_FALSE(state->executed);
  EXPECT_EQ(std::string(64, 'a'), reservation.journal_sha256);

  EXPECT_EQ(reservation,
            session.AcceptCommit(EncodeNativeInstallWireCommandV1(
                Command(reservation, "commitAfterExit"))));
  EXPECT_FALSE(state->executed);
  const NativeInstallTransactionStatusV1 completed =
      session.ExecuteAfterCallerExit();
  EXPECT_TRUE(state->executed);
  EXPECT_EQ("completed", completed.state);
  EXPECT_EQ("completed", completed.result_code);
}

TEST(native_install_session, WrongBindingAndEarlyCallerExitNeverMutate) {
  auto state = std::make_shared<TransactionState>();
  FakeAuthorizer authorizer(state);
  NativeInstallOneShotSessionV1 session(
      authorizer,
      [] { return std::string(43, 'A'); },
      [](const std::string&) { return std::string(64, 'a'); },
      [] { return std::int64_t{1000}; }, 300000);
  const auto reservation = session.Prepare(
      EncodeCanonicalNativeInstallTransactionRequestV1(Request()));
  auto wrong = Command(reservation, "commitAfterExit");
  wrong.journal_sha256 = std::string(64, 'f');
  EXPECT_THROW(session.AcceptCommit(
                   EncodeNativeInstallWireCommandV1(wrong)),
               NativeInstallSessionError);
  EXPECT_FALSE(state->executed);
  EXPECT_FALSE(state->cancelled);

  const auto cancelled = session.CancelBeforeCommitOnCallerExit();
  EXPECT_TRUE(state->cancelled);
  EXPECT_EQ("rolledBack", cancelled.result_code);
  EXPECT_EQ("oldTarget", cancelled.verified_outcome);
}

TEST(native_install_session, ExpiredCommitCancelsPreparedState) {
  auto state = std::make_shared<TransactionState>();
  FakeAuthorizer authorizer(state);
  std::int64_t now = 1000;
  NativeInstallOneShotSessionV1 session(
      authorizer,
      [] { return std::string(43, 'A'); },
      [](const std::string&) { return std::string(64, 'a'); },
      [&] { return now; }, 10);
  const auto reservation = session.Prepare(
      EncodeCanonicalNativeInstallTransactionRequestV1(Request()));
  now = 1011;
  EXPECT_THROW(session.AcceptCommit(EncodeNativeInstallWireCommandV1(
                   Command(reservation, "commitAfterExit"))),
               NativeInstallSessionError);
  EXPECT_TRUE(state->cancelled);
  EXPECT_FALSE(state->executed);
}

}  // namespace
}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
