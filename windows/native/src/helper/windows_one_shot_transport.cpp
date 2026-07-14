#include "windows_one_shot_transport.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <filesystem>
#include <iomanip>
#include <limits>
#include <sstream>
#include <utility>
#include <vector>

#include "windows_transaction_journal.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::NativeInstallCallerExitMonitorV1;
using desktop_updater::runtime::internal::NativeInstallCallerV1;
using desktop_updater::runtime::internal::NativeInstallOneShotServiceRuntimeV1;
using desktop_updater::runtime::internal::NativeInstallOneShotSessionV1;

std::int64_t NowUnixMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

DWORD RemainingMilliseconds(std::int64_t deadline_unix_milliseconds) {
  const std::int64_t now = NowUnixMilliseconds();
  if (deadline_unix_milliseconds <= now) {
    throw WindowsOneShotTransportError("one-shot pipe deadline expired");
  }
  const std::int64_t remaining = deadline_unix_milliseconds - now;
  return static_cast<DWORD>(std::min<std::int64_t>(
      remaining, static_cast<std::int64_t>(MAXDWORD - 1)));
}

std::uint64_t ProcessStartIdentity(HANDLE process) {
  FILETIME creation{};
  FILETIME exit{};
  FILETIME kernel{};
  FILETIME user{};
  if (!GetProcessTimes(process, &creation, &exit, &kernel, &user)) {
    throw WindowsOneShotTransportError(
        "caller process start identity unavailable");
  }
  return (static_cast<std::uint64_t>(creation.dwHighDateTime) << 32) |
         creation.dwLowDateTime;
}

std::filesystem::path ProcessExecutablePath(HANDLE process) {
  std::vector<wchar_t> buffer(32768);
  DWORD length = static_cast<DWORD>(buffer.size());
  if (!QueryFullProcessImageNameW(process, 0, buffer.data(), &length) ||
      length == 0 || length >= buffer.size()) {
    throw WindowsOneShotTransportError(
        "caller executable path unavailable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty() ||
      value.size() > static_cast<std::size_t>(
                         std::numeric_limits<int>::max())) {
    throw WindowsOneShotTransportError("invalid caller publisher UTF-8");
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    throw WindowsOneShotTransportError("invalid caller publisher UTF-8");
  }
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    throw WindowsOneShotTransportError(
        "caller publisher UTF-8 conversion failed");
  }
  return result;
}

ObservedWindowsCallerIdentity ObserveCaller(DWORD process_id,
                                            HANDLE process) {
  const std::filesystem::path executable_path =
      ProcessExecutablePath(process);
  const VerifiedWindowsExecutable executable =
      VerifyWindowsExecutable(executable_path);
  if (!VerifyWindowsExecutableStillMatches(executable_path, executable)) {
    throw WindowsOneShotTransportError(
        "caller executable changed during verification");
  }
  return {process_id, ProcessStartIdentity(process), executable};
}

class WindowsCallerExitMonitor final
    : public NativeInstallCallerExitMonitorV1 {
 public:
  WindowsCallerExitMonitor(UniqueWindowsHandle process,
                           std::filesystem::path executable_path,
                           VerifiedWindowsExecutable executable)
      : process_(std::move(process)),
        executable_path_(std::move(executable_path)),
        executable_(std::move(executable)) {}

  void WaitForExit(std::int64_t expires_at_unix_milliseconds) override {
    if (!VerifyWindowsExecutableStillMatches(executable_path_, executable_)) {
      throw WindowsOneShotTransportError(
          "caller executable changed before commit exit");
    }
    const DWORD wait = WaitForSingleObject(
        process_.get(), RemainingMilliseconds(expires_at_unix_milliseconds));
    if (wait != WAIT_OBJECT_0) {
      throw WindowsOneShotTransportError(
          wait == WAIT_TIMEOUT ? "caller exit timed out"
                               : "caller exit wait failed");
    }
  }

 private:
  UniqueWindowsHandle process_;
  std::filesystem::path executable_path_;
  VerifiedWindowsExecutable executable_;
};

}  // namespace

std::string WindowsProcessStartIdentityString(std::uint64_t identity) {
  std::ostringstream encoded;
  encoded << "windows:" << std::hex << std::nouppercase << std::setfill('0')
          << std::setw(16) << identity;
  return encoded.str();
}

void ValidateWindowsOneShotFrameLength(std::uint32_t length) {
  if (length == 0 || length > kMaximumWindowsOneShotFrameLength) {
    throw WindowsOneShotTransportError("invalid one-shot pipe frame length");
  }
}

void ValidateWindowsCallerIdentity(
    const NativeInstallCallerV1& caller,
    const ObservedWindowsCallerIdentity& observed,
    const WindowsHelperPolicy& policy) {
  if (caller.process_id <= 0 ||
      static_cast<std::uint64_t>(caller.process_id) >
          std::numeric_limits<DWORD>::max() ||
      observed.process_id != static_cast<DWORD>(caller.process_id) ||
      caller.process_start_identity != WindowsProcessStartIdentityString(
                                           observed.process_start_identity) ||
      caller.executable_sha256 != observed.executable.sha256 ||
      caller.package_id != policy.application_package_id() ||
      caller.signer_identity != policy.application_publisher() ||
      !observed.executable.signature_valid ||
      observed.executable.publisher !=
          Utf8ToWide(policy.application_publisher())) {
    throw WindowsOneShotTransportError(
        "frozen caller identity does not match named-pipe peer");
  }
}

WindowsOneShotPipeChannel::WindowsOneShotPipeChannel(
    HANDLE pipe,
    HANDLE caller_process,
    std::int64_t startup_deadline_unix_milliseconds)
    : pipe_(pipe),
      caller_process_(caller_process),
      startup_deadline_unix_milliseconds_(
          startup_deadline_unix_milliseconds) {
  if (pipe_ == nullptr || pipe_ == INVALID_HANDLE_VALUE ||
      caller_process_ == nullptr ||
      caller_process_ == INVALID_HANDLE_VALUE) {
    throw WindowsOneShotTransportError("invalid one-shot pipe handles");
  }
}

void WindowsOneShotPipeChannel::TransferExact(
    bool write,
    void* bytes,
    std::uint32_t length,
    std::int64_t deadline_unix_milliseconds) {
  std::uint32_t offset = 0;
  while (offset < length) {
    UniqueWindowsHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!event.valid()) {
      throw WindowsOneShotTransportError("pipe event creation failed");
    }
    OVERLAPPED overlapped{};
    overlapped.hEvent = event.get();
    DWORD transferred = 0;
    const DWORD remaining = length - offset;
    unsigned char* cursor = static_cast<unsigned char*>(bytes) + offset;
    const BOOL started = write
                             ? WriteFile(pipe_, cursor, remaining,
                                         &transferred, &overlapped)
                             : ReadFile(pipe_, cursor, remaining,
                                        &transferred, &overlapped);
    if (!started) {
      const DWORD error = GetLastError();
      if (error != ERROR_IO_PENDING) {
        throw WindowsOneShotTransportError(
            write ? "one-shot pipe write failed"
                  : "one-shot pipe read failed");
      }
      const std::array<HANDLE, 2> waits = {event.get(), caller_process_};
      const DWORD wait = WaitForMultipleObjects(
          static_cast<DWORD>(waits.size()), waits.data(), FALSE,
          RemainingMilliseconds(deadline_unix_milliseconds));
      if (wait != WAIT_OBJECT_0) {
        CancelIoEx(pipe_, &overlapped);
        WaitForSingleObject(event.get(), INFINITE);
        throw WindowsOneShotTransportError(
            wait == WAIT_OBJECT_0 + 1
                ? "caller exited during one-shot pipe transfer"
                : "one-shot pipe transfer timed out");
      }
      if (!GetOverlappedResult(pipe_, &overlapped, &transferred, FALSE)) {
        throw WindowsOneShotTransportError(
            write ? "one-shot pipe write completion failed"
                  : "one-shot pipe read completion failed");
      }
    }
    if (transferred == 0 || transferred > remaining) {
      throw WindowsOneShotTransportError(
          "one-shot pipe transfer made invalid progress");
    }
    offset += transferred;
  }
}

std::string WindowsOneShotPipeChannel::ReadFrameAt(
    std::int64_t deadline_unix_milliseconds) {
  std::array<unsigned char, 4> header{};
  TransferExact(false, header.data(), static_cast<std::uint32_t>(header.size()),
                deadline_unix_milliseconds);
  const std::uint32_t length =
      (static_cast<std::uint32_t>(header[0]) << 24) |
      (static_cast<std::uint32_t>(header[1]) << 16) |
      (static_cast<std::uint32_t>(header[2]) << 8) |
      static_cast<std::uint32_t>(header[3]);
  ValidateWindowsOneShotFrameLength(length);
  std::string frame(length, '\0');
  TransferExact(false, frame.data(), length, deadline_unix_milliseconds);
  return frame;
}

std::string WindowsOneShotPipeChannel::ReadFrame() {
  return ReadFrameAt(startup_deadline_unix_milliseconds_);
}

std::string WindowsOneShotPipeChannel::ReadFrameUntil(
    std::int64_t expires_at_unix_milliseconds) {
  return ReadFrameAt(expires_at_unix_milliseconds);
}

void WindowsOneShotPipeChannel::WriteFrame(
    const std::string& canonical_frame) {
  if (canonical_frame.size() >
      std::numeric_limits<std::uint32_t>::max()) {
    throw WindowsOneShotTransportError("one-shot pipe frame is too large");
  }
  const std::uint32_t length =
      static_cast<std::uint32_t>(canonical_frame.size());
  ValidateWindowsOneShotFrameLength(length);
  std::vector<unsigned char> encoded(4 + length);
  encoded[0] = static_cast<unsigned char>((length >> 24) & 0xff);
  encoded[1] = static_cast<unsigned char>((length >> 16) & 0xff);
  encoded[2] = static_cast<unsigned char>((length >> 8) & 0xff);
  encoded[3] = static_cast<unsigned char>(length & 0xff);
  std::copy(canonical_frame.begin(), canonical_frame.end(),
            encoded.begin() + 4);
  const std::int64_t deadline =
      NowUnixMilliseconds() + 30'000;
  TransferExact(true, encoded.data(),
                static_cast<std::uint32_t>(encoded.size()), deadline);
  if (!FlushFileBuffers(pipe_)) {
    throw WindowsOneShotTransportError("one-shot pipe flush failed");
  }
}

WindowsCallerExitMonitorFactory::WindowsCallerExitMonitorFactory(
    DWORD observed_caller_process_id,
    const WindowsHelperPolicy& policy)
    : observed_caller_process_id_(observed_caller_process_id),
      policy_(policy) {}

std::unique_ptr<NativeInstallCallerExitMonitorV1>
WindowsCallerExitMonitorFactory::Create(
    const NativeInstallCallerV1& caller) {
  if (caller.process_id <= 0 ||
      static_cast<std::uint64_t>(caller.process_id) >
          std::numeric_limits<DWORD>::max() ||
      static_cast<DWORD>(caller.process_id) !=
          observed_caller_process_id_) {
    throw WindowsOneShotTransportError(
        "request caller PID does not match named-pipe server");
  }
  UniqueWindowsHandle process(OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE,
      observed_caller_process_id_));
  if (!process.valid()) {
    throw WindowsOneShotTransportError("caller process cannot be retained");
  }
  const std::filesystem::path executable_path =
      ProcessExecutablePath(process.get());
  const ObservedWindowsCallerIdentity observed =
      ObserveCaller(observed_caller_process_id_, process.get());
  ValidateWindowsCallerIdentity(caller, observed, policy_);
  return std::make_unique<WindowsCallerExitMonitor>(
      std::move(process), executable_path, observed.executable);
}

void RunWindowsOneShotPipeSession(
    HANDLE pipe,
    DWORD observed_caller_process_id,
    const WindowsHelperPolicy& policy,
    desktop_updater::runtime::internal::NativeInstallRequestAuthorizerV1&
        authorizer,
    NativeInstallOneShotSessionV1::ReadyTokenGenerator ready_token_generator,
    NativeInstallOneShotSessionV1::Sha256Function sha256,
    NativeInstallOneShotSessionV1::Clock now_unix_milliseconds,
    std::int64_t reservation_lifetime_milliseconds,
    DWORD startup_timeout_milliseconds) {
  if (!now_unix_milliseconds || startup_timeout_milliseconds == 0) {
    throw WindowsOneShotTransportError(
        "invalid one-shot session timing dependencies");
  }
  const std::int64_t now = now_unix_milliseconds();
  if (now < 0 ||
      now > std::numeric_limits<std::int64_t>::max() -
                startup_timeout_milliseconds) {
    throw WindowsOneShotTransportError("one-shot startup deadline overflow");
  }
  UniqueWindowsHandle caller_process(OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE,
      observed_caller_process_id));
  if (!caller_process.valid()) {
    throw WindowsOneShotTransportError("named-pipe caller cannot be retained");
  }
  WindowsOneShotPipeChannel channel(
      pipe, caller_process.get(), now + startup_timeout_milliseconds);
  WindowsCallerExitMonitorFactory monitor_factory(
      observed_caller_process_id, policy);
  NativeInstallOneShotSessionV1 session(
      authorizer, std::move(ready_token_generator), std::move(sha256),
      std::move(now_unix_milliseconds),
      reservation_lifetime_milliseconds);
  NativeInstallOneShotServiceRuntimeV1 runtime(session, monitor_factory);
  runtime.Run(channel);
}

}  // namespace desktop_updater::helper
