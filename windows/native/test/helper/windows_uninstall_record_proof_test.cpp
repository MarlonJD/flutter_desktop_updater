#include <gtest/gtest.h>

#include <windows.h>

#include <aclapi.h>

#include <array>
#include <cwchar>
#include <filesystem>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "windows_uninstall_record_proof.h"

namespace desktop_updater::helper {
namespace {

struct NativeUnicodeString {
  USHORT length;
  USHORT maximum_length;
  PWSTR buffer;
};

using NtSetValueKeyFunction = LONG(NTAPI*)(HANDLE, NativeUnicodeString*, ULONG,
                                           ULONG, void*, ULONG);

bool SetRawRegistryString(HKEY key,
                          const wchar_t* value_name,
                          const void* bytes,
                          ULONG byte_count) {
  if (key == nullptr || value_name == nullptr || bytes == nullptr) {
    return false;
  }
  const std::size_t name_length = std::wcslen(value_name);
  if (name_length == 0 ||
      name_length > std::numeric_limits<USHORT>::max() / sizeof(wchar_t)) {
    return false;
  }
  const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  const auto set_value = ntdll == nullptr
                             ? nullptr
                             : reinterpret_cast<NtSetValueKeyFunction>(
                                   GetProcAddress(ntdll, "NtSetValueKey"));
  if (set_value == nullptr) return false;
  NativeUnicodeString name{
      static_cast<USHORT>(name_length * sizeof(wchar_t)),
      static_cast<USHORT>(name_length * sizeof(wchar_t)),
      const_cast<PWSTR>(value_name),
  };
  return set_value(reinterpret_cast<HANDLE>(key), &name, 0, REG_SZ,
                   const_cast<void*>(bytes), byte_count) >= 0;
}

class ScopedRegistryKey {
 public:
  explicit ScopedRegistryKey(HKEY key = nullptr) : key_(key) {}
  ~ScopedRegistryKey() {
    if (key_ != nullptr) RegCloseKey(key_);
  }
  ScopedRegistryKey(const ScopedRegistryKey&) = delete;
  ScopedRegistryKey& operator=(const ScopedRegistryKey&) = delete;

  HKEY get() const { return key_; }
  void reset(HKEY key = nullptr) {
    if (key_ != nullptr) RegCloseKey(key_);
    key_ = key;
  }

 private:
  HKEY key_;
};

class WindowsUninstallRecordProofTest : public testing::Test {
 protected:
  void SetUp() override {
    root_path_ = L"Software\\DesktopUpdater\\Tests\\UninstallProof-" +
                 std::to_wstring(GetCurrentProcessId()) + L"-" +
                 std::to_wstring(GetTickCount64());
    HKEY raw_root = nullptr;
    ASSERT_EQ(ERROR_SUCCESS,
              RegCreateKeyExW(HKEY_CURRENT_USER, root_path_.c_str(), 0,
                              nullptr, REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS,
                              nullptr, &raw_root, nullptr));
    root_.reset(raw_root);
    ASSERT_EQ(ERROR_SUCCESS,
              RegOverridePredefKey(HKEY_LOCAL_MACHINE, root_.get()));
    override_active_ = true;

    constexpr wchar_t kUninstallPath[] =
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall";
    HKEY raw_uninstall = nullptr;
    ASSERT_EQ(ERROR_SUCCESS,
              RegCreateKeyExW(HKEY_LOCAL_MACHINE, kUninstallPath, 0, nullptr,
                              REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, nullptr,
                              &raw_uninstall, nullptr));
    uninstall_.reset(raw_uninstall);
    HKEY raw_record = nullptr;
    ASSERT_EQ(ERROR_SUCCESS,
              RegCreateKeyExW(uninstall_.get(), L"DesktopUpdaterProofFixture",
                              0, nullptr, REG_OPTION_NON_VOLATILE,
                              KEY_ALL_ACCESS, nullptr, &raw_record, nullptr));
    record_.reset(raw_record);

    ASSERT_EQ(ERROR_SUCCESS,
              GetSecurityInfo(record_.get(), SE_REGISTRY_KEY,
                              DACL_SECURITY_INFORMATION, nullptr, nullptr,
                              &original_dacl_, nullptr,
                              &original_security_descriptor_));
    ASSERT_NE(nullptr, original_security_descriptor_);
    ASSERT_NE(nullptr, original_dacl_);
    SetValidValues();
  }

  void TearDown() override {
    if (record_.get() != nullptr && original_dacl_ != nullptr) {
      SetSecurityInfo(record_.get(), SE_REGISTRY_KEY,
                      DACL_SECURITY_INFORMATION, nullptr, nullptr,
                      original_dacl_, nullptr);
    }
    if (original_security_descriptor_ != nullptr) {
      LocalFree(original_security_descriptor_);
    }
    record_.reset();
    uninstall_.reset();
    if (override_active_) {
      RegOverridePredefKey(HKEY_LOCAL_MACHINE, nullptr);
    }
    root_.reset();
    RegDeleteTreeW(HKEY_CURRENT_USER, root_path_.c_str());
  }

  void SetValidValues() {
    const std::wstring target = target_.wstring();
    ASSERT_EQ(ERROR_SUCCESS,
              RegSetValueExW(
                  record_.get(), L"InstallLocation", 0, REG_SZ,
                  reinterpret_cast<const BYTE*>(target.c_str()),
                  static_cast<DWORD>((target.size() + 1) * sizeof(wchar_t))));
    const std::wstring package(package_id_.begin(), package_id_.end());
    ASSERT_EQ(ERROR_SUCCESS,
              RegSetValueExW(
                  record_.get(), L"DesktopUpdaterPackageId", 0, REG_SZ,
                  reinterpret_cast<const BYTE*>(package.c_str()),
                  static_cast<DWORD>((package.size() + 1) * sizeof(wchar_t))));
  }

  void ProtectRecordFromCallerWrites() {
    HANDLE raw_token = nullptr;
    ASSERT_TRUE(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token));
    ScopedHandle token(raw_token);
    DWORD token_user_size = 0;
    GetTokenInformation(token.get(), TokenUser, nullptr, 0, &token_user_size);
    ASSERT_EQ(ERROR_INSUFFICIENT_BUFFER, GetLastError());
    std::vector<BYTE> token_user_buffer(token_user_size);
    ASSERT_TRUE(GetTokenInformation(token.get(), TokenUser,
                                    token_user_buffer.data(), token_user_size,
                                    &token_user_size));
    const auto* token_user =
        reinterpret_cast<const TOKEN_USER*>(token_user_buffer.data());

    std::array<BYTE, SECURITY_MAX_SID_SIZE> owner_rights_sid{};
    DWORD owner_rights_sid_size =
        static_cast<DWORD>(owner_rights_sid.size());
    ASSERT_TRUE(CreateWellKnownSid(WinCreatorOwnerRightsSid, nullptr,
                                   owner_rights_sid.data(),
                                   &owner_rights_sid_size));

    std::array<EXPLICIT_ACCESSW, 2> entries{};
    entries[0].grfAccessPermissions = KEY_READ;
    entries[0].grfAccessMode = SET_ACCESS;
    entries[0].grfInheritance = NO_INHERITANCE;
    entries[0].Trustee.TrusteeForm = TRUSTEE_IS_SID;
    entries[0].Trustee.TrusteeType = TRUSTEE_IS_USER;
    entries[0].Trustee.ptstrName =
        static_cast<LPWSTR>(token_user->User.Sid);
    entries[1].grfAccessPermissions = KEY_READ;
    entries[1].grfAccessMode = SET_ACCESS;
    entries[1].grfInheritance = NO_INHERITANCE;
    entries[1].Trustee.TrusteeForm = TRUSTEE_IS_SID;
    entries[1].Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
    entries[1].Trustee.ptstrName =
        reinterpret_cast<LPWSTR>(owner_rights_sid.data());
    PACL raw_acl = nullptr;
    ASSERT_EQ(ERROR_SUCCESS,
              SetEntriesInAclW(static_cast<ULONG>(entries.size()),
                               entries.data(), nullptr, &raw_acl));
    ASSERT_NE(nullptr, raw_acl);
    std::unique_ptr<void, decltype(&LocalFree)> acl(raw_acl, LocalFree);
    ASSERT_EQ(ERROR_SUCCESS,
              SetSecurityInfo(record_.get(), SE_REGISTRY_KEY,
                              DACL_SECURITY_INFORMATION |
                                  PROTECTED_DACL_SECURITY_INFORMATION,
                              nullptr, nullptr, raw_acl, nullptr));
  }

  class ScopedHandle {
   public:
    explicit ScopedHandle(HANDLE handle) : handle_(handle) {}
    ~ScopedHandle() {
      if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
        CloseHandle(handle_);
      }
    }
    HANDLE get() const { return handle_; }

   private:
    HANDLE handle_;
  };

  std::optional<std::string> FindProof() const {
    return FindCanonicalWindowsUninstallRecordProof(
        target_, package_id_, GetCurrentProcess());
  }

  std::wstring root_path_;
  ScopedRegistryKey root_;
  ScopedRegistryKey uninstall_;
  ScopedRegistryKey record_;
  bool override_active_ = false;
  PSECURITY_DESCRIPTOR original_security_descriptor_ = nullptr;
  PACL original_dacl_ = nullptr;
  const std::filesystem::path target_ =
      L"C:\\Program Files\\DesktopUpdaterProofFixture";
  const std::string package_id_ = "com.example.desktop-updater-proof";
};

TEST_F(WindowsUninstallRecordProofTest,
       AcceptsAWellFormedRecordThatTheCallerCannotWrite) {
  ProtectRecordFromCallerWrites();

  EXPECT_TRUE(FindProof().has_value());
}

TEST_F(WindowsUninstallRecordProofTest,
       RejectsARecordWritableByTheNamedPipeCaller) {
  EXPECT_FALSE(FindProof().has_value());
}

TEST_F(WindowsUninstallRecordProofTest,
       AutonomousProofRejectsAnUntrustedRegistryOwner) {
  ProtectRecordFromCallerWrites();

  EXPECT_FALSE(FindCanonicalWindowsUninstallRecordProofForTrustedHost(
                   target_, package_id_)
                   .has_value());
}

TEST_F(WindowsUninstallRecordProofTest, RejectsAnOddLengthRegistryString) {
  const std::array<BYTE, 3> malformed = {'x', 0, 'y'};
  ASSERT_EQ(ERROR_SUCCESS,
            RegSetValueExW(record_.get(), L"InstallLocation", 0, REG_SZ,
                           malformed.data(),
                           static_cast<DWORD>(malformed.size())));
  ProtectRecordFromCallerWrites();

  EXPECT_FALSE(FindProof().has_value());
}

TEST_F(WindowsUninstallRecordProofTest,
       RejectsARegistryStringWithoutATerminator) {
  const std::wstring target = target_.wstring();
  ASSERT_TRUE(SetRawRegistryString(
      record_.get(), L"InstallLocation", target.data(),
      static_cast<ULONG>(target.size() * sizeof(wchar_t))));
  ProtectRecordFromCallerWrites();

  EXPECT_FALSE(FindProof().has_value());
}

TEST_F(WindowsUninstallRecordProofTest,
       RejectsARegistryStringWithAnEmbeddedNull) {
  const std::wstring target = target_.wstring();
  std::vector<wchar_t> malformed(target.begin(), target.end());
  malformed.push_back(L'\0');
  malformed.insert(malformed.end(), {L't', L'a', L'm', L'p', L'e', L'r'});
  malformed.push_back(L'\0');
  ASSERT_EQ(ERROR_SUCCESS,
            RegSetValueExW(
                record_.get(), L"InstallLocation", 0, REG_SZ,
                reinterpret_cast<const BYTE*>(malformed.data()),
                static_cast<DWORD>(malformed.size() * sizeof(wchar_t))));
  ProtectRecordFromCallerWrites();

  EXPECT_FALSE(FindProof().has_value());
}

}  // namespace
}  // namespace desktop_updater::helper
