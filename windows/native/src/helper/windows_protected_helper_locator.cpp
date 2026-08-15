#include "windows_protected_helper_locator.h"

#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cwctype>
#include <iomanip>
#include <limits>
#include <memory>
#include <regex>
#include <set>
#include <sstream>
#include <vector>

#include "json_value.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;

constexpr wchar_t kEndpointRoot[] =
    L"SOFTWARE\\DesktopUpdater\\Endpoints\\";
constexpr wchar_t kTransactionEndpointRoot[] =
    L"SOFTWARE\\DesktopUpdater\\TransactionEndpoints\\";
constexpr wchar_t kRecordValueName[] = L"Record";
constexpr wchar_t kHelperFileName[] =
    L"desktop_updater_install_helper.exe";
constexpr wchar_t kPolicyFileName[] =
    L"desktop_updater_helper_policy.json";
constexpr DWORD kMaximumEndpointRecordBytes = 128 * 1024;

const std::regex kIdentifier(
    "^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$");
const std::regex kSha256("^[0-9a-f]{64}$");
const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

class ScopedRegistryKey {
 public:
  explicit ScopedRegistryKey(HKEY key = nullptr) : key_(key) {}
  ~ScopedRegistryKey() {
    if (key_ != nullptr) RegCloseKey(key_);
  }
  ScopedRegistryKey(const ScopedRegistryKey&) = delete;
  ScopedRegistryKey& operator=(const ScopedRegistryKey&) = delete;
  ScopedRegistryKey(ScopedRegistryKey&& other) noexcept : key_(other.release()) {}
  HKEY get() const { return key_; }
  HKEY release() {
    HKEY result = key_;
    key_ = nullptr;
    return result;
  }

 private:
  HKEY key_;
};

[[noreturn]] void Fail(const std::string& detail) {
  throw WindowsProtectedHelperLocatorError(detail);
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty() ||
      value.size() > static_cast<std::size_t>(
                         std::numeric_limits<int>::max())) {
    Fail("protected helper locator UTF-8 is invalid");
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) Fail("protected helper locator UTF-8 is invalid");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    Fail("protected helper locator UTF-8 conversion failed");
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty() ||
      value.size() > static_cast<std::size_t>(
                         std::numeric_limits<int>::max())) {
    Fail("protected helper locator path is invalid");
  }
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) Fail("protected helper locator path is invalid");
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length, nullptr, nullptr) != length) {
    Fail("protected helper locator path conversion failed");
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

void ValidateEndpoint(const ProtectedWindowsHelperEndpointV1& endpoint) {
  if (endpoint.schema_version !=
          ProtectedWindowsHelperEndpointV1::kSchemaVersion ||
      !std::regex_match(endpoint.policy_id, kIdentifier) ||
      !std::regex_match(endpoint.package_id, kIdentifier) ||
      !std::regex_match(endpoint.helper_service_id, kIdentifier) ||
      !std::regex_match(endpoint.helper_sha256, kSha256) ||
      !std::regex_match(endpoint.policy_sha256, kSha256) ||
      !endpoint.helper_path.is_absolute() ||
      endpoint.helper_path.lexically_normal() != endpoint.helper_path ||
      !endpoint.policy_path.is_absolute() ||
      endpoint.policy_path.lexically_normal() != endpoint.policy_path ||
      NormalizePath(endpoint.helper_path.parent_path()) !=
          NormalizePath(endpoint.policy_path.parent_path()) ||
      _wcsicmp(endpoint.helper_path.filename().c_str(), kHelperFileName) != 0 ||
      _wcsicmp(endpoint.policy_path.filename().c_str(), kPolicyFileName) != 0) {
    Fail("protected helper endpoint record is invalid");
  }
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
  auto fail = [&]() -> void {
    cleanup();
    Fail("protected helper locator SHA-256 failed");
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
                       0, 0) < 0 ||
      BCryptHashData(
          hash,
          reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())),
          static_cast<ULONG>(bytes.size()), 0) < 0 ||
      BCryptFinishHash(hash, digest.data(),
                       static_cast<ULONG>(digest.size()), 0) < 0) {
    fail();
  }
  cleanup();
  std::ostringstream encoded;
  encoded << std::hex << std::setfill('0');
  for (unsigned char byte : digest) {
    encoded << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return encoded.str();
}

void RequireTransactionId(const std::string& transaction_id) {
  if (!std::regex_match(transaction_id, kTransactionId)) {
    Fail("protected transaction endpoint ID is invalid");
  }
}

void ValidateProtectedRegistryKey(HKEY key) {
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PACL dacl = nullptr;
  PSID owner = nullptr;
  const DWORD status = GetSecurityInfo(
      key, SE_REGISTRY_KEY,
      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, nullptr, &dacl, nullptr, &raw_descriptor);
  if (status != ERROR_SUCCESS || raw_descriptor == nullptr || dacl == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    Fail("protected helper locator DACL is unavailable");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> system_sid{};
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> administrators_sid{};
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> authenticated_users_sid{};
  DWORD system_size = static_cast<DWORD>(system_sid.size());
  DWORD administrators_size = static_cast<DWORD>(administrators_sid.size());
  DWORD users_size = static_cast<DWORD>(authenticated_users_sid.size());
  if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid.data(),
                          &system_size) ||
      !CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr,
                          administrators_sid.data(), &administrators_size) ||
      !CreateWellKnownSid(WinAuthenticatedUserSid, nullptr,
                          authenticated_users_sid.data(), &users_size)) {
    Fail("protected helper locator trusted SID construction failed");
  }
  auto trusted_writer = [&](PSID sid) {
    return sid != nullptr &&
           (EqualSid(sid, system_sid.data()) ||
            EqualSid(sid, administrators_sid.data()));
  };
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!trusted_writer(owner) ||
      !GetSecurityDescriptorControl(raw_descriptor, &control, &revision) ||
      (control & SE_DACL_PROTECTED) == 0) {
    Fail("protected helper locator owner or DACL is invalid");
  }
  bool system_full = false;
  bool administrators_full = false;
  bool authenticated_users_read = false;
  constexpr DWORD write_authority =
      KEY_SET_VALUE | KEY_CREATE_SUB_KEY | DELETE | WRITE_DAC | WRITE_OWNER;
  for (DWORD index = 0; index < dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace) || raw_ace == nullptr) {
      Fail("protected helper locator DACL is unreadable");
    }
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) {
      Fail("protected helper locator DACL authority is unsupported");
    }
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    if ((ace->Mask & write_authority) != 0 && !trusted_writer(sid)) {
      Fail("protected helper locator grants untrusted write authority");
    }
    if (EqualSid(sid, system_sid.data()) &&
        (ace->Mask & KEY_ALL_ACCESS) == KEY_ALL_ACCESS) {
      system_full = true;
    }
    if (EqualSid(sid, administrators_sid.data()) &&
        (ace->Mask & KEY_ALL_ACCESS) == KEY_ALL_ACCESS) {
      administrators_full = true;
    }
    if (EqualSid(sid, authenticated_users_sid.data()) &&
        (ace->Mask & KEY_READ) == KEY_READ &&
        (ace->Mask & write_authority) == 0) {
      authenticated_users_read = true;
    }
  }
  if (!system_full || !administrators_full || !authenticated_users_read) {
    Fail("protected helper locator DACL is incomplete");
  }
}

std::optional<ScopedRegistryKey> OpenRecordKey(const std::wstring& path,
                                                bool create,
                                                DWORD* disposition) {
  HKEY raw_key = nullptr;
  if (!create) {
    const LSTATUS status = RegOpenKeyExW(
        HKEY_LOCAL_MACHINE, path.c_str(), 0,
        KEY_QUERY_VALUE | READ_CONTROL | KEY_WOW64_64KEY, &raw_key);
    if (status == ERROR_FILE_NOT_FOUND) return std::nullopt;
    if (status != ERROR_SUCCESS || raw_key == nullptr) {
      Fail("protected helper locator is unavailable");
    }
  } else {
    PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
    const std::wstring sddl = BuildProtectedWindowsRegistrySddl();
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.c_str(), SDDL_REVISION_1, &raw_descriptor, nullptr) ||
        raw_descriptor == nullptr) {
      Fail("protected helper locator DACL construction failed");
    }
    std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                           LocalFree);
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = raw_descriptor;
    const LSTATUS status = RegCreateKeyExW(
        HKEY_LOCAL_MACHINE, path.c_str(), 0, nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_QUERY_VALUE | KEY_SET_VALUE | READ_CONTROL | KEY_WOW64_64KEY,
        &attributes, &raw_key, disposition);
    if (status != ERROR_SUCCESS || raw_key == nullptr) {
      Fail("protected helper locator cannot be created (Windows status " +
           std::to_string(status) + ")");
    }
  }
  ScopedRegistryKey key(raw_key);
  ValidateProtectedRegistryKey(key.get());
  return std::optional<ScopedRegistryKey>(std::move(key));
}

std::optional<ProtectedWindowsHelperEndpointV1> ReadRecord(HKEY key) {
  DWORD type = 0;
  DWORD size = 0;
  LSTATUS status = RegQueryValueExW(key, kRecordValueName, nullptr, &type,
                                    nullptr, &size);
  if (status == ERROR_FILE_NOT_FOUND) return std::nullopt;
  if (status != ERROR_SUCCESS || type != REG_BINARY || size == 0 ||
      size > kMaximumEndpointRecordBytes) {
    Fail("protected helper locator record is invalid");
  }
  std::string bytes(size, '\0');
  DWORD received = size;
  status = RegQueryValueExW(key, kRecordValueName, nullptr, &type,
                            reinterpret_cast<BYTE*>(bytes.data()), &received);
  if (status != ERROR_SUCCESS || type != REG_BINARY || received != size) {
    Fail("protected helper locator record read failed");
  }
  return ProtectedWindowsHelperEndpointV1::DecodeStrict(bytes);
}

void WriteRecord(HKEY key, const ProtectedWindowsHelperEndpointV1& endpoint) {
  const std::string canonical = endpoint.EncodeCanonical();
  if (canonical.size() > std::numeric_limits<DWORD>::max() ||
      RegSetValueExW(
          key, kRecordValueName, 0, REG_BINARY,
          reinterpret_cast<const BYTE*>(canonical.data()),
          static_cast<DWORD>(canonical.size())) != ERROR_SUCCESS ||
      RegFlushKey(key) != ERROR_SUCCESS) {
    Fail("protected helper locator record flush failed");
  }
}

}  // namespace

std::string ProtectedWindowsHelperEndpointV1::EncodeCanonical() const {
  ValidateEndpoint(*this);
  JsonValue::Object object;
  object.emplace("helperPath", JsonValue(WideToUtf8(helper_path.wstring())));
  object.emplace("helperServiceId", JsonValue(helper_service_id));
  object.emplace("helperSha256", JsonValue(helper_sha256));
  object.emplace("packageId", JsonValue(package_id));
  object.emplace("policyId", JsonValue(policy_id));
  object.emplace("policyPath", JsonValue(WideToUtf8(policy_path.wstring())));
  object.emplace("policySha256", JsonValue(policy_sha256));
  object.emplace("schemaVersion", JsonValue(schema_version));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

ProtectedWindowsHelperEndpointV1 ProtectedWindowsHelperEndpointV1::DecodeStrict(
    const std::string& canonical_json) {
  try {
    const JsonValue value = ParseJson(canonical_json);
    if (EncodeCanonicalJson(value) != canonical_json) {
      Fail("protected helper endpoint record is not canonical JSON");
    }
    const std::set<std::string> expected = {
        "helperPath", "helperServiceId", "helperSha256", "packageId",
        "policyId", "policyPath", "policySha256", "schemaVersion"};
    std::set<std::string> actual;
    for (const auto& entry : value.object()) actual.insert(entry.first);
    if (actual != expected) Fail("protected helper endpoint fields changed");
    ProtectedWindowsHelperEndpointV1 endpoint;
    endpoint.schema_version = value.at("schemaVersion").integer();
    endpoint.policy_id = value.at("policyId").string();
    endpoint.package_id = value.at("packageId").string();
    endpoint.helper_service_id = value.at("helperServiceId").string();
    endpoint.helper_path =
        std::filesystem::path(Utf8ToWide(value.at("helperPath").string()));
    endpoint.policy_path =
        std::filesystem::path(Utf8ToWide(value.at("policyPath").string()));
    endpoint.helper_sha256 = value.at("helperSha256").string();
    endpoint.policy_sha256 = value.at("policySha256").string();
    ValidateEndpoint(endpoint);
    return endpoint;
  } catch (const WindowsProtectedHelperLocatorError&) {
    throw;
  } catch (const std::exception&) {
    Fail("protected helper endpoint record is invalid");
  }
}

bool ProtectedWindowsHelperEndpointV1::operator==(
    const ProtectedWindowsHelperEndpointV1& other) const {
  return schema_version == other.schema_version &&
         policy_id == other.policy_id && package_id == other.package_id &&
         helper_service_id == other.helper_service_id &&
         NormalizePath(helper_path) == NormalizePath(other.helper_path) &&
         NormalizePath(policy_path) == NormalizePath(other.policy_path) &&
         helper_sha256 == other.helper_sha256 &&
         policy_sha256 == other.policy_sha256;
}

std::wstring BuildProtectedWindowsRegistrySddl() {
  return L"O:BAG:BAD:P(A;;KA;;;SY)(A;;KA;;;BA)(A;;KR;;;AU)";
}

std::wstring ProtectedWindowsEndpointPackageRegistryPath(
    const std::string& package_id) {
  if (!std::regex_match(package_id, kIdentifier)) {
    Fail("protected helper endpoint package ID is invalid");
  }
  return std::wstring(kEndpointRoot) + Utf8ToWide(Sha256Hex(package_id));
}

std::wstring ProtectedWindowsEndpointRegistryPath(
    const std::string& package_id,
    const std::filesystem::path& helper_path) {
  if (!helper_path.is_absolute()) {
    Fail("protected helper endpoint path is not absolute");
  }
  const std::string normalized_path = WideToUtf8(NormalizePath(helper_path));
  if (normalized_path.empty()) {
    Fail("protected helper endpoint path identity is invalid");
  }
  return ProtectedWindowsEndpointPackageRegistryPath(package_id) + L"\\" +
         Utf8ToWide(Sha256Hex(normalized_path));
}

std::wstring ProtectedWindowsTransactionEndpointRegistryPath(
    const std::string& transaction_id) {
  RequireTransactionId(transaction_id);
  return std::wstring(kTransactionEndpointRoot) +
         Utf8ToWide(transaction_id);
}

void RegisterProtectedWindowsHelperEndpoint(
    const ProtectedWindowsHelperEndpointV1& endpoint) {
  ValidateEndpoint(endpoint);
  DWORD disposition = 0;
  auto key = OpenRecordKey(
      ProtectedWindowsEndpointRegistryPath(endpoint.package_id,
                                           endpoint.helper_path),
      true,
      &disposition);
  if (!key.has_value()) Fail("protected helper endpoint creation failed");
  if (disposition == REG_OPENED_EXISTING_KEY) {
    const auto existing = ReadRecord(key->get());
    if (existing.has_value()) {
      if (!(*existing == endpoint)) {
        Fail("protected helper endpoint immutable binding changed");
      }
      return;
    }
  }
  WriteRecord(key->get(), endpoint);
  const auto written = ReadRecord(key->get());
  if (!written.has_value() || !(*written == endpoint)) {
    Fail("protected helper endpoint durable readback failed");
  }
}

std::optional<ProtectedWindowsHelperEndpointV1>
LoadProtectedWindowsHelperEndpoint(
    const std::string& package_id,
    const std::filesystem::path& helper_path) {
  auto key = OpenRecordKey(
      ProtectedWindowsEndpointRegistryPath(package_id, helper_path), false,
      nullptr);
  if (!key.has_value()) return std::nullopt;
  auto endpoint = ReadRecord(key->get());
  if (endpoint.has_value() &&
      (endpoint->package_id != package_id ||
       NormalizePath(endpoint->helper_path) != NormalizePath(helper_path))) {
    Fail("protected helper endpoint package binding changed");
  }
  return endpoint;
}

void BindProtectedWindowsTransactionEndpoint(
    const std::string& transaction_id,
    const ProtectedWindowsHelperEndpointV1& endpoint) {
  ValidateEndpoint(endpoint);
  DWORD disposition = 0;
  auto key = OpenRecordKey(
      ProtectedWindowsTransactionEndpointRegistryPath(transaction_id), true,
      &disposition);
  if (!key.has_value()) Fail("protected transaction endpoint creation failed");
  if (disposition == REG_OPENED_EXISTING_KEY) {
    const auto existing = ReadRecord(key->get());
    if (!existing.has_value() || !(*existing == endpoint)) {
      Fail("protected transaction endpoint binding changed");
    }
    return;
  }
  WriteRecord(key->get(), endpoint);
}

std::optional<ProtectedWindowsHelperEndpointV1>
LoadProtectedWindowsTransactionEndpoint(const std::string& transaction_id) {
  auto key = OpenRecordKey(
      ProtectedWindowsTransactionEndpointRegistryPath(transaction_id), false,
      nullptr);
  if (!key.has_value()) return std::nullopt;
  return ReadRecord(key->get());
}

}  // namespace desktop_updater::helper
