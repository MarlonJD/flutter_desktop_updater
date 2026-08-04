#include <gtest/gtest.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "native_install_request.h"
#include "native_install_service_runtime.h"
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
  request.transaction_id = "00000000-0000-4000-8000-000000000019";
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
  request.caller = {4242, "windows:123", std::string(64, 'a'),
                    "com.example.app", "Example Publisher"};
  request.request_nonce =
      "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA";
  request.diagnostics_destination = {true, "platformLog", {}};
  return request;
}

struct RuntimeState {
  bool prepared = false;
  bool commit_marked = false;
  bool waited = false;
  bool executed = false;
  bool cancelled = false;
  std::int64_t monitored_process_id = 0;
  std::string monitored_process_start_identity;
  std::string monitored_executable_sha256;
  std::string monitored_package_id;
  std::string monitored_signer_identity;
};

class RuntimeTransaction final : public NativeInstallPreparedTransactionV1 {
 public:
  RuntimeTransaction(std::string transaction_id,
                     std::shared_ptr<RuntimeState> state)
      : transaction_id_(std::move(transaction_id)),
        state_(std::move(state)) {}

  const std::string& transaction_id() const override {
    return transaction_id_;
  }
  std::string PrepareDurableJournal() override {
    state_->prepared = true;
    return "canonical-journal";
  }
  void MarkCommitAccepted() override { state_->commit_marked = true; }
  void ExecuteAfterCallerExit() override {
    if (!state_->waited) {
      throw std::runtime_error("mutation preceded caller exit");
    }
    state_->executed = true;
  }
  void CancelPrepared() override { state_->cancelled = true; }

 private:
  std::string transaction_id_;
  std::shared_ptr<RuntimeState> state_;
};

class RuntimeAuthorizer final : public NativeInstallRequestAuthorizerV1 {
 public:
  explicit RuntimeAuthorizer(std::shared_ptr<RuntimeState> state)
      : state_(std::move(state)) {}

  const std::string& helper_endpoint_identity_sha256() const override {
    return endpoint_;
  }
  std::unique_ptr<NativeInstallPreparedTransactionV1> Authorize(
      const NativeInstallTransactionRequestV1& request) override {
    return std::make_unique<RuntimeTransaction>(request.transaction_id,
                                                state_);
  }

 private:
  std::shared_ptr<RuntimeState> state_;
  std::string endpoint_ = std::string(64, 'b');
};

class RuntimeMonitor final : public NativeInstallCallerExitMonitorV1 {
 public:
  RuntimeMonitor(std::shared_ptr<RuntimeState> state,
                 std::function<void(std::int64_t)> wait)
      : state_(std::move(state)), wait_(std::move(wait)) {}

  void WaitForExit(std::int64_t expires_at_unix_milliseconds) override {
    wait_(expires_at_unix_milliseconds);
    state_->waited = true;
  }

 private:
  std::shared_ptr<RuntimeState> state_;
  std::function<void(std::int64_t)> wait_;
};

class RuntimeMonitorFactory final
    : public NativeInstallCallerExitMonitorFactoryV1 {
 public:
  RuntimeMonitorFactory(std::shared_ptr<RuntimeState> state,
                        std::function<void(std::int64_t)> wait)
      : state_(std::move(state)), wait_(std::move(wait)) {}

  std::unique_ptr<NativeInstallCallerExitMonitorV1> Create(
      const NativeInstallCallerV1& caller) override {
    state_->monitored_process_id = caller.process_id;
    state_->monitored_process_start_identity =
        caller.process_start_identity;
    state_->monitored_executable_sha256 = caller.executable_sha256;
    state_->monitored_package_id = caller.package_id;
    state_->monitored_signer_identity = caller.signer_identity;
    return std::make_unique<RuntimeMonitor>(state_, wait_);
  }

 private:
  std::shared_ptr<RuntimeState> state_;
  std::function<void(std::int64_t)> wait_;
};

class RuntimeChannel final : public NativeInstallWireChannelV1 {
 public:
  RuntimeChannel(std::string request, std::string operation)
      : request_(std::move(request)), operation_(std::move(operation)) {}

  std::string ReadFrame() override {
    if (read_count_++ != 0) throw std::runtime_error("unexpected read");
    return request_;
  }

  std::string ReadFrameUntil(
      std::int64_t expires_at_unix_milliseconds) override {
    command_deadline_ = expires_at_unix_milliseconds;
    if (outputs.size() != 1) {
      throw std::runtime_error("command read preceded reservation ACK");
    }
    const NativeInstallReservationV1 reservation =
        ParseNativeInstallReservationV1(outputs.front());
    return EncodeNativeInstallWireCommandV1(
        {operation_, 1, reservation.transaction_id, reservation.ready_token,
         reservation.journal_sha256,
         reservation.helper_endpoint_identity_sha256});
  }

  void WriteFrame(const std::string& canonical_frame) override {
    outputs.push_back(canonical_frame);
  }

  std::vector<std::string> outputs;
  std::int64_t command_deadline() const { return command_deadline_; }
  int read_count() const { return read_count_; }

 private:
  std::string request_;
  std::string operation_;
  int read_count_ = 0;
  std::int64_t command_deadline_ = 0;
};

NativeInstallOneShotSessionV1 Session(RuntimeAuthorizer& authorizer) {
  return NativeInstallOneShotSessionV1(
      authorizer, [] { return std::string(43, 'A'); },
      [](const std::string&) { return std::string(64, 'a'); },
      [] { return std::int64_t{1000}; }, 300000);
}

TEST(native_install_service_runtime,
     AcknowledgesCommitBeforeWaitingAndMutating) {
  auto state = std::make_shared<RuntimeState>();
  RuntimeAuthorizer authorizer(state);
  auto session = Session(authorizer);
  RuntimeChannel channel(
      EncodeCanonicalNativeInstallTransactionRequestV1(Request()),
      "commitAfterExit");
  RuntimeMonitorFactory monitor_factory(
      state, [&](std::int64_t deadline) {
        EXPECT_EQ(301000, deadline);
        ASSERT_EQ(2U, channel.outputs.size());
        EXPECT_EQ(channel.outputs[0], channel.outputs[1]);
        EXPECT_FALSE(state->executed);
      });

  NativeInstallOneShotServiceRuntimeV1 runtime(session, monitor_factory);
  runtime.Run(channel);

  EXPECT_EQ(4242, state->monitored_process_id);
  EXPECT_EQ("windows:123", state->monitored_process_start_identity);
  EXPECT_EQ(std::string(64, 'a'), state->monitored_executable_sha256);
  EXPECT_EQ("com.example.app", state->monitored_package_id);
  EXPECT_EQ("Example Publisher", state->monitored_signer_identity);
  EXPECT_EQ(301000, channel.command_deadline());
  EXPECT_TRUE(state->prepared);
  EXPECT_TRUE(state->commit_marked);
  EXPECT_TRUE(state->waited);
  EXPECT_TRUE(state->executed);
  EXPECT_FALSE(state->cancelled);
}

TEST(native_install_service_runtime,
     CancelsCommitWhenCallerExitWaitFails) {
  auto state = std::make_shared<RuntimeState>();
  RuntimeAuthorizer authorizer(state);
  auto session = Session(authorizer);
  RuntimeChannel channel(
      EncodeCanonicalNativeInstallTransactionRequestV1(Request()),
      "commitAfterExit");
  RuntimeMonitorFactory monitor_factory(
      state, [](std::int64_t) { throw std::runtime_error("timed out"); });
  NativeInstallOneShotServiceRuntimeV1 runtime(session, monitor_factory);

  EXPECT_THROW(runtime.Run(channel), std::runtime_error);
  EXPECT_TRUE(state->prepared);
  EXPECT_TRUE(state->cancelled);
  EXPECT_FALSE(state->executed);
}

TEST(native_install_service_runtime,
     ReturnsCanonicalRecoveryForCancellation) {
  auto state = std::make_shared<RuntimeState>();
  RuntimeAuthorizer authorizer(state);
  auto session = Session(authorizer);
  RuntimeChannel channel(
      EncodeCanonicalNativeInstallTransactionRequestV1(Request()),
      "cancelReservation");
  RuntimeMonitorFactory monitor_factory(state, [](std::int64_t) {});
  NativeInstallOneShotServiceRuntimeV1 runtime(session, monitor_factory);

  runtime.Run(channel);

  ASSERT_EQ(2U, channel.outputs.size());
  const NativeInstallRecoveryResultV1 result =
      ParseNativeInstallRecoveryResultV1(channel.outputs[1]);
  EXPECT_EQ("rolledBack", result.result_code);
  EXPECT_EQ("oldTarget", result.verified_outcome);
  EXPECT_TRUE(state->cancelled);
  EXPECT_FALSE(state->waited);
  EXPECT_FALSE(state->executed);
}

TEST(native_install_service_runtime,
     DispatchesAnAlreadyAuthenticatedInitialRequestWithoutRereading) {
  auto state = std::make_shared<RuntimeState>();
  RuntimeAuthorizer authorizer(state);
  auto session = Session(authorizer);
  RuntimeChannel channel("must-not-be-read", "cancelReservation");
  RuntimeMonitorFactory monitor_factory(state, [](std::int64_t) {});
  NativeInstallOneShotServiceRuntimeV1 runtime(session, monitor_factory);

  runtime.RunWithInitialRequest(
      channel, EncodeCanonicalNativeInstallTransactionRequestV1(Request()));

  EXPECT_EQ(0, channel.read_count());
  ASSERT_EQ(2U, channel.outputs.size());
  EXPECT_EQ(
      "rolledBack",
      ParseNativeInstallRecoveryResultV1(channel.outputs[1]).result_code);
}

}  // namespace
}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
