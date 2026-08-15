#include "windows_helper_bootstrap.h"

#include <windows.h>

#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cwctype>
#include <filesystem>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "json_value.h"
#include "stage_provenance.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;
using desktop_updater::runtime::internal::StageBytesToHex;

constexpr std::size_t kMaximumWindowsPolicyBytes = 1024 * 1024;
constexpr wchar_t kWindowsHelperPolicyName[] =
    L"desktop_updater_helper_policy.json";

[[noreturn]] void Fail(const std::string& detail) {
  throw WindowsHelperPolicyError(
      WindowsHelperPolicyError::Code::kInvalidPolicy, detail);
}

std::filesystem::path CurrentExecutablePath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  for (;;) {
    const DWORD length = GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) Fail("helper executable path is unavailable");
    if (length < buffer.size() - 1) {
      return std::filesystem::path(std::wstring(buffer.data(), length));
    }
    if (buffer.size() >= 32768) Fail("helper executable path is too long");
    buffer.resize(std::min<std::size_t>(buffer.size() * 2, 32768));
  }
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

std::filesystem::path FinalPath(HANDLE file) {
  const DWORD length = GetFinalPathNameByHandleW(
      file, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (length == 0) Fail("protected policy final path is unavailable");
  std::wstring value(length, L'\0');
  const DWORD written = GetFinalPathNameByHandleW(
      file, value.data(), length,
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (written == 0 || written >= length) {
    Fail("protected policy final path changed");
  }
  value.resize(written);
  return std::filesystem::path(value);
}

std::string ReadPolicy(HANDLE file) {
  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(file, &information) ||
      (information.dwFileAttributes &
       (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
      information.nFileSizeHigh != 0 || information.nFileSizeLow == 0 ||
      information.nFileSizeLow > kMaximumWindowsPolicyBytes) {
    Fail("protected policy is not a bounded regular file");
  }
  std::string result(information.nFileSizeLow, '\0');
  std::size_t offset = 0;
  while (offset < result.size()) {
    DWORD count = 0;
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        result.size() - offset, 64 * 1024));
    if (!ReadFile(file, result.data() + offset, requested, &count, nullptr) ||
        count == 0 || count > requested) {
      Fail("protected policy read failed");
    }
    offset += count;
  }
  if (!result.empty() && result.back() == '\n') {
    result.pop_back();
  }
  return result;
}

UniqueWindowsHandle OpenCallerToken(DWORD caller_process_id) {
  UniqueWindowsHandle caller(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                         FALSE, caller_process_id));
  if (!caller.valid()) Fail("caller process cannot be opened for policy ACL");
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(caller.get(), TOKEN_QUERY | TOKEN_DUPLICATE,
                        &raw_token)) {
    Fail("caller token cannot be opened for policy ACL");
  }
  UniqueWindowsHandle token(raw_token);
  HANDLE raw_impersonation = nullptr;
  if (!DuplicateToken(token.get(), SecurityImpersonation,
                      &raw_impersonation)) {
    Fail("caller token cannot be duplicated for policy ACL");
  }
  return UniqueWindowsHandle(raw_impersonation);
}

void RejectCallerWritableObject(HANDLE object,
                                DWORD caller_process_id,
                                const char* detail) {
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PACL dacl = nullptr;
  const DWORD security = GetSecurityInfo(
      object, SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |
          DACL_SECURITY_INFORMATION,
      nullptr, nullptr, &dacl, nullptr, &raw_descriptor);
  if (security != ERROR_SUCCESS || raw_descriptor == nullptr || dacl == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    Fail(std::string(detail) + " security descriptor is unavailable");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  UniqueWindowsHandle caller_token = OpenCallerToken(caller_process_id);
  GENERIC_MAPPING mapping{FILE_GENERIC_READ, FILE_GENERIC_WRITE,
                          FILE_GENERIC_EXECUTE, FILE_ALL_ACCESS};
  std::vector<unsigned char> privileges(4096);
  DWORD privileges_size = static_cast<DWORD>(privileges.size());
  DWORD granted = 0;
  BOOL access = FALSE;
  const BOOL checked = AccessCheck(
      raw_descriptor, caller_token.get(), MAXIMUM_ALLOWED, &mapping,
      reinterpret_cast<PRIVILEGE_SET*>(privileges.data()), &privileges_size,
      &granted, &access);
  if (!checked) Fail(std::string(detail) + " caller access check failed");
  constexpr DWORD write_authority =
      FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA |
      FILE_WRITE_ATTRIBUTES | FILE_DELETE_CHILD | DELETE | WRITE_DAC |
      WRITE_OWNER;
  if (access == TRUE && (granted & write_authority) != 0) {
    Fail(std::string(detail) + " is writable by the named-pipe caller");
  }
}

void ValidateInstallerProtectedObject(HANDLE object, const char* detail) {
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PACL dacl = nullptr;
  PSID owner = nullptr;
  const DWORD security = GetSecurityInfo(
      object, SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, nullptr, &dacl, nullptr, &raw_descriptor);
  if (security != ERROR_SUCCESS || raw_descriptor == nullptr || dacl == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    Fail(std::string(detail) + " protected DACL is unavailable");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> system_sid{};
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> administrators_sid{};
  DWORD system_size = static_cast<DWORD>(system_sid.size());
  DWORD administrators_size = static_cast<DWORD>(administrators_sid.size());
  PSID trusted_installer_sid = nullptr;
  std::unique_ptr<void, decltype(&LocalFree)> trusted_installer(
      nullptr, LocalFree);
  if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid.data(),
                          &system_size) ||
      !CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr,
                          administrators_sid.data(), &administrators_size) ||
      !ConvertStringSidToSidW(
          L"S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",
          &trusted_installer_sid)) {
    Fail(std::string(detail) + " trusted SID construction failed");
  }
  trusted_installer.reset(trusted_installer_sid);
  auto trusted_writer = [&](PSID sid) {
    return sid != nullptr &&
           (EqualSid(sid, system_sid.data()) ||
            EqualSid(sid, administrators_sid.data()) ||
            EqualSid(sid, trusted_installer.get()));
  };
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!trusted_writer(owner) ||
      !GetSecurityDescriptorControl(raw_descriptor, &control, &revision) ||
      (control & SE_DACL_PROTECTED) == 0) {
    Fail(std::string(detail) + " owner or DACL protection is invalid");
  }
  constexpr DWORD write_authority =
      FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA |
      FILE_WRITE_ATTRIBUTES | FILE_DELETE_CHILD | DELETE | WRITE_DAC |
      WRITE_OWNER;
  for (DWORD index = 0; index < dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace) || raw_ace == nullptr) {
      Fail(std::string(detail) + " DACL is unreadable");
    }
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) {
      Fail(std::string(detail) + " DACL authority is unsupported");
    }
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    if ((ace->Mask & write_authority) != 0 && !trusted_writer(sid)) {
      Fail(std::string(detail) + " grants untrusted write authority");
    }
  }
}

UniqueWindowsHandle OpenProtectedObject(
    const std::filesystem::path& path,
    bool directory,
    const std::optional<DWORD>& caller_process_id,
    const char* detail) {
  const DWORD flags = FILE_FLAG_OPEN_REPARSE_POINT |
                      (directory ? FILE_FLAG_BACKUP_SEMANTICS
                                 : FILE_ATTRIBUTE_NORMAL);
  UniqueWindowsHandle object(CreateFileW(
      path.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES | READ_CONTROL,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING, flags, nullptr));
  if (!object.valid()) Fail(std::string(detail) + " is unavailable");
  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(object.get(), &information) ||
      (information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      (((information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) !=
       directory)) {
    Fail(std::string(detail) + " has unsafe filesystem metadata");
  }
  ValidateInstallerProtectedObject(object.get(), detail);
  if (caller_process_id.has_value()) {
    RejectCallerWritableObject(object.get(), *caller_process_id, detail);
  }
  return object;
}

UniqueWindowsHandle OpenPortableObject(
    const std::filesystem::path& path,
    bool directory,
    const char* detail) {
  const DWORD flags = FILE_FLAG_OPEN_REPARSE_POINT |
                      (directory ? FILE_FLAG_BACKUP_SEMANTICS
                                 : FILE_ATTRIBUTE_NORMAL);
  UniqueWindowsHandle object(CreateFileW(
      path.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, flags,
      nullptr));
  if (!object.valid()) Fail(std::string(detail) + " is unavailable");
  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(object.get(), &information) ||
      (information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      (((information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) !=
       directory)) {
    Fail(std::string(detail) + " has unsafe filesystem metadata");
  }
  return object;
}

std::string EncodeBase64Url32(const std::array<unsigned char, 32>& bytes) {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::string result;
  result.reserve(43);
  std::uint32_t accumulator = 0;
  int bits = 0;
  for (const unsigned char byte : bytes) {
    accumulator = (accumulator << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      result.push_back(alphabet[(accumulator >> bits) & 0x3f]);
    }
  }
  if (bits > 0) {
    result.push_back(alphabet[(accumulator << (6 - bits)) & 0x3f]);
  }
  if (result.size() != 43) Fail("secure ready token encoding failed");
  return result;
}

}  // namespace

WindowsHelperBootstrap::WindowsHelperBootstrap(
    WindowsHelperPolicy policy,
    VerifiedWindowsExecutable helper_identity,
    ProtectedWindowsHelperEndpointV1 endpoint,
    UniqueWindowsHandle helper_file,
    UniqueWindowsHandle policy_file)
    : policy_(std::move(policy)),
      helper_identity_(std::move(helper_identity)),
      endpoint_(std::move(endpoint)),
      helper_file_(std::move(helper_file)),
      policy_file_(std::move(policy_file)) {}

PortableWindowsHelperBootstrap::PortableWindowsHelperBootstrap(
    WindowsHelperPolicy policy,
    VerifiedWindowsExecutable helper_identity,
    UniqueWindowsHandle helper_file,
    UniqueWindowsHandle policy_file)
    : policy_(std::move(policy)),
      helper_identity_(std::move(helper_identity)),
      helper_file_(std::move(helper_file)),
      policy_file_(std::move(policy_file)) {}

std::vector<std::uint8_t> WindowsHelperSha256Bytes(
    const std::string& bytes) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0;
  DWORD received = 0;
  std::vector<unsigned char> object;
  std::vector<std::uint8_t> digest(32);
  auto cleanup = [&]() {
    if (hash != nullptr) BCryptDestroyHash(hash);
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  };
  auto fail = [&]() -> void {
    cleanup();
    Fail("Windows helper SHA-256 failed");
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
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const ULONG length = static_cast<ULONG>(std::min<std::size_t>(
        bytes.size() - offset,
        static_cast<std::size_t>(std::numeric_limits<ULONG>::max())));
    if (BCryptHashData(
            hash,
            reinterpret_cast<PUCHAR>(
                const_cast<char*>(bytes.data() + offset)),
            length, 0) < 0) {
      fail();
    }
    offset += length;
  }
  if (BCryptFinishHash(hash, digest.data(),
                       static_cast<ULONG>(digest.size()), 0) < 0) {
    fail();
  }
  cleanup();
  return digest;
}

std::string WindowsHelperSha256Hex(const std::string& bytes) {
  return StageBytesToHex(WindowsHelperSha256Bytes(bytes));
}

std::int64_t WindowsHelperNowUnixMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

std::string SecureWindowsReadyToken() {
  std::array<unsigned char, 32> bytes{};
  if (BCryptGenRandom(nullptr, bytes.data(),
                      static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    Fail("secure ready token generation failed");
  }
  return EncodeBase64Url32(bytes);
}

WindowsHelperBootstrap LoadWindowsHelperBootstrapInternal(
    const std::optional<DWORD>& caller_process_id,
    const std::optional<std::string>& transaction_id,
    bool registration) {
  const std::filesystem::path helper_path = CurrentExecutablePath();
  VerifiedWindowsExecutable helper_identity =
      VerifyWindowsExecutable(helper_path);
  if (!helper_identity.signature_valid ||
      !VerifyWindowsExecutableStillMatches(helper_path, helper_identity)) {
    Fail("helper executable is not a retained protected signed binary");
  }
  UniqueWindowsHandle helper_parent = OpenProtectedObject(
      helper_identity.final_path.parent_path(), true, caller_process_id,
      "protected helper parent");
  UniqueWindowsHandle helper_file = OpenProtectedObject(
      helper_identity.final_path, false, caller_process_id,
      "protected helper executable");
  if (NormalizePath(FinalPath(helper_file.get())) !=
      NormalizePath(helper_identity.final_path)) {
    Fail("protected helper handle identity changed");
  }
  helper_identity.installer_protected_location = true;

  const std::filesystem::path policy_path =
      helper_identity.final_path.parent_path() / kWindowsHelperPolicyName;
  UniqueWindowsHandle policy_file = OpenProtectedObject(
      policy_path, false, caller_process_id, "protected helper policy");
  const std::filesystem::path final_policy_path = FinalPath(policy_file.get());
  if (NormalizePath(final_policy_path.parent_path()) !=
          NormalizePath(helper_identity.final_path.parent_path()) ||
      _wcsicmp(final_policy_path.filename().c_str(),
               kWindowsHelperPolicyName) != 0) {
    Fail("helper policy is not adjacent to the protected helper");
  }
  const std::string policy_json = ReadPolicy(policy_file.get());
  const JsonValue policy_value = ParseJson(policy_json);
  if (EncodeCanonicalJson(policy_value) != policy_json) {
    Fail("protected helper policy is not canonical JSON");
  }
  const std::string application_package_id =
      policy_value.at("applicationPackageId").string();
  const std::string policy_sha256 = WindowsHelperSha256Hex(policy_json);
  ProtectedWindowsHelperEndpointV1 endpoint;
  if (registration) {
    endpoint = {
        ProtectedWindowsHelperEndpointV1::kSchemaVersion,
        policy_value.at("policyId").string(),
        application_package_id,
        policy_value.at("helperServiceId").string(),
        helper_identity.final_path.lexically_normal(),
        final_policy_path.lexically_normal(),
        helper_identity.sha256,
        policy_sha256,
    };
    (void)endpoint.EncodeCanonical();
  } else {
    const auto registered = transaction_id.has_value()
                                ? LoadProtectedWindowsTransactionEndpoint(
                                      *transaction_id)
                                : LoadProtectedWindowsHelperEndpoint(
                                      application_package_id,
                                      helper_identity.final_path);
    if (!registered.has_value()) {
      Fail("registered protected helper endpoint is unavailable");
    }
    endpoint = *registered;
    if (endpoint.package_id != application_package_id ||
        endpoint.policy_id != policy_value.at("policyId").string() ||
        endpoint.helper_service_id !=
            policy_value.at("helperServiceId").string() ||
        NormalizePath(endpoint.helper_path) !=
            NormalizePath(helper_identity.final_path) ||
        NormalizePath(endpoint.policy_path) !=
            NormalizePath(final_policy_path) ||
        endpoint.helper_sha256 != helper_identity.sha256 ||
        endpoint.policy_sha256 != policy_sha256) {
      Fail("registered protected helper endpoint binding changed");
    }
  }
  WindowsHelperPolicy policy = WindowsHelperPolicy::Load(
      policy_json, endpoint.policy_sha256,
      application_package_id, endpoint.helper_sha256);
  ValidateWindowsHelperIdentity(helper_identity, policy, true);
  if (!VerifyWindowsExecutableStillMatches(helper_path, helper_identity)) {
    Fail("helper executable changed after policy validation");
  }
  return WindowsHelperBootstrap(
      std::move(policy), helper_identity, std::move(endpoint),
      std::move(helper_file),
      std::move(policy_file));
}

WindowsHelperBootstrap LoadWindowsHelperBootstrap(
    DWORD caller_process_id) {
  return LoadWindowsHelperBootstrapInternal(caller_process_id, std::nullopt,
                                            false);
}

WindowsHelperBootstrap LoadWindowsHelperBootstrapForRegistration() {
  return LoadWindowsHelperBootstrapInternal(std::nullopt, std::nullopt, true);
}

WindowsHelperBootstrap LoadWindowsHelperBootstrapForAutonomousRecovery(
    const std::string& transaction_id) {
  return LoadWindowsHelperBootstrapInternal(std::nullopt, transaction_id,
                                            false);
}

PortableWindowsHelperBootstrap LoadPortableWindowsHelperBootstrap(
    DWORD caller_process_id) {
  if (caller_process_id == 0) {
    Fail("portable helper caller process ID is invalid");
  }
  UniqueWindowsHandle caller(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
                                             SYNCHRONIZE,
                                         FALSE, caller_process_id));
  if (!caller.valid()) Fail("portable helper caller cannot be retained");

  const std::filesystem::path helper_path = CurrentExecutablePath();
  VerifiedWindowsExecutable helper_identity =
      VerifyWindowsExecutable(helper_path);
  UniqueWindowsHandle helper_file = OpenPortableObject(
      helper_path, false, "portable helper executable");
  if (NormalizePath(FinalPath(helper_file.get())) !=
      NormalizePath(helper_identity.final_path)) {
    Fail("portable helper handle identity changed");
  }

  const std::filesystem::path policy_path =
      helper_path.parent_path() / kWindowsHelperPolicyName;
  UniqueWindowsHandle policy_file = OpenPortableObject(
      policy_path, false, "portable helper policy");
  const std::filesystem::path final_policy_path = FinalPath(policy_file.get());
  if (NormalizePath(final_policy_path.parent_path()) !=
          NormalizePath(helper_identity.final_path.parent_path()) ||
      _wcsicmp(final_policy_path.filename().c_str(),
               kWindowsHelperPolicyName) != 0) {
    Fail("portable helper policy is not adjacent to the helper");
  }
  const std::string policy_json = ReadPolicy(policy_file.get());
  const JsonValue policy_value = ParseJson(policy_json);
  if (EncodeCanonicalJson(policy_value) != policy_json) {
    Fail("portable helper policy is not canonical JSON");
  }
  const std::string package_id =
      policy_value.at("applicationPackageId").string();
  WindowsHelperPolicy policy = WindowsHelperPolicy::Load(
      policy_json, WindowsHelperSha256Hex(policy_json), package_id,
      helper_identity.sha256);
  if (!policy.is_portable()) {
    Fail("portable helper policy grants unsupported authority");
  }
  ValidateWindowsHelperIdentity(helper_identity, policy, false);
  if (!VerifyWindowsExecutableStillMatches(helper_path, helper_identity)) {
    Fail("portable helper executable changed after policy validation");
  }
  return PortableWindowsHelperBootstrap(
      std::move(policy), std::move(helper_identity), std::move(helper_file),
      std::move(policy_file));
}

}  // namespace desktop_updater::helper
