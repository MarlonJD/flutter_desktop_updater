#include "windows_portable_recovery_host.h"

#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shlobj.h>
#include <winternl.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cwctype>
#include <exception>
#include <limits>
#include <memory>
#include <regex>
#include <set>
#include <utility>
#include <vector>

#include "json_value.h"
#include "windows_helper_bootstrap.h"
#include "windows_helper_diagnostics.h"
#include "windows_portable_transaction_index.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;

constexpr wchar_t kStableRootName[] =
    L"desktop_updater_portable_recovery_host_v1";
constexpr wchar_t kHelperFileName[] =
    L"desktop_updater_install_helper.exe";
constexpr wchar_t kPolicyFileName[] =
    L"desktop_updater_helper_policy.json";
constexpr std::size_t kMaximumPolicyBytes = 256 * 1024;
const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

// Some MinGW taskschd.h revisions omit ILogonTrigger even though the COM
// interface has been present since Windows Vista. Keep the ABI declaration
// local and use the Windows SDK interface IID directly.
struct PortableILogonTrigger : public ITrigger {
  virtual HRESULT STDMETHODCALLTYPE get_Delay(BSTR* delay) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Delay(BSTR delay) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_UserId(BSTR* user) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_UserId(BSTR user) = 0;
};

const IID kPortableILogonTriggerIid = {
    0x72dade38,
    0xfae4,
    0x4b3e,
    {0xba, 0xf4, 0x5d, 0x00, 0x9a, 0xf0, 0x2b, 0x1c}};

enum class PortableRecoveryProvisionStage {
  kAuthority,
  kSource,
  kStorage,
  kArtifact,
};

class PortableRecoveryProvisionDiagnostics final {
 public:
  PortableRecoveryProvisionDiagnostics()
      : uncaught_exceptions_(std::uncaught_exceptions()) {}

  ~PortableRecoveryProvisionDiagnostics() {
    if (std::uncaught_exceptions() <= uncaught_exceptions_) return;
    switch (stage_) {
      case PortableRecoveryProvisionStage::kAuthority:
        RecordWindowsHelperEvent(
            WindowsHelperEvent::kPortableRecoveryAuthorityFailure);
        break;
      case PortableRecoveryProvisionStage::kSource:
        RecordWindowsHelperEvent(
            WindowsHelperEvent::kPortableRecoverySourceFailure);
        break;
      case PortableRecoveryProvisionStage::kStorage:
        RecordWindowsHelperEvent(
            WindowsHelperEvent::kPortableRecoveryStorageFailure);
        break;
      case PortableRecoveryProvisionStage::kArtifact:
        RecordWindowsHelperEvent(
            WindowsHelperEvent::kPortableRecoveryArtifactFailure);
        break;
    }
  }

  void Advance(PortableRecoveryProvisionStage stage) { stage_ = stage; }

 private:
  int uncaught_exceptions_;
  PortableRecoveryProvisionStage stage_ =
      PortableRecoveryProvisionStage::kAuthority;
};

[[noreturn]] void Fail(const std::string& detail) {
  throw WindowsPortableRecoveryHostError(detail);
}

bool IsSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return std::isdigit(byte) != 0 || (byte >= 'a' && byte <= 'f');
         });
}

bool IsReadyNonce(const std::string& value) {
  return value.size() == 43 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return (byte >= 'A' && byte <= 'Z') ||
                  (byte >= 'a' && byte <= 'z') ||
                  (byte >= '0' && byte <= '9') || byte == '-' || byte == '_';
         });
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty() ||
      value.size() >
          static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    Fail("portable recovery UTF-8 value is invalid");
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) Fail("portable recovery UTF-8 value is invalid");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    Fail("portable recovery UTF-8 conversion failed");
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty() ||
      value.size() >
          static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    Fail("portable recovery wide value is invalid");
  }
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) Fail("portable recovery wide value is invalid");
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length, nullptr, nullptr) != length) {
    Fail("portable recovery wide conversion failed");
  }
  return result;
}

std::wstring NormalizePath(std::filesystem::path path) {
  std::wstring value = path.lexically_normal().wstring();
  if (value.rfind(L"\\\\?\\", 0) == 0) value.erase(0, 4);
  std::replace(value.begin(), value.end(), L'/', L'\\');
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t byte) { return std::towlower(byte); });
  while (value.size() > 3 && value.back() == L'\\') value.pop_back();
  return value;
}

bool IsAtOrUnder(const std::filesystem::path& candidate,
                 const std::filesystem::path& root) {
  const std::wstring candidate_path = NormalizePath(candidate);
  const std::wstring root_path = NormalizePath(root);
  return candidate_path == root_path ||
         (candidate_path.size() > root_path.size() &&
          candidate_path.compare(0, root_path.size(), root_path) == 0 &&
          candidate_path[root_path.size()] == L'\\');
}

std::filesystem::path FinalPath(HANDLE handle) {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetFinalPathNameByHandleW(
      handle, buffer.data(), static_cast<DWORD>(buffer.size()),
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (length == 0 || length >= buffer.size()) {
    Fail("portable recovery final path is unavailable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

std::vector<unsigned char> TokenUserSid(HANDLE process) {
  HANDLE raw_token = nullptr;
  if (process == nullptr ||
      !OpenProcessToken(process, TOKEN_QUERY, &raw_token)) {
    Fail("portable recovery process token is unavailable");
  }
  UniqueWindowsHandle token(raw_token);
  DWORD size = 0;
  (void)GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
  if (size == 0 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
    Fail("portable recovery user SID is unavailable");
  }
  std::vector<unsigned char> bytes(size);
  if (!GetTokenInformation(token.get(), TokenUser, bytes.data(), size,
                           &size)) {
    Fail("portable recovery user SID is unavailable");
  }
  const auto* user = reinterpret_cast<const TOKEN_USER*>(bytes.data());
  if (user->User.Sid == nullptr || !IsValidSid(user->User.Sid)) {
    Fail("portable recovery user SID is invalid");
  }
  const DWORD sid_size = GetLengthSid(user->User.Sid);
  std::vector<unsigned char> result(sid_size);
  if (!CopySid(sid_size, result.data(), user->User.Sid)) {
    Fail("portable recovery user SID copy failed");
  }
  return result;
}

std::wstring SidText(PSID sid) {
  LPWSTR raw = nullptr;
  if (sid == nullptr || !IsValidSid(sid) ||
      !ConvertSidToStringSidW(sid, &raw) || raw == nullptr) {
    Fail("portable recovery SID conversion failed");
  }
  std::wstring result(raw);
  LocalFree(raw);
  return result;
}

std::vector<unsigned char> ParseSid(const std::wstring& text) {
  PSID raw = nullptr;
  if (text.empty() ||
      !ConvertStringSidToSidW(text.c_str(), &raw) || raw == nullptr) {
    Fail("portable recovery SID is invalid");
  }
  std::unique_ptr<void, decltype(&LocalFree)> owner(raw, LocalFree);
  if (!IsValidSid(raw)) Fail("portable recovery SID is invalid");
  const DWORD length = GetLengthSid(raw);
  std::vector<unsigned char> result(length);
  if (!CopySid(length, result.data(), raw)) {
    Fail("portable recovery SID copy failed");
  }
  return result;
}

std::wstring AccountNameForSid(const std::wstring& sid_text) {
  const auto sid = ParseSid(sid_text);
  DWORD name_length = 0;
  DWORD domain_length = 0;
  SID_NAME_USE use = SidTypeUnknown;
  (void)LookupAccountSidW(nullptr, const_cast<unsigned char*>(sid.data()),
                           nullptr, &name_length,
                           nullptr, &domain_length, &use);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || name_length == 0) {
    Fail("portable recovery account name is unavailable");
  }
  std::vector<wchar_t> name(name_length + 1, L'\0');
  std::vector<wchar_t> domain(domain_length + 1, L'\0');
  if (!LookupAccountSidW(nullptr, const_cast<unsigned char*>(sid.data()),
                         name.data(), &name_length,
                         domain.data(), &domain_length, &use)) {
    Fail("portable recovery account name is unavailable");
  }
  if (domain_length == 0) return std::wstring(name.data(), name_length);
  return std::wstring(domain.data(), domain_length) + L"\\" +
         std::wstring(name.data(), name_length);
}

bool CaseInsensitiveEqual(const std::wstring& left,
                          const std::wstring& right) {
  if (left.size() != right.size()) return false;
  for (std::size_t index = 0; index < left.size(); ++index) {
    if (std::towlower(left[index]) != std::towlower(right[index])) {
      return false;
    }
  }
  return true;
}

bool TaskPrincipalMatchesSid(const std::wstring& actual,
                             const std::wstring& expected_sid) {
  if (actual == expected_sid) return true;
  const std::wstring account = AccountNameForSid(expected_sid);
  if (CaseInsensitiveEqual(actual, account)) return true;
  const std::size_t separator = account.find(L'\\');
  return separator != std::wstring::npos &&
         CaseInsensitiveEqual(actual, account.substr(separator + 1));
}

bool IsLocalSystemSid(PSID sid) {
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> system{};
  DWORD size = static_cast<DWORD>(system.size());
  return CreateWellKnownSid(WinLocalSystemSid, nullptr, system.data(),
                            &size) != FALSE &&
         EqualSid(sid, system.data()) != FALSE;
}

PSID SidPointer(const std::vector<unsigned char>& sid) {
  return const_cast<unsigned char*>(sid.data());
}

struct CurrentTokenFacts {
  std::vector<unsigned char> user;
  std::wstring user_sid;
  bool elevated = false;
  bool local_system = false;
};

CurrentTokenFacts ReadCurrentTokenFacts() {
  CurrentTokenFacts result;
  result.user = TokenUserSid(GetCurrentProcess());
  result.user_sid = SidText(result.user.data());
  result.local_system = IsLocalSystemSid(result.user.data());
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
    Fail("portable recovery process token is unavailable");
  }
  UniqueWindowsHandle token(raw_token);
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  if (!GetTokenInformation(token.get(), TokenElevation, &elevation,
                           sizeof(elevation), &size) ||
      size != sizeof(elevation)) {
    Fail("portable recovery elevation state is unavailable");
  }
  result.elevated = elevation.TokenIsElevated != 0;
  return result;
}

void ValidateExactUserSecurity(HANDLE object, PSID user, bool directory) {
  ValidatePortableWindowsExactUserSecurity(object, user, directory);
}

UniqueWindowsHandle OpenKnownLocalAppData(
    std::filesystem::path* retained_path) {
  return OpenPortableWindowsExactUserLocalAppData(retained_path);
}

UniqueWindowsHandle OpenSecureDirectory(HANDLE parent,
                                        const std::wstring& leaf,
                                        PSID user,
                                        const std::wstring& user_sid,
                                        bool create_if_missing) {
  if (leaf.empty() || leaf == L"." || leaf == L".." ||
      leaf.find_first_of(L"\\/") != std::wstring::npos) {
    Fail("portable recovery directory leaf is invalid");
  }
  constexpr ACCESS_MASK access =
      FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY |
      FILE_READ_ATTRIBUTES | READ_CONTROL | DELETE | SYNCHRONIZE;
  constexpr ULONG share =
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
  constexpr ULONG options =
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT;
  auto validate = [&](UniqueWindowsHandle directory) {
    const WindowsFileIdentity identity =
        ReadWindowsFileIdentity(directory.get());
    if (!identity.directory ||
        (identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      Fail("portable recovery component is not a plain directory");
    }
    ValidateExactUserSecurity(directory.get(), user, true);
    return directory;
  };
  auto open_existing = [&]() {
    return validate(OpenRelativeNoReparse(parent, leaf, access, share,
                                          FILE_OPEN, options,
                                          FILE_ATTRIBUTE_HIDDEN));
  };
  auto create_new = [&]() {
    UniqueWindowsHandle directory;
    try {
      directory = CreatePortableWindowsExactUserDirectory(
          parent, leaf, access, share, options, FILE_ATTRIBUTE_HIDDEN, user,
          user_sid);
    } catch (...) {
      // Only an atomic FILE_CREATE collision can be recovered by reopening.
      // Security validation and parent durability failures remain fatal.
      if (!ExistsRelativeNoReparse(parent, leaf)) throw;
      return open_existing();
    }
    directory = validate(std::move(directory));
    FlushWindowsDirectory(parent);
    return directory;
  };

  const bool exists = ExistsRelativeNoReparse(parent, leaf);
  if (exists) {
    try {
      return open_existing();
    } catch (...) {
      if (!create_if_missing || ExistsRelativeNoReparse(parent, leaf)) throw;
    }
  } else if (!create_if_missing) {
    return UniqueWindowsHandle();
  }
  return create_new();
}

UniqueWindowsHandle OpenSecureFile(HANDLE parent,
                                   const std::wstring& leaf,
                                   ACCESS_MASK access) {
  if (leaf.empty() || leaf == L"." || leaf == L".." ||
      leaf.find_first_of(L"\\/") != std::wstring::npos) {
    Fail("portable recovery file leaf is invalid");
  }
  return OpenRelativeNoReparse(
      parent, leaf, access | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
}

struct StableFileOpen {
  UniqueWindowsHandle file;
  bool created = false;
};

StableFileOpen OpenOrCreateSecureFile(HANDLE parent,
                                      const std::wstring& leaf,
                                      ACCESS_MASK access,
                                      PSID user,
                                      const std::wstring& user_sid) {
  auto open_existing = [&]() {
    auto file = OpenSecureFile(parent, leaf, access);
    ValidateExactUserSecurity(file.get(), user, false);
    return StableFileOpen{std::move(file), false};
  };
  if (ExistsRelativeNoReparse(parent, leaf)) {
    try {
      return open_existing();
    } catch (...) {
      if (ExistsRelativeNoReparse(parent, leaf)) throw;
    }
  }
  try {
    auto file = CreatePortableWindowsExactUserFile(
        parent, leaf,
        access | FILE_READ_ATTRIBUTES | READ_CONTROL | WRITE_DAC |
            WRITE_OWNER | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_DELETE,
        FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
            FILE_WRITE_THROUGH,
        FILE_ATTRIBUTE_HIDDEN, user, user_sid);
    return {std::move(file), true};
  } catch (...) {
    // FILE_CREATE race loser reopens and validates the exact winner. A live
    // writer or an unsafe replacement remains a fail-closed provisioning
    // failure and is never granted or rewritten.
    if (!ExistsRelativeNoReparse(parent, leaf)) throw;
    return open_existing();
  }
}

std::string ReadHandle(HANDLE file, std::size_t maximum_bytes) {
  LARGE_INTEGER start{};
  if (!SetFilePointerEx(file, start, nullptr, FILE_BEGIN)) {
    Fail("portable recovery file seek failed");
  }
  std::string result;
  std::array<char, 16 * 1024> buffer{};
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &count, nullptr)) {
      Fail("portable recovery file read failed");
    }
    if (count == 0) return result;
    if (result.size() + count > maximum_bytes) {
      Fail("portable recovery file exceeds size limit");
    }
    result.append(buffer.data(), count);
  }
}

std::string Sha256Handle(HANDLE file) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0;
  DWORD received = 0;
  std::vector<unsigned char> object;
  std::array<unsigned char, 32> digest{};
  auto cleanup = [&]() {
    if (hash != nullptr) BCryptDestroyHash(hash);
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  };
  auto fail = [&]() -> void {
    cleanup();
    Fail("portable recovery retained helper SHA-256 failed");
  };
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_size),
                        sizeof(object_size), &received, 0) < 0) {
    fail();
  }
  object.resize(object_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr,
                       0, 0) < 0) {
    fail();
  }
  LARGE_INTEGER start{};
  if (!SetFilePointerEx(file, start, nullptr, FILE_BEGIN)) fail();
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &count, nullptr)) {
      fail();
    }
    if (count == 0) break;
    if (BCryptHashData(hash, buffer.data(), count, 0) < 0) fail();
  }
  if (BCryptFinishHash(hash, digest.data(),
                       static_cast<ULONG>(digest.size()), 0) < 0) {
    fail();
  }
  cleanup();
  static constexpr char hex[] = "0123456789abcdef";
  std::string result;
  result.reserve(64);
  for (unsigned char byte : digest) {
    result.push_back(hex[byte >> 4]);
    result.push_back(hex[byte & 0x0f]);
  }
  return result;
}

void WriteHandle(HANDLE file, const std::string& bytes) {
  LARGE_INTEGER start{};
  if (!SetFilePointerEx(file, start, nullptr, FILE_BEGIN) ||
      !SetEndOfFile(file)) {
    Fail("portable recovery destination initialization failed");
  }
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const DWORD count = static_cast<DWORD>(std::min<std::size_t>(
        bytes.size() - offset, std::numeric_limits<DWORD>::max()));
    DWORD written = 0;
    if (!WriteFile(file, bytes.data() + offset, count, &written, nullptr) ||
        written != count) {
      Fail("portable recovery destination write failed");
    }
    offset += written;
  }
  if (!FlushFileBuffers(file)) {
    Fail("portable recovery destination flush failed");
  }
}

std::string ReadCanonicalPolicy(const std::filesystem::path& path,
                                std::filesystem::path* final_path) {
  UniqueWindowsHandle file(CreateFileW(
      path.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES | READ_CONTROL |
                        SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!file.valid()) Fail("portable recovery policy cannot open");
  const WindowsFileIdentity identity = ReadWindowsFileIdentity(file.get());
  if (identity.directory ||
      (identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      identity.number_of_links != 1) {
    Fail("portable recovery policy is not a plain single-link file");
  }
  const std::string canonical = ReadHandle(file.get(), kMaximumPolicyBytes);
  if (canonical.empty()) Fail("portable recovery policy is empty");
  const JsonValue parsed = ParseJson(canonical);
  if (EncodeCanonicalJson(parsed) != canonical) {
    Fail("portable recovery policy is not canonical JSON");
  }
  if (final_path != nullptr) {
    *final_path = FinalPath(file.get()).lexically_normal();
  }
  return canonical;
}

bool PoliciesEqual(const WindowsHelperPolicy& first,
                   const WindowsHelperPolicy& second) {
  if (first.policy_id() != second.policy_id() ||
      first.application_package_id() != second.application_package_id() ||
      first.helper_service_id() != second.helper_service_id() ||
      first.application_signer_kind() != second.application_signer_kind() ||
      first.application_signer_identity() !=
          second.application_signer_identity() ||
      first.helper_signer_kind() != second.helper_signer_kind() ||
      first.helper_signer_identity() != second.helper_signer_identity() ||
      first.helper_sha256() != second.helper_sha256() ||
      first.allowed_install_roots() != second.allowed_install_roots() ||
      first.allowed_target_classes() != second.allowed_target_classes() ||
      first.minimum_helper_protocol_version() !=
          second.minimum_helper_protocol_version()) {
    return false;
  }
  const auto& first_keys = first.release_root_public_keys();
  const auto& second_keys = second.release_root_public_keys();
  if (first_keys.size() != second_keys.size()) return false;
  for (std::size_t index = 0; index < first_keys.size(); ++index) {
    if (first_keys[index].key_id != second_keys[index].key_id ||
        first_keys[index].algorithm != second_keys[index].algorithm ||
        first_keys[index].public_key_base64 !=
            second_keys[index].public_key_base64) {
      return false;
    }
  }
  const auto& first_strategies = first.allowed_strategies();
  const auto& second_strategies = second.allowed_strategies();
  if (first_strategies.size() != second_strategies.size()) return false;
  for (std::size_t index = 0; index < first_strategies.size(); ++index) {
    if (first_strategies[index].strategy !=
            second_strategies[index].strategy ||
        first_strategies[index].provider !=
            second_strategies[index].provider) {
      return false;
    }
  }
  return true;
}

WindowsHelperPolicy ParsePortablePolicy(const std::string& canonical,
                                        const std::string& helper_sha256) {
  try {
    const JsonValue value = ParseJson(canonical);
    const std::string package_id =
        value.at("applicationPackageId").string();
    WindowsHelperPolicy policy = WindowsHelperPolicy::Load(
        canonical, WindowsHelperSha256Hex(canonical), package_id,
        helper_sha256);
    if (!policy.is_portable()) {
      Fail("stable recovery policy is not portable");
    }
    return policy;
  } catch (const WindowsPortableRecoveryHostError&) {
    throw;
  } catch (const std::exception&) {
    Fail("stable recovery policy is invalid");
  }
}

std::filesystem::path CurrentExecutablePath() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) {
    Fail("portable recovery current executable path is unavailable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

void CopySourceHelper(HANDLE destination,
                      const VerifiedWindowsExecutable& source_identity) {
  UniqueWindowsHandle source(CreateFileW(
      source_identity.final_path.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES |
                                               READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!source.valid() ||
      !VerifyWindowsExecutableStillMatches(source_identity.final_path,
                                           source_identity)) {
    Fail("portable recovery source helper identity changed");
  }
  const WindowsFileIdentity identity = ReadWindowsFileIdentity(source.get());
  ValidatePortableWindowsRetainedHelperFacts(
      source_identity, identity, Sha256Handle(source.get()),
      FinalPath(source.get()));
  LARGE_INTEGER start{};
  if (!SetFilePointerEx(source.get(), start, nullptr, FILE_BEGIN) ||
      !SetFilePointerEx(destination, start, nullptr, FILE_BEGIN) ||
      !SetEndOfFile(destination)) {
    Fail("portable recovery helper copy initialization failed");
  }
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(source.get(), buffer.data(),
                  static_cast<DWORD>(buffer.size()), &count, nullptr)) {
      Fail("portable recovery helper source read failed");
    }
    if (count == 0) break;
    DWORD written = 0;
    if (!WriteFile(destination, buffer.data(), count, &written, nullptr) ||
        written != count) {
      Fail("portable recovery helper copy failed");
    }
  }
  if (!FlushFileBuffers(destination) ||
      !VerifyWindowsExecutableStillMatches(source_identity.final_path,
                                           source_identity)) {
    Fail("portable recovery helper copy was not stable");
  }
}

void EnsureStablePolicy(HANDLE endpoint_directory,
                        PSID user,
                        const std::wstring& user_sid,
                        const std::string& canonical_policy) {
  StableFileOpen opened = OpenOrCreateSecureFile(
      endpoint_directory, kPolicyFileName, GENERIC_READ | GENERIC_WRITE, user,
      user_sid);
  if (opened.created) {
    WriteHandle(opened.file.get(), canonical_policy);
    FlushWindowsDirectory(endpoint_directory);
  }
  ValidateExactUserSecurity(opened.file.get(), user, false);
  if (ReadHandle(opened.file.get(), kMaximumPolicyBytes) != canonical_policy) {
    Fail("portable recovery stable policy readback changed");
  }
}

void EnsureStableHelper(HANDLE endpoint_directory,
                        const PortableWindowsRecoveryHostEndpointV1& endpoint,
                        PSID user,
                        const std::wstring& user_sid,
                        const WindowsHelperPolicy& policy,
                        const VerifiedWindowsExecutable& source_identity) {
  StableFileOpen opened = OpenOrCreateSecureFile(
      endpoint_directory, kHelperFileName, GENERIC_READ | GENERIC_WRITE, user,
      user_sid);
  if (opened.created) {
    CopySourceHelper(opened.file.get(), source_identity);
    FlushWindowsDirectory(endpoint_directory);
  }
  ValidateExactUserSecurity(opened.file.get(), user, false);
  opened.file.reset();
  const VerifiedWindowsExecutable copied =
      VerifyWindowsExecutable(endpoint.helper_path);
  ValidateWindowsHelperIdentity(copied, policy, false);
  if (copied.sha256 != endpoint.helper_sha256 ||
      NormalizePath(copied.final_path) != NormalizePath(endpoint.helper_path) ||
      !VerifyWindowsExecutableStillMatches(endpoint.helper_path, copied)) {
    Fail("portable recovery stable helper readback changed");
  }
}

struct StableTreeHandles {
  UniqueWindowsHandle root;
  UniqueWindowsHandle binding;
  UniqueWindowsHandle endpoint;
};

StableTreeHandles OpenStableTree(
    HANDLE local_app_data,
    const PortableWindowsRecoveryHostEndpointV1& endpoint,
    PSID user,
    bool create_if_missing,
    bool* endpoint_existed = nullptr) {
  StableTreeHandles result;
  result.root = OpenSecureDirectory(local_app_data, kStableRootName, user,
                                    endpoint.user_sid, create_if_missing);
  if (!result.root.valid()) return result;
  if (!create_if_missing) {
    RecordWindowsHelperEvent(
        WindowsHelperEvent::kPortableSecurityDescriptorFailure);
  }
  result.binding = OpenSecureDirectory(
      result.root.get(), Utf8ToWide(endpoint.binding_sha256), user,
      endpoint.user_sid, create_if_missing);
  if (!result.binding.valid()) return result;
  if (!create_if_missing) {
    RecordWindowsHelperEvent(WindowsHelperEvent::kPortableCallerTokenFailure);
  }
  const std::wstring endpoint_leaf =
      Utf8ToWide(endpoint.helper_sha256);
  const bool existed =
      ExistsRelativeNoReparse(result.binding.get(), endpoint_leaf);
  if (endpoint_existed != nullptr) *endpoint_existed = existed;
  if (!create_if_missing) {
    RecordWindowsHelperEvent(
        WindowsHelperEvent::kPortableImpersonationTokenFailure);
  }
  result.endpoint = OpenSecureDirectory(
      result.binding.get(), endpoint_leaf, user, endpoint.user_sid,
      create_if_missing);
  if (!create_if_missing && result.endpoint.valid()) {
    RecordWindowsHelperEvent(WindowsHelperEvent::kPortableAccessCheckFailure);
  }
  return result;
}

void ValidateEndpointShape(
    const PortableWindowsRecoveryHostEndpointV1& endpoint) {
  const auto user = ParseSid(endpoint.user_sid);
  if (endpoint.schema_version !=
          PortableWindowsRecoveryHostEndpointV1::kSchemaVersion ||
      endpoint.policy_id.empty() || endpoint.package_id.empty() ||
      IsLocalSystemSid(const_cast<unsigned char*>(user.data())) ||
      !IsSha256(endpoint.binding_sha256) ||
      !IsSha256(endpoint.helper_sha256) ||
      !IsSha256(endpoint.policy_sha256) ||
      !endpoint.local_app_data_path.is_absolute()) {
    Fail("portable recovery endpoint authority is invalid");
  }
  const std::string binding = WindowsHelperSha256Hex(
      "portable-recovery-host-v1\n" + endpoint.policy_id + "\n" +
      endpoint.package_id + "\n" + endpoint.helper_sha256 + "\n" +
      endpoint.policy_sha256 + "\n" + WideToUtf8(endpoint.user_sid));
  // The binding directory commits the full policy/helper/user identity. Keep
  // only the helper digest in the endpoint leaf so the executable action path
  // remains within Task Scheduler's MAX_PATH-compatible limit.
  const std::filesystem::path expected_endpoint =
      endpoint.local_app_data_path / kStableRootName /
      Utf8ToWide(binding) /
      Utf8ToWide(endpoint.helper_sha256);
  if (binding != endpoint.binding_sha256 ||
      NormalizePath(endpoint.endpoint_path) !=
          NormalizePath(expected_endpoint) ||
      NormalizePath(endpoint.helper_path) !=
          NormalizePath(expected_endpoint / kHelperFileName) ||
      NormalizePath(endpoint.policy_path) !=
          NormalizePath(expected_endpoint / kPolicyFileName)) {
    Fail("portable recovery endpoint path binding changed");
  }
}

std::wstring TaskSecurityDescriptor(const std::wstring& user_sid) {
  (void)ParseSid(user_sid);
  return L"O:" + user_sid + L"G:" + user_sid + L"D:P(A;;GA;;;" +
         user_sid + L")(A;;GA;;;SY)";
}

void ValidateTaskDefinition(
    const PortableWindowsRecoveryHostTaskDefinition& definition) {
  const std::wstring transaction(definition.transaction_id.begin(),
                                 definition.transaction_id.end());
  const std::wstring nonce(definition.recovery_ready_nonce.begin(),
                           definition.recovery_ready_nonce.end());
  if (!std::regex_match(definition.transaction_id, kTransactionId) ||
      !IsReadyNonce(definition.recovery_ready_nonce) ||
      definition.principal_user_id.empty() ||
      definition.task_path.rfind(L"\\DesktopUpdater-Portable-", 0) != 0 ||
      definition.task_path.find(L'*') != std::wstring::npos ||
      definition.ready_event_name.rfind(
          L"Local\\DesktopUpdater-PortableRecoveryReady-", 0) != 0 ||
      definition.ready_event_name.find(L'*') != std::wstring::npos ||
      definition.ready_event_name.size() <= nonce.size() + 1 ||
      definition.ready_event_name.compare(
          definition.ready_event_name.size() - nonce.size(), nonce.size(),
          nonce) != 0 ||
      !definition.executable_path.is_absolute() ||
      definition.executable_path.filename() != kHelperFileName ||
      definition.arguments != L"--portable-recover-current " + transaction ||
      definition.security_descriptor !=
          TaskSecurityDescriptor(definition.principal_user_id) ||
      definition.logon_type != TASK_LOGON_INTERACTIVE_TOKEN ||
      definition.run_level != TASK_RUNLEVEL_LUA ||
      definition.trigger_type != TASK_TRIGGER_LOGON ||
      definition.trigger_delay != L"PT0M" ||
      !definition.trigger_start_boundary.empty() ||
      !definition.trigger_end_boundary.empty() ||
      definition.registration_flags !=
          (TASK_CREATE | TASK_DONT_ADD_PRINCIPAL_ACE) ||
      definition.run_flags != kPortableWindowsTaskRunAsSelf) {
    Fail("portable recovery task definition is invalid");
  }
}

template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  explicit ComPtr(T* value) : value_(value) {}
  ~ComPtr() {
    if (value_ != nullptr) value_->Release();
  }
  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;
  ComPtr(ComPtr&& other) noexcept : value_(other.release()) {}
  T* get() const { return value_; }
  T** put() {
    if (value_ != nullptr) {
      value_->Release();
      value_ = nullptr;
    }
    return &value_;
  }
  T* release() {
    T* result = value_;
    value_ = nullptr;
    return result;
  }

 private:
  T* value_ = nullptr;
};

class ScopedBstr {
 public:
  explicit ScopedBstr(const std::wstring& value)
      : value_(SysAllocStringLen(value.data(),
                                 static_cast<UINT>(value.size()))) {
    if (value_ == nullptr) Fail("Task Scheduler BSTR allocation failed");
  }
  ~ScopedBstr() { SysFreeString(value_); }
  BSTR get() const { return value_; }

 private:
  BSTR value_ = nullptr;
};

class ReceivedBstr {
 public:
  ~ReceivedBstr() { SysFreeString(value_); }
  BSTR* put() { return &value_; }
  std::wstring value() const {
    return value_ == nullptr ? std::wstring() : std::wstring(value_);
  }

 private:
  BSTR value_ = nullptr;
};

class ScopedVariant {
 public:
  ScopedVariant() { VariantInit(&value_); }
  explicit ScopedVariant(const std::wstring& value) : ScopedVariant() {
    value_.vt = VT_BSTR;
    value_.bstrVal = SysAllocStringLen(
        value.data(), static_cast<UINT>(value.size()));
    if (value_.bstrVal == nullptr) {
      Fail("Task Scheduler VARIANT allocation failed");
    }
  }
  ~ScopedVariant() { VariantClear(&value_); }
  VARIANT value() const { return value_; }

 private:
  VARIANT value_;
};

class ScopedComInitialization {
 public:
  ScopedComInitialization() {
    const HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (result == S_OK || result == S_FALSE) {
      uninitialize_ = true;
    } else if (result != RPC_E_CHANGED_MODE) {
      Fail("Task Scheduler COM initialization failed");
    }
  }
  ~ScopedComInitialization() {
    if (uninitialize_) CoUninitialize();
  }

 private:
  bool uninitialize_ = false;
};

void Check(HRESULT result, const char* detail) {
  if (FAILED(result)) Fail(detail);
}

ComPtr<ITaskService> ConnectTaskService() {
  ComPtr<ITaskService> service;
  Check(CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER,
                         IID_ITaskService,
                         reinterpret_cast<void**>(service.put())),
        "Task Scheduler service creation failed");
  ScopedVariant empty;
  Check(service.get()->Connect(empty.value(), empty.value(), empty.value(),
                               empty.value()),
        "Task Scheduler service connection failed");
  return service;
}

ComPtr<ITaskFolder> RootTaskFolder(ITaskService* service) {
  ScopedBstr root(L"\\");
  ComPtr<ITaskFolder> folder;
  Check(service->GetFolder(root.get(), folder.put()),
        "Task Scheduler root folder is unavailable");
  return folder;
}

void ConfigureTask(
    ITaskDefinition* task,
    const PortableWindowsRecoveryHostTaskDefinition& definition) {
  ComPtr<IRegistrationInfo> registration;
  Check(task->get_RegistrationInfo(registration.put()),
        "Task Scheduler registration metadata is unavailable");
  ScopedBstr author(L"DesktopUpdater portable recovery host");
  Check(registration.get()->put_Author(author.get()),
        "Task Scheduler author binding failed");

  ComPtr<IPrincipal> principal;
  Check(task->get_Principal(principal.put()),
        "Task Scheduler principal is unavailable");
  // Task Scheduler accepts a SID in many elevated/admin contexts, but a
  // standard-user registration can reject the same definition as
  // SCHED_E_INVALIDVALUE. Resolve the already-authorized SID to its canonical
  // account name for the task XML while retaining the SID as the security and
  // validation authority.
  ScopedBstr user(AccountNameForSid(definition.principal_user_id));
  Check(principal.get()->put_UserId(user.get()),
        "Task Scheduler exact-user principal failed");
  Check(principal.get()->put_LogonType(definition.logon_type),
        "Task Scheduler interactive-token logon failed");
  Check(principal.get()->put_RunLevel(definition.run_level),
        "Task Scheduler LUA run level failed");

  ComPtr<ITaskSettings> settings;
  Check(task->get_Settings(settings.put()),
        "Task Scheduler settings are unavailable");
  Check(settings.get()->put_Enabled(VARIANT_TRUE),
        "Task Scheduler enable failed");
  Check(settings.get()->put_AllowDemandStart(VARIANT_TRUE),
        "Task Scheduler demand start failed");
  Check(settings.get()->put_StartWhenAvailable(VARIANT_TRUE),
        "Task Scheduler start-when-available failed");
  Check(settings.get()->put_DisallowStartIfOnBatteries(VARIANT_FALSE),
        "Task Scheduler battery policy failed");
  Check(settings.get()->put_StopIfGoingOnBatteries(VARIANT_FALSE),
        "Task Scheduler battery stop policy failed");
  Check(settings.get()->put_MultipleInstances(TASK_INSTANCES_IGNORE_NEW),
        "Task Scheduler instance policy failed");
  ScopedBstr no_limit(L"PT0S");
  Check(settings.get()->put_ExecutionTimeLimit(no_limit.get()),
        "Task Scheduler execution limit failed");

  ComPtr<ITriggerCollection> triggers;
  Check(task->get_Triggers(triggers.put()),
        "Task Scheduler triggers are unavailable");
  ComPtr<ITrigger> raw_trigger;
  Check(triggers.get()->Create(definition.trigger_type, raw_trigger.put()),
        "Task Scheduler logon trigger creation failed");
  Check(raw_trigger.get()->put_Enabled(VARIANT_TRUE),
        "Task Scheduler logon trigger enable failed");
  ComPtr<PortableILogonTrigger> logon;
  Check(raw_trigger.get()->QueryInterface(
            kPortableILogonTriggerIid,
            reinterpret_cast<void**>(logon.put())),
        "Task Scheduler logon trigger binding failed");
  Check(logon.get()->put_UserId(user.get()),
        "Task Scheduler logon trigger user binding failed");
  ScopedBstr no_delay(definition.trigger_delay);
  Check(logon.get()->put_Delay(no_delay.get()),
        "Task Scheduler logon trigger delay binding failed");

  ComPtr<IActionCollection> actions;
  Check(task->get_Actions(actions.put()),
        "Task Scheduler actions are unavailable");
  ComPtr<IAction> raw_action;
  Check(actions.get()->Create(TASK_ACTION_EXEC, raw_action.put()),
        "Task Scheduler exec action creation failed");
  ComPtr<IExecAction> executable;
  Check(raw_action.get()->QueryInterface(
            IID_IExecAction, reinterpret_cast<void**>(executable.put())),
        "Task Scheduler exec action binding failed");
  ScopedBstr path(definition.executable_path.wstring());
  ScopedBstr arguments(definition.arguments);
  Check(executable.get()->put_Path(path.get()),
        "Task Scheduler executable binding failed");
  Check(executable.get()->put_Arguments(arguments.get()),
        "Task Scheduler argument binding failed");
}

void ValidateTaskSecurity(IRegisteredTask* task,
                          const std::wstring& expected_user_sid) {
  ReceivedBstr encoded;
  Check(task->GetSecurityDescriptor(
        OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |
                DACL_SECURITY_INFORMATION,
            encoded.put()),
        "Task Scheduler DACL readback failed");
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  if (encoded.value().empty() ||
      !ConvertStringSecurityDescriptorToSecurityDescriptorW(
          encoded.value().c_str(), SDDL_REVISION_1, &raw_descriptor,
          nullptr) ||
      raw_descriptor == nullptr) {
    Fail("Task Scheduler DACL readback is invalid");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  PSID owner = nullptr;
  PSID group = nullptr;
  PACL dacl = nullptr;
  BOOL defaulted = FALSE;
  BOOL present = FALSE;
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!GetSecurityDescriptorOwner(raw_descriptor, &owner, &defaulted) ||
      !GetSecurityDescriptorGroup(raw_descriptor, &group, &defaulted) ||
      !GetSecurityDescriptorDacl(raw_descriptor, &present, &dacl,
                                 &defaulted) ||
      present == FALSE || dacl == nullptr ||
      !GetSecurityDescriptorControl(raw_descriptor, &control, &revision) ||
      owner == nullptr || group == nullptr) {
    Fail("Task Scheduler exact-user DACL changed");
  }
  std::vector<PortableWindowsRecoveryAclAceFacts> aces;
  aces.reserve(dacl->AceCount);
  for (DWORD index = 0; index < dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace) || raw_ace == nullptr) {
      Fail("Task Scheduler DACL is unreadable");
    }
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE &&
        header->AceType != ACCESS_DENIED_ACE_TYPE) {
      Fail("Task Scheduler DACL contains unsupported ACE type");
    }
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    aces.push_back({SidText(sid), ace->Mask, header->AceFlags,
                    header->AceType == ACCESS_ALLOWED_ACE_TYPE});
  }
  // Task Scheduler expands GA ACEs in the registered task descriptor to the
  // FILE_ALL_ACCESS mask during readback.
  try {
    ValidatePortableWindowsRecoveryExactAclFacts(
        expected_user_sid, SidText(owner), SidText(group),
        (control & SE_DACL_PROTECTED) != 0, FILE_ALL_ACCESS, 0, aces);
  } catch (const std::exception& error) {
    const std::string detail = error.what();
    throw;
  }
}

void ValidateRegisteredTask(
    IRegisteredTask* registered,
    const PortableWindowsRecoveryHostTaskDefinition& expected) {
  ReceivedBstr path;
  VARIANT_BOOL registered_enabled = VARIANT_FALSE;
  Check(registered->get_Path(path.put()),
        "Task Scheduler task path readback failed");
  Check(registered->get_Enabled(&registered_enabled),
        "Task Scheduler registered enabled readback failed");
  if (path.value() != expected.task_path) {
    Fail("Task Scheduler task path changed");
  }
  ValidateTaskSecurity(registered, expected.principal_user_id);
  ComPtr<ITaskDefinition> definition;
  Check(registered->get_Definition(definition.put()),
        "Task Scheduler definition readback failed");
  ComPtr<ITaskSettings> settings;
  Check(definition.get()->get_Settings(settings.put()),
        "Task Scheduler settings readback failed");
  VARIANT_BOOL settings_enabled = VARIANT_FALSE;
  VARIANT_BOOL allow_demand_start = VARIANT_FALSE;
  VARIANT_BOOL start_when_available = VARIANT_FALSE;
  VARIANT_BOOL disallow_start_if_on_batteries = VARIANT_TRUE;
  VARIANT_BOOL stop_if_going_on_batteries = VARIANT_TRUE;
  TASK_INSTANCES_POLICY multiple_instances = TASK_INSTANCES_PARALLEL;
  ReceivedBstr execution_time_limit;
  Check(settings.get()->get_Enabled(&settings_enabled),
        "Task Scheduler settings enabled readback failed");
  Check(settings.get()->get_AllowDemandStart(&allow_demand_start),
        "Task Scheduler demand-start readback failed");
  Check(settings.get()->get_StartWhenAvailable(&start_when_available),
        "Task Scheduler start-when-available readback failed");
  Check(settings.get()->get_DisallowStartIfOnBatteries(
            &disallow_start_if_on_batteries),
        "Task Scheduler battery-start readback failed");
  Check(settings.get()->get_StopIfGoingOnBatteries(
            &stop_if_going_on_batteries),
        "Task Scheduler battery-stop readback failed");
  Check(settings.get()->get_MultipleInstances(&multiple_instances),
        "Task Scheduler instance-policy readback failed");
  Check(settings.get()->get_ExecutionTimeLimit(execution_time_limit.put()),
        "Task Scheduler execution-limit readback failed");
  ComPtr<IPrincipal> principal;
  Check(definition.get()->get_Principal(principal.put()),
        "Task Scheduler principal readback failed");
  ReceivedBstr principal_user;
  TASK_LOGON_TYPE logon_type = TASK_LOGON_NONE;
  TASK_RUNLEVEL_TYPE run_level = TASK_RUNLEVEL_HIGHEST;
  Check(principal.get()->get_UserId(principal_user.put()),
        "Task Scheduler principal user readback failed");
  Check(principal.get()->get_LogonType(&logon_type),
        "Task Scheduler logon type readback failed");
  Check(principal.get()->get_RunLevel(&run_level),
        "Task Scheduler run level readback failed");
  if (!TaskPrincipalMatchesSid(principal_user.value(),
                               expected.principal_user_id) ||
      logon_type != expected.logon_type || run_level != expected.run_level) {
    Fail("Task Scheduler principal authority changed");
  }
  ComPtr<ITriggerCollection> triggers;
  Check(definition.get()->get_Triggers(triggers.put()),
        "Task Scheduler trigger readback failed");
  LONG trigger_count = 0;
  Check(triggers.get()->get_Count(&trigger_count),
        "Task Scheduler trigger count readback failed");
  if (trigger_count != 1) Fail("Task Scheduler trigger count changed");
  ComPtr<ITrigger> raw_trigger;
  Check(triggers.get()->get_Item(1, raw_trigger.put()),
        "Task Scheduler trigger item readback failed");
  TASK_TRIGGER_TYPE2 trigger_type = TASK_TRIGGER_EVENT;
  VARIANT_BOOL trigger_enabled = VARIANT_FALSE;
  ReceivedBstr trigger_start_boundary;
  ReceivedBstr trigger_end_boundary;
  Check(raw_trigger.get()->get_Type(&trigger_type),
        "Task Scheduler trigger type readback failed");
  Check(raw_trigger.get()->get_Enabled(&trigger_enabled),
        "Task Scheduler trigger enabled readback failed");
  Check(raw_trigger.get()->get_StartBoundary(trigger_start_boundary.put()),
        "Task Scheduler trigger start-boundary readback failed");
  Check(raw_trigger.get()->get_EndBoundary(trigger_end_boundary.put()),
        "Task Scheduler trigger end-boundary readback failed");
  ComPtr<PortableILogonTrigger> logon;
  Check(raw_trigger.get()->QueryInterface(
            kPortableILogonTriggerIid,
            reinterpret_cast<void**>(logon.put())),
        "Task Scheduler logon trigger readback failed");
  ReceivedBstr trigger_user;
  ReceivedBstr trigger_delay;
  Check(logon.get()->get_UserId(trigger_user.put()),
        "Task Scheduler logon trigger user readback failed");
  Check(logon.get()->get_Delay(trigger_delay.put()),
        "Task Scheduler logon trigger delay readback failed");
  if (trigger_type != expected.trigger_type ||
      !TaskPrincipalMatchesSid(trigger_user.value(),
                               expected.principal_user_id)) {
    Fail("Task Scheduler logon trigger authority changed");
  }
  ValidatePortableWindowsRecoveryTaskSemanticFacts(
      {registered_enabled == VARIANT_TRUE,
       settings_enabled == VARIANT_TRUE,
       allow_demand_start == VARIANT_TRUE,
       start_when_available == VARIANT_TRUE,
       disallow_start_if_on_batteries == VARIANT_TRUE,
       stop_if_going_on_batteries == VARIANT_TRUE,
       multiple_instances,
       execution_time_limit.value(),
       trigger_enabled == VARIANT_TRUE,
       trigger_delay.value(),
       trigger_start_boundary.value(),
       trigger_end_boundary.value()});
  ComPtr<IActionCollection> actions;
  Check(definition.get()->get_Actions(actions.put()),
        "Task Scheduler action readback failed");
  LONG action_count = 0;
  Check(actions.get()->get_Count(&action_count),
        "Task Scheduler action count readback failed");
  if (action_count != 1) Fail("Task Scheduler action count changed");
  ComPtr<IAction> raw_action;
  Check(actions.get()->get_Item(1, raw_action.put()),
        "Task Scheduler action item readback failed");
  TASK_ACTION_TYPE action_type = TASK_ACTION_COM_HANDLER;
  Check(raw_action.get()->get_Type(&action_type),
        "Task Scheduler action type readback failed");
  ComPtr<IExecAction> executable;
  Check(raw_action.get()->QueryInterface(
            IID_IExecAction, reinterpret_cast<void**>(executable.put())),
        "Task Scheduler exec action readback failed");
  ReceivedBstr executable_path;
  ReceivedBstr arguments;
  ReceivedBstr working_directory;
  Check(executable.get()->get_Path(executable_path.put()),
        "Task Scheduler executable path readback failed");
  Check(executable.get()->get_Arguments(arguments.put()),
        "Task Scheduler arguments readback failed");
  Check(executable.get()->get_WorkingDirectory(working_directory.put()),
        "Task Scheduler working directory readback failed");
  if (action_type != TASK_ACTION_EXEC ||
      NormalizePath(executable_path.value()) !=
          NormalizePath(expected.executable_path) ||
      arguments.value() != expected.arguments ||
      !working_directory.value().empty()) {
    Fail("Task Scheduler fixed action changed");
  }
}

}  // namespace

PortableWindowsRecoveryHostEndpointV1
BuildPortableWindowsRecoveryHostEndpoint(
    const std::filesystem::path& local_app_data_path,
    const WindowsHelperPolicy& policy,
    const std::string& helper_sha256,
    const std::string& policy_sha256,
    const std::wstring& user_sid) {
  const auto sid = ParseSid(user_sid);
  if (!policy.is_portable() || !local_app_data_path.is_absolute() ||
      local_app_data_path.lexically_normal() != local_app_data_path ||
      !IsSha256(helper_sha256) || helper_sha256 != policy.helper_sha256() ||
      !IsSha256(policy_sha256) || IsLocalSystemSid(SidPointer(sid))) {
    Fail("portable recovery endpoint authority is invalid");
  }
  const std::string binding = WindowsHelperSha256Hex(
      "portable-recovery-host-v1\n" + policy.policy_id() + "\n" +
      policy.application_package_id() + "\n" + helper_sha256 + "\n" +
      policy_sha256 + "\n" + WideToUtf8(user_sid));
  const std::filesystem::path endpoint_path =
      local_app_data_path / kStableRootName / Utf8ToWide(binding) /
      Utf8ToWide(helper_sha256);
  PortableWindowsRecoveryHostEndpointV1 endpoint{
      PortableWindowsRecoveryHostEndpointV1::kSchemaVersion,
      policy.policy_id(),
      policy.application_package_id(),
      user_sid,
      binding,
      helper_sha256,
      policy_sha256,
      local_app_data_path,
      endpoint_path,
      endpoint_path / kHelperFileName,
      endpoint_path / kPolicyFileName,
  };
  ValidateEndpointShape(endpoint);
  return endpoint;
}

PortableWindowsRecoveryHostSourceDecision
DecidePortableWindowsRecoveryHostSource(
    const PortableWindowsRecoveryHostEndpointV1& endpoint,
    const std::filesystem::path& verified_source_helper_path,
    const std::filesystem::path& verified_source_policy_path) {
  ValidateEndpointShape(endpoint);
  if (!verified_source_helper_path.is_absolute() ||
      !verified_source_policy_path.is_absolute() ||
      _wcsicmp(verified_source_helper_path.filename().c_str(),
               kHelperFileName) != 0 ||
      _wcsicmp(verified_source_policy_path.filename().c_str(),
               kPolicyFileName) != 0 ||
      NormalizePath(verified_source_helper_path.parent_path()) !=
          NormalizePath(verified_source_policy_path.parent_path())) {
    return PortableWindowsRecoveryHostSourceDecision::kReject;
  }
  const bool exact_helper =
      NormalizePath(verified_source_helper_path) ==
      NormalizePath(endpoint.helper_path);
  const bool exact_policy =
      NormalizePath(verified_source_policy_path) ==
      NormalizePath(endpoint.policy_path);
  if (exact_helper && exact_policy) {
    return PortableWindowsRecoveryHostSourceDecision::kReuseExactStable;
  }
  if (exact_helper || exact_policy ||
      IsAtOrUnder(endpoint.endpoint_path,
                  verified_source_helper_path.parent_path()) ||
      IsAtOrUnder(verified_source_helper_path.parent_path(),
                  endpoint.endpoint_path)) {
    return PortableWindowsRecoveryHostSourceDecision::kReject;
  }
  return PortableWindowsRecoveryHostSourceDecision::kProvisionExternal;
}

void RequirePortableWindowsRecoveryHostOutsideMutationRoots(
    const PortableWindowsRecoveryHostEndpointV1& endpoint,
    const std::filesystem::path& target_path,
    const std::filesystem::path& stage_path) {
  ValidateEndpointShape(endpoint);
  if (!target_path.is_absolute() || !stage_path.is_absolute() ||
      IsAtOrUnder(endpoint.endpoint_path, target_path) ||
      IsAtOrUnder(target_path, endpoint.endpoint_path) ||
      IsAtOrUnder(endpoint.endpoint_path, stage_path) ||
      IsAtOrUnder(stage_path, endpoint.endpoint_path)) {
    Fail("portable recovery host overlaps a mutation root");
  }
}

void RequirePortableWindowsRecoveryTokenAuthority(
    const std::wstring& expected_user_sid,
    const std::wstring& actual_user_sid,
    bool elevated,
    bool local_system) {
  const auto expected = ParseSid(expected_user_sid);
  const auto actual = ParseSid(actual_user_sid);
  if (elevated || local_system || IsLocalSystemSid(SidPointer(actual)) ||
      !EqualSid(SidPointer(expected), SidPointer(actual))) {
    Fail("portable recovery host must run as the exact non-elevated user");
  }
}

void ValidatePortableWindowsRecoveryExactAclFacts(
    const std::wstring& expected_user_sid,
    const std::wstring& owner_sid,
    const std::wstring& group_sid,
    bool dacl_protected,
    DWORD expected_mask,
    BYTE expected_flags,
    const std::vector<PortableWindowsRecoveryAclAceFacts>& aces) {
  try {
    ValidatePortableWindowsExactUserAclFacts(
        expected_user_sid, owner_sid, group_sid, dacl_protected,
        expected_mask, expected_flags, aces);
  } catch (const std::exception& error) {
    Fail(error.what());
  }
}

void ValidatePortableWindowsRetainedHelperFacts(
    const VerifiedWindowsExecutable& expected,
    const WindowsFileIdentity& observed,
    const std::string& observed_sha256,
    const std::filesystem::path& observed_final_path) {
  if (!IsSha256(expected.sha256) || observed.directory ||
      (observed.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      observed.number_of_links != 1 ||
      observed.volume_serial != expected.volume_serial ||
      observed.file_id != expected.file_id ||
      observed_sha256 != expected.sha256 ||
      NormalizePath(observed_final_path) != NormalizePath(expected.final_path)) {
    Fail("portable recovery retained helper handle identity changed");
  }
}

PortableWindowsStableEndpointDecision DecidePortableWindowsStableEndpoint(
    PortableWindowsStableEndpointProbe probe) {
  switch (probe) {
    case PortableWindowsStableEndpointProbe::kMissing:
      return PortableWindowsStableEndpointDecision::kCreate;
    case PortableWindowsStableEndpointProbe::kExact:
      return PortableWindowsStableEndpointDecision::kReuse;
    case PortableWindowsStableEndpointProbe::kIncompleteSecure:
      return PortableWindowsStableEndpointDecision::kQuarantineAndRecreate;
    case PortableWindowsStableEndpointProbe::kUnsafe:
      return PortableWindowsStableEndpointDecision::kReject;
  }
  Fail("portable recovery endpoint probe is invalid");
}

PortableWindowsRecoveryTaskRegistrationDecision
DecidePortableWindowsRecoveryTaskRegistration(
    PortableWindowsRecoveryTaskProbe probe) {
  switch (probe) {
    case PortableWindowsRecoveryTaskProbe::kMissing:
      return PortableWindowsRecoveryTaskRegistrationDecision::kRegisterNew;
    case PortableWindowsRecoveryTaskProbe::kExact:
      return PortableWindowsRecoveryTaskRegistrationDecision::kReuseExact;
    case PortableWindowsRecoveryTaskProbe::kMismatch:
      return PortableWindowsRecoveryTaskRegistrationDecision::kReject;
  }
  Fail("portable recovery task probe is invalid");
}

void ValidatePortableWindowsRecoveryTaskSemanticFacts(
    const PortableWindowsRecoveryTaskSemanticFacts& facts) {
  if (!facts.registered_enabled || !facts.settings_enabled ||
      !facts.allow_demand_start || !facts.start_when_available ||
      facts.disallow_start_if_on_batteries ||
      facts.stop_if_going_on_batteries ||
      facts.multiple_instances != TASK_INSTANCES_IGNORE_NEW ||
      facts.execution_time_limit != L"PT0S" || !facts.trigger_enabled ||
      (!facts.trigger_delay.empty() && facts.trigger_delay != L"PT0M") ||
      !facts.trigger_start_boundary.empty() ||
      !facts.trigger_end_boundary.empty()) {
    Fail("Task Scheduler recovery semantics changed");
  }
}

PortableWindowsRecoveryHostEndpointV1 ProvisionPortableWindowsRecoveryHost(
    const WindowsHelperPolicy& policy,
    const VerifiedWindowsExecutable& source_helper_identity,
    HANDLE authenticated_caller_process) {
  PortableRecoveryProvisionDiagnostics diagnostics;
  const CurrentTokenFacts current = ReadCurrentTokenFacts();
  const auto caller = TokenUserSid(authenticated_caller_process);
  RequirePortableWindowsRecoveryTokenAuthority(
      SidText(SidPointer(caller)), current.user_sid, current.elevated,
      current.local_system);
  if (!policy.is_portable() ||
      !EqualSid(SidPointer(caller), SidPointer(current.user))) {
    Fail("portable recovery caller is another user");
  }
  diagnostics.Advance(PortableRecoveryProvisionStage::kSource);
  ValidateWindowsHelperIdentity(source_helper_identity, policy, false);
  if (!VerifyWindowsExecutableStillMatches(
          source_helper_identity.final_path, source_helper_identity)) {
    Fail("portable recovery source helper identity changed");
  }
  const std::filesystem::path source_policy_path =
      source_helper_identity.final_path.parent_path() / kPolicyFileName;
  std::filesystem::path source_policy_final;
  const std::string canonical_policy =
      ReadCanonicalPolicy(source_policy_path, &source_policy_final);
  if (NormalizePath(source_policy_final.parent_path()) !=
          NormalizePath(source_helper_identity.final_path.parent_path()) ||
      _wcsicmp(source_policy_final.filename().c_str(), kPolicyFileName) != 0) {
    Fail("portable recovery source policy is not adjacent");
  }
  const WindowsHelperPolicy parsed =
      ParsePortablePolicy(canonical_policy, source_helper_identity.sha256);
  if (!PoliciesEqual(policy, parsed)) {
    Fail("portable recovery source policy binding changed");
  }
  diagnostics.Advance(PortableRecoveryProvisionStage::kStorage);
  std::filesystem::path local_app_data_path;
  UniqueWindowsHandle local_app_data =
      OpenKnownLocalAppData(&local_app_data_path);
  const auto endpoint = BuildPortableWindowsRecoveryHostEndpoint(
      local_app_data_path, policy, source_helper_identity.sha256,
      WindowsHelperSha256Hex(canonical_policy), current.user_sid);
  switch (DecidePortableWindowsRecoveryHostSource(
      endpoint, source_helper_identity.final_path, source_policy_final)) {
    case PortableWindowsRecoveryHostSourceDecision::kReuseExactStable: {
      diagnostics.Advance(PortableRecoveryProvisionStage::kArtifact);
      PortableWindowsRecoveryHostBootstrap stable =
          LoadPortableWindowsRecoveryHostBootstrap();
      if (!PoliciesEqual(policy, stable.policy) ||
          WindowsPortableIndexBindingKey(policy) !=
              WindowsPortableIndexBindingKey(stable.policy) ||
          stable.endpoint.schema_version != endpoint.schema_version ||
          stable.endpoint.policy_id != endpoint.policy_id ||
          stable.endpoint.package_id != endpoint.package_id ||
          stable.endpoint.user_sid != endpoint.user_sid ||
          stable.endpoint.binding_sha256 != endpoint.binding_sha256 ||
          stable.endpoint.helper_sha256 != endpoint.helper_sha256 ||
          stable.endpoint.policy_sha256 != endpoint.policy_sha256 ||
          NormalizePath(stable.endpoint.local_app_data_path) !=
              NormalizePath(endpoint.local_app_data_path) ||
          NormalizePath(stable.endpoint.endpoint_path) !=
              NormalizePath(endpoint.endpoint_path) ||
          NormalizePath(stable.endpoint.helper_path) !=
              NormalizePath(endpoint.helper_path) ||
          NormalizePath(stable.endpoint.policy_path) !=
              NormalizePath(endpoint.policy_path) ||
          !stable.helper_identity.signature_valid ||
          stable.helper_identity.publisher !=
              source_helper_identity.publisher ||
          stable.helper_identity.sha256 != source_helper_identity.sha256 ||
          stable.helper_identity.installer_protected_location !=
              source_helper_identity.installer_protected_location ||
          stable.helper_identity.volume_serial !=
              source_helper_identity.volume_serial ||
          stable.helper_identity.file_id != source_helper_identity.file_id ||
          NormalizePath(stable.helper_identity.final_path) !=
              NormalizePath(source_helper_identity.final_path)) {
        Fail("portable recovery stable source binding changed");
      }
      return stable.endpoint;
    }
    case PortableWindowsRecoveryHostSourceDecision::kReject:
      Fail("portable recovery stable host overlaps the current application");
    case PortableWindowsRecoveryHostSourceDecision::kProvisionExternal:
      break;
  }
  bool endpoint_existed = false;
  StableTreeHandles tree = OpenStableTree(
      local_app_data.get(), endpoint, SidPointer(current.user), true,
      &endpoint_existed);
  if (!tree.endpoint.valid()) {
    Fail("portable recovery stable endpoint is unavailable");
  }
  diagnostics.Advance(PortableRecoveryProvisionStage::kArtifact);
  auto provision_and_read_back = [&]() {
    EnsureStablePolicy(tree.endpoint.get(), SidPointer(current.user),
                       current.user_sid, canonical_policy);
    EnsureStableHelper(tree.endpoint.get(), endpoint,
                       SidPointer(current.user), current.user_sid, policy,
                       source_helper_identity);
  };
  try {
    provision_and_read_back();
  } catch (const std::exception&) {
    if (!endpoint_existed ||
        DecidePortableWindowsStableEndpoint(
            PortableWindowsStableEndpointProbe::kIncompleteSecure) !=
            PortableWindowsStableEndpointDecision::kQuarantineAndRecreate) {
      throw;
    }
    const WindowsFileIdentity incomplete_identity =
        ReadWindowsFileIdentity(tree.endpoint.get());
    const std::wstring endpoint_leaf = Utf8ToWide(
        endpoint.helper_sha256);
    const std::wstring quarantine_leaf =
        endpoint_leaf + L".incomplete-" +
        Utf8ToWide(SecureWindowsReadyToken());
    RenameHandleRelative(tree.endpoint.get(), tree.binding.get(),
                         quarantine_leaf, false);
    FlushWindowsDirectory(tree.binding.get());
    tree.endpoint.reset();
    tree.endpoint = OpenSecureDirectory(
        tree.binding.get(), endpoint_leaf, SidPointer(current.user),
        current.user_sid, true);
    provision_and_read_back();
    try {
      DeleteTreeRelative(tree.binding.get(), quarantine_leaf,
                         incomplete_identity);
    } catch (const std::exception&) {
      // A quarantined exact-user tree is never executable by a task and is
      // safe to leave for a later bounded garbage-collection pass.
    }
  }
  const std::string policy_readback =
      ReadCanonicalPolicy(endpoint.policy_path, nullptr);
  if (policy_readback != canonical_policy ||
      WindowsHelperSha256Hex(policy_readback) != endpoint.policy_sha256) {
    Fail("portable recovery stable policy digest changed");
  }
  return endpoint;
}

PortableWindowsRecoveryHostBootstrap
LoadPortableWindowsRecoveryHostBootstrap() {
  const CurrentTokenFacts current = ReadCurrentTokenFacts();
  RequirePortableWindowsRecoveryTokenAuthority(
      current.user_sid, current.user_sid, current.elevated,
      current.local_system);
  RecordWindowsHelperEvent(
      WindowsHelperEvent::kPortableTargetCallerRootFailure);
  const std::filesystem::path current_path = CurrentExecutablePath();
  RecordWindowsHelperEvent(
      WindowsHelperEvent::kPortableTargetReadAuthorityFailure);
  const VerifiedWindowsExecutable helper =
      VerifyWindowsExecutable(current_path);
  RecordWindowsHelperEvent(
      WindowsHelperEvent::kPortableParentMutationAuthorityFailure);
  const std::filesystem::path policy_path =
      helper.final_path.parent_path() / kPolicyFileName;
  const std::string canonical_policy =
      ReadCanonicalPolicy(policy_path, nullptr);
  RecordWindowsHelperEvent(WindowsHelperEvent::kPortableTargetMarkerFailure);
  WindowsHelperPolicy policy =
      ParsePortablePolicy(canonical_policy, helper.sha256);
  ValidateWindowsHelperIdentity(helper, policy, false);
  if (!VerifyWindowsExecutableStillMatches(current_path, helper)) {
    Fail("portable recovery stable helper identity changed");
  }
  RecordWindowsHelperEvent(WindowsHelperEvent::kPortableDirectoryHandleFailure);
  std::filesystem::path local_app_data_path;
  UniqueWindowsHandle local_app_data =
      OpenKnownLocalAppData(&local_app_data_path);
  auto endpoint = BuildPortableWindowsRecoveryHostEndpoint(
      local_app_data_path, policy, helper.sha256,
      WindowsHelperSha256Hex(canonical_policy), current.user_sid);
  if (NormalizePath(helper.final_path) != NormalizePath(endpoint.helper_path) ||
      NormalizePath(policy_path) != NormalizePath(endpoint.policy_path)) {
    Fail("portable recovery process is outside the stable endpoint");
  }
  StableTreeHandles tree = OpenStableTree(
      local_app_data.get(), endpoint, SidPointer(current.user), false);
  if (!tree.root.valid() || !tree.binding.valid() ||
      !tree.endpoint.valid()) {
    Fail("portable recovery stable endpoint is unavailable");
  }
  UniqueWindowsHandle helper_file = OpenSecureFile(
      tree.endpoint.get(), kHelperFileName, GENERIC_READ);
  UniqueWindowsHandle policy_file = OpenSecureFile(
      tree.endpoint.get(), kPolicyFileName, GENERIC_READ);
  RecordWindowsHelperEvent(
      WindowsHelperEvent::kPortableStageProvenanceFailure);
  ValidateExactUserSecurity(helper_file.get(), SidPointer(current.user),
                            false);
  ValidateExactUserSecurity(policy_file.get(), SidPointer(current.user),
                            false);
  const WindowsFileIdentity policy_identity =
      ReadWindowsFileIdentity(policy_file.get());
  ValidatePortableWindowsRetainedHelperFacts(
      helper, ReadWindowsFileIdentity(helper_file.get()),
      Sha256Handle(helper_file.get()), FinalPath(helper_file.get()));
  RecordWindowsHelperEvent(
      WindowsHelperEvent::kPortableStageManifestFailure);
  if (policy_identity.directory ||
      (policy_identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      policy_identity.number_of_links != 1 ||
      ReadHandle(policy_file.get(), kMaximumPolicyBytes) != canonical_policy ||
      NormalizePath(FinalPath(policy_file.get())) !=
          NormalizePath(endpoint.policy_path)) {
    Fail("portable recovery stable endpoint readback changed");
  }
  RecordWindowsHelperEvent(
      WindowsHelperEvent::kPortableStageRequestBindingFailure);
  return {std::move(policy), helper, std::move(endpoint)};
}

void ValidateCurrentPortableWindowsRecoveryHost(
    const WindowsHelperPolicy& expected_policy) {
  const auto bootstrap = LoadPortableWindowsRecoveryHostBootstrap();
  if (!PoliciesEqual(bootstrap.policy, expected_policy)) {
    Fail("portable recovery host policy differs from the transaction policy");
  }
}

PortableWindowsRecoveryHostTaskDefinition
BuildPortableWindowsRecoveryHostTaskDefinition(
    const PortableWindowsRecoveryHostEndpointV1& endpoint,
    const std::string& transaction_id,
    const std::string& recovery_ready_nonce) {
  ValidateEndpointShape(endpoint);
  if (!std::regex_match(transaction_id, kTransactionId) ||
      !IsReadyNonce(recovery_ready_nonce)) {
    Fail("portable recovery task authority is invalid");
  }
  const std::wstring transaction(transaction_id.begin(),
                                 transaction_id.end());
  const std::wstring nonce(recovery_ready_nonce.begin(),
                           recovery_ready_nonce.end());
  const std::wstring key = Utf8ToWide(endpoint.binding_sha256.substr(0, 16));
  PortableWindowsRecoveryHostTaskDefinition definition{
      transaction_id,
      recovery_ready_nonce,
      L"\\DesktopUpdater-Portable-" + key + L"-" + transaction,
      L"Local\\DesktopUpdater-PortableRecoveryReady-" + key + L"-" +
          transaction + L"-" + nonce,
      endpoint.helper_path,
      L"--portable-recover-current " + transaction,
      TaskSecurityDescriptor(endpoint.user_sid),
      endpoint.user_sid,
      TASK_LOGON_INTERACTIVE_TOKEN,
      TASK_RUNLEVEL_LUA,
      TASK_TRIGGER_LOGON,
      L"PT0M",
      L"",
      L"",
      TASK_CREATE | TASK_DONT_ADD_PRINCIPAL_ACE,
      kPortableWindowsTaskRunAsSelf,
  };
  ValidateTaskDefinition(definition);
  return definition;
}

bool IsPortableWindowsRecoveryTaskStartFallback(HRESULT result) {
  // SCHED_E_USER_NOT_LOGGED_ON is the documented interactive-token failure.
  constexpr HRESULT task_user_not_logged_on =
      static_cast<HRESULT>(0x80041320UL);
  // Hosted Windows standard-user runs created with CreateProcessWithLogonW
  // return this Task Scheduler result even though the task registration and
  // all definition readbacks are exact. Keep this empirical compatibility
  // path narrowly scoped to the same interactive-token start operation.
  constexpr HRESULT task_interactive_token_unavailable =
      static_cast<HRESULT>(0x8007136FUL);
  // Keep accepting the Task Scheduler-facility form observed on older
  // Windows builds as well.
  constexpr HRESULT task_interactive_token_unavailable_legacy =
      static_cast<HRESULT>(0x8004136FUL);
  // Task Scheduler may wrap the same scheduler start failure with either its
  // own facility or the Win32 facility. The stable error code is 0x136F.
  constexpr DWORD task_interactive_token_error_code = 0x136Fu;
  const bool task_interactive_token_error =
      (static_cast<DWORD>(result) & 0xFFFFu) ==
      task_interactive_token_error_code;
  return result == task_user_not_logged_on ||
         result == task_interactive_token_unavailable ||
         result == task_interactive_token_unavailable_legacy ||
         task_interactive_token_error;
}

std::string RunPortableWindowsRecoveryPrepareBoundary(
    std::function<void()> persist_preparing,
    std::function<void()> arm_and_read_back,
    std::function<std::string()> prepare_mutation) {
  if (!persist_preparing || !arm_and_read_back || !prepare_mutation) {
    Fail("portable recovery prepare dependency is unavailable");
  }
  persist_preparing();
  arm_and_read_back();
  return prepare_mutation();
}

bool ShouldDisarmPortableWindowsRecoveryHost(
    const std::string& result_code,
    const std::string& verified_outcome) {
  return (result_code == "completed" && verified_outcome == "newTarget") ||
         (result_code == "rolledBack" && verified_outcome == "oldTarget") ||
         (result_code == "relaunchFailure" &&
          (verified_outcome == "newTarget" ||
           verified_outcome == "oldTarget"));
}

PortableWindowsRecoveryResolution
RunPortableWindowsAutonomousRecoveryBoundary(
    PortableWindowsRecoveryHostController& controller,
    const PortableWindowsRecoveryHostTaskDefinition& definition,
    std::function<PortableWindowsRecoveryResolution()> recover) {
  ValidateTaskDefinition(definition);
  if (!recover) {
    Fail("portable autonomous recovery dependency is unavailable");
  }
  const PortableWindowsRecoveryResolution result = recover();
  if (ShouldDisarmPortableWindowsRecoveryHost(result.result_code,
                                               result.verified_outcome)) {
    controller.Disarm(definition);
  }
  return result;
}

void SignalPortableWindowsRecoveryHostReady(
    const PortableWindowsRecoveryHostTaskDefinition& definition) {
  ValidateTaskDefinition(definition);
  UniqueWindowsHandle event(OpenEventW(EVENT_MODIFY_STATE, FALSE,
                                       definition.ready_event_name.c_str()));
  if (!event.valid()) {
    if (GetLastError() == ERROR_FILE_NOT_FOUND) return;
    Fail("portable recovery readiness event cannot open");
  }
  if (!SetEvent(event.get())) {
    Fail("portable recovery readiness event cannot signal");
  }
}

namespace {

UniqueWindowsHandle LaunchPortableWindowsRecoveryHostDirect(
    const PortableWindowsRecoveryHostTaskDefinition& definition) {
  std::wstring command_line = L"\"" + definition.executable_path.wstring() +
                              L"\" " + definition.arguments;
  std::vector<wchar_t> mutable_command(command_line.begin(),
                                       command_line.end());
  mutable_command.push_back(L'\0');
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(
          definition.executable_path.c_str(), mutable_command.data(), nullptr,
          nullptr, FALSE, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
          nullptr, definition.executable_path.parent_path().c_str(), &startup,
          &process)) {
    Fail("portable recovery direct process launch failed");
  }
  RecordWindowsHelperEvent(WindowsHelperEvent::kPortableTargetAuthorityFailure);
  UniqueWindowsHandle thread(process.hThread);
  return UniqueWindowsHandle(process.hProcess);
}

}  // namespace

void TaskSchedulerPortableWindowsRecoveryHostController::ArmAndStart(
    const PortableWindowsRecoveryHostTaskDefinition& definition,
    DWORD startup_timeout_milliseconds) {
  PortableRecoveryProvisionDiagnostics diagnostics;
  ValidateTaskDefinition(definition);
  if (startup_timeout_milliseconds == 0) {
    Fail("portable recovery startup timeout is invalid");
  }
  const CurrentTokenFacts current = ReadCurrentTokenFacts();
  RequirePortableWindowsRecoveryTokenAuthority(
      definition.principal_user_id, current.user_sid, current.elevated,
      current.local_system);
  diagnostics.Advance(PortableRecoveryProvisionStage::kSource);
  PSECURITY_DESCRIPTOR raw_event_descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          definition.security_descriptor.c_str(), SDDL_REVISION_1,
          &raw_event_descriptor, nullptr) ||
      raw_event_descriptor == nullptr) {
    Fail("portable recovery readiness DACL construction failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> event_descriptor(
      raw_event_descriptor, LocalFree);
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = raw_event_descriptor;
  UniqueWindowsHandle ready_event(CreateEventW(
      &attributes, TRUE, FALSE, definition.ready_event_name.c_str()));
  if (!ready_event.valid() || GetLastError() == ERROR_ALREADY_EXISTS) {
    Fail("portable recovery readiness event is unavailable");
  }

  ScopedComInitialization com;
  ComPtr<ITaskService> service = ConnectTaskService();
  ComPtr<ITaskFolder> folder = RootTaskFolder(service.get());
  ComPtr<ITaskDefinition> task;
  Check(service.get()->NewTask(0, task.put()),
        "Task Scheduler definition creation failed");
  ConfigureTask(task.get(), definition);
  diagnostics.Advance(PortableRecoveryProvisionStage::kArtifact);
  ScopedBstr task_path(definition.task_path);
  // The principal on the task definition is already bound to the exact SID.
  // Passing that SID again as registration credentials makes Task Scheduler
  // resolve an interactive logon for a credentialed standard-user process;
  // that process may have no active Winlogon session (for example, a service
  // or CI-launched user process).  An empty user VARIANT keeps registration
  // in the caller's security context while preserving the exact principal.
  ScopedVariant user;
  ScopedVariant password;
  ScopedVariant security(definition.security_descriptor);
  ComPtr<IRegisteredTask> registered;
  constexpr HRESULT task_not_found = static_cast<HRESULT>(0x8004130FUL);
  const HRESULT lookup =
      folder.get()->GetTask(task_path.get(), registered.put());
  const bool missing =
      lookup == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
      lookup == task_not_found;
  if (!missing) {
    Check(lookup, "Task Scheduler portable recovery lookup failed");
    try {
      ValidateRegisteredTask(registered.get(), definition);
    } catch (const std::exception&) {
      (void)DecidePortableWindowsRecoveryTaskRegistration(
          PortableWindowsRecoveryTaskProbe::kMismatch);
      throw;
    }
    if (DecidePortableWindowsRecoveryTaskRegistration(
            PortableWindowsRecoveryTaskProbe::kExact) !=
        PortableWindowsRecoveryTaskRegistrationDecision::kReuseExact) {
      Fail("Task Scheduler exact task cannot be reused");
    }
  } else {
    if (DecidePortableWindowsRecoveryTaskRegistration(
            PortableWindowsRecoveryTaskProbe::kMissing) !=
        PortableWindowsRecoveryTaskRegistrationDecision::kRegisterNew) {
      Fail("Task Scheduler missing task cannot be registered");
    }
    diagnostics.Advance(PortableRecoveryProvisionStage::kStorage);
    const HRESULT registration = folder.get()->RegisterTaskDefinition(
        task_path.get(), task.get(), definition.registration_flags,
        user.value(), password.value(), definition.logon_type,
        security.value(), registered.put());
    if (registration != S_OK) {
      // TASK_CREATE never overwrites a concurrently-created task. A retry
      // must reopen and verify that exact task before any mutation proceeds.
      Fail("Task Scheduler portable recovery registration was incomplete");
    }
    diagnostics.Advance(PortableRecoveryProvisionStage::kArtifact);
    ValidateRegisteredTask(registered.get(), definition);
  }

  diagnostics.Advance(PortableRecoveryProvisionStage::kArtifact);
  ScopedVariant parameters;
  ScopedBstr run_user(AccountNameForSid(definition.principal_user_id));
  ComPtr<IRunningTask> running;
  UniqueWindowsHandle direct_process;
  const auto launch_direct_fallback = [&]() {
    if (direct_process.valid()) return;
    RecordWindowsHelperEvent(WindowsHelperEvent::kPortableAuthorizationFailure);
    direct_process = LaunchPortableWindowsRecoveryHostDirect(definition);
  };
  const HRESULT start = registered.get()->RunEx(
      parameters.value(), definition.run_flags, 0, run_user.get(),
      running.put());
  if (FAILED(start)) {
    const bool use_direct_fallback =
        IsPortableWindowsRecoveryTaskStartFallback(start);
    if (!use_direct_fallback) {
      Check(start, "Task Scheduler portable recovery start failed");
    }
    // The durable task has already passed exact registration/readback. A
    // credential-created standard-user process can still lack a Winlogon
    // session, so Task Scheduler cannot start its INTERACTIVE_TOKEN task.
    // Start the same verified helper directly in the current exact token and
    // keep the task registered for the next real user logon.
    launch_direct_fallback();
  }
  ULONGLONG started = GetTickCount64();
  const ULONGLONG task_fallback_grace_milliseconds =
      std::min<DWORD>(startup_timeout_milliseconds, 5'000);
  for (;;) {
    if (WaitForSingleObject(ready_event.get(), 25) == WAIT_OBJECT_0) return;
    const ULONGLONG elapsed = GetTickCount64() - started;
    if (!direct_process.valid() &&
        elapsed >= task_fallback_grace_milliseconds) {
      launch_direct_fallback();
      started = GetTickCount64();
      continue;
    }
    if (direct_process.valid()) {
      const DWORD process_wait = WaitForSingleObject(direct_process.get(), 0);
      if (process_wait == WAIT_OBJECT_0) {
        RecordWindowsHelperEvent(
            WindowsHelperEvent::kPortableTargetRequestFailure);
        Fail("portable recovery host exited before readiness");
      }
      if (process_wait == WAIT_FAILED) {
        Fail("portable recovery direct process state read failed");
      }
    }
    if (GetTickCount64() - started >= startup_timeout_milliseconds) {
      RecordWindowsHelperEvent(
          WindowsHelperEvent::kPortableTargetExecutableIdentityFailure);
      Fail("portable recovery host startup timed out");
    }
  }
}

void TaskSchedulerPortableWindowsRecoveryHostController::Disarm(
    const PortableWindowsRecoveryHostTaskDefinition& definition) {
  ValidateTaskDefinition(definition);
  const CurrentTokenFacts current = ReadCurrentTokenFacts();
  RequirePortableWindowsRecoveryTokenAuthority(
      definition.principal_user_id, current.user_sid, current.elevated,
      current.local_system);
  ScopedComInitialization com;
  ComPtr<ITaskService> service = ConnectTaskService();
  ComPtr<ITaskFolder> folder = RootTaskFolder(service.get());
  ScopedBstr task_path(definition.task_path);
  ComPtr<IRegisteredTask> registered;
  const HRESULT lookup = folder.get()->GetTask(task_path.get(),
                                               registered.put());
  constexpr HRESULT task_not_found = static_cast<HRESULT>(0x8004130FUL);
  if (lookup == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
      lookup == task_not_found) {
    return;
  }
  Check(lookup, "Task Scheduler portable recovery lookup failed");
  ValidateRegisteredTask(registered.get(), definition);
  const HRESULT result = folder.get()->DeleteTask(task_path.get(), 0);
  if (FAILED(result) && result != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) &&
      result != task_not_found) {
    Fail("Task Scheduler portable recovery removal failed");
  }
}

}  // namespace desktop_updater::helper
