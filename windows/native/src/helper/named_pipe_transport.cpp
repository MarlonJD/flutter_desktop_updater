#include "named_pipe_transport.h"

#include <sddl.h>
#include <shellapi.h>

#include <array>
#include <memory>
#include <mutex>
#include <set>
#include <vector>

#include "json_value.h"

namespace desktop_updater::helper {
namespace {

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle = INVALID_HANDLE_VALUE)
      : handle_(handle) {}
  ~ScopedHandle() { Reset(); }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
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
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT |
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

void WriteExact(HANDLE pipe, const void* bytes, DWORD length) {
  DWORD written = 0;
  if (!WriteFile(pipe, bytes, length, &written, nullptr) || written != length) {
    throw NamedPipeTransportError("canonical request write failed");
  }
}

void ReadExact(HANDLE pipe, void* bytes, DWORD length) {
  DWORD received = 0;
  if (!ReadFile(pipe, bytes, length, &received, nullptr) ||
      received != length) {
    throw NamedPipeTransportError("canonical request read failed");
  }
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

ElevationLaunchResult LaunchAuthenticatedElevatedHelper(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const std::string& nonce,
    const std::string& canonical_request,
    DWORD timeout_millis) {
  if (canonical_request.empty() || canonical_request.size() > 1024 * 1024) {
    throw NamedPipeTransportError("canonical request size rejected");
  }
  try {
    const auto parsed =
        desktop_updater::runtime::internal::ParseJson(canonical_request);
    if (desktop_updater::runtime::internal::EncodeCanonicalJson(parsed) !=
        canonical_request) {
      throw NamedPipeTransportError("request is not canonical JSON");
    }
  } catch (const desktop_updater::runtime::internal::JsonError&) {
    throw NamedPipeTransportError("request is not valid canonical JSON");
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
    return ClassifyElevationResult(GetLastError(), false);
  }
  ScopedHandle helper_process(launch.hProcess);
  if (!ConnectWithTimeout(pipe.get(), timeout_millis)) {
    return ElevationLaunchResult::kTimedOut;
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

  const DWORD request_length = static_cast<DWORD>(canonical_request.size());
  WriteExact(pipe.get(), &request_length, sizeof(request_length));
  WriteExact(pipe.get(), canonical_request.data(), request_length);
  if (!FlushFileBuffers(pipe.get())) {
    throw NamedPipeTransportError("canonical request flush failed");
  }

  std::array<char, 128> response{};
  DWORD received = 0;
  if (!ReadFile(pipe.get(), response.data(),
                static_cast<DWORD>(response.size()), &received, nullptr)) {
    throw NamedPipeTransportError("helper handshake read failed");
  }
  const std::string expected_response = "AUTHENTICATED " + nonce;
  if (std::string(response.data(), received) != expected_response ||
      !VerifyWindowsExecutableStillMatches(fixed_helper_path, identity)) {
    throw NamedPipeTransportError("helper handshake or identity changed");
  }
  return ElevationLaunchResult::kLaunched;
}

int ConnectElevatedHelperToCallerPipe(const std::wstring& pipe_name,
                                      const std::string& nonce,
                                      DWORD timeout_millis) {
  if (pipe_name != DerivePipeName(nonce)) {
    throw NamedPipeTransportError("pipe locator is not nonce-derived");
  }
  if (!WaitNamedPipeW(pipe_name.c_str(), timeout_millis)) {
    return static_cast<int>(WAIT_TIMEOUT);
  }
  ScopedHandle pipe(CreateFileW(
      pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
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
  DWORD request_length = 0;
  ReadExact(pipe.get(), &request_length, sizeof(request_length));
  if (request_length == 0 || request_length > 1024 * 1024) {
    throw NamedPipeTransportError("canonical request size rejected");
  }
  std::string canonical_request(request_length, '\0');
  ReadExact(pipe.get(), canonical_request.data(), request_length);
  try {
    const auto parsed =
        desktop_updater::runtime::internal::ParseJson(canonical_request);
    if (desktop_updater::runtime::internal::EncodeCanonicalJson(parsed) !=
        canonical_request) {
      throw NamedPipeTransportError("request is not canonical JSON");
    }
  } catch (const desktop_updater::runtime::internal::JsonError&) {
    throw NamedPipeTransportError("request is not valid canonical JSON");
  }
  // Task 7 authenticates and reserves authority only. Task 8 consumes this
  // canonical request for the handle-relative transaction.
  const std::string response = "AUTHENTICATED " + nonce;
  DWORD written = 0;
  if (!WriteFile(pipe.get(), response.data(),
                 static_cast<DWORD>(response.size()), &written, nullptr) ||
      written != response.size() || !FlushFileBuffers(pipe.get())) {
    throw NamedPipeTransportError("helper handshake write failed");
  }
  return ERROR_SUCCESS;
}

}  // namespace desktop_updater::helper
