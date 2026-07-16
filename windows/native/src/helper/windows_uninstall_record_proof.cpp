#include "windows_uninstall_record_proof.h"

#include <windows.h>

#include <aclapi.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <cwctype>
#include <limits>
#include <memory>
#include <vector>

namespace desktop_updater::helper {
namespace {

class RegistryKey {
 public:
  explicit RegistryKey(HKEY key = nullptr) : key_(key) {}
  ~RegistryKey() {
    if (key_ != nullptr) RegCloseKey(key_);
  }
  RegistryKey(const RegistryKey&) = delete;
  RegistryKey& operator=(const RegistryKey&) = delete;
  HKEY get() const { return key_; }

 private:
  HKEY key_;
};

class WindowsHandle {
 public:
  explicit WindowsHandle(HANDLE handle = nullptr) : handle_(handle) {}
  ~WindowsHandle() {
    if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(handle_);
    }
  }
  WindowsHandle(const WindowsHandle&) = delete;
  WindowsHandle& operator=(const WindowsHandle&) = delete;
  HANDLE get() const { return handle_; }

 private:
  HANDLE handle_;
};

std::optional<std::wstring> ReadRegistryString(HKEY key,
                                               const wchar_t* value_name) {
  DWORD type = 0;
  DWORD size = 0;
  if (RegQueryValueExW(key, value_name, nullptr, &type, nullptr, &size) !=
          ERROR_SUCCESS ||
      type != REG_SZ || size < sizeof(wchar_t) ||
      size > 64 * 1024 || size % sizeof(wchar_t) != 0) {
    return std::nullopt;
  }
  std::vector<wchar_t> buffer(size / sizeof(wchar_t), L'\0');
  DWORD received = size;
  if (RegQueryValueExW(key, value_name, nullptr, &type,
                       reinterpret_cast<BYTE*>(buffer.data()), &received) !=
          ERROR_SUCCESS ||
      type != REG_SZ || received != size || buffer.back() != L'\0' ||
      std::find(buffer.begin(), buffer.end() - 1, L'\0') !=
          buffer.end() - 1) {
    return std::nullopt;
  }
  return std::wstring(buffer.data(), buffer.size() - 1);
}

bool CallerCanWriteRegistryKey(HKEY key, HANDLE caller_process) {
  if (key == nullptr || caller_process == nullptr ||
      caller_process == INVALID_HANDLE_VALUE) {
    return true;
  }
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PACL dacl = nullptr;
  const DWORD security_status = GetSecurityInfo(
      key, SE_REGISTRY_KEY,
      OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |
          DACL_SECURITY_INFORMATION,
      nullptr, nullptr, &dacl, nullptr, &raw_descriptor);
  if (security_status != ERROR_SUCCESS || raw_descriptor == nullptr ||
      dacl == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    return true;
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);

  HANDLE raw_primary_token = nullptr;
  if (!OpenProcessToken(caller_process, TOKEN_QUERY | TOKEN_DUPLICATE,
                        &raw_primary_token)) {
    return true;
  }
  WindowsHandle primary_token(raw_primary_token);
  HANDLE raw_impersonation_token = nullptr;
  if (!DuplicateToken(primary_token.get(), SecurityImpersonation,
                      &raw_impersonation_token)) {
    return true;
  }
  WindowsHandle impersonation_token(raw_impersonation_token);

  GENERIC_MAPPING mapping{KEY_READ, KEY_WRITE, KEY_EXECUTE, KEY_ALL_ACCESS};
  std::vector<BYTE> privileges(sizeof(PRIVILEGE_SET) +
                               8 * sizeof(LUID_AND_ATTRIBUTES));
  DWORD privileges_size = static_cast<DWORD>(privileges.size());
  DWORD granted = 0;
  BOOL access = FALSE;
  if (!AccessCheck(raw_descriptor, impersonation_token.get(), MAXIMUM_ALLOWED,
                   &mapping,
                   reinterpret_cast<PRIVILEGE_SET*>(privileges.data()),
                   &privileges_size, &granted, &access)) {
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || privileges_size == 0) {
      return true;
    }
    privileges.resize(privileges_size);
    if (!AccessCheck(raw_descriptor, impersonation_token.get(),
                     MAXIMUM_ALLOWED, &mapping,
                     reinterpret_cast<PRIVILEGE_SET*>(privileges.data()),
                     &privileges_size, &granted, &access)) {
      return true;
    }
  }
  constexpr DWORD kMutationRights =
      KEY_SET_VALUE | KEY_CREATE_SUB_KEY | KEY_CREATE_LINK | DELETE |
      WRITE_DAC | WRITE_OWNER;
  return access == TRUE && (granted & kMutationRights) != 0;
}

bool RegistryKeyIsInstallerProtected(HKEY key) {
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PACL dacl = nullptr;
  PSID owner = nullptr;
  const DWORD status = GetSecurityInfo(
      key, SE_REGISTRY_KEY,
      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, nullptr, &dacl, nullptr, &raw_descriptor);
  if (status != ERROR_SUCCESS || raw_descriptor == nullptr || dacl == nullptr ||
      owner == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    return false;
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  std::array<BYTE, SECURITY_MAX_SID_SIZE> system_sid{};
  std::array<BYTE, SECURITY_MAX_SID_SIZE> administrators_sid{};
  DWORD system_size = static_cast<DWORD>(system_sid.size());
  DWORD administrators_size =
      static_cast<DWORD>(administrators_sid.size());
  PSID raw_trusted_installer = nullptr;
  if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid.data(),
                          &system_size) ||
      !CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr,
                          administrators_sid.data(),
                          &administrators_size) ||
      !ConvertStringSidToSidW(
          L"S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",
          &raw_trusted_installer)) {
    if (raw_trusted_installer != nullptr) LocalFree(raw_trusted_installer);
    return false;
  }
  std::unique_ptr<void, decltype(&LocalFree)> trusted_installer(
      raw_trusted_installer, LocalFree);
  const auto trusted_writer = [&](PSID sid) {
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
    return false;
  }
  constexpr DWORD kMutationRights =
      KEY_SET_VALUE | KEY_CREATE_SUB_KEY | KEY_CREATE_LINK | DELETE |
      WRITE_DAC | WRITE_OWNER;
  bool trusted_mutation_authority = false;
  for (DWORD index = 0; index < dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace) || raw_ace == nullptr) return false;
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) return false;
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    if ((ace->Mask & kMutationRights) == 0) continue;
    if (!trusted_writer(sid)) return false;
    trusted_mutation_authority = true;
  }
  return trusted_mutation_authority;
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

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty() ||
      value.size() >
          static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    return "";
  }
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) return "";
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), length,
                          nullptr, nullptr) != length) {
    return "";
  }
  return result;
}

void AppendField(const std::string& value, std::string* output) {
  output->append(std::to_string(value.size()));
  output->push_back(':');
  output->append(value);
}

}  // namespace

std::optional<std::string> FindCanonicalWindowsUninstallRecordProofInternal(
    const std::filesystem::path& canonical_target,
    const std::string& package_id,
    HANDLE caller_process,
    bool trusted_host) {
  if (!canonical_target.is_absolute() || package_id.empty() ||
      (!trusted_host &&
       (caller_process == nullptr ||
        caller_process == INVALID_HANDLE_VALUE))) {
    return std::nullopt;
  }
  constexpr wchar_t kUninstallPath[] =
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall";
  struct View {
    REGSAM access;
    const char* name;
  };
  constexpr View views[] = {{KEY_WOW64_64KEY, "64"},
                            {KEY_WOW64_32KEY, "32"}};
  const std::wstring normalized_target = NormalizePath(canonical_target);
  const std::wstring wide_package(
      package_id.begin(), package_id.end());
  std::vector<std::string> matches;
  for (const View& view : views) {
    HKEY raw_uninstall = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kUninstallPath, 0,
                      KEY_READ | view.access, &raw_uninstall) !=
        ERROR_SUCCESS) {
      continue;
    }
    RegistryKey uninstall(raw_uninstall);
    for (DWORD index = 0;; ++index) {
      std::vector<wchar_t> name(16384, L'\0');
      DWORD length = static_cast<DWORD>(name.size());
      const LSTATUS enumerated = RegEnumKeyExW(
          uninstall.get(), index, name.data(), &length, nullptr, nullptr,
          nullptr, nullptr);
      if (enumerated == ERROR_NO_MORE_ITEMS) break;
      if (enumerated != ERROR_SUCCESS || length == 0 ||
          length >= name.size()) {
        continue;
      }
      const std::wstring key_name(name.data(), length);
      HKEY raw_record = nullptr;
      if (RegOpenKeyExW(uninstall.get(), key_name.c_str(), 0, KEY_READ,
                        &raw_record) != ERROR_SUCCESS) {
        continue;
      }
      RegistryKey record(raw_record);
      if (trusted_host ? !RegistryKeyIsInstallerProtected(record.get())
                       : CallerCanWriteRegistryKey(record.get(),
                                                   caller_process)) {
        continue;
      }
      const auto install_location =
          ReadRegistryString(record.get(), L"InstallLocation");
      const auto record_package =
          ReadRegistryString(record.get(), L"DesktopUpdaterPackageId");
      if (!install_location.has_value() || !record_package.has_value() ||
          NormalizePath(*install_location) != normalized_target ||
          _wcsicmp(record_package->c_str(), wide_package.c_str()) != 0) {
        continue;
      }
      const std::string utf8_key = WideToUtf8(key_name);
      const std::string utf8_target = WideToUtf8(normalized_target);
      if (utf8_key.empty() || utf8_target.empty()) continue;
      std::string canonical = "desktop-updater-uninstall-record-v1";
      AppendField(view.name, &canonical);
      AppendField(utf8_key, &canonical);
      AppendField(utf8_target, &canonical);
      AppendField(package_id, &canonical);
      matches.push_back(std::move(canonical));
    }
  }
  if (matches.empty()) return std::nullopt;
  return *std::min_element(matches.begin(), matches.end());
}

std::optional<std::string> FindCanonicalWindowsUninstallRecordProof(
    const std::filesystem::path& canonical_target,
    const std::string& package_id,
    HANDLE caller_process) {
  return FindCanonicalWindowsUninstallRecordProofInternal(
      canonical_target, package_id, caller_process, false);
}

std::optional<std::string>
FindCanonicalWindowsUninstallRecordProofForTrustedHost(
    const std::filesystem::path& canonical_target,
    const std::string& package_id) {
  return FindCanonicalWindowsUninstallRecordProofInternal(
      canonical_target, package_id, nullptr, true);
}

}  // namespace desktop_updater::helper
