#include "named_pipe_transport.h"

#include <sddl.h>
#include <shellapi.h>

#include <chrono>
#include <limits>
#include <memory>
#include <mutex>
#include <set>
#include <utility>
#include <vector>

#include "native_install_request.h"
#include "native_install_wire.h"
#include "windows_one_shot_transport.h"

namespace desktop_updater::helper {
namespace {

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle = INVALID_HANDLE_VALUE)
      : handle_(handle) {}
  ~ScopedHandle() { Reset(); }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
  ScopedHandle(ScopedHandle&& other) noexcept : handle_(other.release()) {}
  ScopedHandle& operator=(ScopedHandle&& other) noexcept {
    if (this != &other) Reset(other.release());
    return *this;
  }
  HANDLE get() const { return handle_; }
  HANDLE release() {
    HANDLE result = handle_;
    handle_ = INVALID_HANDLE_VALUE;
    return result;
  }
  void Reset(HANDLE value = INVALID_HANDLE_VALUE) {
    if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(handle_);
    }
    handle_ = value;
  }

 private:
  HANDLE handle_;
};

bool IsNonce(const std::string& nonce) {
  if (nonce.size() != 43) return false;
  for (unsigned char character : nonce) {
    if (!(character >= 'A' && character <= 'Z') &&
        !(character >= 'a' && character <= 'z') &&
        !(character >= '0' && character <= '9') && character != '-' &&
        character != '_') {
      return false;
    }
  }
  return true;
}

std::wstring AsciiToWide(const std::string& value) {
  return std::wstring(value.begin(), value.end());
}

std::wstring CurrentUserSid() {
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
    throw NamedPipeTransportError("OpenProcessToken failed");
  }
  ScopedHandle token(raw_token);
  DWORD size = 0;
  GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
  if (size == 0) throw NamedPipeTransportError("TokenUser size failed");
  std::vector<unsigned char> bytes(size);
  if (!GetTokenInformation(token.get(), TokenUser, bytes.data(), size, &size)) {
    throw NamedPipeTransportError("TokenUser failed");
  }
  const auto* user = reinterpret_cast<const TOKEN_USER*>(bytes.data());
  LPWSTR sid_text = nullptr;
  if (!ConvertSidToStringSidW(user->User.Sid, &sid_text)) {
    throw NamedPipeTransportError("caller SID conversion failed");
  }
  std::wstring result(sid_text);
  LocalFree(sid_text);
  return result;
}

std::wstring ProcessUserSid(HANDLE process) {
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &raw_token)) {
    throw NamedPipeTransportError("peer OpenProcessToken failed");
  }
  ScopedHandle token(raw_token);
  DWORD size = 0;
  GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
  if (size == 0) throw NamedPipeTransportError("peer TokenUser size failed");
  std::vector<unsigned char> bytes(size);
  if (!GetTokenInformation(token.get(), TokenUser, bytes.data(), size, &size)) {
    throw NamedPipeTransportError("peer TokenUser failed");
  }
  const auto* user = reinterpret_cast<const TOKEN_USER*>(bytes.data());
  LPWSTR sid_text = nullptr;
  if (!ConvertSidToStringSidW(user->User.Sid, &sid_text)) {
    throw NamedPipeTransportError("peer SID conversion failed");
  }
  std::wstring result(sid_text);
  LocalFree(sid_text);
  return result;
}

ScopedHandle CreateCallerPipe(const std::wstring& pipe_name,
                              const std::wstring& caller_sid) {
  // The caller and its UAC-elevated helper retain the same user SID. Grant
  // only that identity and SYSTEM; never grant the broad Administrators SID.
  const std::wstring sddl = L"D:P(A;;GA;;;" + caller_sid +
                            L")(A;;GA;;;SY)";
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl.c_str(), SDDL_REVISION_1, &raw_descriptor, nullptr)) {
    throw NamedPipeTransportError("pipe DACL conversion failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = descriptor.get();
  attributes.bInheritHandle = FALSE;
  HANDLE pipe = CreateNamedPipeW(
      pipe_name.c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      1, 4096, 4096, 0, &attributes);
  if (pipe == INVALID_HANDLE_VALUE) {
    throw NamedPipeTransportError("exclusive caller pipe creation failed");
  }
  return ScopedHandle(pipe);
}

bool ConnectWithTimeout(HANDLE pipe, DWORD timeout_millis) {
  ScopedHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (event.get() == nullptr) return false;
  OVERLAPPED overlapped{};
  overlapped.hEvent = event.get();
  if (ConnectNamedPipe(pipe, &overlapped)) return true;
  const DWORD error = GetLastError();
  if (error == ERROR_PIPE_CONNECTED) return true;
  if (error != ERROR_IO_PENDING) return false;
  const DWORD wait = WaitForSingleObject(event.get(), timeout_millis);
  if (wait != WAIT_OBJECT_0) {
    CancelIoEx(pipe, &overlapped);
    return false;
  }
  DWORD transferred = 0;
  return GetOverlappedResult(pipe, &overlapped, &transferred, FALSE) != FALSE;
}

void ConsumeNonceOnce(const std::string& nonce) {
  static std::mutex mutex;
  static std::set<std::string> consumed;
  std::lock_guard<std::mutex> lock(mutex);
  const bool nonceReuse = !consumed.insert(nonce).second;
  if (nonceReuse) {
    throw NamedPipeTransportError("nonce reuse rejected");
  }
}

std::int64_t NowUnixMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

}  // namespace

std::wstring DerivePipeName(const std::string& nonce) {
  if (!IsNonce(nonce)) {
    throw NamedPipeTransportError("nonce must be 32-byte base64url");
  }
  return L"\\\\.\\pipe\\desktop-updater-" + AsciiToWide(nonce);
}

void ValidatePeerBinding(const PeerBinding& binding,
                         DWORD observed_process_id,
                         const std::wstring& observed_user_sid,
                         const std::string& observed_nonce) {
  if (binding.process_id != observed_process_id ||
      binding.user_sid != observed_user_sid ||
      binding.nonce != observed_nonce) {
    throw NamedPipeTransportError("named-pipe peer binding mismatch");
  }
}

ElevationLaunchResult ClassifyElevationResult(DWORD error,
                                              bool wait_timed_out) {
  if (wait_timed_out || error == WAIT_TIMEOUT) {
    return ElevationLaunchResult::kTimedOut;
  }
  if (error == ERROR_CANCELLED) return ElevationLaunchResult::kCancelled;
  return error == ERROR_SUCCESS ? ElevationLaunchResult::kLaunched
                                : ElevationLaunchResult::kFailed;
}

struct WindowsElevatedHelperClientSession::Impl {
  enum class State {
    kPrepared,
    kCommitAccepted,
    kCancelled,
  };

  Impl(ScopedHandle pipe_value,
       ScopedHandle helper_process_value,
       std::filesystem::path helper_path_value,
       VerifiedWindowsExecutable helper_identity_value,
       desktop_updater::runtime::internal::NativeInstallReservationV1
           reservation_value,
       std::int64_t startup_deadline_unix_milliseconds)
      : pipe(std::move(pipe_value)),
        helper_process(std::move(helper_process_value)),
        helper_path(std::move(helper_path_value)),
        helper_identity(std::move(helper_identity_value)),
        reservation(std::move(reservation_value)),
        channel(pipe.get(), helper_process.get(),
                startup_deadline_unix_milliseconds) {}

  ScopedHandle pipe;
  ScopedHandle helper_process;
  std::filesystem::path helper_path;
  VerifiedWindowsExecutable helper_identity;
  desktop_updater::runtime::internal::NativeInstallReservationV1 reservation;
  WindowsOneShotPipeChannel channel;
  State state = State::kPrepared;
};

WindowsElevatedHelperClientSession::WindowsElevatedHelperClientSession(
    std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

WindowsElevatedHelperClientSession::~WindowsElevatedHelperClientSession() {
  if (impl_ != nullptr && impl_->state == Impl::State::kPrepared) {
    try {
      (void)CancelReservation();
    } catch (...) {
    }
  }
}

const desktop_updater::runtime::internal::NativeInstallReservationV1&
WindowsElevatedHelperClientSession::reservation() const {
  if (impl_ == nullptr) {
    throw NamedPipeTransportError("elevated helper session is unavailable");
  }
  return impl_->reservation;
}

desktop_updater::runtime::internal::NativeInstallReservationV1
WindowsElevatedHelperClientSession::CommitAfterExit() {
  using desktop_updater::runtime::internal::EncodeNativeInstallWireCommandV1;
  using desktop_updater::runtime::internal::NativeInstallWireCommandV1;
  using desktop_updater::runtime::internal::ParseNativeInstallReservationV1;
  if (impl_ == nullptr || impl_->state != Impl::State::kPrepared) {
    throw NamedPipeTransportError("elevated helper session is not prepared");
  }
  const auto& reservation = impl_->reservation;
  const NativeInstallWireCommandV1 command{
      "commitAfterExit",
      reservation.protocol_version,
      reservation.transaction_id,
      reservation.ready_token,
      reservation.journal_sha256,
      reservation.helper_endpoint_identity_sha256};
  impl_->channel.WriteFrame(EncodeNativeInstallWireCommandV1(command));
  const auto acknowledged = ParseNativeInstallReservationV1(
      impl_->channel.ReadFrameUntil(
          reservation.expires_at_unix_milliseconds));
  if (!(acknowledged == reservation) ||
      !VerifyWindowsExecutableStillMatches(impl_->helper_path,
                                           impl_->helper_identity)) {
    throw NamedPipeTransportError(
        "helper commit acknowledgement binding changed");
  }
  impl_->state = Impl::State::kCommitAccepted;
  return acknowledged;
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
WindowsElevatedHelperClientSession::CancelReservation() {
  using desktop_updater::runtime::internal::EncodeNativeInstallWireCommandV1;
  using desktop_updater::runtime::internal::NativeInstallWireCommandV1;
  using desktop_updater::runtime::internal::ParseNativeInstallRecoveryResultV1;
  if (impl_ == nullptr || impl_->state != Impl::State::kPrepared) {
    throw NamedPipeTransportError("elevated helper session is not prepared");
  }
  const auto& reservation = impl_->reservation;
  const NativeInstallWireCommandV1 command{
      "cancelReservation",
      reservation.protocol_version,
      reservation.transaction_id,
      reservation.ready_token,
      reservation.journal_sha256,
      reservation.helper_endpoint_identity_sha256};
  impl_->channel.WriteFrame(EncodeNativeInstallWireCommandV1(command));
  const auto result = ParseNativeInstallRecoveryResultV1(
      impl_->channel.ReadFrameUntil(
          reservation.expires_at_unix_milliseconds));
  if (result.transaction_id != reservation.transaction_id ||
      result.journal_sha256 != reservation.journal_sha256 ||
      result.result_code != "rolledBack" ||
      result.verified_outcome != "oldTarget" ||
      !VerifyWindowsExecutableStillMatches(impl_->helper_path,
                                           impl_->helper_identity)) {
    throw NamedPipeTransportError("helper cancellation binding changed");
  }
  impl_->state = Impl::State::kCancelled;
  return result;
}

WindowsElevatedHelperLaunch LaunchAuthenticatedElevatedHelper(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const std::string& nonce,
    const std::string& canonical_request,
    DWORD timeout_millis) {
  using desktop_updater::runtime::internal::ParseNativeInstallTransactionRequestV1;
  const auto request =
      ParseNativeInstallTransactionRequestV1(canonical_request);
  if (request.request_nonce != nonce || request.policy_id != policy.policy_id() ||
      request.package_id != policy.application_package_id() ||
      !policy.AllowsRequest(request.protocol_version,
                            request.target.target_class, request.strategy,
                            request.provider)) {
    throw NamedPipeTransportError(
        "canonical request is not bound to sealed helper policy");
  }
  ConsumeNonceOnce(nonce);
  const VerifiedWindowsExecutable identity =
      VerifyWindowsExecutable(fixed_helper_path);
  ValidateWindowsHelperIdentity(identity, policy, true);
  const std::wstring pipe_name = DerivePipeName(nonce);
  const std::wstring caller_sid = CurrentUserSid();
  ScopedHandle pipe = CreateCallerPipe(pipe_name, caller_sid);

  const std::wstring parameters =
      L"--pipe \"" + pipe_name + L"\" --nonce " + AsciiToWide(nonce);
  SHELLEXECUTEINFOW launch{};
  launch.cbSize = sizeof(launch);
  launch.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
  launch.lpVerb = L"runas";
  launch.lpFile = fixed_helper_path.c_str();
  launch.lpParameters = parameters.c_str();
  launch.nShow = SW_HIDE;
  if (!ShellExecuteExW(&launch)) {
    return {ClassifyElevationResult(GetLastError(), false), nullptr};
  }
  ScopedHandle helper_process(launch.hProcess);
  if (!ConnectWithTimeout(pipe.get(), timeout_millis)) {
    return {ElevationLaunchResult::kTimedOut, nullptr};
  }

  ULONG peer_pid = 0;
  if (!GetNamedPipeClientProcessId(pipe.get(), &peer_pid) ||
      peer_pid != GetProcessId(helper_process.get())) {
    throw NamedPipeTransportError("pipe client is not launched helper");
  }
  ScopedHandle peer_process(OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, peer_pid));
  if (peer_process.get() == nullptr) {
    throw NamedPipeTransportError("cannot retain helper process");
  }
  const PeerBinding expected{peer_pid, caller_sid, nonce};
  ValidatePeerBinding(expected, peer_pid, ProcessUserSid(peer_process.get()),
                      nonce);

  const std::int64_t now = NowUnixMilliseconds();
  if (timeout_millis == 0 ||
      now > std::numeric_limits<std::int64_t>::max() - timeout_millis) {
    throw NamedPipeTransportError("helper startup deadline overflow");
  }
  const std::int64_t deadline = now + timeout_millis;
  WindowsOneShotPipeChannel channel(pipe.get(), helper_process.get(), deadline);
  channel.WriteFrame(canonical_request);
  const auto reservation =
      desktop_updater::runtime::internal::ParseNativeInstallReservationV1(
          channel.ReadFrameUntil(deadline));
  if (reservation.transaction_id != request.transaction_id ||
      reservation.helper_endpoint_identity_sha256 != identity.sha256 ||
      reservation.helper_endpoint_identity_sha256 != policy.helper_sha256() ||
      reservation.expires_at_unix_milliseconds <= NowUnixMilliseconds() ||
      !VerifyWindowsExecutableStillMatches(fixed_helper_path, identity)) {
    throw NamedPipeTransportError("helper reservation binding changed");
  }
  auto impl = std::make_unique<WindowsElevatedHelperClientSession::Impl>(
      std::move(pipe), std::move(helper_process), fixed_helper_path, identity,
      reservation, deadline);
  return {ElevationLaunchResult::kLaunched,
          std::unique_ptr<WindowsElevatedHelperClientSession>(
              new WindowsElevatedHelperClientSession(std::move(impl)))};
}

int ConnectElevatedHelperToCallerPipe(const std::wstring& pipe_name,
                                      const std::string& nonce,
                                      DWORD timeout_millis,
                                      const WindowsElevatedPipeSessionRunner&
                                          session_runner) {
  if (!session_runner) {
    throw NamedPipeTransportError("one-shot session runner is required");
  }
  if (pipe_name != DerivePipeName(nonce)) {
    throw NamedPipeTransportError("pipe locator is not nonce-derived");
  }
  if (!WaitNamedPipeW(pipe_name.c_str(), timeout_millis)) {
    return static_cast<int>(WAIT_TIMEOUT);
  }
  ScopedHandle pipe(CreateFileW(
      pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, nullptr));
  if (pipe.get() == INVALID_HANDLE_VALUE) {
    throw NamedPipeTransportError("helper cannot connect to caller pipe");
  }
  ULONG server_pid = 0;
  if (!GetNamedPipeServerProcessId(pipe.get(), &server_pid)) {
    throw NamedPipeTransportError("pipe server PID unavailable");
  }
  ScopedHandle caller_process(OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, server_pid));
  if (caller_process.get() == nullptr ||
      ProcessUserSid(caller_process.get()).empty()) {
    throw NamedPipeTransportError("caller process/token validation failed");
  }
  session_runner(pipe.get(), server_pid);
  return ERROR_SUCCESS;
}

}  // namespace desktop_updater::helper
