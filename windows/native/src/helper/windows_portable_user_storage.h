#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_PORTABLE_USER_STORAGE_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_PORTABLE_USER_STORAGE_H_

#include <windows.h>

#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

class WindowsPortableUserStorageError : public std::runtime_error {
 public:
  explicit WindowsPortableUserStorageError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct PortableWindowsExactUserAclAceFacts {
  std::wstring sid;
  DWORD mask = 0;
  BYTE flags = 0;
  bool allowed = false;
};

void ValidatePortableWindowsExactUserAclFacts(
    const std::wstring& expected_user_sid,
    const std::wstring& owner_sid,
    const std::wstring& group_sid,
    bool dacl_protected,
    DWORD expected_mask,
    BYTE expected_flags,
    const std::vector<PortableWindowsExactUserAclAceFacts>& aces);

// Retains LocalAppData by walking every component from a fixed drive root
// using handle-relative OBJ_DONT_REPARSE opens.
UniqueWindowsHandle OpenPortableWindowsExactUserLocalAppData(
    std::filesystem::path* retained_path = nullptr);

// Creates a single-link file with its exact owner/group/DACL supplied to
// NtCreateFile, so no inherited-ACL crash window ever exists.
UniqueWindowsHandle CreatePortableWindowsExactUserFile(
    HANDLE parent,
    const std::wstring& leaf,
    ACCESS_MASK desired_access,
    ULONG share_access,
    ULONG create_options,
    ULONG file_attributes,
    PSID user,
    const std::wstring& user_sid);

// Creates a directory with its exact inheritable owner/group/DACL supplied to
// NtCreateFile. The directory is never observable with an inherited ACL.
UniqueWindowsHandle CreatePortableWindowsExactUserDirectory(
    HANDLE parent,
    const std::wstring& leaf,
    ACCESS_MASK desired_access,
    ULONG share_access,
    ULONG create_options,
    ULONG file_attributes,
    PSID user,
    const std::wstring& user_sid);

// Applies and reads back a protected descriptor with exact owner/group=user
// and exactly two allow ACEs: the user and LocalSystem.
void ApplyPortableWindowsExactUserSecurity(HANDLE object,
                                           PSID user,
                                           const std::wstring& user_sid,
                                           bool directory);
void ValidatePortableWindowsExactUserSecurity(HANDLE object,
                                              PSID user,
                                              bool directory);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_PORTABLE_USER_STORAGE_H_
