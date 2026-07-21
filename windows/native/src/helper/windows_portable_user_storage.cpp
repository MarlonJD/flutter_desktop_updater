#include "windows_portable_user_storage.h"

#include <winternl.h>

#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>

#include <algorithm>
#include <array>
#include <cwctype>
#include <memory>
#include <utility>

namespace desktop_updater::helper {
namespace {

[[noreturn]] void Fail(const std::string& detail) {
  throw WindowsPortableUserStorageError("portable exact-user storage: " +
                                        detail);
}

std::vector<unsigned char> ParseSid(const std::wstring& value) {
  PSID raw = nullptr;
  if (value.empty() ||
      !ConvertStringSidToSidW(value.c_str(), &raw) || raw == nullptr) {
    Fail("SID is invalid");
  }
  std::unique_ptr<void, decltype(&LocalFree)> owner(raw, LocalFree);
  const DWORD size = GetLengthSid(raw);
  std::vector<unsigned char> result(size);
  if (size == 0 || !CopySid(size, result.data(), raw)) {
    Fail("SID copy failed");
  }
  return result;
}

PSID SidPointer(const std::vector<unsigned char>& sid) {
  return const_cast<unsigned char*>(sid.data());
}

std::wstring SidText(PSID sid) {
  LPWSTR raw = nullptr;
  if (sid == nullptr || !IsValidSid(sid) ||
      !ConvertSidToStringSidW(sid, &raw) || raw == nullptr) {
    Fail("SID conversion failed");
  }
  std::wstring result(raw);
  LocalFree(raw);
  return result;
}

bool IsLocalSystemSid(PSID sid) {
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> system{};
  DWORD size = static_cast<DWORD>(system.size());
  return sid != nullptr &&
         CreateWellKnownSid(WinLocalSystemSid, nullptr, system.data(),
                            &size) &&
         EqualSid(sid, system.data());
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
    Fail("final path is unavailable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

std::wstring ExactSecurityDescriptor(const std::wstring& user_sid,
                                     bool directory) {
  (void)ParseSid(user_sid);
  const std::wstring flags = directory ? L"OICI" : L"";
  return L"O:" + user_sid + L"G:" + user_sid + L"D:P(A;" + flags +
         L";FA;;;" + user_sid + L")(A;" + flags + L";FA;;;SY)";
}

}  // namespace

void ValidatePortableWindowsExactUserAclFacts(
    const std::wstring& expected_user_sid,
    const std::wstring& owner_sid,
    const std::wstring& group_sid,
    bool dacl_protected,
    DWORD expected_mask,
    BYTE expected_flags,
    const std::vector<PortableWindowsExactUserAclAceFacts>& aces) {
  const auto expected_user = ParseSid(expected_user_sid);
  const auto owner = ParseSid(owner_sid);
  const auto group = ParseSid(group_sid);
  if (!dacl_protected || expected_mask == 0 || aces.size() != 2 ||
      !EqualSid(SidPointer(expected_user), SidPointer(owner)) ||
      !EqualSid(SidPointer(expected_user), SidPointer(group))) {
    Fail("owner, group, or protected DACL changed");
  }
  bool user_exact = false;
  bool system_exact = false;
  for (const auto& ace : aces) {
    const auto sid = ParseSid(ace.sid);
    if (!ace.allowed || ace.mask != expected_mask ||
        ace.flags != expected_flags) {
      Fail("DACL mask or flags changed");
    }
    if (EqualSid(SidPointer(sid), SidPointer(expected_user))) {
      if (user_exact) Fail("user ACE is duplicated");
      user_exact = true;
    } else if (IsLocalSystemSid(SidPointer(sid))) {
      if (system_exact) Fail("SYSTEM ACE is duplicated");
      system_exact = true;
    } else {
      Fail("DACL grants another principal");
    }
  }
  if (!user_exact || !system_exact) {
    Fail("exact-user DACL is incomplete");
  }
}

UniqueWindowsHandle OpenPortableWindowsExactUserLocalAppData(
    std::filesystem::path* retained_path) {
  PWSTR raw_path = nullptr;
  if (SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr,
                           &raw_path) != S_OK ||
      raw_path == nullptr) {
    Fail("LocalAppData is unavailable");
  }
  std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> owner(raw_path,
                                                           CoTaskMemFree);
  const std::filesystem::path path =
      std::filesystem::path(raw_path).lexically_normal();
  const std::wstring root_name = path.root_name().wstring();
  if (root_name.size() != 2 || root_name[1] != L':' ||
      path.root_directory().empty() || !path.has_relative_path()) {
    Fail("LocalAppData is not on a fixed local volume");
  }
  UniqueWindowsHandle current(CreateFileW(
      path.root_path().c_str(),
      FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!current.valid()) Fail("LocalAppData volume cannot open");
  const WindowsFileIdentity root_identity =
      ReadWindowsFileIdentity(current.get());
  if (!root_identity.directory ||
      (root_identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    Fail("LocalAppData volume is not a plain directory");
  }
  std::vector<std::wstring> components;
  for (const auto& component : path.relative_path()) {
    const std::wstring leaf = component.wstring();
    if (leaf.empty() || leaf == L"." || leaf == L".." ||
        leaf.find_first_of(L"\\/") != std::wstring::npos) {
      Fail("LocalAppData component is invalid");
    }
    components.push_back(leaf);
  }
  if (components.empty()) Fail("LocalAppData path is incomplete");
  for (std::size_t index = 0; index < components.size(); ++index) {
    const bool final_component = index + 1 == components.size();
    const ACCESS_MASK access =
        FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | READ_CONTROL |
        SYNCHRONIZE |
        (final_component ? FILE_ADD_SUBDIRECTORY
                         : static_cast<ACCESS_MASK>(0));
    UniqueWindowsHandle next = OpenRelativeNoReparse(
        current.get(), components[index], access,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
        FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
    const WindowsFileIdentity identity =
        ReadWindowsFileIdentity(next.get());
    if (!identity.directory ||
        (identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      Fail("LocalAppData ancestor is not plain");
    }
    current = std::move(next);
  }
  const std::filesystem::path final_path =
      FinalPath(current.get()).lexically_normal();
  if (NormalizePath(final_path) != NormalizePath(path)) {
    Fail("LocalAppData retained identity changed");
  }
  if (retained_path != nullptr) *retained_path = final_path;
  return current;
}

UniqueWindowsHandle CreatePortableWindowsExactUserFile(
    HANDLE parent,
    const std::wstring& leaf,
    ACCESS_MASK desired_access,
    ULONG share_access,
    ULONG create_options,
    ULONG file_attributes,
    PSID user,
    const std::wstring& user_sid) {
  if (user == nullptr || !IsValidSid(user)) {
    Fail("atomic file user is invalid");
  }
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  const std::wstring sddl = ExactSecurityDescriptor(user_sid, false);
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl.c_str(), SDDL_REVISION_1, &raw_descriptor, nullptr) ||
      raw_descriptor == nullptr) {
    Fail("atomic file security construction failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  UniqueWindowsHandle file = OpenRelativeNoReparse(
      parent, leaf, desired_access, share_access, FILE_CREATE, create_options,
      file_attributes, raw_descriptor);
  ValidatePortableWindowsExactUserSecurity(file.get(), user, false);
  return file;
}

UniqueWindowsHandle CreatePortableWindowsExactUserDirectory(
    HANDLE parent,
    const std::wstring& leaf,
    ACCESS_MASK desired_access,
    ULONG share_access,
    ULONG create_options,
    ULONG file_attributes,
    PSID user,
    const std::wstring& user_sid) {
  if (user == nullptr || !IsValidSid(user)) {
    Fail("atomic directory user is invalid");
  }
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  const std::wstring sddl = ExactSecurityDescriptor(user_sid, true);
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl.c_str(), SDDL_REVISION_1, &raw_descriptor, nullptr) ||
      raw_descriptor == nullptr) {
    Fail("atomic directory security construction failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  UniqueWindowsHandle directory = OpenRelativeNoReparse(
      parent, leaf, desired_access, share_access, FILE_CREATE,
      create_options | FILE_DIRECTORY_FILE, file_attributes, raw_descriptor);
  ValidatePortableWindowsExactUserSecurity(directory.get(), user, true);
  return directory;
}

void ApplyPortableWindowsExactUserSecurity(HANDLE object,
                                           PSID user,
                                           const std::wstring& user_sid,
                                           bool directory) {
  if (object == nullptr || object == INVALID_HANDLE_VALUE || user == nullptr ||
      !IsValidSid(user)) {
    Fail("security target or user is invalid");
  }
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  const std::wstring sddl = ExactSecurityDescriptor(user_sid, directory);
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl.c_str(), SDDL_REVISION_1, &raw_descriptor, nullptr) ||
      raw_descriptor == nullptr) {
    Fail("DACL construction failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  PACL dacl = nullptr;
  BOOL present = FALSE;
  BOOL defaulted = FALSE;
  if (!GetSecurityDescriptorDacl(raw_descriptor, &present, &dacl,
                                 &defaulted) ||
      present == FALSE || dacl == nullptr ||
      SetSecurityInfo(object, SE_FILE_OBJECT,
                      OWNER_SECURITY_INFORMATION |
                          GROUP_SECURITY_INFORMATION |
                          DACL_SECURITY_INFORMATION |
                          PROTECTED_DACL_SECURITY_INFORMATION,
                      user, user, dacl, nullptr) != ERROR_SUCCESS) {
    Fail("exact-user security application failed");
  }
}

void ValidatePortableWindowsExactUserSecurity(HANDLE object,
                                              PSID user,
                                              bool directory) {
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PSID owner = nullptr;
  PSID group = nullptr;
  PACL dacl = nullptr;
  const DWORD status = GetSecurityInfo(
      object, SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |
          DACL_SECURITY_INFORMATION,
      &owner, &group, &dacl, nullptr, &raw_descriptor);
  if (status != ERROR_SUCCESS || raw_descriptor == nullptr || owner == nullptr ||
      group == nullptr || dacl == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    Fail("security descriptor readback failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!GetSecurityDescriptorControl(raw_descriptor, &control, &revision)) {
    Fail("DACL control readback failed");
  }
  std::vector<PortableWindowsExactUserAclAceFacts> aces;
  aces.reserve(dacl->AceCount);
  for (DWORD index = 0; index < dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace) || raw_ace == nullptr) {
      Fail("DACL is unreadable");
    }
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE &&
        header->AceType != ACCESS_DENIED_ACE_TYPE) {
      Fail("DACL contains unsupported ACE type");
    }
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    aces.push_back({SidText(sid), ace->Mask, header->AceFlags,
                    header->AceType == ACCESS_ALLOWED_ACE_TYPE});
  }
  ValidatePortableWindowsExactUserAclFacts(
      SidText(user), SidText(owner), SidText(group),
      (control & SE_DACL_PROTECTED) != 0, FILE_ALL_ACCESS,
      directory ? static_cast<BYTE>(OBJECT_INHERIT_ACE |
                                    CONTAINER_INHERIT_ACE)
                : static_cast<BYTE>(0),
      aces);
}

}  // namespace desktop_updater::helper
