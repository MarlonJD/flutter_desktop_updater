#include "windows_portable_transaction_index.h"

#include <winternl.h>

#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shlobj.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cwctype>
#include <filesystem>
#include <functional>
#include <limits>
#include <memory>
#include <regex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "json_value.h"
#include "windows_portable_recovery_host.h"
#include "windows_portable_user_storage.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;

constexpr std::size_t kMaximumRecordBytes = 1024 * 1024;
constexpr std::size_t kMaximumClaimBytes = 64 * 1024;
constexpr std::size_t kMaximumLocatorBytes = 128 * 1024;
constexpr wchar_t kIndexRootName[] =
    L"desktop_updater_portable_transactions_v1";
constexpr wchar_t kLocatorRootName[] = L"transaction_locators";
constexpr wchar_t kLocatorName[] = L"locator.json";
constexpr wchar_t kLocatorNextName[] = L"locator.next";
constexpr wchar_t kStableHostRootName[] =
    L"desktop_updater_portable_recovery_host_v1";
constexpr wchar_t kStableHelperName[] =
    L"desktop_updater_install_helper.exe";
constexpr wchar_t kStablePolicyName[] =
    L"desktop_updater_helper_policy.json";
constexpr wchar_t kRecordName[] = L"record.json";
constexpr wchar_t kRecordNextName[] = L"record.next";
constexpr wchar_t kClaimName[] = L"resolver_claim.json";
constexpr wchar_t kClaimNextName[] = L"resolver_claim.next";
const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
const std::regex kIdentifier(
    "^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$");

class NoWindowsPortableTransactionStoreFaultInjector final
    : public WindowsPortableTransactionStoreFaultInjector {
 public:
  void Hit(WindowsPortableTransactionStoreFaultPoint) override {}
};

[[noreturn]] void Fail(const std::string& detail) {
  throw std::runtime_error("portable transaction index: " + detail);
}

bool IsSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return std::isdigit(byte) != 0 || (byte >= 'a' && byte <= 'f');
         });
}

std::string Sha256Hex(const std::string& bytes) {
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
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_size),
                        sizeof(object_size), &received, 0) < 0) {
    cleanup();
    Fail("SHA-256 setup failed");
  }
  object.resize(object_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr, 0,
                       0) < 0) {
    cleanup();
    Fail("SHA-256 creation failed");
  }
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const ULONG count = static_cast<ULONG>(std::min<std::size_t>(
        bytes.size() - offset, std::numeric_limits<ULONG>::max()));
    if (BCryptHashData(
            hash,
            reinterpret_cast<PUCHAR>(
                const_cast<char*>(bytes.data() + offset)),
            count, 0) < 0) {
      cleanup();
      Fail("SHA-256 update failed");
    }
    offset += count;
  }
  if (BCryptFinishHash(hash, digest.data(),
                       static_cast<ULONG>(digest.size()), 0) < 0) {
    cleanup();
    Fail("SHA-256 finalization failed");
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

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty() ||
      value.size() > static_cast<std::size_t>(
                         std::numeric_limits<int>::max())) {
    Fail("UTF-8 value is invalid");
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) Fail("UTF-8 value is invalid");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    Fail("UTF-8 conversion failed");
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  if (value.size() >
      static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    Fail("wide value is too long");
  }
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) Fail("wide value is invalid");
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length, nullptr, nullptr) != length) {
    Fail("wide value conversion failed");
  }
  return result;
}

std::wstring NormalizePath(std::filesystem::path path) {
  std::wstring value = path.lexically_normal().wstring();
  if (value.rfind(L"\\\\?\\", 0) == 0) value.erase(0, 4);
  std::replace(value.begin(), value.end(), L'/', L'\\');
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  while (value.size() > 3 && value.back() == L'\\') value.pop_back();
  return value;
}

std::filesystem::path FinalPath(HANDLE handle) {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetFinalPathNameByHandleW(
      handle, buffer.data(), static_cast<DWORD>(buffer.size()),
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (length == 0 || length >= buffer.size()) {
    Fail("stable endpoint final path is unavailable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

void AppendBindingField(std::string* binding, const std::string& value) {
  *binding += std::to_string(value.size()) + ":" + value + "\n";
}

std::string PortablePolicyGenerationBinding(
    const WindowsHelperPolicy& policy) {
  std::string binding = "portable-index-generation-v2\n";
  AppendBindingField(&binding, policy.policy_id());
  AppendBindingField(&binding, policy.application_package_id());
  AppendBindingField(&binding, policy.helper_service_id());
  AppendBindingField(&binding, policy.application_signer_kind());
  AppendBindingField(&binding, policy.application_signer_identity());
  AppendBindingField(&binding, policy.helper_signer_kind());
  AppendBindingField(&binding, policy.helper_signer_identity());
  AppendBindingField(&binding, policy.helper_sha256());
  AppendBindingField(
      &binding, std::to_string(policy.minimum_helper_protocol_version()));
  AppendBindingField(&binding,
                     std::to_string(policy.allowed_install_roots().size()));
  for (const auto& root : policy.allowed_install_roots()) {
    AppendBindingField(&binding, WideToUtf8(root));
  }
  AppendBindingField(&binding,
                     std::to_string(policy.allowed_target_classes().size()));
  for (const auto& target_class : policy.allowed_target_classes()) {
    AppendBindingField(&binding, target_class);
  }
  AppendBindingField(
      &binding, std::to_string(policy.release_root_public_keys().size()));
  for (const auto& root : policy.release_root_public_keys()) {
    AppendBindingField(&binding, root.key_id);
    AppendBindingField(&binding, root.algorithm);
    AppendBindingField(&binding, root.public_key_base64);
  }
  AppendBindingField(&binding,
                     std::to_string(policy.allowed_strategies().size()));
  for (const auto& strategy : policy.allowed_strategies()) {
    AppendBindingField(&binding, strategy.strategy);
    AppendBindingField(&binding, strategy.provider);
  }
  return binding;
}

std::vector<unsigned char> ProcessUserSid(HANDLE process) {
  HANDLE raw_token = nullptr;
  if (process == nullptr || process == INVALID_HANDLE_VALUE ||
      !OpenProcessToken(process, TOKEN_QUERY, &raw_token)) {
    Fail("process token is unavailable");
  }
  UniqueWindowsHandle token(raw_token);
  DWORD size = 0;
  (void)GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
  if (size == 0 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
    Fail("process SID size is unavailable");
  }
  std::vector<unsigned char> bytes(size);
  if (!GetTokenInformation(token.get(), TokenUser, bytes.data(), size, &size)) {
    Fail("process SID is unavailable");
  }
  const auto* user = reinterpret_cast<const TOKEN_USER*>(bytes.data());
  if (user->User.Sid == nullptr || !IsValidSid(user->User.Sid)) {
    Fail("process SID is invalid");
  }
  const DWORD sid_size = GetLengthSid(user->User.Sid);
  std::vector<unsigned char> sid(sid_size);
  if (!CopySid(sid_size, sid.data(), user->User.Sid)) {
    Fail("process SID copy failed");
  }
  return sid;
}

std::wstring SidText(PSID sid) {
  LPWSTR raw = nullptr;
  if (sid == nullptr || !ConvertSidToStringSidW(sid, &raw) || raw == nullptr) {
    Fail("user SID conversion failed");
  }
  std::wstring result(raw);
  LocalFree(raw);
  return result;
}

void RequireCallerUser(HANDLE caller_process, PSID expected_user) {
  if (caller_process == nullptr || caller_process == INVALID_HANDLE_VALUE) {
    return;
  }
  std::vector<unsigned char> caller = ProcessUserSid(caller_process);
  if (!EqualSid(caller.data(), expected_user)) {
    Fail("caller token is not the current user");
  }
}

UniqueWindowsHandle OpenLocalAppData(
    std::filesystem::path* retained_path = nullptr) {
  return OpenPortableWindowsExactUserLocalAppData(retained_path);
}

UniqueWindowsHandle OpenSecureDirectory(HANDLE parent,
                                        const std::wstring& leaf,
                                        ULONG disposition,
                                        PSID expected_user,
                                        const std::wstring& user_sid) {
  if (disposition != FILE_OPEN && disposition != FILE_CREATE &&
      disposition != FILE_OPEN_IF) {
    Fail("index directory disposition is invalid");
  }
  constexpr ACCESS_MASK access =
      FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY |
      FILE_READ_ATTRIBUTES | READ_CONTROL | WRITE_DAC | WRITE_OWNER | DELETE |
      SYNCHRONIZE;
  constexpr ULONG share =
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
  constexpr ULONG options =
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT;
  auto validate = [&](UniqueWindowsHandle directory) {
    const WindowsFileIdentity identity =
        ReadWindowsFileIdentity(directory.get());
    if (!identity.directory) Fail("index component is not a directory");
    ValidatePortableWindowsExactUserSecurity(directory.get(), expected_user,
                                             true);
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
          parent, leaf, access, share, options, FILE_ATTRIBUTE_HIDDEN,
          expected_user, user_sid);
    } catch (...) {
      // Only the atomic FILE_CREATE is race-recoverable. Validation and the
      // durability barrier below are never converted into apparent success.
      if (disposition != FILE_OPEN_IF ||
          !ExistsRelativeNoReparse(parent, leaf)) {
        throw;
      }
      return open_existing();
    }
    directory = validate(std::move(directory));
    FlushWindowsDirectory(parent);
    return directory;
  };

  const bool exists = ExistsRelativeNoReparse(parent, leaf);
  if (disposition == FILE_OPEN) {
    return exists ? open_existing() : UniqueWindowsHandle();
  }
  if (disposition == FILE_CREATE) {
    if (exists) Fail("index component already exists");
    return create_new();
  }

  if (exists) {
    try {
      return open_existing();
    } catch (...) {
      // A concurrent deletion may turn an observed object into a missing one.
      // An object that still exists must be validated, never replaced.
      if (ExistsRelativeNoReparse(parent, leaf)) throw;
    }
  }
  return create_new();
}

std::string ReadHandle(HANDLE file, std::size_t maximum_bytes) {
  LARGE_INTEGER beginning{};
  if (!SetFilePointerEx(file, beginning, nullptr, FILE_BEGIN)) {
    Fail("record seek failed");
  }
  std::string result;
  std::array<char, 4096> buffer{};
  for (;;) {
    DWORD read = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &read,
                  nullptr)) {
      Fail("record read failed");
    }
    if (read == 0) return result;
    if (result.size() + read > maximum_bytes) Fail("record exceeds size limit");
    result.append(buffer.data(), read);
  }
}

using PortableCanonicalValidator =
    std::function<void(const std::string& canonical)>;
using PortableValidPairReconciler = std::function<
    WindowsPortableValidPairDecision(const std::string& final_canonical,
                                     const std::string& next_canonical)>;

struct PortableDurableFileCandidate {
  WindowsPortableDurableFileProbe probe =
      WindowsPortableDurableFileProbe::kMissing;
  UniqueWindowsHandle handle;
  std::string canonical;
};

PortableDurableFileCandidate ProbePortableDurableFile(
    HANDLE directory,
    const std::wstring& leaf,
    std::size_t maximum_bytes,
    PSID expected_user,
    bool exclusive_delete,
    const PortableCanonicalValidator& validate) {
  PortableDurableFileCandidate candidate;
  try {
    if (!ExistsRelativeNoReparse(directory, leaf)) return candidate;
    candidate.handle = OpenRelativeNoReparse(
        directory, leaf,
        GENERIC_READ | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE |
            (exclusive_delete ? DELETE : static_cast<ACCESS_MASK>(0)),
        exclusive_delete ? 0 : FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
        FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
    ValidatePortableWindowsExactUserSecurity(candidate.handle.get(),
                                             expected_user, false);
  } catch (const std::exception&) {
    candidate.handle.reset();
    candidate.probe = WindowsPortableDurableFileProbe::kUnsafe;
    return candidate;
  }
  candidate.canonical = ReadHandle(candidate.handle.get(), maximum_bytes);
  if (candidate.canonical.empty()) {
    candidate.probe = WindowsPortableDurableFileProbe::kExactEmpty;
    return candidate;
  }
  try {
    validate(candidate.canonical);
    candidate.probe = WindowsPortableDurableFileProbe::kExactValid;
  } catch (const std::exception&) {
    candidate.probe = WindowsPortableDurableFileProbe::kExactInvalid;
  }
  return candidate;
}

std::optional<std::string> ReadSecureFile(
    HANDLE directory,
    const std::wstring& leaf,
    const std::wstring& next_leaf,
    std::size_t maximum_bytes,
    PSID expected_user,
    const PortableCanonicalValidator& validate,
    const PortableValidPairReconciler& reconcile) {
  auto final_file = ProbePortableDurableFile(
      directory, leaf, maximum_bytes, expected_user, false, validate);
  auto next_file = ProbePortableDurableFile(
      directory, next_leaf, maximum_bytes, expected_user, true, validate);
  switch (DecideWindowsPortableDurableFileRecovery(final_file.probe,
                                                   next_file.probe)) {
    case WindowsPortableDurableFileDecision::kUnavailable:
      return std::nullopt;
    case WindowsPortableDurableFileDecision::kDiscardNextAndUnavailable:
      DeleteHandleExact(next_file.handle.get());
      next_file.handle.reset();
      FlushWindowsDirectory(directory);
      return std::nullopt;
    case WindowsPortableDurableFileDecision::kUseFinal:
      return final_file.canonical;
    case WindowsPortableDurableFileDecision::kUseFinalAndDiscardNext:
      DeleteHandleExact(next_file.handle.get());
      next_file.handle.reset();
      FlushWindowsDirectory(directory);
      return final_file.canonical;
    case WindowsPortableDurableFileDecision::kReconcileValidPair:
      if (reconcile(final_file.canonical, next_file.canonical) !=
          WindowsPortableValidPairDecision::kPromoteNext) {
        Fail("durable record valid pair is not a forward transition");
      }
      [[fallthrough]];
    case WindowsPortableDurableFileDecision::kPromoteNext: {
      const std::string promoted = next_file.canonical;
      RenameHandleRelative(
          next_file.handle.get(), directory, leaf,
          final_file.probe != WindowsPortableDurableFileProbe::kMissing);
      next_file.handle.reset();
      final_file.handle.reset();
      FlushWindowsDirectory(directory);
      const auto readback = ReadSecureFile(
          directory, leaf, next_leaf, maximum_bytes, expected_user, validate,
          reconcile);
      if (!readback.has_value() || *readback != promoted) {
        Fail("promoted crash record readback changed");
      }
      return readback;
    }
    case WindowsPortableDurableFileDecision::kReject:
      Fail("durable record crash state is unsafe or corrupt");
  }
  Fail("durable record crash decision is invalid");
}

void WriteSecureFile(HANDLE directory,
                     const std::wstring& leaf,
                     const std::wstring& next_leaf,
                     const std::string& canonical,
                     std::size_t maximum_bytes,
                     PSID expected_user,
                     const std::wstring& user_sid,
                     const PortableCanonicalValidator& validate,
                     const PortableValidPairReconciler& reconcile,
                     WindowsPortableTransactionStoreFaultInjector* fault) {
  if (canonical.empty() || canonical.size() > maximum_bytes) {
    Fail("record length is invalid");
  }
  validate(canonical);
  const auto current = ReadSecureFile(directory, leaf, next_leaf,
                                      maximum_bytes, expected_user, validate,
                                      reconcile);
  if (current.has_value() &&
      reconcile(*current, canonical) !=
          WindowsPortableValidPairDecision::kPromoteNext) {
    Fail("durable record update is not a forward transition");
  }
  UniqueWindowsHandle next = CreatePortableWindowsExactUserFile(
      directory, next_leaf,
      GENERIC_READ | GENERIC_WRITE | DELETE | FILE_READ_ATTRIBUTES |
          READ_CONTROL | WRITE_DAC | WRITE_OWNER | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH,
      FILE_ATTRIBUTE_HIDDEN, expected_user, user_sid);
  fault->Hit(
      WindowsPortableTransactionStoreFaultPoint::kAfterNextCreate);
  DWORD written = 0;
  if (canonical.size() > std::numeric_limits<DWORD>::max() ||
      !WriteFile(next.get(), canonical.data(),
                 static_cast<DWORD>(canonical.size()), &written, nullptr) ||
      written != canonical.size() || !FlushFileBuffers(next.get())) {
    Fail("record durable write failed");
  }
  fault->Hit(
      WindowsPortableTransactionStoreFaultPoint::kAfterNextFlush);
  RenameHandleRelative(next.get(), directory, leaf, true);
  fault->Hit(WindowsPortableTransactionStoreFaultPoint::
                 kAfterRenameBeforeDirectoryFlush);
  FlushWindowsDirectory(directory);
  const auto readback = ReadSecureFile(directory, leaf, next_leaf,
                                       maximum_bytes, expected_user, validate,
                                       reconcile);
  if (!readback.has_value() || *readback != canonical) {
    Fail("record durable readback changed");
  }
}

void ValidatePortableLocatorFields(
    const WindowsPortableTransactionLocatorV1& locator) {
  if (locator.schema_version !=
          WindowsPortableTransactionLocatorV1::kSchemaVersion ||
      !std::regex_match(locator.transaction_id, kTransactionId) ||
      !std::regex_match(locator.policy_id, kIdentifier) ||
      !std::regex_match(locator.package_id, kIdentifier) ||
      !IsSha256(locator.index_binding_sha256) ||
      !IsSha256(locator.helper_sha256) ||
      !IsSha256(locator.policy_sha256)) {
    Fail("portable transaction locator authority is invalid");
  }
}

void ValidatePortableLocatorCanonical(const std::string& transaction_id,
                                      const std::string& canonical) {
  const WindowsPortableTransactionLocatorV1 locator =
      WindowsPortableTransactionLocatorV1::DecodeStrict(canonical);
  if (locator.transaction_id != transaction_id) {
    Fail("portable transaction locator ID changed");
  }
}

std::string StableHostBinding(
    const WindowsPortableTransactionLocatorV1& locator,
    const std::wstring& user_sid) {
  return Sha256Hex("portable-recovery-host-v1\n" + locator.policy_id + "\n" +
                   locator.package_id + "\n" + locator.helper_sha256 + "\n" +
                   locator.policy_sha256 + "\n" + WideToUtf8(user_sid));
}

ResolvedWindowsPortableTransactionEndpointV1 ResolveStableEndpointPaths(
    const WindowsPortableTransactionLocatorV1& locator,
    const std::wstring& user_sid,
    const std::filesystem::path& local_app_data_path) {
  ValidatePortableLocatorFields(locator);
  if (user_sid.empty() || !local_app_data_path.is_absolute() ||
      local_app_data_path.lexically_normal() != local_app_data_path) {
    Fail("portable transaction stable endpoint root is invalid");
  }
  const std::string binding = StableHostBinding(locator, user_sid);
  const std::filesystem::path endpoint_path =
      local_app_data_path / kStableHostRootName / Utf8ToWide(binding) /
      Utf8ToWide(locator.helper_sha256 + "-" + locator.policy_sha256);
  return {locator,
          user_sid,
          local_app_data_path,
          endpoint_path,
          endpoint_path / kStableHelperName,
          endpoint_path / kStablePolicyName};
}

UniqueWindowsHandle OpenExactStableFile(HANDLE parent,
                                        const std::wstring& leaf,
                                        const std::filesystem::path& expected,
                                        PSID user) {
  auto file = OpenRelativeNoReparse(
      parent, leaf,
      GENERIC_READ | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  ValidatePortableWindowsExactUserSecurity(file.get(), user, false);
  const WindowsFileIdentity identity = ReadWindowsFileIdentity(file.get());
  if (identity.directory ||
      (identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      identity.number_of_links != 1 ||
      NormalizePath(FinalPath(file.get())) != NormalizePath(expected)) {
    Fail("portable transaction stable endpoint file changed");
  }
  return file;
}

void ValidateStableEndpointStorage(
    HANDLE local_app_data,
    const ResolvedWindowsPortableTransactionEndpointV1& endpoint,
    PSID user) {
  auto root = OpenSecureDirectory(
      local_app_data, kStableHostRootName, FILE_OPEN, user,
      endpoint.user_sid);
  if (!root.valid()) Fail("portable stable host root is unavailable");
  const std::string binding =
      StableHostBinding(endpoint.locator, endpoint.user_sid);
  auto binding_directory = OpenSecureDirectory(
      root.get(), Utf8ToWide(binding), FILE_OPEN, user, endpoint.user_sid);
  if (!binding_directory.valid()) {
    Fail("portable stable host binding is unavailable");
  }
  auto endpoint_directory = OpenSecureDirectory(
      binding_directory.get(),
      Utf8ToWide(endpoint.locator.helper_sha256 + "-" +
                 endpoint.locator.policy_sha256),
      FILE_OPEN, user, endpoint.user_sid);
  if (!endpoint_directory.valid()) {
    Fail("portable stable host endpoint is unavailable");
  }
  auto helper = OpenExactStableFile(endpoint_directory.get(),
                                    kStableHelperName, endpoint.helper_path,
                                    user);
  auto policy = OpenExactStableFile(endpoint_directory.get(),
                                    kStablePolicyName, endpoint.policy_path,
                                    user);
  (void)helper;
  (void)policy;
}

void ValidatePortableProbeRecord(const WindowsHelperPolicy& policy,
                                 const std::string& transaction_id,
                                 const std::string& canonical) {
  const JsonValue value = ParseJson(canonical);
  if (EncodeCanonicalJson(value) != canonical) {
    Fail("record is not canonical JSON");
  }
  const std::set<std::string> expected = {
      "callerProcessId",
      "callerProcessStartIdentity",
      "executorProcessId",
      "executorProcessStartIdentity",
      "helperEndpointIdentitySha256",
      "journalCanonical",
      "journalSha256",
      "packageId",
      "policyId",
      "recordState",
      "recoveryReadyNonce",
      "relaunchState",
      "schemaVersion",
      "targetPathHint",
      "transactionId",
      "verifiedOutcome",
  };
  std::set<std::string> actual;
  for (const auto& entry : value.object()) actual.insert(entry.first);
  const std::string journal = value.at("journalCanonical").string();
  const std::string state = value.at("recordState").string();
  const std::string outcome = value.at("verifiedOutcome").string();
  const std::string relaunch = value.at("relaunchState").string();
  const std::string nonce = value.at("recoveryReadyNonce").string();
  const std::int64_t executor_id = value.at("executorProcessId").integer();
  const std::int64_t executor_start =
      value.at("executorProcessStartIdentity").integer();
  const std::int64_t caller_id = value.at("callerProcessId").integer();
  const std::int64_t caller_start =
      value.at("callerProcessStartIdentity").integer();
  const std::filesystem::path target_path =
      std::filesystem::path(Utf8ToWide(value.at("targetPathHint").string()));
  const std::set<std::string> record_states = {
      "preparing", "prepared", "commitAccepted", "cancelling",
      "completedCleanupPending", "rolledBackCleanupPending", "completed",
      "rolledBack", "manualActionRequired"};
  const std::set<std::string> relaunch_states = {
      "notRequested", "launchPending", "launchAttempting", "launched",
      "launchFailed"};
  const auto valid_nonce_character = [](unsigned char byte) {
    return std::isalnum(byte) != 0 || byte == '-' || byte == '_';
  };
  const bool completed =
      state == "completed" || state == "completedCleanupPending";
  const bool rolled_back =
      state == "rolledBack" || state == "rolledBackCleanupPending";
  const bool terminal = state == "completed" || state == "rolledBack";
  const bool commit_requires_relaunch =
      state == "commitAccepted" || state == "completedCleanupPending" ||
      state == "completed";
  const bool attempt_started = relaunch == "launchAttempting" ||
                               relaunch == "launched" ||
                               relaunch == "launchFailed";
  if (actual != expected || value.at("schemaVersion").integer() != 3 ||
      value.at("transactionId").string() != transaction_id ||
      value.at("policyId").string() != policy.policy_id() ||
      value.at("packageId").string() != policy.application_package_id() ||
      value.at("helperEndpointIdentitySha256").string() !=
          policy.helper_sha256() ||
      executor_id <= 0 || executor_id > std::numeric_limits<DWORD>::max() ||
      executor_start <= 0 || caller_id <= 0 ||
      caller_id > std::numeric_limits<DWORD>::max() || caller_start <= 0 ||
      nonce.size() != 43 ||
      !std::all_of(nonce.begin(), nonce.end(), valid_nonce_character) ||
      !target_path.is_absolute() ||
      target_path.lexically_normal() != target_path ||
      target_path.filename().empty() || record_states.count(state) == 0 ||
      !IsSha256(value.at("journalSha256").string()) || journal.empty() ||
      relaunch_states.count(relaunch) == 0 ||
      (completed && outcome != "newTarget") ||
      (rolled_back && outcome != "oldTarget") ||
      (!completed && !rolled_back && outcome != "none") ||
      (commit_requires_relaunch && relaunch == "notRequested") ||
      (attempt_started && !terminal) ||
      (!terminal && relaunch != "notRequested" &&
       relaunch != "launchPending") ||
      Sha256Hex(journal) != value.at("journalSha256").string()) {
    Fail("record authority binding changed");
  }
  const WindowsTransactionJournal decoded =
      WindowsTransactionJournal::DecodeStrict(journal);
  if (decoded.transaction_id != transaction_id ||
      decoded.owner_process_id != static_cast<DWORD>(executor_id) ||
      decoded.owner_process_start_identity !=
          static_cast<std::uint64_t>(executor_start) ||
      decoded.target_name != target_path.filename().wstring()) {
    Fail("record journal authority binding changed");
  }
}

void ValidatePortableResolverClaim(const std::string& transaction_id,
                                   const std::string& canonical) {
  const JsonValue value = ParseJson(canonical);
  if (EncodeCanonicalJson(value) != canonical) {
    Fail("resolver claim is not canonical JSON");
  }
  const std::set<std::string> expected = {
      "callerProcessId", "callerProcessStartIdentity", "claimNonce",
      "resolverProcessId", "resolverProcessStartIdentity", "schemaVersion",
      "state", "transactionId"};
  std::set<std::string> actual;
  for (const auto& entry : value.object()) actual.insert(entry.first);
  const std::string nonce = value.at("claimNonce").string();
  const std::string state = value.at("state").string();
  const auto valid_nonce_character = [](unsigned char byte) {
    return std::isalnum(byte) != 0 || byte == '-' || byte == '_';
  };
  if (actual != expected || value.at("schemaVersion").integer() != 1 ||
      value.at("transactionId").string() != transaction_id ||
      value.at("resolverProcessId").integer() <= 0 ||
      value.at("resolverProcessId").integer() >
          std::numeric_limits<DWORD>::max() ||
      value.at("resolverProcessStartIdentity").integer() <= 0 ||
      value.at("callerProcessId").integer() <= 0 ||
      value.at("callerProcessId").integer() >
          std::numeric_limits<DWORD>::max() ||
      value.at("callerProcessStartIdentity").integer() <= 0 ||
      nonce.size() != 43 ||
      !std::all_of(nonce.begin(), nonce.end(), valid_nonce_character) ||
      (state != "claimed" && state != "consumed")) {
    Fail("resolver claim authority binding changed");
  }
}

struct PortableRecordTransitionFacts {
  std::string immutable_binding;
  std::string state;
  std::string outcome;
  std::string relaunch;
};

PortableRecordTransitionFacts ReadPortableRecordTransitionFacts(
    const WindowsHelperPolicy& policy,
    const std::string& transaction_id,
    const std::string& canonical) {
  ValidatePortableProbeRecord(policy, transaction_id, canonical);
  const JsonValue value = ParseJson(canonical);
  JsonValue::Object immutable;
  for (const char* key : {
           "callerProcessId",
           "callerProcessStartIdentity",
           "executorProcessId",
           "executorProcessStartIdentity",
           "helperEndpointIdentitySha256",
           "journalCanonical",
           "journalSha256",
           "packageId",
           "policyId",
           "recoveryReadyNonce",
           "schemaVersion",
           "targetPathHint",
           "transactionId",
       }) {
    immutable.emplace(key, value.at(key));
  }
  return {EncodeCanonicalJson(JsonValue(std::move(immutable))),
          value.at("recordState").string(),
          value.at("verifiedOutcome").string(),
          value.at("relaunchState").string()};
}

bool IsTerminalRecordState(const std::string& state) {
  return state == "completed" || state == "rolledBack" ||
         state == "manualActionRequired";
}

bool IsRelaunchForwardTransition(const std::string& record_state,
                                 const std::string& final_state,
                                 const std::string& next_state) {
  if (final_state == next_state) return true;
  if (final_state == "notRequested" && next_state == "launchPending") {
    return record_state != "manualActionRequired";
  }
  const bool relaunchable_terminal =
      record_state == "completed" || record_state == "rolledBack";
  if (!relaunchable_terminal) return false;
  if (final_state == "launchPending" && next_state == "launchAttempting") {
    return true;
  }
  return final_state == "launchAttempting" &&
         (next_state == "launched" || next_state == "launchFailed");
}

bool IsRecordForwardTransition(const PortableRecordTransitionFacts& final,
                               const PortableRecordTransitionFacts& next) {
  if (final.immutable_binding != next.immutable_binding) return false;
  if (final.state == next.state) {
    return final.outcome == next.outcome &&
           IsRelaunchForwardTransition(final.state, final.relaunch,
                                       next.relaunch);
  }
  if (next.state == "manualActionRequired") {
    return !IsTerminalRecordState(final.state) && next.outcome == "none" &&
           final.relaunch == next.relaunch;
  }
  if (final.state == "preparing" && next.state == "prepared") {
    return final.outcome == "none" && next.outcome == "none" &&
           final.relaunch == next.relaunch;
  }
  if ((final.state == "preparing" || final.state == "prepared" ||
       final.state == "commitAccepted") &&
      next.state == "cancelling") {
    return final.outcome == "none" && next.outcome == "none" &&
           final.relaunch == next.relaunch;
  }
  if (final.state == "prepared" && next.state == "commitAccepted") {
    return final.outcome == "none" && next.outcome == "none" &&
           next.relaunch == "launchPending" &&
           (final.relaunch == "notRequested" ||
            final.relaunch == "launchPending");
  }
  if (final.state == "commitAccepted" &&
      next.state == "completedCleanupPending") {
    return final.outcome == "none" && next.outcome == "newTarget" &&
           final.relaunch == next.relaunch;
  }
  if (final.state == "cancelling" &&
      next.state == "rolledBackCleanupPending") {
    return final.outcome == "none" && next.outcome == "oldTarget" &&
           final.relaunch == next.relaunch;
  }
  if (final.state == "completedCleanupPending" &&
      next.state == "completed") {
    return final.outcome == "newTarget" && next.outcome == "newTarget" &&
           final.relaunch == next.relaunch;
  }
  if (final.state == "rolledBackCleanupPending" &&
      next.state == "rolledBack") {
    return final.outcome == "oldTarget" && next.outcome == "oldTarget" &&
           final.relaunch == next.relaunch;
  }
  return false;
}

struct PortableResolverTransitionFacts {
  std::string caller_binding;
  std::string resolver_binding;
  std::string state;
};

PortableResolverTransitionFacts ReadPortableResolverTransitionFacts(
    const std::string& transaction_id,
    const std::string& canonical) {
  ValidatePortableResolverClaim(transaction_id, canonical);
  const JsonValue value = ParseJson(canonical);
  JsonValue::Object caller;
  for (const char* key : {"callerProcessId", "callerProcessStartIdentity",
                          "schemaVersion", "transactionId"}) {
    caller.emplace(key, value.at(key));
  }
  JsonValue::Object resolver;
  for (const char* key : {"claimNonce", "resolverProcessId",
                          "resolverProcessStartIdentity"}) {
    resolver.emplace(key, value.at(key));
  }
  return {EncodeCanonicalJson(JsonValue(std::move(caller))),
          EncodeCanonicalJson(JsonValue(std::move(resolver))),
          value.at("state").string()};
}

}  // namespace

std::string WindowsPortableTransactionLocatorV1::EncodeCanonical() const {
  ValidatePortableLocatorFields(*this);
  JsonValue::Object object;
  object.emplace("helperSha256", JsonValue(helper_sha256));
  object.emplace("indexBindingSha256", JsonValue(index_binding_sha256));
  object.emplace("packageId", JsonValue(package_id));
  object.emplace("policyId", JsonValue(policy_id));
  object.emplace("policySha256", JsonValue(policy_sha256));
  object.emplace("schemaVersion", JsonValue(schema_version));
  object.emplace("transactionId", JsonValue(transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

WindowsPortableTransactionLocatorV1
WindowsPortableTransactionLocatorV1::DecodeStrict(
    const std::string& canonical_json) {
  try {
    const JsonValue value = ParseJson(canonical_json);
    if (EncodeCanonicalJson(value) != canonical_json) {
      Fail("portable transaction locator is not canonical JSON");
    }
    const std::set<std::string> expected = {
        "helperSha256", "indexBindingSha256", "packageId", "policyId",
        "policySha256", "schemaVersion", "transactionId"};
    std::set<std::string> actual;
    for (const auto& entry : value.object()) actual.insert(entry.first);
    if (actual != expected) {
      Fail("portable transaction locator fields changed");
    }
    WindowsPortableTransactionLocatorV1 locator;
    locator.schema_version = value.at("schemaVersion").integer();
    locator.transaction_id = value.at("transactionId").string();
    locator.index_binding_sha256 =
        value.at("indexBindingSha256").string();
    locator.policy_id = value.at("policyId").string();
    locator.package_id = value.at("packageId").string();
    locator.helper_sha256 = value.at("helperSha256").string();
    locator.policy_sha256 = value.at("policySha256").string();
    if (locator.EncodeCanonical() != canonical_json) {
      Fail("portable transaction locator encoding changed");
    }
    return locator;
  } catch (const std::exception&) {
    Fail("portable transaction locator is invalid");
  }
}

bool WindowsPortableTransactionLocatorV1::operator==(
    const WindowsPortableTransactionLocatorV1& other) const {
  return schema_version == other.schema_version &&
         transaction_id == other.transaction_id &&
         index_binding_sha256 == other.index_binding_sha256 &&
         policy_id == other.policy_id && package_id == other.package_id &&
         helper_sha256 == other.helper_sha256 &&
         policy_sha256 == other.policy_sha256;
}

WindowsPortableTransactionLocatorV1 BuildWindowsPortableTransactionLocator(
    const std::string& transaction_id,
    const WindowsHelperPolicy& policy,
    const PortableWindowsRecoveryHostEndpointV1& endpoint) {
  WindowsPortableTransactionLocatorV1 locator{
      WindowsPortableTransactionLocatorV1::kSchemaVersion,
      transaction_id,
      WindowsPortableIndexBindingKey(policy),
      policy.policy_id(),
      policy.application_package_id(),
      endpoint.helper_sha256,
      endpoint.policy_sha256,
  };
  ValidatePortableLocatorFields(locator);
  const auto resolved = ResolveStableEndpointPaths(
      locator, endpoint.user_sid, endpoint.local_app_data_path);
  if (!policy.is_portable() ||
      endpoint.schema_version !=
          PortableWindowsRecoveryHostEndpointV1::kSchemaVersion ||
      endpoint.policy_id != locator.policy_id ||
      endpoint.package_id != locator.package_id ||
      endpoint.helper_sha256 != policy.helper_sha256() ||
      endpoint.binding_sha256 !=
          StableHostBinding(locator, endpoint.user_sid) ||
      NormalizePath(endpoint.endpoint_path) !=
          NormalizePath(resolved.endpoint_path) ||
      NormalizePath(endpoint.helper_path) !=
          NormalizePath(resolved.helper_path) ||
      NormalizePath(endpoint.policy_path) !=
          NormalizePath(resolved.policy_path)) {
    Fail("portable transaction locator endpoint binding changed");
  }
  return locator;
}

void BindWindowsPortableTransactionEndpoint(
    const std::string& transaction_id,
    const WindowsHelperPolicy& policy,
    const PortableWindowsRecoveryHostEndpointV1& endpoint,
    HANDLE caller_process) {
  const WindowsPortableTransactionLocatorV1 locator =
      BuildWindowsPortableTransactionLocator(transaction_id, policy, endpoint);
  std::vector<unsigned char> user = ProcessUserSid(GetCurrentProcess());
  const std::wstring user_sid = SidText(user.data());
  RequireCallerUser(caller_process, user.data());
  std::filesystem::path local_app_data_path;
  auto local_app_data = OpenLocalAppData(&local_app_data_path);
  if (user_sid != endpoint.user_sid ||
      NormalizePath(local_app_data_path) !=
          NormalizePath(endpoint.local_app_data_path)) {
    Fail("portable transaction locator current-user root changed");
  }
  auto root = OpenSecureDirectory(
      local_app_data.get(), kIndexRootName, FILE_OPEN_IF, user.data(),
      user_sid);
  auto locators = OpenSecureDirectory(
      root.get(), kLocatorRootName, FILE_OPEN_IF, user.data(), user_sid);
  auto transaction = OpenSecureDirectory(
      locators.get(), Utf8ToWide(transaction_id), FILE_OPEN_IF, user.data(),
      user_sid);
  NoWindowsPortableTransactionStoreFaultInjector no_fault;
  const auto validate = [&transaction_id](const auto& bytes) {
    ValidatePortableLocatorCanonical(transaction_id, bytes);
  };
  const auto reconcile = [](const auto& final_bytes, const auto& next_bytes) {
    return final_bytes == next_bytes
               ? WindowsPortableValidPairDecision::kPromoteNext
               : WindowsPortableValidPairDecision::kReject;
  };
  const auto existing = ReadSecureFile(
      transaction.get(), kLocatorName, kLocatorNextName, kMaximumLocatorBytes,
      user.data(), validate, reconcile);
  const std::string canonical = locator.EncodeCanonical();
  if (existing.has_value()) {
    if (*existing != canonical) {
      Fail("portable transaction locator immutable binding changed");
    }
    return;
  }
  WriteSecureFile(transaction.get(), kLocatorName, kLocatorNextName,
                  canonical, kMaximumLocatorBytes, user.data(), user_sid,
                  validate, reconcile, &no_fault);
  FlushWindowsDirectory(locators.get());
}

std::optional<ResolvedWindowsPortableTransactionEndpointV1>
LoadWindowsPortableTransactionEndpoint(const std::string& transaction_id) {
  if (!std::regex_match(transaction_id, kTransactionId)) {
    Fail("portable transaction locator ID is invalid");
  }
  std::vector<unsigned char> user = ProcessUserSid(GetCurrentProcess());
  const std::wstring user_sid = SidText(user.data());
  std::filesystem::path local_app_data_path;
  auto local_app_data = OpenLocalAppData(&local_app_data_path);
  auto root = OpenSecureDirectory(local_app_data.get(), kIndexRootName,
                                  FILE_OPEN, user.data(), user_sid);
  if (!root.valid()) return std::nullopt;
  auto locators = OpenSecureDirectory(root.get(), kLocatorRootName, FILE_OPEN,
                                      user.data(), user_sid);
  if (!locators.valid()) return std::nullopt;
  auto transaction = OpenSecureDirectory(
      locators.get(), Utf8ToWide(transaction_id), FILE_OPEN, user.data(),
      user_sid);
  if (!transaction.valid()) return std::nullopt;
  const auto validate = [&transaction_id](const auto& bytes) {
    ValidatePortableLocatorCanonical(transaction_id, bytes);
  };
  const auto reconcile = [](const auto& final_bytes, const auto& next_bytes) {
    return final_bytes == next_bytes
               ? WindowsPortableValidPairDecision::kPromoteNext
               : WindowsPortableValidPairDecision::kReject;
  };
  const auto encoded = ReadSecureFile(
      transaction.get(), kLocatorName, kLocatorNextName, kMaximumLocatorBytes,
      user.data(), validate, reconcile);
  if (!encoded.has_value()) return std::nullopt;
  const WindowsPortableTransactionLocatorV1 locator =
      WindowsPortableTransactionLocatorV1::DecodeStrict(*encoded);
  auto resolved =
      ResolveStableEndpointPaths(locator, user_sid, local_app_data_path);
  ValidateStableEndpointStorage(local_app_data.get(), resolved, user.data());
  return resolved;
}

WindowsPortableTransactionResolution
ResolveWindowsPortableTransactionAuthority(
    const WindowsPortableTransactionLocatorV1& locator,
    const WindowsHelperPolicy& frozen_policy,
    const std::string& transaction_id,
    const std::string& canonical_record,
    const VerifiedWindowsExecutable& caller_identity,
    const std::filesystem::path& observed_process_path,
    bool identity_still_matches) {
  try {
    (void)locator.EncodeCanonical();
    if (!frozen_policy.is_portable() ||
        locator.transaction_id != transaction_id ||
        locator.index_binding_sha256 !=
            WindowsPortableIndexBindingKey(frozen_policy) ||
        locator.policy_id != frozen_policy.policy_id() ||
        locator.package_id != frozen_policy.application_package_id() ||
        locator.helper_sha256 != frozen_policy.helper_sha256()) {
      return WindowsPortableTransactionResolution::kReject;
    }
    return DecideWindowsPortableTransactionCallerAuthority(
        frozen_policy, transaction_id, canonical_record, caller_identity,
        observed_process_path, identity_still_matches);
  } catch (const std::exception&) {
  }
  return WindowsPortableTransactionResolution::kReject;
}

WindowsPortableTransactionResolution
DecideWindowsPortableTransactionCallerAuthority(
    const WindowsHelperPolicy& frozen_policy,
    const std::string& transaction_id,
    const std::string& canonical_record,
    const VerifiedWindowsExecutable& caller_identity,
    const std::filesystem::path& observed_process_path,
    bool identity_still_matches) {
  try {
    ValidatePortableProbeRecord(frozen_policy, transaction_id,
                                canonical_record);
    const JsonValue record = ParseJson(canonical_record);
    const WindowsTransactionJournal frozen =
        WindowsTransactionJournal::DecodeStrict(
            record.at("journalCanonical").string());
    const std::filesystem::path expected_path =
        std::filesystem::path(
            Utf8ToWide(record.at("targetPathHint").string())) /
        frozen.expected_payload_identity.executable_relative_path;
    if (!frozen_policy.is_portable() || !caller_identity.signature_valid ||
        !identity_still_matches || !IsSha256(caller_identity.sha256) ||
        NormalizePath(observed_process_path) != NormalizePath(expected_path) ||
        NormalizePath(caller_identity.final_path) !=
            NormalizePath(expected_path)) {
      return WindowsPortableTransactionResolution::kReject;
    }
    if (frozen_policy.application_signer_kind() == "sha256" &&
        caller_identity.sha256 ==
            frozen_policy.application_signer_identity()) {
      return WindowsPortableTransactionResolution::
          kVerifiedOriginalGeneration;
    }
    if (caller_identity.sha256 ==
            frozen.expected_payload_identity.executable_sha256 &&
        caller_identity.publisher == Utf8ToWide(
                                         frozen.expected_payload_identity
                                             .authenticode_publisher)) {
      return WindowsPortableTransactionResolution::kVerifiedSuccessor;
    }
  } catch (const std::exception&) {
  }
  return WindowsPortableTransactionResolution::kReject;
}

WindowsPortableValidPairDecision DecideWindowsPortableRecordValidPair(
    const WindowsHelperPolicy& policy,
    const std::string& transaction_id,
    const std::string& final_canonical,
    const std::string& next_canonical) {
  const auto final = ReadPortableRecordTransitionFacts(
      policy, transaction_id, final_canonical);
  const auto next = ReadPortableRecordTransitionFacts(
      policy, transaction_id, next_canonical);
  return IsRecordForwardTransition(final, next)
             ? WindowsPortableValidPairDecision::kPromoteNext
             : WindowsPortableValidPairDecision::kReject;
}

WindowsPortableValidPairDecision
DecideWindowsPortableResolverClaimValidPair(
    const std::string& transaction_id,
    const std::string& final_canonical,
    const std::string& next_canonical) {
  const auto final = ReadPortableResolverTransitionFacts(transaction_id,
                                                          final_canonical);
  const auto next = ReadPortableResolverTransitionFacts(transaction_id,
                                                         next_canonical);
  if (final.caller_binding != next.caller_binding) {
    return WindowsPortableValidPairDecision::kReject;
  }
  if (final.state == "consumed") {
    return final.resolver_binding == next.resolver_binding &&
                   next.state == "consumed"
               ? WindowsPortableValidPairDecision::kPromoteNext
               : WindowsPortableValidPairDecision::kReject;
  }
  if (next.state == "claimed") {
    return WindowsPortableValidPairDecision::kPromoteNext;
  }
  return next.state == "consumed" &&
                 final.resolver_binding == next.resolver_binding
             ? WindowsPortableValidPairDecision::kPromoteNext
             : WindowsPortableValidPairDecision::kReject;
}

class WindowsPortableTransactionStore::Impl {
 public:
  Impl(const WindowsHelperPolicy& policy,
       HANDLE caller_process,
       bool create_if_missing,
       WindowsPortableTransactionStoreFaultInjector* fault_injector)
      : policy_(policy),
        user_(ProcessUserSid(GetCurrentProcess())),
        user_sid_(SidText(user_.data())),
        fault_(fault_injector == nullptr ? &no_faults_ : fault_injector) {
    if (!policy.is_portable()) Fail("policy is not portable");
    RequireCallerUser(caller_process, user_.data());
    UniqueWindowsHandle local_app_data = OpenLocalAppData();
    root_ = OpenSecureDirectory(local_app_data.get(), kIndexRootName,
                                create_if_missing ? FILE_OPEN_IF : FILE_OPEN,
                                user_.data(), user_sid_);
    if (!root_.valid()) return;
    if (create_if_missing) FlushWindowsDirectory(local_app_data.get());
    const std::wstring binding =
        Utf8ToWide(WindowsPortableIndexBindingKey(policy_));
    binding_ = OpenSecureDirectory(
        root_.get(), binding, create_if_missing ? FILE_OPEN_IF : FILE_OPEN,
        user_.data(), user_sid_);
    if (binding_.valid() && create_if_missing) {
      FlushWindowsDirectory(root_.get());
    }
  }

  UniqueWindowsHandle OpenTransaction(const std::string& transaction_id,
                                      bool create) const {
    if (!std::regex_match(transaction_id, kTransactionId)) {
      Fail("transaction ID is invalid");
    }
    if (!binding_.valid()) return UniqueWindowsHandle();
    return OpenSecureDirectory(binding_.get(), Utf8ToWide(transaction_id),
                               create ? FILE_CREATE : FILE_OPEN, user_sid(),
                               user_sid_);
  }

  PSID user_sid() const {
    return const_cast<unsigned char*>(user_.data());
  }

  WindowsHelperPolicy policy_;
  std::vector<unsigned char> user_;
  std::wstring user_sid_;
  UniqueWindowsHandle root_;
  UniqueWindowsHandle binding_;
  NoWindowsPortableTransactionStoreFaultInjector no_faults_;
  WindowsPortableTransactionStoreFaultInjector* fault_;
};

WindowsTransactionLookupDecision DecideWindowsTransactionLookup(
    WindowsPortableTransactionProbe portable,
    bool protected_transaction_present) {
  if (portable == WindowsPortableTransactionProbe::kBindingMismatch ||
      (portable == WindowsPortableTransactionProbe::kPresent &&
       protected_transaction_present)) {
    return WindowsTransactionLookupDecision::kBindingMismatch;
  }
  if (portable == WindowsPortableTransactionProbe::kPresent) {
    return WindowsTransactionLookupDecision::kPortable;
  }
  return protected_transaction_present
             ? WindowsTransactionLookupDecision::kProtected
             : WindowsTransactionLookupDecision::kUnavailable;
}

WindowsPortableDurableFileDecision
DecideWindowsPortableDurableFileRecovery(
    WindowsPortableDurableFileProbe final_file,
    WindowsPortableDurableFileProbe next_file) {
  if (final_file == WindowsPortableDurableFileProbe::kUnsafe ||
      next_file == WindowsPortableDurableFileProbe::kUnsafe) {
    return WindowsPortableDurableFileDecision::kReject;
  }
  if (final_file == WindowsPortableDurableFileProbe::kExactValid) {
    if (next_file == WindowsPortableDurableFileProbe::kMissing) {
      return WindowsPortableDurableFileDecision::kUseFinal;
    }
    return next_file == WindowsPortableDurableFileProbe::kExactValid
               ? WindowsPortableDurableFileDecision::kReconcileValidPair
               : WindowsPortableDurableFileDecision::
                     kUseFinalAndDiscardNext;
  }
  if (final_file == WindowsPortableDurableFileProbe::kMissing &&
      next_file == WindowsPortableDurableFileProbe::kExactEmpty) {
    return WindowsPortableDurableFileDecision::
        kDiscardNextAndUnavailable;
  }
  if (final_file == WindowsPortableDurableFileProbe::kMissing &&
      next_file == WindowsPortableDurableFileProbe::kExactValid) {
    return WindowsPortableDurableFileDecision::kPromoteNext;
  }
  if (final_file == WindowsPortableDurableFileProbe::kMissing &&
      next_file == WindowsPortableDurableFileProbe::kMissing) {
    return WindowsPortableDurableFileDecision::kUnavailable;
  }
  return WindowsPortableDurableFileDecision::kReject;
}

std::string WindowsPortableIndexBindingKey(
    const WindowsHelperPolicy& policy) {
  if (!policy.is_portable()) Fail("binding policy is not portable");
  return Sha256Hex(PortablePolicyGenerationBinding(policy));
}

WindowsPortableTransactionStore::WindowsPortableTransactionStore(
    const WindowsHelperPolicy& policy,
    HANDLE caller_process,
    bool create_if_missing,
    WindowsPortableTransactionStoreFaultInjector* fault_injector)
    : impl_(std::make_unique<Impl>(policy, caller_process,
                                  create_if_missing, fault_injector)) {}

WindowsPortableTransactionStore::~WindowsPortableTransactionStore() = default;

void WindowsPortableTransactionStore::CreateRecord(
    const std::string& transaction_id,
    const std::string& canonical_record) {
  UniqueWindowsHandle transaction =
      impl_->OpenTransaction(transaction_id, true);
  if (!transaction.valid()) Fail("transaction directory is unavailable");
  impl_->fault_->Hit(WindowsPortableTransactionStoreFaultPoint::
                         kAfterTransactionDirectoryCreate);
  if (ExistsRelativeNoReparse(transaction.get(), kRecordName)) {
    Fail("transaction ID already exists");
  }
  const auto validate = [this, &transaction_id](const auto& bytes) {
    ValidatePortableProbeRecord(impl_->policy_, transaction_id, bytes);
  };
  const auto reconcile = [this, &transaction_id](const auto& final_bytes,
                                                  const auto& next_bytes) {
    return DecideWindowsPortableRecordValidPair(
        impl_->policy_, transaction_id, final_bytes, next_bytes);
  };
  WriteSecureFile(transaction.get(), kRecordName, kRecordNextName,
                  canonical_record, kMaximumRecordBytes, impl_->user_.data(),
                  impl_->user_sid_, validate, reconcile, impl_->fault_);
  FlushWindowsDirectory(impl_->binding_.get());
}

void WindowsPortableTransactionStore::WriteRecord(
    const std::string& transaction_id,
    const std::string& canonical_record) {
  UniqueWindowsHandle transaction =
      impl_->OpenTransaction(transaction_id, false);
  if (!transaction.valid()) {
    Fail("transaction record is unavailable");
  }
  const auto validate = [this, &transaction_id](const auto& bytes) {
    ValidatePortableProbeRecord(impl_->policy_, transaction_id, bytes);
  };
  const auto reconcile = [this, &transaction_id](const auto& final_bytes,
                                                  const auto& next_bytes) {
    return DecideWindowsPortableRecordValidPair(
        impl_->policy_, transaction_id, final_bytes, next_bytes);
  };
  if (!ReadSecureFile(transaction.get(), kRecordName, kRecordNextName,
                      kMaximumRecordBytes, impl_->user_.data(), validate,
                      reconcile)
           .has_value()) {
    Fail("transaction record is unavailable");
  }
  WriteSecureFile(transaction.get(), kRecordName, kRecordNextName,
                  canonical_record, kMaximumRecordBytes, impl_->user_.data(),
                  impl_->user_sid_, validate, reconcile, impl_->fault_);
}

std::optional<std::string> WindowsPortableTransactionStore::ReadRecord(
    const std::string& transaction_id) const {
  UniqueWindowsHandle transaction =
      impl_->OpenTransaction(transaction_id, false);
  if (!transaction.valid()) return std::nullopt;
  const auto validate = [this, &transaction_id](const auto& bytes) {
    ValidatePortableProbeRecord(impl_->policy_, transaction_id, bytes);
  };
  const auto reconcile = [this, &transaction_id](const auto& final_bytes,
                                                  const auto& next_bytes) {
    return DecideWindowsPortableRecordValidPair(
        impl_->policy_, transaction_id, final_bytes, next_bytes);
  };
  return ReadSecureFile(transaction.get(), kRecordName, kRecordNextName,
                        kMaximumRecordBytes, impl_->user_.data(), validate,
                        reconcile);
}

std::optional<std::string>
WindowsPortableTransactionStore::ReadResolverClaim(
    const std::string& transaction_id) const {
  UniqueWindowsHandle transaction =
      impl_->OpenTransaction(transaction_id, false);
  if (!transaction.valid()) return std::nullopt;
  const auto validate = [&transaction_id](const auto& bytes) {
    ValidatePortableResolverClaim(transaction_id, bytes);
  };
  const auto reconcile = [&transaction_id](const auto& final_bytes,
                                            const auto& next_bytes) {
    return DecideWindowsPortableResolverClaimValidPair(
        transaction_id, final_bytes, next_bytes);
  };
  return ReadSecureFile(transaction.get(), kClaimName, kClaimNextName,
                        kMaximumClaimBytes, impl_->user_.data(), validate,
                        reconcile);
}

void WindowsPortableTransactionStore::WriteResolverClaim(
    const std::string& transaction_id,
    const std::string& canonical_claim) {
  UniqueWindowsHandle transaction =
      impl_->OpenTransaction(transaction_id, false);
  if (!transaction.valid()) Fail("resolver transaction is unavailable");
  const auto validate = [&transaction_id](const auto& bytes) {
    ValidatePortableResolverClaim(transaction_id, bytes);
  };
  const auto reconcile = [&transaction_id](const auto& final_bytes,
                                            const auto& next_bytes) {
    return DecideWindowsPortableResolverClaimValidPair(
        transaction_id, final_bytes, next_bytes);
  };
  WriteSecureFile(transaction.get(), kClaimName, kClaimNextName,
                  canonical_claim, kMaximumClaimBytes, impl_->user_.data(),
                  impl_->user_sid_, validate, reconcile, impl_->fault_);
}

WindowsPortableTransactionProbe ProbeWindowsPortableTransaction(
    const WindowsHelperPolicy& policy,
    const std::string& transaction_id) {
  try {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), false);
    const auto record = store.ReadRecord(transaction_id);
    if (!record.has_value()) return WindowsPortableTransactionProbe::kAbsent;
    ValidatePortableProbeRecord(policy, transaction_id, *record);
    return WindowsPortableTransactionProbe::kPresent;
  } catch (const std::exception&) {
    return WindowsPortableTransactionProbe::kBindingMismatch;
  }
}

}  // namespace desktop_updater::helper
