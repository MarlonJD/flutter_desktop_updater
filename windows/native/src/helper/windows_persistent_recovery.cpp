#include "windows_persistent_recovery.h"

#include <aclapi.h>
#include <sddl.h>
#include <winternl.h>

#include <algorithm>
#include <array>
#include <cwctype>
#include <limits>
#include <memory>
#include <regex>
#include <set>
#include <utility>
#include <vector>

#include "helper_authenticode.h"
#include "json_value.h"
#include "windows_helper_bootstrap.h"
#include "windows_helper_diagnostics.h"
#include "windows_portable_recovery_host.h"
#include "windows_portable_transaction_index.h"
#include "windows_recovery_service.h"
#include "windows_relaunch_service.h"
#include "windows_uninstall_record_proof.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;

constexpr std::size_t kMaximumPersistentRecordBytes = 1024 * 1024;
constexpr std::size_t kMaximumPersistentResolverClaimBytes = 64 * 1024;
constexpr wchar_t kPersistentRecordValueName[] = L"Record";
constexpr wchar_t kPersistentResolverClaimValueName[] = L"ResolverClaim";
constexpr DWORD kResolverClaimMutexTimeoutMilliseconds = 30'000;
constexpr ULONGLONG kConcurrentRecoveryOwnerTimeoutMilliseconds = 300'000;
constexpr DWORD kConcurrentRecoveryOwnerPollMilliseconds = 50;
const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
const std::regex kSha256("^[0-9a-f]{64}$");
const std::set<std::string> kRecordStates = {"preparing",
                                             "prepared",
                                             "commitAccepted",
                                             "cancelling",
                                             "completedCleanupPending",
                                             "rolledBackCleanupPending",
                                             "completed",
                                             "rolledBack",
                                             "manualActionRequired"};
const std::set<std::string> kRelaunchStates = {
    "notRequested", "launchPending", "launchAttempting", "launched",
    "launchFailed"};
const std::set<std::string> kResolverClaimStates = {"claimed", "consumed"};

bool IsRecoveryReadyNonce(const std::string& nonce) {
  return nonce.size() == 43 &&
         std::all_of(nonce.begin(), nonce.end(), [](unsigned char value) {
           return (value >= 'A' && value <= 'Z') ||
                  (value >= 'a' && value <= 'z') ||
                  (value >= '0' && value <= '9') || value == '-' ||
                  value == '_';
         });
}

class ScopedRegistryKey {
 public:
  explicit ScopedRegistryKey(HKEY key = nullptr) : key_(key) {}
  ~ScopedRegistryKey() {
    if (key_ != nullptr) RegCloseKey(key_);
  }
  ScopedRegistryKey(const ScopedRegistryKey&) = delete;
  ScopedRegistryKey& operator=(const ScopedRegistryKey&) = delete;
  ScopedRegistryKey(ScopedRegistryKey&& other) noexcept
      : key_(other.release()) {}
  ScopedRegistryKey& operator=(ScopedRegistryKey&& other) noexcept {
    if (this != &other) {
      if (key_ != nullptr) RegCloseKey(key_);
      key_ = other.release();
    }
    return *this;
  }
  HKEY get() const { return key_; }
  HKEY release() {
    HKEY result = key_;
    key_ = nullptr;
    return result;
  }

 private:
  HKEY key_;
};

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty() || value.size() > static_cast<std::size_t>(
                                          std::numeric_limits<int>::max())) {
    throw WindowsPersistentRecoveryError("persistent UTF-8 value is invalid");
  }
  const int length =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    throw WindowsPersistentRecoveryError("persistent UTF-8 value is invalid");
  }
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    throw WindowsPersistentRecoveryError("persistent UTF-8 conversion failed");
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty() || value.size() > static_cast<std::size_t>(
                                          std::numeric_limits<int>::max())) {
    throw WindowsPersistentRecoveryError("persistent path is invalid");
  }
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    throw WindowsPersistentRecoveryError("persistent path is invalid UTF-16");
  }
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), length,
                          nullptr, nullptr) != length) {
    throw WindowsPersistentRecoveryError("persistent path conversion failed");
  }
  return result;
}

void RequireTransactionId(const std::string& transaction_id) {
  if (!std::regex_match(transaction_id, kTransactionId)) {
    throw WindowsPersistentRecoveryError("transaction ID is invalid");
  }
}

void RequireExactKeys(const JsonValue& value,
                      const std::set<std::string>& expected) {
  const auto& object = value.object();
  if (object.size() != expected.size()) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction record fields are invalid");
  }
  for (const std::string& key : expected) {
    if (object.find(key) == object.end()) {
      throw WindowsPersistentRecoveryError(
          "persistent transaction record fields are invalid");
    }
  }
}

std::filesystem::path CanonicalAbsolutePath(const std::string& encoded) {
  const std::filesystem::path path(Utf8ToWide(encoded));
  if (!path.is_absolute() || path.lexically_normal() != path ||
      path.filename().empty()) {
    throw WindowsPersistentRecoveryError(
        "persistent target path hint is invalid");
  }
  return path;
}

std::filesystem::path ProcessExecutablePath(HANDLE process) {
  if (process == nullptr) {
    throw WindowsPersistentRecoveryError(
        "recovery caller process is unavailable");
  }
  std::vector<wchar_t> buffer(32768);
  DWORD length = static_cast<DWORD>(buffer.size());
  if (!QueryFullProcessImageNameW(process, 0, buffer.data(), &length) ||
      length == 0 || length >= buffer.size()) {
    throw WindowsPersistentRecoveryError(
        "recovery caller executable is unavailable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

UniqueWindowsHandle OpenExactRecoveryActor(std::int64_t process_id,
                                           std::int64_t process_start_identity,
                                           const char* actor) {
  UniqueWindowsHandle process(
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE,
                  static_cast<DWORD>(process_id)));
  if (!process.valid()) {
    const DWORD error = GetLastError();
    if (error == ERROR_INVALID_PARAMETER || error == ERROR_NOT_FOUND) {
      return UniqueWindowsHandle();
    }
    throw WindowsPersistentRecoveryError(
        std::string("persistent transaction ") + actor +
        " cannot be inspected");
  }
  if (WindowsProcessStartIdentity(process.get()) !=
      static_cast<std::uint64_t>(process_start_identity)) {
    return UniqueWindowsHandle();
  }
  return process;
}

std::unique_ptr<CallerTokenWindowsLauncher> WaitForExactRecoveryActorsExit(
    const WindowsPersistentTransactionRecord& record,
    const std::function<void(const std::string&)>& signal_ready) {
  if (!signal_ready) {
    throw WindowsPersistentRecoveryError(
        "autonomous recovery readiness signal is unavailable");
  }
  UniqueWindowsHandle executor = OpenExactRecoveryActor(
      record.executor_process_id, record.executor_process_start_identity,
      "executor");
  UniqueWindowsHandle caller = OpenExactRecoveryActor(
      record.caller_process_id, record.caller_process_start_identity, "caller");
  std::unique_ptr<CallerTokenWindowsLauncher> launcher;
  if (caller.valid()) {
    try {
      // Capture the exact authenticated user's token before readiness allows
      // either actor to exit. The SYSTEM host never launches with its own
      // token, and a boot-time host with no surviving caller records failure.
      launcher = std::make_unique<CallerTokenWindowsLauncher>(caller.get());
    } catch (const std::exception&) {
      launcher.reset();
    }
  }
  // Readiness means both exact identities have either been retained or proven
  // already gone. The host keeps both handles across the signal so PID reuse
  // cannot change which processes gate recovery.
  signal_ready(record.recovery_ready_nonce);
  if (executor.valid() &&
      WaitForSingleObject(executor.get(), INFINITE) != WAIT_OBJECT_0) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction executor wait failed");
  }
  if (caller.valid() &&
      WaitForSingleObject(caller.get(), INFINITE) != WAIT_OBJECT_0) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction caller wait failed");
  }
  return launcher;
}

std::wstring NormalizeComparablePath(std::filesystem::path path) {
  std::wstring value = path.lexically_normal().wstring();
  if (value.rfind(L"\\\\?\\", 0) == 0) value.erase(0, 4);
  std::replace(value.begin(), value.end(), L'/', L'\\');
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  while (value.size() > 3 && value.back() == L'\\') value.pop_back();
  return value;
}

bool ApplicationIdentityMatchesPolicy(
    const VerifiedWindowsExecutable& identity,
    const WindowsHelperPolicy& policy) {
  if (!identity.signature_valid) return false;
  if (policy.is_portable()) {
    return policy.application_signer_kind() == "sha256" &&
           identity.sha256 == policy.application_signer_identity();
  }
  return identity.publisher == Utf8ToWide(policy.application_publisher());
}

UniqueWindowsHandle CallerImpersonationToken(HANDLE caller_process) {
  if (caller_process == nullptr) {
    throw WindowsPersistentRecoveryError(
        "persistent index caller process is unavailable");
  }
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(caller_process, TOKEN_QUERY | TOKEN_DUPLICATE,
                        &raw_token)) {
    throw WindowsPersistentRecoveryError(
        "persistent index caller token is unavailable");
  }
  UniqueWindowsHandle token(raw_token);
  HANDLE raw_impersonation = nullptr;
  if (!DuplicateToken(token.get(), SecurityImpersonation, &raw_impersonation)) {
    throw WindowsPersistentRecoveryError(
        "persistent index caller token cannot be duplicated");
  }
  return UniqueWindowsHandle(raw_impersonation);
}

void RejectCallerWritableRegistryKey(HKEY key, HANDLE caller_process) {
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PACL dacl = nullptr;
  PSID owner = nullptr;
  const DWORD security =
      GetSecurityInfo(key, SE_REGISTRY_KEY,
                      OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |
                          DACL_SECURITY_INFORMATION,
                      &owner, nullptr, &dacl, nullptr, &raw_descriptor);
  if (security != ERROR_SUCCESS || raw_descriptor == nullptr ||
      dacl == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    throw WindowsPersistentRecoveryError(
        "persistent index security descriptor is unavailable");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> system_sid{};
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> administrators_sid{};
  DWORD system_sid_size = static_cast<DWORD>(system_sid.size());
  DWORD administrators_sid_size = static_cast<DWORD>(administrators_sid.size());
  if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid.data(),
                          &system_sid_size) ||
      !CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr,
                          administrators_sid.data(),
                          &administrators_sid_size)) {
    throw WindowsPersistentRecoveryError(
        "persistent index trusted SID construction failed");
  }
  auto is_trusted_sid = [&](PSID sid) {
    return sid != nullptr && (EqualSid(sid, system_sid.data()) ||
                              EqualSid(sid, administrators_sid.data()));
  };
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!is_trusted_sid(owner) ||
      !GetSecurityDescriptorControl(raw_descriptor, &control, &revision) ||
      (control & SE_DACL_PROTECTED) == 0) {
    throw WindowsPersistentRecoveryError(
        "persistent index owner or DACL protection is invalid");
  }
  bool system_full_control = false;
  bool administrators_full_control = false;
  for (DWORD index = 0; index < dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace) || raw_ace == nullptr) {
      throw WindowsPersistentRecoveryError(
          "persistent index DACL is unreadable");
    }
    const ACE_HEADER* header = static_cast<const ACE_HEADER*>(raw_ace);
    if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) {
      throw WindowsPersistentRecoveryError(
          "persistent index DACL contains unsupported authority");
    }
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    constexpr DWORD write_authority =
        KEY_SET_VALUE | KEY_CREATE_SUB_KEY | DELETE | WRITE_DAC | WRITE_OWNER;
    if ((ace->Mask & write_authority) != 0 && !is_trusted_sid(sid)) {
      throw WindowsPersistentRecoveryError(
          "persistent index DACL grants untrusted write authority");
    }
    if (EqualSid(sid, system_sid.data()) &&
        (ace->Mask & KEY_ALL_ACCESS) == KEY_ALL_ACCESS) {
      system_full_control = true;
    }
    if (EqualSid(sid, administrators_sid.data()) &&
        (ace->Mask & KEY_ALL_ACCESS) == KEY_ALL_ACCESS) {
      administrators_full_control = true;
    }
  }
  if (!system_full_control || !administrators_full_control) {
    throw WindowsPersistentRecoveryError(
        "persistent index trusted principals lack full control");
  }
  if (caller_process == nullptr) {
    return;
  }
  UniqueWindowsHandle caller_token = CallerImpersonationToken(caller_process);
  GENERIC_MAPPING mapping{KEY_READ, KEY_WRITE, KEY_EXECUTE, KEY_ALL_ACCESS};
  std::vector<unsigned char> privileges(4096);
  DWORD privileges_size = static_cast<DWORD>(privileges.size());
  DWORD granted = 0;
  BOOL access = FALSE;
  if (!AccessCheck(raw_descriptor, caller_token.get(), MAXIMUM_ALLOWED,
                   &mapping,
                   reinterpret_cast<PRIVILEGE_SET*>(privileges.data()),
                   &privileges_size, &granted, &access)) {
    throw WindowsPersistentRecoveryError(
        "persistent index caller access check failed");
  }
  constexpr DWORD write_authority =
      KEY_SET_VALUE | KEY_CREATE_SUB_KEY | DELETE | WRITE_DAC | WRITE_OWNER;
  if (access == TRUE && (granted & write_authority) != 0) {
    throw WindowsPersistentRecoveryError(
        "persistent index is writable by the named-pipe caller");
  }
}

HKEY OpenPersistentIndexKey(const WindowsHelperPolicy& policy,
                            HANDLE caller_process, bool create_if_missing) {
  const std::string binding = policy.policy_id() + "\n" +
                              policy.application_package_id() + "\n" +
                              policy.helper_service_id();
  const std::wstring key_path = L"SOFTWARE\\DesktopUpdater\\Transactions\\" +
                                Utf8ToWide(WindowsHelperSha256Hex(binding));
  HKEY raw_key = nullptr;
  if (!create_if_missing) {
    const LSTATUS open_status = RegOpenKeyExW(
        HKEY_LOCAL_MACHINE, key_path.c_str(), 0,
        KEY_READ | KEY_WRITE | READ_CONTROL | KEY_WOW64_64KEY, &raw_key);
    if (open_status == ERROR_FILE_NOT_FOUND) return nullptr;
    if (open_status != ERROR_SUCCESS || raw_key == nullptr) {
      throw WindowsPersistentRecoveryError(
          "installer-protected persistent index is unavailable");
    }
    ScopedRegistryKey existing(raw_key);
    RejectCallerWritableRegistryKey(existing.get(), caller_process);
    return existing.release();
  }
  DWORD disposition = 0;
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"O:BAG:BAD:P(A;;KA;;;SY)(A;;KA;;;BA)", SDDL_REVISION_1,
          &raw_descriptor, nullptr) ||
      raw_descriptor == nullptr) {
    throw WindowsPersistentRecoveryError(
        "persistent index protected DACL construction failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = raw_descriptor;
  attributes.bInheritHandle = FALSE;
  const LSTATUS status = RegCreateKeyExW(
      HKEY_LOCAL_MACHINE, key_path.c_str(), 0, nullptr, REG_OPTION_NON_VOLATILE,
      KEY_READ | KEY_WRITE | READ_CONTROL | KEY_WOW64_64KEY, &attributes,
      &raw_key, &disposition);
  if (status != ERROR_SUCCESS || raw_key == nullptr) {
    throw WindowsPersistentRecoveryError(
        "installer-protected persistent index is unavailable");
  }
  ScopedRegistryKey key(raw_key);
  RejectCallerWritableRegistryKey(key.get(), caller_process);
  return key.release();
}

HKEY CreatePersistentTransactionKey(HKEY parent,
                                    const std::string& transaction_id,
                                    HANDLE caller_process) {
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"O:BAG:BAD:P(A;;KA;;;SY)(A;;KA;;;BA)", SDDL_REVISION_1,
          &raw_descriptor, nullptr) ||
      raw_descriptor == nullptr) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction DACL construction failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = raw_descriptor;
  attributes.bInheritHandle = FALSE;
  HKEY raw_key = nullptr;
  DWORD disposition = 0;
  const LSTATUS status =
      RegCreateKeyExW(parent, Utf8ToWide(transaction_id).c_str(), 0, nullptr,
                      REG_OPTION_NON_VOLATILE,
                      KEY_READ | KEY_WRITE | READ_CONTROL | KEY_WOW64_64KEY,
                      &attributes, &raw_key, &disposition);
  if (status != ERROR_SUCCESS || raw_key == nullptr) {
    throw WindowsPersistentRecoveryError("persistent transaction claim failed");
  }
  ScopedRegistryKey key(raw_key);
  RejectCallerWritableRegistryKey(key.get(), caller_process);
  if (disposition != REG_CREATED_NEW_KEY) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction ID already exists");
  }
  return key.release();
}

std::optional<ScopedRegistryKey> OpenPersistentTransactionKey(
    HKEY parent, const std::string& transaction_id, HANDLE caller_process,
    REGSAM access) {
  HKEY raw_key = nullptr;
  const LSTATUS status =
      RegOpenKeyExW(parent, Utf8ToWide(transaction_id).c_str(), 0,
                    access | READ_CONTROL | KEY_WOW64_64KEY, &raw_key);
  if (status == ERROR_FILE_NOT_FOUND) return std::nullopt;
  if (status != ERROR_SUCCESS || raw_key == nullptr) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction claim is unavailable");
  }
  ScopedRegistryKey key(raw_key);
  RejectCallerWritableRegistryKey(key.get(), caller_process);
  return std::optional<ScopedRegistryKey>(std::move(key));
}

void WritePersistentRecord(HKEY key,
                           const WindowsPersistentTransactionRecord& record) {
  const std::string canonical = record.EncodeCanonical();
  if (canonical.size() > std::numeric_limits<DWORD>::max() ||
      RegSetValueExW(key, kPersistentRecordValueName, 0, REG_BINARY,
                     reinterpret_cast<const BYTE*>(canonical.data()),
                     static_cast<DWORD>(canonical.size())) != ERROR_SUCCESS ||
      RegFlushKey(key) != ERROR_SUCCESS) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction record flush failed");
  }
}

std::optional<WindowsPersistentResolverClaim> ReadPersistentResolverClaim(
    HKEY key, const std::string& transaction_id) {
  DWORD type = 0;
  DWORD size = 0;
  LSTATUS status = RegQueryValueExW(key, kPersistentResolverClaimValueName,
                                    nullptr, &type, nullptr, &size);
  if (status == ERROR_FILE_NOT_FOUND) return std::nullopt;
  if (status != ERROR_SUCCESS || type != REG_BINARY || size == 0 ||
      size > kMaximumPersistentResolverClaimBytes) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver claim value is invalid");
  }
  std::string bytes(size, '\0');
  DWORD received = size;
  status =
      RegQueryValueExW(key, kPersistentResolverClaimValueName, nullptr, &type,
                       reinterpret_cast<BYTE*>(bytes.data()), &received);
  if (status != ERROR_SUCCESS || type != REG_BINARY || received != size) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver claim read failed");
  }
  WindowsPersistentResolverClaim claim =
      WindowsPersistentResolverClaim::DecodeStrict(bytes);
  if (claim.transaction_id != transaction_id) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver claim binding changed");
  }
  return claim;
}

void WritePersistentResolverClaim(HKEY key,
                                  const WindowsPersistentResolverClaim& claim) {
  const std::string canonical = claim.EncodeCanonical();
  if (canonical.size() > std::numeric_limits<DWORD>::max() ||
      RegSetValueExW(key, kPersistentResolverClaimValueName, 0, REG_BINARY,
                     reinterpret_cast<const BYTE*>(canonical.data()),
                     static_cast<DWORD>(canonical.size())) != ERROR_SUCCESS ||
      RegFlushKey(key) != ERROR_SUCCESS) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver claim flush failed");
  }
}

class ScopedResolverClaimMutex {
 public:
  ScopedResolverClaimMutex(const WindowsPersistentTransactionRecord& record,
                           bool portable) {
    // The protected high-entropy recovery nonce prevents an unprivileged
    // process from pre-creating the global synchronization object by name.
    const std::string binding =
        "resolver-claim-v1\n" + record.policy_id + "\n" + record.package_id +
        "\n" + record.transaction_id + "\n" + record.recovery_ready_nonce;
    const std::wstring name =
        (portable ? L"Local\\DesktopUpdater-PortableResolverClaim-"
                  : L"Global\\DesktopUpdater-ResolverClaim-") +
        Utf8ToWide(WindowsHelperSha256Hex(binding));
    std::wstring sddl = L"O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)";
    if (portable) {
      HANDLE raw_token = nullptr;
      if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
        throw WindowsPersistentRecoveryError(
            "portable resolver user token is unavailable");
      }
      UniqueWindowsHandle token(raw_token);
      DWORD size = 0;
      (void)GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
      if (size == 0 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
        throw WindowsPersistentRecoveryError(
            "portable resolver user SID is unavailable");
      }
      std::vector<unsigned char> bytes(size);
      if (!GetTokenInformation(token.get(), TokenUser, bytes.data(), size,
                               &size)) {
        throw WindowsPersistentRecoveryError(
            "portable resolver user SID is unavailable");
      }
      const auto* user = reinterpret_cast<const TOKEN_USER*>(bytes.data());
      LPWSTR raw_sid = nullptr;
      if (user->User.Sid == nullptr ||
          !ConvertSidToStringSidW(user->User.Sid, &raw_sid) ||
          raw_sid == nullptr) {
        throw WindowsPersistentRecoveryError(
            "portable resolver user SID conversion failed");
      }
      const std::wstring sid(raw_sid);
      LocalFree(raw_sid);
      sddl = L"O:" + sid + L"G:" + sid + L"D:P(A;;GA;;;" + sid +
             L")(A;;GA;;;SY)";
    }
    PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.c_str(), SDDL_REVISION_1,
            &raw_descriptor, nullptr) ||
        raw_descriptor == nullptr) {
      throw WindowsPersistentRecoveryError(
          "persistent resolver claim mutex DACL construction failed");
    }
    std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                           LocalFree);
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = raw_descriptor;
    attributes.bInheritHandle = FALSE;
    handle_ =
        UniqueWindowsHandle(CreateMutexW(&attributes, FALSE, name.c_str()));
    if (!handle_.valid()) {
      throw WindowsPersistentRecoveryError(
          "persistent resolver claim mutex is unavailable");
    }
    const DWORD wait = WaitForSingleObject(
        handle_.get(), kResolverClaimMutexTimeoutMilliseconds);
    if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
      throw WindowsPersistentRecoveryError(
          "persistent resolver claim mutex wait failed");
    }
    owned_ = true;
  }

  ~ScopedResolverClaimMutex() {
    if (owned_) (void)ReleaseMutex(handle_.get());
  }

  ScopedResolverClaimMutex(const ScopedResolverClaimMutex&) = delete;
  ScopedResolverClaimMutex& operator=(const ScopedResolverClaimMutex&) = delete;

 private:
  UniqueWindowsHandle handle_;
  bool owned_ = false;
};

bool ResolverClaimOwnerAlive(const WindowsPersistentResolverClaim& claim) {
  try {
    return OpenExactRecoveryActor(claim.resolver_process_id,
                                  claim.resolver_process_start_identity,
                                  "resolver")
        .valid();
  } catch (const std::exception&) {
    // Inability to prove that an exact claimant died must not authorize a
    // second relaunch owner.
    return true;
  }
}

std::string JournalStateName(WindowsTransactionState state) {
  switch (state) {
    case WindowsTransactionState::kPrepared:
      return "prepared";
    case WindowsTransactionState::kBackupCreated:
      return "backupCreated";
    case WindowsTransactionState::kTargetActivated:
      return "targetActivated";
    case WindowsTransactionState::kCompleted:
      return "targetActivated";
    case WindowsTransactionState::kManualActionRequired:
      return "manualActionRequired";
  }
  return "manualActionRequired";
}

UniqueWindowsHandle OpenTargetParent(const std::filesystem::path& target) {
  const std::filesystem::path parent = target.parent_path();
  UniqueWindowsHandle result(CreateFileW(
      parent.c_str(), GENERIC_READ | FILE_TRAVERSE | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr));
  if (!result.valid()) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction parent is unavailable");
  }
  const WindowsFileIdentity identity = ReadWindowsFileIdentity(result.get());
  if (!identity.directory ||
      (identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction parent is not authoritative");
  }
  return result;
}

std::optional<WindowsTransactionJournal> LoadCurrentJournal(
    const WindowsPersistentTransactionRecord& record) {
  const WindowsTransactionJournal frozen =
      WindowsTransactionJournal::DecodeStrict(record.journal_canonical);
  const WindowsTransactionPaths paths = WindowsTransactionPaths::Create(
      frozen.target_name, record.transaction_id);
  UniqueWindowsHandle parent = OpenTargetParent(record.target_path_hint);
  if (ReadWindowsFileIdentity(parent.get()) != frozen.parent_identity) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction journal is corrupt or torn");
  }
  DurableWindowsTransactionJournalStore store(parent.get(), paths);
  const auto current = store.Load();
  if (!current.has_value()) return std::nullopt;
  if (current->schema_version != frozen.schema_version ||
      current->transaction_id != frozen.transaction_id ||
      current->owner_process_id != frozen.owner_process_id ||
      current->owner_process_start_identity !=
          frozen.owner_process_start_identity ||
      current->target_name != frozen.target_name ||
      current->original_stage_parent_path !=
          frozen.original_stage_parent_path ||
      current->original_stage_name != frozen.original_stage_name ||
      current->prepared_name != frozen.prepared_name ||
      current->backup_name != frozen.backup_name ||
      current->lock_name != frozen.lock_name ||
      current->parent_identity != frozen.parent_identity ||
      current->stage_parent_identity != frozen.stage_parent_identity ||
      current->target_identity != frozen.target_identity ||
      current->stage_identity != frozen.stage_identity ||
      current->expected_payload_identity != frozen.expected_payload_identity) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction journal binding changed");
  }
  if (record.record_state != "commitAccepted" &&
      current->state != WindowsTransactionState::kPrepared) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction journal state is not monotonic");
  }
  return current;
}

bool VerifyExpectedPayload(HANDLE parent, const std::wstring& leaf,
                           const WindowsVerifiedPayloadIdentity& expected) {
  try {
    AuthenticodeWindowsPayloadVerifier verifier(expected);
    return verifier.Verify(parent, leaf) == expected;
  } catch (const std::exception&) {
    return false;
  }
}

bool VerifyInstalledTargetAuthority(
    HANDLE parent, const WindowsTransactionJournal& frozen,
    const WindowsPersistentTransactionRecord& record,
    const WindowsHelperPolicy& policy, HANDLE caller_process) {
  try {
    const std::filesystem::path executable =
        record.target_path_hint /
        std::filesystem::path(
            frozen.expected_payload_identity.executable_relative_path);
    const VerifiedWindowsExecutable identity =
        VerifyWindowsExecutable(executable);
    if (!ApplicationIdentityMatchesPolicy(identity, policy) ||
        !VerifyWindowsExecutableStillMatches(executable, identity)) {
      return false;
    }
    const auto uninstall_record =
        caller_process == nullptr
            ? FindCanonicalWindowsUninstallRecordProofForTrustedHost(
                  record.target_path_hint, record.package_id)
            : FindCanonicalWindowsUninstallRecordProof(
                  record.target_path_hint, record.package_id, caller_process);
    if (uninstall_record.has_value()) {
      return true;
    }
    const std::string marker = ReadUtf8FileRelative(
        parent,
        frozen.target_name + L"\\.desktop_updater_install_identity.json",
        64 * 1024);
    const JsonValue value = ParseJson(marker);
    const auto& object = value.object();
    return object.size() == 2 && object.find("packageId") != object.end() &&
           object.find("schemaVersion") != object.end() &&
           value.at("schemaVersion").integer() == 1 &&
           value.at("packageId").string() == record.package_id &&
           EncodeCanonicalJson(value) == marker;
  } catch (const std::exception&) {
    return false;
  }
}

enum class FinalTopology {
  kNone,
  kCompleted,
  kRolledBack,
};

FinalTopology InspectFinalTopology(
    const WindowsPersistentTransactionRecord& record,
    const WindowsHelperPolicy& policy, bool allow_exact_lock,
    HANDLE caller_process) {
  const WindowsTransactionJournal frozen =
      WindowsTransactionJournal::DecodeStrict(record.journal_canonical);
  const WindowsTransactionPaths paths = WindowsTransactionPaths::Create(
      frozen.target_name, record.transaction_id);
  UniqueWindowsHandle parent = OpenTargetParent(record.target_path_hint);
  if (ReadWindowsFileIdentity(parent.get()) != frozen.parent_identity ||
      ExistsRelativeNoReparse(parent.get(), paths.prepared_name) ||
      ExistsRelativeNoReparse(parent.get(), paths.backup_name) ||
      ExistsRelativeNoReparse(parent.get(), paths.journal_name) ||
      ExistsRelativeNoReparse(parent.get(), paths.journal_next_name) ||
      (!allow_exact_lock &&
       ExistsRelativeNoReparse(parent.get(), paths.lock_name)) ||
      !ExistsRelativeNoReparse(parent.get(), paths.target_name)) {
    return FinalTopology::kNone;
  }

  UniqueWindowsHandle target = OpenRelativeNoReparse(
      parent.get(), paths.target_name,
      FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  const WindowsFileIdentity target_identity =
      ReadWindowsFileIdentity(target.get());

  UniqueWindowsHandle stage_parent = OpenTargetParent(
      std::filesystem::path(frozen.original_stage_parent_path) /
      frozen.original_stage_name);
  if (ReadWindowsFileIdentity(stage_parent.get()) !=
      frozen.stage_parent_identity) {
    return FinalTopology::kNone;
  }
  const bool stage_exists =
      ExistsRelativeNoReparse(stage_parent.get(), frozen.original_stage_name);

  if (!stage_exists && target_identity == frozen.stage_identity &&
      VerifyExpectedPayload(parent.get(), paths.target_name,
                            frozen.expected_payload_identity) &&
      ReadWindowsFileIdentity(target.get()) == target_identity) {
    return FinalTopology::kCompleted;
  }
  if (stage_exists && target_identity == frozen.target_identity &&
      VerifyInstalledTargetAuthority(parent.get(), frozen, record, policy,
                                     caller_process) &&
      ReadWindowsFileIdentity(target.get()) == target_identity) {
    UniqueWindowsHandle stage = OpenRelativeNoReparse(
        stage_parent.get(), frozen.original_stage_name,
        FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
        FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
    if (ReadWindowsFileIdentity(stage.get()) == frozen.stage_identity &&
        VerifyExpectedPayload(stage_parent.get(), frozen.original_stage_name,
                              frozen.expected_payload_identity)) {
      return FinalTopology::kRolledBack;
    }
  }
  return FinalTopology::kNone;
}

desktop_updater::runtime::internal::NativeInstallTransactionStatusV1
StatusFromRecoveryResult(
    const desktop_updater::runtime::internal::NativeInstallRecoveryResultV1&
        recovery) {
  std::string state = "prepared";
  if (recovery.result_code == "completed") {
    state = "completed";
  } else if (recovery.result_code == "rolledBack") {
    state = "rolledBack";
  } else if (recovery.result_code == "manualActionRequired" ||
             recovery.result_code == "helperUnavailable") {
    state = "manualActionRequired";
  }
  return {recovery.protocol_version, recovery.transaction_id, state,
          recovery.result_code, recovery.journal_sha256};
}

void RelaunchRecoveredApplication(
    const WindowsPersistentTransactionRecord& record,
    const desktop_updater::runtime::internal::NativeInstallRecoveryResultV1&
        recovery,
    const WindowsHelperPolicy& policy, WindowsProcessLauncher& launcher) {
  const WindowsTransactionJournal frozen =
      WindowsTransactionJournal::DecodeStrict(record.journal_canonical);
  if (recovery.result_code == "completed" &&
      recovery.verified_outcome == "newTarget") {
    AuthenticodeWindowsPayloadVerifier verifier(
        frozen.expected_payload_identity);
    WindowsRelaunchService relaunch(frozen.expected_payload_identity, verifier,
                                    launcher);
    relaunch.Relaunch(record.target_path_hint);
    return;
  }
  if (recovery.result_code != "rolledBack" ||
      recovery.verified_outcome != "oldTarget" ||
      InspectFinalTopology(record, policy, false, nullptr) !=
          FinalTopology::kRolledBack) {
    throw WindowsPersistentRecoveryError(
        "recovered application topology is not relaunchable");
  }

  const std::filesystem::path executable =
      record.target_path_hint /
      std::filesystem::path(
          frozen.expected_payload_identity.executable_relative_path);
  const VerifiedWindowsExecutable identity =
      VerifyWindowsExecutable(executable);
  if (!ApplicationIdentityMatchesPolicy(identity, policy) ||
      NormalizeComparablePath(identity.final_path) !=
          NormalizeComparablePath(executable) ||
      !VerifyWindowsExecutableStillMatches(executable, identity)) {
    throw WindowsPersistentRecoveryError(
        "rolled-back application relaunch identity changed");
  }
  launcher.Launch(identity.final_path);
}

struct ExactLockObservation {
  enum class State {
    kAbsent,
    kAcquired,
    kLiveOwner,
    kForeign,
    kMalformed,
  };
  State state = State::kMalformed;
  UniqueWindowsHandle handle;
  bool created = false;
};

void FlushPersistentMetadata(HANDLE directory) {
  FlushWindowsDirectory(directory);
  FlushWindowsVolume(directory);
}

ExactLockObservation ObserveExactLock(HANDLE parent,
                                      const WindowsTransactionPaths& paths,
                                      bool create_if_missing) {
  bool exists = false;
  try {
    exists = ExistsRelativeNoReparse(parent, paths.lock_name);
  } catch (const WindowsTransactionJournalError& error) {
    if (error.code() ==
        WindowsTransactionJournalError::Code::kSharingViolation) {
      return {ExactLockObservation::State::kLiveOwner, UniqueWindowsHandle(),
              false};
    }
    return {ExactLockObservation::State::kMalformed, UniqueWindowsHandle(),
            false};
  }
  if (!exists) {
    if (!create_if_missing) {
      return {ExactLockObservation::State::kAbsent, UniqueWindowsHandle(),
              false};
    }
    try {
      if (ExistsRelativeNoReparse(parent, paths.lock_candidate_name)) {
        UniqueWindowsHandle stale_candidate = OpenRelativeNoReparse(
            parent, paths.lock_candidate_name,
            GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE, 0, FILE_OPEN,
            FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
                FILE_WRITE_THROUGH);
        DeleteHandleExact(stale_candidate.get());
        stale_candidate.reset();
        FlushPersistentMetadata(parent);
      }
      UniqueWindowsHandle candidate = OpenRelativeNoReparse(
          parent, paths.lock_candidate_name,
          GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE, 0, FILE_CREATE,
          FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
              FILE_WRITE_THROUGH,
          FILE_ATTRIBUTE_HIDDEN);
      try {
        WriteWindowsTransactionLockBinding(candidate.get(),
                                           paths.transaction_id);
        RenameHandleRelative(candidate.get(), parent, paths.lock_name, false);
        FlushPersistentMetadata(parent);
        return {ExactLockObservation::State::kAcquired, std::move(candidate),
                true};
      } catch (...) {
        if (candidate.valid()) {
          try {
            DeleteHandleExact(candidate.get());
            candidate.reset();
            FlushPersistentMetadata(parent);
          } catch (...) {
            candidate.reset();
          }
        }
        throw;
      }
    } catch (const WindowsTransactionJournalError& error) {
      if (error.code() ==
          WindowsTransactionJournalError::Code::kSharingViolation) {
        return {ExactLockObservation::State::kLiveOwner, UniqueWindowsHandle(),
                false};
      }
      // A competing helper may have published the target-wide stable lock.
      // Re-open and classify it below without replacing it.
    }
  }
  try {
    UniqueWindowsHandle lock = OpenRelativeNoReparse(
        parent, paths.lock_name,
        GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE, 0, FILE_OPEN,
        FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
            FILE_WRITE_THROUGH);
    switch (ClassifyWindowsTransactionLockBinding(lock.get(),
                                                  paths.transaction_id)) {
      case WindowsTransactionLockBindingState::kExact:
        return {ExactLockObservation::State::kAcquired, std::move(lock), false};
      case WindowsTransactionLockBindingState::kForeign:
        return {ExactLockObservation::State::kForeign, std::move(lock), false};
      case WindowsTransactionLockBindingState::kMalformed:
        return {ExactLockObservation::State::kMalformed, std::move(lock),
                false};
    }
    return {ExactLockObservation::State::kMalformed, std::move(lock), false};
  } catch (const WindowsTransactionJournalError& error) {
    if (error.code() ==
        WindowsTransactionJournalError::Code::kSharingViolation) {
      return {ExactLockObservation::State::kLiveOwner, UniqueWindowsHandle(),
              false};
    }
    return {ExactLockObservation::State::kMalformed, UniqueWindowsHandle(),
            false};
  }
}

}  // namespace

std::string WindowsPersistentTransactionRecord::EncodeCanonical() const {
  if (schema_version != kSchemaVersion ||
      !std::regex_match(transaction_id, kTransactionId) || policy_id.empty() ||
      package_id.empty() ||
      !std::regex_match(helper_endpoint_identity_sha256, kSha256) ||
      executor_process_id <= 0 ||
      executor_process_id > std::numeric_limits<DWORD>::max() ||
      executor_process_start_identity <= 0 || caller_process_id <= 0 ||
      caller_process_id > std::numeric_limits<DWORD>::max() ||
      caller_process_start_identity <= 0 ||
      !IsRecoveryReadyNonce(recovery_ready_nonce) ||
      !target_path_hint.is_absolute() ||
      target_path_hint.lexically_normal() != target_path_hint ||
      target_path_hint.filename().empty() ||
      kRecordStates.count(record_state) == 0 ||
      kRelaunchStates.count(relaunch_state) == 0 ||
      !std::regex_match(journal_sha256, kSha256)) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction record is invalid");
  }
  const bool completed =
      record_state == "completed" || record_state == "completedCleanupPending";
  const bool rolled_back = record_state == "rolledBack" ||
                           record_state == "rolledBackCleanupPending";
  if ((completed && verified_outcome != "newTarget") ||
      (rolled_back && verified_outcome != "oldTarget") ||
      (!completed && !rolled_back && verified_outcome != "none")) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction outcome binding is invalid");
  }
  const bool terminal = record_state == "completed" ||
                        record_state == "rolledBack";
  const bool commit_requires_relaunch =
      record_state == "commitAccepted" ||
      record_state == "completedCleanupPending" ||
      record_state == "completed";
  const bool attempt_has_started =
      relaunch_state == "launchAttempting" || relaunch_state == "launched" ||
      relaunch_state == "launchFailed";
  if ((commit_requires_relaunch && relaunch_state == "notRequested") ||
      (attempt_has_started && !terminal) ||
      (!terminal && relaunch_state != "notRequested" &&
       relaunch_state != "launchPending")) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction relaunch binding is invalid");
  }
  if (journal_canonical.empty()) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction journal binding is missing");
  }
  const WindowsTransactionJournal journal =
      WindowsTransactionJournal::DecodeStrict(journal_canonical);
  if (journal.transaction_id != transaction_id ||
      journal.owner_process_id != static_cast<DWORD>(executor_process_id) ||
      journal.owner_process_start_identity !=
          static_cast<std::uint64_t>(executor_process_start_identity) ||
      journal.target_name != target_path_hint.filename().wstring() ||
      WindowsHelperSha256Hex(journal_canonical) != journal_sha256) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction journal binding is invalid");
  }
  JsonValue::Object object;
  object.emplace("helperEndpointIdentitySha256",
                 JsonValue(helper_endpoint_identity_sha256));
  object.emplace("executorProcessId", JsonValue(executor_process_id));
  object.emplace("executorProcessStartIdentity",
                 JsonValue(executor_process_start_identity));
  object.emplace("callerProcessId", JsonValue(caller_process_id));
  object.emplace("callerProcessStartIdentity",
                 JsonValue(caller_process_start_identity));
  object.emplace("recoveryReadyNonce", JsonValue(recovery_ready_nonce));
  object.emplace("journalCanonical", JsonValue(journal_canonical));
  object.emplace("journalSha256", JsonValue(journal_sha256));
  object.emplace("packageId", JsonValue(package_id));
  object.emplace("policyId", JsonValue(policy_id));
  object.emplace("recordState", JsonValue(record_state));
  object.emplace("relaunchState", JsonValue(relaunch_state));
  object.emplace("schemaVersion", JsonValue(schema_version));
  object.emplace("targetPathHint",
                 JsonValue(WideToUtf8(target_path_hint.wstring())));
  object.emplace("transactionId", JsonValue(transaction_id));
  object.emplace("verifiedOutcome", JsonValue(verified_outcome));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

WindowsPersistentTransactionRecord
WindowsPersistentTransactionRecord::DecodeStrict(
    const std::string& canonical_json) {
  if (canonical_json.empty() ||
      canonical_json.size() > kMaximumPersistentRecordBytes) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction record length is invalid");
  }
  try {
    const JsonValue value = ParseJson(canonical_json);
    if (EncodeCanonicalJson(value) != canonical_json) {
      throw WindowsPersistentRecoveryError(
          "persistent transaction record is not canonical JSON");
    }
    RequireExactKeys(
        value,
        {"callerProcessId", "callerProcessStartIdentity", "executorProcessId",
         "executorProcessStartIdentity", "helperEndpointIdentitySha256",
         "journalCanonical", "journalSha256", "packageId", "policyId",
         "recordState", "recoveryReadyNonce", "relaunchState",
         "schemaVersion", "targetPathHint", "transactionId",
         "verifiedOutcome"});
    WindowsPersistentTransactionRecord record;
    record.schema_version = value.at("schemaVersion").integer();
    record.transaction_id = value.at("transactionId").string();
    record.policy_id = value.at("policyId").string();
    record.package_id = value.at("packageId").string();
    record.helper_endpoint_identity_sha256 =
        value.at("helperEndpointIdentitySha256").string();
    record.executor_process_id = value.at("executorProcessId").integer();
    record.executor_process_start_identity =
        value.at("executorProcessStartIdentity").integer();
    record.caller_process_id = value.at("callerProcessId").integer();
    record.caller_process_start_identity =
        value.at("callerProcessStartIdentity").integer();
    record.recovery_ready_nonce = value.at("recoveryReadyNonce").string();
    record.target_path_hint =
        CanonicalAbsolutePath(value.at("targetPathHint").string());
    record.record_state = value.at("recordState").string();
    record.verified_outcome = value.at("verifiedOutcome").string();
    record.relaunch_state = value.at("relaunchState").string();
    record.journal_canonical = value.at("journalCanonical").string();
    record.journal_sha256 = value.at("journalSha256").string();
    if (record.EncodeCanonical() != canonical_json) {
      throw WindowsPersistentRecoveryError(
          "persistent transaction record encoding changed");
    }
    return record;
  } catch (const WindowsPersistentRecoveryError&) {
    throw;
  } catch (const std::exception&) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction record is corrupt");
  }
}

bool WindowsPersistentResolverClaim::operator==(
    const WindowsPersistentResolverClaim& other) const {
  return schema_version == other.schema_version &&
         transaction_id == other.transaction_id &&
         resolver_process_id == other.resolver_process_id &&
         resolver_process_start_identity ==
             other.resolver_process_start_identity &&
         caller_process_id == other.caller_process_id &&
         caller_process_start_identity == other.caller_process_start_identity &&
         claim_nonce == other.claim_nonce && state == other.state;
}

std::string WindowsPersistentResolverClaim::EncodeCanonical() const {
  if (schema_version != kSchemaVersion ||
      !std::regex_match(transaction_id, kTransactionId) ||
      resolver_process_id <= 0 ||
      resolver_process_id > std::numeric_limits<DWORD>::max() ||
      resolver_process_start_identity <= 0 || caller_process_id <= 0 ||
      caller_process_id > std::numeric_limits<DWORD>::max() ||
      caller_process_start_identity <= 0 ||
      !IsRecoveryReadyNonce(claim_nonce) ||
      kResolverClaimStates.count(state) == 0) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver claim is invalid");
  }
  JsonValue::Object object;
  object.emplace("callerProcessId", JsonValue(caller_process_id));
  object.emplace("callerProcessStartIdentity",
                 JsonValue(caller_process_start_identity));
  object.emplace("claimNonce", JsonValue(claim_nonce));
  object.emplace("resolverProcessId", JsonValue(resolver_process_id));
  object.emplace("resolverProcessStartIdentity",
                 JsonValue(resolver_process_start_identity));
  object.emplace("schemaVersion", JsonValue(schema_version));
  object.emplace("state", JsonValue(state));
  object.emplace("transactionId", JsonValue(transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

WindowsPersistentResolverClaim WindowsPersistentResolverClaim::DecodeStrict(
    const std::string& canonical_json) {
  if (canonical_json.empty() ||
      canonical_json.size() > kMaximumPersistentResolverClaimBytes) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver claim length is invalid");
  }
  try {
    const JsonValue value = ParseJson(canonical_json);
    if (EncodeCanonicalJson(value) != canonical_json) {
      throw WindowsPersistentRecoveryError(
          "persistent resolver claim is not canonical JSON");
    }
    RequireExactKeys(
        value, {"callerProcessId", "callerProcessStartIdentity", "claimNonce",
                "resolverProcessId", "resolverProcessStartIdentity",
                "schemaVersion", "state", "transactionId"});
    WindowsPersistentResolverClaim claim;
    claim.schema_version = value.at("schemaVersion").integer();
    claim.transaction_id = value.at("transactionId").string();
    claim.resolver_process_id = value.at("resolverProcessId").integer();
    claim.resolver_process_start_identity =
        value.at("resolverProcessStartIdentity").integer();
    claim.caller_process_id = value.at("callerProcessId").integer();
    claim.caller_process_start_identity =
        value.at("callerProcessStartIdentity").integer();
    claim.claim_nonce = value.at("claimNonce").string();
    claim.state = value.at("state").string();
    if (claim.EncodeCanonical() != canonical_json) {
      throw WindowsPersistentRecoveryError(
          "persistent resolver claim encoding changed");
    }
    return claim;
  } catch (const WindowsPersistentRecoveryError&) {
    throw;
  } catch (const std::exception&) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver claim is corrupt");
  }
}

WindowsResolverClaimDecision DecideWindowsResolverClaim(
    const std::optional<WindowsPersistentResolverClaim>& existing,
    const WindowsPersistentResolverClaim& candidate,
    bool existing_owner_alive) {
  (void)candidate.EncodeCanonical();
  if (!existing.has_value()) return WindowsResolverClaimDecision::kOwn;
  (void)existing->EncodeCanonical();
  if (existing->transaction_id != candidate.transaction_id) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver claim transaction changed");
  }
  if (existing->state == "consumed") {
    return WindowsResolverClaimDecision::kConsumed;
  }
  if (*existing == candidate) return WindowsResolverClaimDecision::kOwn;
  return existing_owner_alive ? WindowsResolverClaimDecision::kFollow
                              : WindowsResolverClaimDecision::kOwn;
}

WindowsAtMostOnceRelaunchOutcome RunWindowsAtMostOnceRelaunch(
    std::function<bool()> consume_attempt_claim,
    std::function<void()> persist_attempting,
    std::function<void()> launch,
    std::function<void(bool)> persist_outcome) {
  if (!consume_attempt_claim || !persist_attempting || !launch ||
      !persist_outcome) {
    throw WindowsPersistentRecoveryError(
        "at-most-once relaunch dependency is unavailable");
  }
  if (!consume_attempt_claim()) {
    return WindowsAtMostOnceRelaunchOutcome::kNotOwned;
  }
  // Claim consumption is the at-most-once boundary. Persist the visible
  // launch-attempt state before invoking the OS launcher so a crash can never
  // be reinterpreted as a successful or retryable relaunch.
  persist_attempting();
  try {
    launch();
  } catch (const std::exception&) {
    persist_outcome(false);
    return WindowsAtMostOnceRelaunchOutcome::kFailed;
  }
  // A launcher return is not reported as success until that fact is durable.
  persist_outcome(true);
  return WindowsAtMostOnceRelaunchOutcome::kLaunched;
}

WindowsTerminalRelaunchDecision DecideWindowsTerminalRelaunch(
    const std::string& relaunch_state) {
  if (relaunch_state == "notRequested") {
    return WindowsTerminalRelaunchDecision::kNotRequested;
  }
  if (relaunch_state == "launchPending") {
    return WindowsTerminalRelaunchDecision::kAttempt;
  }
  if (relaunch_state == "launched") {
    return WindowsTerminalRelaunchDecision::kAlreadyLaunched;
  }
  if (relaunch_state == "launchAttempting" ||
      relaunch_state == "launchFailed") {
    return WindowsTerminalRelaunchDecision::kFailClosed;
  }
  throw WindowsPersistentRecoveryError(
      "persistent terminal relaunch state is invalid");
}

desktop_updater::runtime::internal::NativeInstallTransactionStatusV1
StatusFromWindowsPersistentTerminalRecord(
    const WindowsPersistentTransactionRecord& record) {
  (void)record.EncodeCanonical();
  const bool completed = record.record_state == "completed";
  const bool rolled_back = record.record_state == "rolledBack";
  if (!completed && !rolled_back) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction is not terminal");
  }
  const bool relaunch_confirmed = record.relaunch_state == "launched";
  const bool relaunch_not_requested =
      record.relaunch_state == "notRequested";
  return {1,
          record.transaction_id,
          completed ? "completed" : "rolledBack",
          relaunch_confirmed || relaunch_not_requested
              ? (completed ? "completed" : "rolledBack")
              : "relaunchFailure",
          record.journal_sha256};
}

WindowsResolveAfterExitCoordination CoordinateWindowsResolveAfterExit(
    std::function<WindowsPersistentRecoveryAttempt()> attempt_recovery,
    std::function<bool()> wait_for_exact_owner,
    std::function<bool()> consume_relaunch_claim) {
  if (!attempt_recovery || !wait_for_exact_owner || !consume_relaunch_claim) {
    throw WindowsPersistentRecoveryError(
        "pending recovery coordination dependency is unavailable");
  }
  WindowsPersistentRecoveryAttempt attempt = attempt_recovery();
  while (attempt.exact_owner_active) {
    if (attempt.recovery.result_code != "recoveryRequired") {
      throw WindowsPersistentRecoveryError(
          "active recovery owner returned a terminal result");
    }
    if (!wait_for_exact_owner()) {
      return {attempt.recovery, false};
    }
    attempt = attempt_recovery();
  }
  const bool relaunchable =
      (attempt.recovery.result_code == "completed" &&
       attempt.recovery.verified_outcome == "newTarget") ||
      (attempt.recovery.result_code == "rolledBack" &&
       attempt.recovery.verified_outcome == "oldTarget");
  return {attempt.recovery, relaunchable && consume_relaunch_claim()};
}

WindowsAutonomousRecoveryAuthorityDecision
DecideWindowsAutonomousRecoveryAuthority(bool portable_policy,
                                         bool local_system,
                                         bool elevated,
                                         bool stable_host_verified) {
  if (portable_policy) {
    return !local_system && !elevated && stable_host_verified
               ? WindowsAutonomousRecoveryAuthorityDecision::
                     kPortableStableUser
               : WindowsAutonomousRecoveryAuthorityDecision::kReject;
  }
  return local_system && !stable_host_verified
             ? WindowsAutonomousRecoveryAuthorityDecision::kProtectedSystem
             : WindowsAutonomousRecoveryAuthorityDecision::kReject;
}

WindowsPersistentTransactionIndex::WindowsPersistentTransactionIndex(
    const WindowsHelperPolicy& policy, HANDLE caller_process,
    bool create_if_missing)
    : caller_process_(caller_process),
      portable_(policy.is_portable()),
      policy_id_(policy.policy_id()),
      package_id_(policy.application_package_id()),
      helper_endpoint_identity_sha256_(policy.helper_sha256()) {
  try {
    if (portable_) {
      portable_store_ = std::make_unique<WindowsPortableTransactionStore>(
          policy, caller_process, create_if_missing);
    } else {
      key_ = OpenPersistentIndexKey(policy, caller_process, create_if_missing);
    }
  } catch (...) {
    if (portable_) {
      RecordWindowsHelperEvent(
          WindowsHelperEvent::kPortableRecoveryStorageFailure);
    }
    throw;
  }
}

WindowsPersistentTransactionIndex::~WindowsPersistentTransactionIndex() {
  if (key_ != nullptr) RegCloseKey(key_);
}

void WindowsPersistentTransactionIndex::PersistPreparing(
    const std::string& transaction_id, const std::filesystem::path& target_path,
    const std::string& journal_canonical, DWORD executor_process_id,
    std::uint64_t executor_process_start_identity, DWORD caller_process_id,
    std::uint64_t caller_process_start_identity,
    const std::string& recovery_ready_nonce) {
  RequireTransactionId(transaction_id);
  if (executor_process_id == 0 || executor_process_start_identity == 0 ||
      executor_process_start_identity >
          static_cast<std::uint64_t>(
              std::numeric_limits<std::int64_t>::max()) ||
      caller_process_id == 0 || caller_process_start_identity == 0 ||
      caller_process_start_identity >
          static_cast<std::uint64_t>(
              std::numeric_limits<std::int64_t>::max()) ||
      !IsRecoveryReadyNonce(recovery_ready_nonce)) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction process identities are invalid");
  }
  PersistNew(
      {WindowsPersistentTransactionRecord::kSchemaVersion, transaction_id,
       policy_id_, package_id_, helper_endpoint_identity_sha256_,
       static_cast<std::int64_t>(executor_process_id),
       static_cast<std::int64_t>(executor_process_start_identity),
       static_cast<std::int64_t>(caller_process_id),
       static_cast<std::int64_t>(caller_process_start_identity),
       recovery_ready_nonce,
       std::filesystem::absolute(target_path).lexically_normal(), "preparing",
       "none", "notRequested", journal_canonical,
       WindowsHelperSha256Hex(journal_canonical)});
}

void WindowsPersistentTransactionIndex::PersistActive(
    const std::string& transaction_id, const std::string& journal_canonical) {
  auto record = Load(transaction_id);
  if (!record.has_value() || record->record_state != "preparing") {
    throw WindowsPersistentRecoveryError(
        "persistent transaction is not preparing");
  }
  if (record->journal_canonical != journal_canonical ||
      record->journal_sha256 != WindowsHelperSha256Hex(journal_canonical)) {
    throw WindowsPersistentRecoveryError(
        "persistent prepared journal binding changed");
  }
  record->record_state = "prepared";
  Persist(*record);
}

void WindowsPersistentTransactionIndex::MarkCommitAccepted(
    const std::string& transaction_id) {
  auto record = Load(transaction_id);
  if (!record.has_value() || record->record_state != "prepared" ||
      record->journal_canonical.empty()) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction is not prepared");
  }
  record->record_state = "commitAccepted";
  record->relaunch_state = "launchPending";
  Persist(*record);
}

void WindowsPersistentTransactionIndex::MarkCancelling(
    const std::string& transaction_id) {
  auto record = Load(transaction_id);
  if (record.has_value() && record->record_state == "cancelling") {
    return;
  }
  if (!record.has_value() || (record->record_state != "preparing" &&
                              record->record_state != "prepared" &&
                              record->record_state != "commitAccepted")) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction is not cancellable");
  }
  record->record_state = "cancelling";
  Persist(*record);
}

void WindowsPersistentTransactionIndex::MarkRelaunchPending(
    const std::string& transaction_id) {
  auto record = Load(transaction_id);
  if (!record.has_value() ||
      record->record_state == "manualActionRequired") {
    throw WindowsPersistentRecoveryError(
        "persistent transaction cannot request relaunch");
  }
  if (record->relaunch_state == "launchPending") return;
  if (record->relaunch_state != "notRequested") {
    throw WindowsPersistentRecoveryError(
        "persistent transaction relaunch is already decided");
  }
  record->relaunch_state = "launchPending";
  Persist(*record);
}

void WindowsPersistentTransactionIndex::MarkRelaunchAttempting(
    const std::string& transaction_id) {
  auto record = Load(transaction_id);
  if (!record.has_value() ||
      (record->record_state != "completed" &&
       record->record_state != "rolledBack")) {
    throw WindowsPersistentRecoveryError(
        "persistent relaunch requires a terminal install outcome");
  }
  if (record->relaunch_state == "launchAttempting") return;
  if (record->relaunch_state != "launchPending") {
    throw WindowsPersistentRecoveryError(
        "persistent relaunch attempt transition is invalid");
  }
  record->relaunch_state = "launchAttempting";
  Persist(*record);
}

void WindowsPersistentTransactionIndex::PersistRelaunchOutcome(
    const std::string& transaction_id, bool launched) {
  auto record = Load(transaction_id);
  if (!record.has_value() ||
      (record->record_state != "completed" &&
       record->record_state != "rolledBack")) {
    throw WindowsPersistentRecoveryError(
        "persistent relaunch outcome requires a terminal install outcome");
  }
  const std::string state = launched ? "launched" : "launchFailed";
  if (record->relaunch_state == state) return;
  if (record->relaunch_state != "launchAttempting") {
    throw WindowsPersistentRecoveryError(
        "persistent relaunch outcome transition is invalid");
  }
  record->relaunch_state = state;
  Persist(*record);
}

void WindowsPersistentTransactionIndex::PersistCleanupPending(
    const std::string& transaction_id, const std::string& state,
    const std::string& verified_outcome) {
  if ((state != "completedCleanupPending" &&
       state != "rolledBackCleanupPending") ||
      (state == "completedCleanupPending" && verified_outcome != "newTarget") ||
      (state == "rolledBackCleanupPending" &&
       verified_outcome != "oldTarget")) {
    throw WindowsPersistentRecoveryError(
        "persistent cleanup-pending state is invalid");
  }
  auto record = Load(transaction_id);
  if (!record.has_value()) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction is unavailable");
  }
  if (record->record_state == state &&
      record->verified_outcome == verified_outcome) {
    return;
  }
  if ((state == "completedCleanupPending" &&
       record->record_state != "commitAccepted") ||
      (state == "rolledBackCleanupPending" &&
       record->record_state != "cancelling")) {
    throw WindowsPersistentRecoveryError(
        "persistent cleanup-pending transition is invalid");
  }
  record->record_state = state;
  record->verified_outcome = verified_outcome;
  Persist(*record);
}

void WindowsPersistentTransactionIndex::PersistTerminal(
    const std::string& transaction_id, const std::string& state,
    const std::string& verified_outcome) {
  if ((state != "completed" && state != "rolledBack" &&
       state != "manualActionRequired") ||
      (state == "completed" && verified_outcome != "newTarget") ||
      (state == "rolledBack" && verified_outcome != "oldTarget") ||
      (state == "manualActionRequired" && verified_outcome != "none")) {
    throw WindowsPersistentRecoveryError(
        "persistent terminal state is invalid");
  }
  auto record = Load(transaction_id);
  if (!record.has_value()) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction is unavailable");
  }
  if (record->record_state == "completed" ||
      record->record_state == "rolledBack" ||
      record->record_state == "manualActionRequired") {
    if (record->record_state == state &&
        record->verified_outcome == verified_outcome) {
      return;
    }
    throw WindowsPersistentRecoveryError(
        "persistent terminal state is immutable");
  }
  if ((state == "completed" &&
       record->record_state != "completedCleanupPending") ||
      (state == "rolledBack" &&
       record->record_state != "rolledBackCleanupPending")) {
    throw WindowsPersistentRecoveryError(
        "persistent terminal transition is invalid");
  }
  record->record_state = state;
  record->verified_outcome = verified_outcome;
  Persist(*record);
}

std::optional<WindowsPersistentTransactionRecord>
WindowsPersistentTransactionIndex::Load(
    const std::string& transaction_id) const {
  RequireTransactionId(transaction_id);
  std::string bytes;
  if (portable_) {
    if (portable_store_ == nullptr) return std::nullopt;
    const auto record = portable_store_->ReadRecord(transaction_id);
    if (!record.has_value()) return std::nullopt;
    bytes = *record;
  } else {
    if (key_ == nullptr) return std::nullopt;
    auto transaction_key = OpenPersistentTransactionKey(
        key_, transaction_id, caller_process_, KEY_QUERY_VALUE);
    if (!transaction_key.has_value()) return std::nullopt;
    DWORD type = 0;
    DWORD size = 0;
    LSTATUS status =
        RegQueryValueExW(transaction_key->get(), kPersistentRecordValueName,
                         nullptr, &type, nullptr, &size);
    if (status != ERROR_SUCCESS || type != REG_BINARY || size == 0 ||
        size > kMaximumPersistentRecordBytes) {
      throw WindowsPersistentRecoveryError(
          "persistent transaction index value is invalid");
    }
    bytes.assign(size, '\0');
    DWORD received = size;
    status = RegQueryValueExW(
        transaction_key->get(), kPersistentRecordValueName, nullptr, &type,
        reinterpret_cast<BYTE*>(bytes.data()), &received);
    if (status != ERROR_SUCCESS || type != REG_BINARY || received != size) {
      throw WindowsPersistentRecoveryError(
          "persistent transaction index read failed");
    }
  }
  const WindowsPersistentTransactionRecord record =
      WindowsPersistentTransactionRecord::DecodeStrict(bytes);
  if (record.transaction_id != transaction_id ||
      record.policy_id != policy_id_ || record.package_id != package_id_) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction index binding changed");
  }
  if (record.helper_endpoint_identity_sha256 !=
      helper_endpoint_identity_sha256_) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction helper endpoint binding changed");
  }
  return record;
}

WindowsResolverClaimDecision WindowsPersistentTransactionIndex::ClaimResolver(
    const WindowsPersistentResolverClaim& candidate) {
  (void)candidate.EncodeCanonical();
  const auto initial_record = Load(candidate.transaction_id);
  if (!initial_record.has_value()) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver transaction is unavailable");
  }
  ScopedResolverClaimMutex mutex(*initial_record, portable_);
  const auto current_record = Load(candidate.transaction_id);
  if (!current_record.has_value() || current_record->recovery_ready_nonce !=
                                         initial_record->recovery_ready_nonce) {
    throw WindowsPersistentRecoveryError(
        "persistent resolver transaction binding changed");
  }
  std::optional<ScopedRegistryKey> transaction_key;
  std::optional<WindowsPersistentResolverClaim> existing;
  if (portable_) {
    const auto encoded =
        portable_store_->ReadResolverClaim(candidate.transaction_id);
    if (encoded.has_value()) {
      existing = WindowsPersistentResolverClaim::DecodeStrict(*encoded);
      if (existing->transaction_id != candidate.transaction_id) {
        throw WindowsPersistentRecoveryError(
            "persistent resolver claim binding changed");
      }
    }
  } else {
    transaction_key = OpenPersistentTransactionKey(
        key_, candidate.transaction_id, caller_process_,
        KEY_QUERY_VALUE | KEY_SET_VALUE);
    if (!transaction_key.has_value()) {
      throw WindowsPersistentRecoveryError(
          "persistent resolver transaction claim is unavailable");
    }
    existing = ReadPersistentResolverClaim(transaction_key->get(),
                                           candidate.transaction_id);
  }
  bool existing_owner_alive = false;
  if (existing.has_value() && existing->state == "claimed" &&
      !(*existing == candidate)) {
    existing_owner_alive = ResolverClaimOwnerAlive(*existing);
  }
  const WindowsResolverClaimDecision decision =
      DecideWindowsResolverClaim(existing, candidate, existing_owner_alive);
  if (decision == WindowsResolverClaimDecision::kOwn &&
      (!existing.has_value() || !(*existing == candidate))) {
    if (portable_) {
      portable_store_->WriteResolverClaim(candidate.transaction_id,
                                          candidate.EncodeCanonical());
    } else {
      WritePersistentResolverClaim(transaction_key->get(), candidate);
    }
  }
  return decision;
}

bool WindowsPersistentTransactionIndex::ConsumeResolverClaim(
    const WindowsPersistentResolverClaim& candidate) {
  (void)candidate.EncodeCanonical();
  const auto initial_record = Load(candidate.transaction_id);
  if (!initial_record.has_value()) return false;
  ScopedResolverClaimMutex mutex(*initial_record, portable_);
  const auto current_record = Load(candidate.transaction_id);
  if (!current_record.has_value() || current_record->recovery_ready_nonce !=
                                         initial_record->recovery_ready_nonce) {
    return false;
  }
  std::optional<ScopedRegistryKey> transaction_key;
  std::optional<WindowsPersistentResolverClaim> existing;
  if (portable_) {
    const auto encoded =
        portable_store_->ReadResolverClaim(candidate.transaction_id);
    if (encoded.has_value()) {
      existing = WindowsPersistentResolverClaim::DecodeStrict(*encoded);
      if (existing->transaction_id != candidate.transaction_id) return false;
    }
  } else {
    transaction_key = OpenPersistentTransactionKey(
        key_, candidate.transaction_id, caller_process_,
        KEY_QUERY_VALUE | KEY_SET_VALUE);
    if (!transaction_key.has_value()) return false;
    existing = ReadPersistentResolverClaim(transaction_key->get(),
                                           candidate.transaction_id);
  }
  if (!existing.has_value() || !(*existing == candidate) ||
      existing->state != "claimed") {
    return false;
  }
  WindowsPersistentResolverClaim consumed = candidate;
  consumed.state = "consumed";
  if (portable_) {
    portable_store_->WriteResolverClaim(candidate.transaction_id,
                                        consumed.EncodeCanonical());
  } else {
    WritePersistentResolverClaim(transaction_key->get(), consumed);
  }
  return true;
}

void WindowsPersistentTransactionIndex::PersistNew(
    const WindowsPersistentTransactionRecord& record) {
  RequireTransactionId(record.transaction_id);
  if (portable_) {
    if (portable_store_ == nullptr) {
      throw WindowsPersistentRecoveryError(
          "portable persistent transaction index is unavailable");
    }
    portable_store_->CreateRecord(record.transaction_id,
                                  record.EncodeCanonical());
    return;
  }
  if (key_ == nullptr) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction index is unavailable");
  }
  ScopedRegistryKey transaction_key(CreatePersistentTransactionKey(
      key_, record.transaction_id, caller_process_));
  WritePersistentRecord(transaction_key.get(), record);
  if (RegFlushKey(key_) != ERROR_SUCCESS) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction claim flush failed");
  }
}

void WindowsPersistentTransactionIndex::Persist(
    const WindowsPersistentTransactionRecord& record) {
  if (portable_) {
    if (portable_store_ == nullptr) {
      throw WindowsPersistentRecoveryError(
          "portable persistent transaction index is unavailable");
    }
    portable_store_->WriteRecord(record.transaction_id,
                                 record.EncodeCanonical());
    return;
  }
  if (key_ == nullptr) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction index is unavailable");
  }
  auto transaction_key =
      OpenPersistentTransactionKey(key_, record.transaction_id, caller_process_,
                                   KEY_QUERY_VALUE | KEY_SET_VALUE);
  if (!transaction_key.has_value()) {
    throw WindowsPersistentRecoveryError(
        "persistent transaction claim is unavailable");
  }
  WritePersistentRecord(transaction_key->get(), record);
}

WindowsPersistentRecoveryService::WindowsPersistentRecoveryService(
    const WindowsHelperPolicy& policy, HANDLE caller_process)
    : policy_(policy), caller_process_(caller_process) {}

WindowsPersistentRecoveryService::WindowsPersistentRecoveryService(
    const WindowsHelperPolicy& policy)
    : policy_(policy), caller_process_(nullptr) {}

void WindowsPersistentRecoveryService::AuthenticateCaller() const {
  if (caller_process_ == nullptr) {
    throw WindowsPersistentRecoveryError("recovery caller process is invalid");
  }
  const std::filesystem::path executable =
      ProcessExecutablePath(caller_process_);
  const VerifiedWindowsExecutable identity =
      VerifyWindowsExecutable(executable);
  if (!ApplicationIdentityMatchesPolicy(identity, policy_) ||
      !VerifyWindowsExecutableStillMatches(executable, identity)) {
    throw WindowsPersistentRecoveryError(
        "recovery caller Authenticode identity is rejected");
  }
}

void WindowsPersistentRecoveryService::AuthenticateAutonomousHost() const {
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
    throw WindowsPersistentRecoveryError(
        "autonomous recovery process token is unavailable");
  }
  UniqueWindowsHandle token(raw_token);
  DWORD size = 0;
  (void)GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
  if (size == 0 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
    throw WindowsPersistentRecoveryError(
        "autonomous recovery process identity is unavailable");
  }
  std::vector<unsigned char> token_user(size);
  if (!GetTokenInformation(token.get(), TokenUser, token_user.data(), size,
                           &size)) {
    throw WindowsPersistentRecoveryError(
        "autonomous recovery process identity is unavailable");
  }
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> system_sid{};
  DWORD system_sid_size = static_cast<DWORD>(system_sid.size());
  const auto* user = reinterpret_cast<const TOKEN_USER*>(token_user.data());
  if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid.data(),
                          &system_sid_size) ||
      user->User.Sid == nullptr) {
    throw WindowsPersistentRecoveryError(
        "autonomous recovery process identity is unavailable");
  }
  TOKEN_ELEVATION elevation{};
  size = 0;
  if (!GetTokenInformation(token.get(), TokenElevation, &elevation,
                           sizeof(elevation), &size)) {
    throw WindowsPersistentRecoveryError(
        "autonomous recovery elevation state is unavailable");
  }
  const bool local_system = EqualSid(user->User.Sid, system_sid.data());
  const bool elevated = elevation.TokenIsElevated != 0;
  if (policy_.is_portable()) {
    ValidateCurrentPortableWindowsRecoveryHost(policy_);
    if (DecideWindowsAutonomousRecoveryAuthority(
            true, local_system, elevated, true) !=
        WindowsAutonomousRecoveryAuthorityDecision::kPortableStableUser) {
      throw WindowsPersistentRecoveryError(
          "portable autonomous recovery host authority is rejected");
    }
    return;
  }
  if (DecideWindowsAutonomousRecoveryAuthority(
          false, local_system, elevated, false) !=
      WindowsAutonomousRecoveryAuthorityDecision::kProtectedSystem) {
    throw WindowsPersistentRecoveryError(
        "protected autonomous recovery requires LocalSystem");
  }
  const std::filesystem::path executable =
      ProcessExecutablePath(GetCurrentProcess());
  const VerifiedWindowsExecutable identity =
      VerifyWindowsExecutable(executable);
  ValidateWindowsHelperIdentity(identity, policy_, true);
  if (!VerifyWindowsExecutableStillMatches(executable, identity)) {
    throw WindowsPersistentRecoveryError(
        "autonomous recovery helper identity changed");
  }
}

void WindowsPersistentRecoveryService::AuthenticateCallerForRecord(
    const WindowsPersistentTransactionRecord& record) const {
  const std::filesystem::path caller_path =
      ProcessExecutablePath(caller_process_);
  const VerifiedWindowsExecutable identity =
      VerifyWindowsExecutable(caller_path);
  const bool still_matches =
      VerifyWindowsExecutableStillMatches(caller_path, identity);
  if (policy_.is_portable()) {
    if (DecideWindowsPortableTransactionCallerAuthority(
            policy_, record.transaction_id, record.EncodeCanonical(),
            identity, caller_path, still_matches) ==
        WindowsPortableTransactionResolution::kReject) {
      throw WindowsPersistentRecoveryError(
          "portable recovery caller is not a frozen transaction generation");
    }
    return;
  }
  const WindowsTransactionJournal frozen =
      WindowsTransactionJournal::DecodeStrict(record.journal_canonical);
  const std::filesystem::path expected_path =
      record.target_path_hint /
      std::filesystem::path(
          frozen.expected_payload_identity.executable_relative_path);
  if (!ApplicationIdentityMatchesPolicy(identity, policy_) ||
      NormalizeComparablePath(identity.final_path) !=
          NormalizeComparablePath(expected_path) ||
      !still_matches) {
    throw WindowsPersistentRecoveryError(
        "recovery caller is not the transaction application");
  }
}

void WindowsPersistentRecoveryService::EnsureIndex() {
  if (index_ == nullptr) {
    index_ = std::make_unique<WindowsPersistentTransactionIndex>(
        policy_, caller_process_, false);
  }
}

desktop_updater::runtime::internal::NativeInstallTransactionStatusV1
WindowsPersistentRecoveryService::Query(const std::string& transaction_id) {
  RequireTransactionId(transaction_id);
  if (!policy_.is_portable()) AuthenticateCaller();
  try {
    EnsureIndex();
    const auto record = index_->Load(transaction_id);
    if (!record.has_value()) {
      return {1, transaction_id, "manualActionRequired", "helperUnavailable",
              std::string(64, '0')};
    }
    AuthenticateCallerForRecord(*record);
    if (record->record_state == "completed" ||
        record->record_state == "rolledBack") {
      return StatusFromWindowsPersistentTerminalRecord(*record);
    }
    if (record->record_state == "manualActionRequired") {
      return {1, transaction_id, "manualActionRequired", "manualActionRequired",
              record->journal_sha256};
    }
    if (record->record_state == "completedCleanupPending") {
      return {1, transaction_id, "targetActivated", "recoveryRequired",
              record->journal_sha256};
    }
    if (record->record_state == "rolledBackCleanupPending") {
      return {1, transaction_id, "prepared", "recoveryRequired",
              record->journal_sha256};
    }
    const auto journal = LoadCurrentJournal(*record);
    if (!journal.has_value()) {
      return {1, transaction_id, "prepared", "recoveryRequired",
              record->journal_sha256};
    }
    if (journal->state == WindowsTransactionState::kManualActionRequired) {
      return {1, transaction_id, "manualActionRequired", "manualActionRequired",
              record->journal_sha256};
    }
    return {1, transaction_id, JournalStateName(journal->state),
            "recoveryRequired", record->journal_sha256};
  } catch (const std::exception&) {
    return {1, transaction_id, "manualActionRequired", "journalCorrupt",
            std::string(64, '0')};
  }
}

desktop_updater::runtime::internal::NativeInstallTransactionStatusV1
WindowsPersistentRecoveryService::ResolvePendingInstallAfterCallerExit(
    const std::string& transaction_id,
    std::function<void(const desktop_updater::runtime::internal::
                           NativeInstallTransactionStatusV1&)>
        acknowledge,
    WindowsProcessLauncher& launcher) {
  if (!acknowledge) {
    throw WindowsPersistentRecoveryError(
        "pending recovery acknowledgement is unavailable");
  }

  auto status = Query(transaction_id);
  std::optional<WindowsPersistentTransactionRecord> frozen_record;
  std::optional<WindowsPersistentResolverClaim> resolver_claim;
  if (status.result_code == "recoveryRequired") {
    try {
      EnsureIndex();
      frozen_record = index_->Load(transaction_id);
      if (!frozen_record.has_value()) {
        status = {1, transaction_id, "manualActionRequired",
                  "helperUnavailable", std::string(64, '0')};
      } else {
        AuthenticateCallerForRecord(*frozen_record);
        // The app will exit after the acknowledgement. Make the absence of a
        // confirmed relaunch durable before that irreversible handoff.
        index_->MarkRelaunchPending(transaction_id);
        frozen_record = index_->Load(transaction_id);
        if (!frozen_record.has_value()) {
          throw WindowsPersistentRecoveryError(
              "pending recovery relaunch state is unavailable");
        }
        const DWORD resolver_process_id = GetCurrentProcessId();
        const DWORD caller_process_id = GetProcessId(caller_process_);
        const std::uint64_t resolver_process_start_identity =
            WindowsProcessStartIdentity(GetCurrentProcess());
        const std::uint64_t caller_process_start_identity =
            WindowsProcessStartIdentity(caller_process_);
        if (resolver_process_id == 0 || caller_process_id == 0 ||
            resolver_process_start_identity == 0 ||
            caller_process_start_identity == 0 ||
            resolver_process_start_identity >
                static_cast<std::uint64_t>(
                    std::numeric_limits<std::int64_t>::max()) ||
            caller_process_start_identity >
                static_cast<std::uint64_t>(
                    std::numeric_limits<std::int64_t>::max())) {
          throw WindowsPersistentRecoveryError(
              "pending recovery resolver identity is unavailable");
        }
        resolver_claim = WindowsPersistentResolverClaim{
            WindowsPersistentResolverClaim::kSchemaVersion,
            transaction_id,
            static_cast<std::int64_t>(resolver_process_id),
            static_cast<std::int64_t>(resolver_process_start_identity),
            static_cast<std::int64_t>(caller_process_id),
            static_cast<std::int64_t>(caller_process_start_identity),
            SecureWindowsReadyToken(),
            "claimed"};
        if (index_->ClaimResolver(*resolver_claim) ==
            WindowsResolverClaimDecision::kConsumed) {
          throw WindowsPersistentRecoveryError(
              "pending recovery relaunch claim is already consumed");
        }
      }
    } catch (const std::exception&) {
      frozen_record.reset();
      resolver_claim.reset();
      status = {1, transaction_id, "manualActionRequired", "journalCorrupt",
                std::string(64, '0')};
    }
  }

  // The authenticated status reaches the app before it exits. The server-side
  // acknowledgement callback owns the exact-process wait; re-checking here
  // prevents recovery if a future transport callback returns early.
  acknowledge(status);
  if (status.result_code != "recoveryRequired") return status;
  if (!frozen_record.has_value() || !resolver_claim.has_value() ||
      WaitForSingleObject(caller_process_, 0) != WAIT_OBJECT_0) {
    throw WindowsPersistentRecoveryError(
        "pending recovery caller did not exit after acknowledgement");
  }

  // The process is gone, so subsequent protected-registry and uninstall-record
  // proofs must use trusted-host validation rather than its now-dead token.
  index_ = std::make_unique<WindowsPersistentTransactionIndex>(policy_, nullptr,
                                                               false);
  const ULONGLONG owner_wait_started = GetTickCount64();
  const WindowsResolveAfterExitCoordination coordinated =
      CoordinateWindowsResolveAfterExit(
          [this, &transaction_id]() {
            bool exact_owner_active = false;
            auto recovery = RecoverBound(transaction_id, false, nullptr,
                                         &exact_owner_active);
            return WindowsPersistentRecoveryAttempt{std::move(recovery),
                                                    exact_owner_active};
          },
          [owner_wait_started]() {
            const ULONGLONG elapsed = GetTickCount64() - owner_wait_started;
            if (elapsed >= kConcurrentRecoveryOwnerTimeoutMilliseconds) {
              return false;
            }
            const ULONGLONG remaining =
                kConcurrentRecoveryOwnerTimeoutMilliseconds - elapsed;
            Sleep(static_cast<DWORD>(std::min<ULONGLONG>(
                remaining, kConcurrentRecoveryOwnerPollMilliseconds)));
            return true;
          },
          [this, &resolver_claim]() {
            if (index_->ClaimResolver(*resolver_claim) !=
                WindowsResolverClaimDecision::kOwn) {
              return false;
            }
            return index_->ConsumeResolverClaim(*resolver_claim);
          });
  auto final_status = StatusFromRecoveryResult(coordinated.recovery);
  if (coordinated.should_relaunch) {
    try {
      const WindowsAtMostOnceRelaunchOutcome relaunch =
          RunWindowsAtMostOnceRelaunch(
              []() { return true; },
              [this, &transaction_id]() {
                index_->MarkRelaunchAttempting(transaction_id);
              },
              [this, &frozen_record, &coordinated, &launcher]() {
                RelaunchRecoveredApplication(*frozen_record,
                                             coordinated.recovery, policy_,
                                             launcher);
              },
              [this, &transaction_id](bool launched) {
                index_->PersistRelaunchOutcome(transaction_id, launched);
              });
      if (relaunch != WindowsAtMostOnceRelaunchOutcome::kLaunched) {
        final_status.result_code = "relaunchFailure";
      }
    } catch (const std::exception&) {
      final_status.result_code = "relaunchFailure";
    }
  }
  try {
    const auto latest = index_->Load(transaction_id);
    if (latest.has_value() &&
        (latest->record_state == "completed" ||
         latest->record_state == "rolledBack")) {
      return StatusFromWindowsPersistentTerminalRecord(*latest);
    }
  } catch (const std::exception&) {
    final_status.result_code = "relaunchFailure";
  }
  return final_status;
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
WindowsPersistentRecoveryService::Recover(const std::string& transaction_id) {
  return RecoverBound(transaction_id, true, caller_process_);
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
WindowsPersistentRecoveryService::RecoverAutonomously(
    const std::string& transaction_id,
    std::function<void(const std::string&)> signal_ready) {
  RequireTransactionId(transaction_id);
  AuthenticateAutonomousHost();
  RecordWindowsHelperEvent(WindowsHelperEvent::kPortableStageProvenanceFailure);
  EnsureIndex();
  RecordWindowsHelperEvent(WindowsHelperEvent::kPortableStageManifestFailure);
  const auto record = index_->Load(transaction_id);
  RecordWindowsHelperEvent(
      WindowsHelperEvent::kPortableStageRequestBindingFailure);
  if (!record.has_value()) {
    return {1, transaction_id, "helperUnavailable", "none",
            std::string(64, '0')};
  }
  std::unique_ptr<CallerTokenWindowsLauncher> launcher =
      WaitForExactRecoveryActorsExit(*record, signal_ready);
  RecordWindowsHelperEvent(WindowsHelperEvent::kPortableStageRestageFailure);
  auto recovery = RecoverBound(transaction_id, false, nullptr);
  const bool terminal =
      (recovery.result_code == "completed" &&
       recovery.verified_outcome == "newTarget") ||
      (recovery.result_code == "rolledBack" &&
       recovery.verified_outcome == "oldTarget");
  if (!terminal) return recovery;

  const auto terminal_record = index_->Load(transaction_id);
  if (!terminal_record.has_value()) {
    return recovery;
  }
  switch (DecideWindowsTerminalRelaunch(terminal_record->relaunch_state)) {
    case WindowsTerminalRelaunchDecision::kNotRequested:
    case WindowsTerminalRelaunchDecision::kAlreadyLaunched:
      return recovery;
    case WindowsTerminalRelaunchDecision::kFailClosed:
      recovery.result_code = "relaunchFailure";
      return recovery;
    case WindowsTerminalRelaunchDecision::kAttempt:
      break;
  }
  try {
    const std::uint64_t resolver_start_identity =
        WindowsProcessStartIdentity(GetCurrentProcess());
    if (resolver_start_identity == 0 ||
        resolver_start_identity >
            static_cast<std::uint64_t>(
                std::numeric_limits<std::int64_t>::max())) {
      throw WindowsPersistentRecoveryError(
          "autonomous relaunch resolver identity is unavailable");
    }
    WindowsPersistentResolverClaim claim{
        WindowsPersistentResolverClaim::kSchemaVersion,
        transaction_id,
        static_cast<std::int64_t>(GetCurrentProcessId()),
        static_cast<std::int64_t>(resolver_start_identity),
        terminal_record->caller_process_id,
        terminal_record->caller_process_start_identity,
        SecureWindowsReadyToken(),
        "claimed"};
    const WindowsResolverClaimDecision decision = index_->ClaimResolver(claim);
    if (decision == WindowsResolverClaimDecision::kFollow) {
      // A live exact resolver still owns the only allowed attempt. Leave the
      // recovery task armed rather than converting that in-flight ownership
      // into a false terminal result.
      recovery.result_code = "recoveryRequired";
      return recovery;
    }
    if (decision == WindowsResolverClaimDecision::kConsumed) {
      const auto latest = index_->Load(transaction_id);
      if (!latest.has_value() || latest->relaunch_state != "launched") {
        recovery.result_code = "relaunchFailure";
      }
      return recovery;
    }
    const WindowsAtMostOnceRelaunchOutcome outcome =
        RunWindowsAtMostOnceRelaunch(
            [this, &claim]() { return index_->ConsumeResolverClaim(claim); },
            [this, &transaction_id]() {
              index_->MarkRelaunchAttempting(transaction_id);
            },
            [this, &launcher, &terminal_record, &recovery]() {
              if (!launcher) {
                throw WindowsRelaunchError(
                    "autonomous relaunch caller token is unavailable");
              }
              RelaunchRecoveredApplication(*terminal_record, recovery, policy_,
                                           *launcher);
            },
            [this, &transaction_id](bool launched) {
              index_->PersistRelaunchOutcome(transaction_id, launched);
            });
    if (outcome != WindowsAtMostOnceRelaunchOutcome::kLaunched) {
      recovery.result_code = "relaunchFailure";
    }
  } catch (const std::exception&) {
    recovery.result_code = "relaunchFailure";
  }
  return recovery;
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
WindowsPersistentRecoveryService::RecoverBound(
    const std::string& transaction_id, bool authenticate_caller,
    HANDLE proof_caller_process, bool* exact_owner_active) {
  if (exact_owner_active != nullptr) *exact_owner_active = false;
  RequireTransactionId(transaction_id);
  if (authenticate_caller && !policy_.is_portable()) AuthenticateCaller();
  try {
    EnsureIndex();
    const auto record = index_->Load(transaction_id);
    if (!record.has_value()) {
      return {1, transaction_id, "helperUnavailable", "none",
              std::string(64, '0')};
    }
    if (authenticate_caller) AuthenticateCallerForRecord(*record);
    if (record->record_state == "completed" ||
        record->record_state == "rolledBack") {
      return RecoverTerminal(*record, proof_caller_process);
    }
    if (record->record_state == "completedCleanupPending" ||
        record->record_state == "rolledBackCleanupPending") {
      return RecoverCleanupPending(*record, exact_owner_active);
    }
    if (record->record_state == "manualActionRequired") {
      return {1, transaction_id, "manualActionRequired", "none",
              record->journal_sha256};
    }
    return RecoverActive(*record, proof_caller_process, exact_owner_active);
  } catch (const std::exception&) {
    return {1, transaction_id, "manualActionRequired", "none",
            std::string(64, '0')};
  }
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
WindowsPersistentRecoveryService::RecoverActive(
    const WindowsPersistentTransactionRecord& record,
    HANDLE proof_caller_process, bool* exact_owner_active) {
  const auto current = LoadCurrentJournal(record);
  if (!current.has_value()) {
    return RecoverPreparingWithoutJournal(record, proof_caller_process,
                                          exact_owner_active);
  }
  AuthenticodeWindowsPayloadVerifier verifier(
      current->expected_payload_identity);
  Win32ProcessLivenessChecker liveness;
  const WindowsRecoveryIntent intent =
      record.record_state == "commitAccepted"
          ? WindowsRecoveryIntent::kCompleteCommitted
          : WindowsRecoveryIntent::kRollBackUncommitted;
  WindowsRecoveryService recovery(
      record.target_path_hint, record.transaction_id,
      current->expected_payload_identity, verifier, liveness, intent,
      [this, &record](WindowsRecoveryOutcome outcome) {
        if (outcome == WindowsRecoveryOutcome::kRecovered) {
          index_->PersistCleanupPending(record.transaction_id,
                                        "completedCleanupPending", "newTarget");
        } else if (outcome == WindowsRecoveryOutcome::kRolledBack) {
          index_->PersistCleanupPending(
              record.transaction_id, "rolledBackCleanupPending", "oldTarget");
        }
      },
      [this, &record](WindowsRecoveryOutcome outcome) {
        if (outcome == WindowsRecoveryOutcome::kRecovered) {
          index_->PersistTerminal(record.transaction_id, "completed",
                                  "newTarget");
        } else if (outcome == WindowsRecoveryOutcome::kRolledBack) {
          index_->PersistTerminal(record.transaction_id, "rolledBack",
                                  "oldTarget");
        }
      },
      [this, &record, intent]() {
        if (intent == WindowsRecoveryIntent::kRollBackUncommitted) {
          index_->MarkCancelling(record.transaction_id);
        }
      },
      true);
  switch (recovery.Recover()) {
    case WindowsRecoveryOutcome::kRecovered:
      return {1, record.transaction_id, "completed", "newTarget",
              record.journal_sha256};
    case WindowsRecoveryOutcome::kRolledBack:
      return {1, record.transaction_id, "rolledBack", "oldTarget",
              record.journal_sha256};
    case WindowsRecoveryOutcome::kNothingToRecover:
      return RecoverPreparingWithoutJournal(record, proof_caller_process,
                                            exact_owner_active);
    case WindowsRecoveryOutcome::kLiveOwner:
      if (exact_owner_active != nullptr) *exact_owner_active = true;
      return {1, record.transaction_id, "recoveryRequired", "none",
              record.journal_sha256};
    case WindowsRecoveryOutcome::kManualActionRequired:
      return {1, record.transaction_id, "manualActionRequired", "none",
              record.journal_sha256};
  }
  return {1, record.transaction_id, "manualActionRequired", "none",
          record.journal_sha256};
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
WindowsPersistentRecoveryService::RecoverPreparingWithoutJournal(
    const WindowsPersistentTransactionRecord& record,
    HANDLE proof_caller_process, bool* exact_owner_active) {
  const WindowsTransactionJournal frozen =
      WindowsTransactionJournal::DecodeStrict(record.journal_canonical);
  const WindowsTransactionPaths paths = WindowsTransactionPaths::Create(
      frozen.target_name, record.transaction_id);
  UniqueWindowsHandle parent = OpenTargetParent(record.target_path_hint);
  if (ReadWindowsFileIdentity(parent.get()) != frozen.parent_identity) {
    return {1, record.transaction_id, "manualActionRequired", "none",
            record.journal_sha256};
  }
  ExactLockObservation lock = ObserveExactLock(parent.get(), paths, true);
  if (lock.state == ExactLockObservation::State::kLiveOwner) {
    if (exact_owner_active != nullptr) *exact_owner_active = true;
    return {1, record.transaction_id, "recoveryRequired", "none",
            record.journal_sha256};
  }
  if (lock.state != ExactLockObservation::State::kAcquired) {
    return {1, record.transaction_id, "manualActionRequired", "none",
            record.journal_sha256};
  }
  if (record.record_state != "commitAccepted") {
    index_->MarkCancelling(record.transaction_id);
  }
  const FinalTopology topology =
      InspectFinalTopology(record, policy_, true, proof_caller_process);
  const bool completed = record.record_state == "commitAccepted" &&
                         topology == FinalTopology::kCompleted;
  const bool rolled_back = (record.record_state == "preparing" ||
                            record.record_state == "prepared" ||
                            record.record_state == "cancelling") &&
                           topology == FinalTopology::kRolledBack;
  if (!completed && !rolled_back) {
    if (lock.created) {
      DeleteHandleExact(lock.handle.get());
      lock.handle.reset();
      FlushPersistentMetadata(parent.get());
    }
    return {1, record.transaction_id, "manualActionRequired", "none",
            record.journal_sha256};
  }

  index_->PersistCleanupPending(
      record.transaction_id,
      completed ? "completedCleanupPending" : "rolledBackCleanupPending",
      completed ? "newTarget" : "oldTarget");
  DeleteHandleExact(lock.handle.get());
  lock.handle.reset();
  FlushPersistentMetadata(parent.get());
  index_->PersistTerminal(record.transaction_id,
                          completed ? "completed" : "rolledBack",
                          completed ? "newTarget" : "oldTarget");
  return {1, record.transaction_id, completed ? "completed" : "rolledBack",
          completed ? "newTarget" : "oldTarget", record.journal_sha256};
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
WindowsPersistentRecoveryService::RecoverCleanupPending(
    const WindowsPersistentTransactionRecord& record,
    bool* exact_owner_active) {
  const bool completed = record.record_state == "completedCleanupPending";
  const std::string final_state = completed ? "completed" : "rolledBack";
  const std::string final_outcome = completed ? "newTarget" : "oldTarget";
  try {
    const WindowsTransactionJournal frozen =
        WindowsTransactionJournal::DecodeStrict(record.journal_canonical);
    const WindowsTransactionPaths paths = WindowsTransactionPaths::Create(
        frozen.target_name, record.transaction_id);
    UniqueWindowsHandle parent = OpenTargetParent(record.target_path_hint);
    if (ReadWindowsFileIdentity(parent.get()) != frozen.parent_identity) {
      return {1, record.transaction_id, "recoveryRequired", "none",
              record.journal_sha256};
    }
    ExactLockObservation lock = ObserveExactLock(parent.get(), paths, false);
    if (lock.state == ExactLockObservation::State::kLiveOwner) {
      if (exact_owner_active != nullptr) *exact_owner_active = true;
      return {1, record.transaction_id, "recoveryRequired", "none",
              record.journal_sha256};
    }
    if (lock.state == ExactLockObservation::State::kMalformed) {
      return {1, record.transaction_id, "manualActionRequired", "none",
              record.journal_sha256};
    }
    if (lock.state == ExactLockObservation::State::kAcquired) {
      DeleteHandleExact(lock.handle.get());
      lock.handle.reset();
      FlushPersistentMetadata(parent.get());
    }
    // An absent lock means the release completed before the previous process
    // died. A differently bound lock belongs to a later exact transaction and
    // must not be touched; the protected pending record remains authoritative
    // for this historical outcome.
    index_->PersistTerminal(record.transaction_id, final_state, final_outcome);
    return {1, record.transaction_id, final_state, final_outcome,
            record.journal_sha256};
  } catch (const std::exception&) {
    return {1, record.transaction_id, "recoveryRequired", "none",
            record.journal_sha256};
  }
}

desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
WindowsPersistentRecoveryService::RecoverTerminal(
    const WindowsPersistentTransactionRecord& record,
    HANDLE proof_caller_process) {
  try {
    const WindowsTransactionJournal frozen =
        WindowsTransactionJournal::DecodeStrict(record.journal_canonical);
    const WindowsTransactionPaths paths = WindowsTransactionPaths::Create(
        frozen.target_name, record.transaction_id);
    UniqueWindowsHandle parent = OpenTargetParent(record.target_path_hint);
    if (ReadWindowsFileIdentity(parent.get()) == frozen.parent_identity) {
      ExactLockObservation lock = ObserveExactLock(parent.get(), paths, false);
      const FinalTopology expected = record.record_state == "completed"
                                         ? FinalTopology::kCompleted
                                         : FinalTopology::kRolledBack;
      if (lock.state == ExactLockObservation::State::kAcquired &&
          InspectFinalTopology(record, policy_, true, proof_caller_process) ==
              expected) {
        DeleteHandleExact(lock.handle.get());
        lock.handle.reset();
        FlushPersistentMetadata(parent.get());
      }
    }
  } catch (const std::exception&) {
    // A final tombstone is historical authority. Cleanup is best-effort and
    // must never reinterpret an older outcome after a later valid update.
  }
  return {1, record.transaction_id,
          record.record_state == "completed" ? "completed" : "rolledBack",
          record.record_state == "completed" ? "newTarget" : "oldTarget",
          record.journal_sha256};
}

}  // namespace desktop_updater::helper
