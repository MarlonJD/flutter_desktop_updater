#include "desktop_updater_native.h"

#include <windows.h>
#include <bcrypt.h>
#include <knownfolders.h>
#include <objbase.h>
#include <shlobj.h>

#include <algorithm>
#include <array>
#include <climits>
#include <cstdint>
#include <cwchar>
#include <filesystem>
#include <iomanip>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "helper_authenticode.h"
#include "helper_policy_windows.h"
#include "json_value.h"
#include "named_pipe_transport.h"
#include "native_install_request.h"
#include "sha256_bcrypt.h"
#include "stage_provenance.h"
#include "windows_native_install_request_builder.h"
#include "windows_one_shot_transport.h"
#include "windows_portable_transaction_index.h"
#include "windows_protected_helper_locator.h"
#include "windows_recovery_transport.h"
#include "windows_uninstall_record_proof.h"

#ifndef DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR
#define DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR ""
#endif

namespace fs = std::filesystem;

namespace desktop_updater {
namespace native {
namespace {

constexpr std::size_t kMaximumInstalledIdentityMarkerBytes = 64 * 1024;
constexpr std::size_t kMaximumHelperMetadataBytes = 16 * 1024 * 1024;
constexpr std::size_t kMaximumHelperPolicyBytes = 1024 * 1024;
constexpr DWORD kWindowsHelperStartupTimeoutMilliseconds = 30 * 1000;
constexpr wchar_t kWindowsHelperExecutableName[] =
    L"desktop_updater_install_helper.exe";
constexpr wchar_t kWindowsHelperPolicyName[] =
    L"desktop_updater_helper_policy.json";
constexpr wchar_t kInstalledIdentityMarkerName[] =
    L".desktop_updater_install_identity.json";
constexpr wchar_t kStagedReleaseManifestName[] =
    L".desktop_updater_release_manifest.json";
constexpr wchar_t kRestartParentHandleEnvironment[] =
    L"DESKTOP_UPDATER_RESTART_PARENT_HANDLE";
constexpr wchar_t kRestartReadyHandleEnvironment[] =
    L"DESKTOP_UPDATER_RESTART_READY_HANDLE";
constexpr DWORD kRestartReadinessTimeoutMilliseconds = 10 * 1000;

class ScopedWindowsHandle {
 public:
  ScopedWindowsHandle() = default;
  explicit ScopedWindowsHandle(HANDLE handle) : handle_(handle) {}
  ~ScopedWindowsHandle() { reset(); }
  ScopedWindowsHandle(const ScopedWindowsHandle&) = delete;
  ScopedWindowsHandle& operator=(const ScopedWindowsHandle&) = delete;

  HANDLE get() const { return handle_; }
  bool valid() const {
    return handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE;
  }
  void reset(HANDLE handle = nullptr) {
    if (valid()) CloseHandle(handle_);
    handle_ = handle;
  }

 private:
  HANDLE handle_ = nullptr;
};

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  const int size = WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return "";
  }
  std::string result(size, '\0');
  if (WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size,
                          nullptr, nullptr) <= 0) {
    return "";
  }
  result.pop_back();
  return result;
}

std::string ReadBoundedRegularFileNoReparse(const fs::path& path,
                                            std::size_t maximum_bytes) {
  HANDLE raw_file = CreateFileW(
      path.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (raw_file == INVALID_HANDLE_VALUE) {
    throw std::runtime_error("Required install metadata file is unavailable.");
  }
  struct FileCloser {
    void operator()(void* handle) const {
      if (handle != nullptr && handle != INVALID_HANDLE_VALUE) {
        CloseHandle(static_cast<HANDLE>(handle));
      }
    }
  };
  std::unique_ptr<void, FileCloser> file(raw_file);
  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(raw_file, &information) ||
      (information.dwFileAttributes &
       (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
      information.nFileSizeHigh != 0 || information.nFileSizeLow == 0 ||
      information.nFileSizeLow > maximum_bytes) {
    throw std::runtime_error(
        "Install metadata must be a bounded regular file.");
  }
  std::string contents(information.nFileSizeLow, '\0');
  std::size_t offset = 0;
  while (offset < contents.size()) {
    DWORD bytes_read = 0;
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        contents.size() - offset, 64 * 1024));
    if (!ReadFile(raw_file, contents.data() + offset, requested, &bytes_read,
                  nullptr) ||
        bytes_read == 0 || bytes_read > requested) {
      throw std::runtime_error("Install metadata read failed.");
    }
    offset += bytes_read;
  }
  return contents;
}

std::string Sha256Hex(const std::string& bytes) {
  return runtime::internal::StageBytesToHex(
      runtime::internal::BCryptSha256(bytes));
}

std::string CanonicalJsonFile(const fs::path& path,
                              std::size_t maximum_bytes,
                              const char* description,
                              bool allow_single_trailing_newline = false) {
  const std::string contents =
      ReadBoundedRegularFileNoReparse(path, maximum_bytes);
  std::string canonical = contents;
  if (allow_single_trailing_newline && !canonical.empty() &&
      canonical.back() == '\n') {
    canonical.pop_back();
  }
  const runtime::internal::JsonValue value =
      runtime::internal::ParseJson(canonical);
  if (runtime::internal::EncodeCanonicalJson(value) != canonical) {
    throw std::runtime_error(std::string(description) +
                             " must be canonical JSON.");
  }
  return contents;
}

void ValidateConfiguredWindowsHelperPath(
    const helper::ProtectedWindowsHelperEndpointV1& endpoint) {
  const std::string configured =
      DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR;
  if (!configured.empty()) {
    const fs::path expected =
        fs::u8path(configured) / kWindowsHelperExecutableName;
    if (_wcsicmp(expected.lexically_normal().c_str(),
                 endpoint.helper_path.lexically_normal().c_str()) != 0) {
      throw std::runtime_error(
          "Protected Windows helper install directory is not configured for "
          "the registered endpoint.");
    }
  }
}

fs::path ConfiguredWindowsHelperPath() {
  const std::string configured =
      DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR;
  if (configured.empty()) {
    throw std::runtime_error(
        "Protected Windows helper install directory is not configured.");
  }
  return fs::u8path(configured) / kWindowsHelperExecutableName;
}

std::string NewTransactionId() {
  GUID guid{};
  if (FAILED(CoCreateGuid(&guid))) {
    throw std::runtime_error("Unable to create install transaction ID.");
  }
  std::ostringstream encoded;
  encoded << std::hex << std::nouppercase << std::setfill('0')
          << std::setw(8) << guid.Data1 << '-' << std::setw(4) << guid.Data2
          << '-' << std::setw(4) << guid.Data3 << '-' << std::setw(2)
          << static_cast<unsigned int>(guid.Data4[0]) << std::setw(2)
          << static_cast<unsigned int>(guid.Data4[1]) << '-' << std::setw(2)
          << static_cast<unsigned int>(guid.Data4[2]) << std::setw(2)
          << static_cast<unsigned int>(guid.Data4[3]) << std::setw(2)
          << static_cast<unsigned int>(guid.Data4[4]) << std::setw(2)
          << static_cast<unsigned int>(guid.Data4[5]) << std::setw(2)
          << static_cast<unsigned int>(guid.Data4[6]) << std::setw(2)
          << static_cast<unsigned int>(guid.Data4[7]);
  return encoded.str();
}

std::string SecureRequestNonce() {
  constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::array<unsigned char, 32> bytes{};
  if (BCryptGenRandom(nullptr, bytes.data(),
                      static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    throw std::runtime_error("Unable to create secure install nonce.");
  }
  std::string encoded;
  encoded.reserve(43);
  std::uint32_t accumulator = 0;
  int bit_count = 0;
  for (const unsigned char byte : bytes) {
    accumulator = (accumulator << 8) | byte;
    bit_count += 8;
    while (bit_count >= 6) {
      bit_count -= 6;
      encoded.push_back(alphabet[(accumulator >> bit_count) & 0x3f]);
    }
  }
  if (bit_count != 0) {
    encoded.push_back(alphabet[(accumulator << (6 - bit_count)) & 0x3f]);
  }
  return encoded;
}

std::uint64_t CurrentProcessStartIdentity() {
  FILETIME creation{};
  FILETIME exit{};
  FILETIME kernel{};
  FILETIME user{};
  if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel,
                       &user)) {
    throw std::runtime_error(
        "Unable to read caller process start identity.");
  }
  return (static_cast<std::uint64_t>(creation.dwHighDateTime) << 32) |
         creation.dwLowDateTime;
}

std::string RequestPath(const fs::path& path) {
  std::string encoded = WideToUtf8(path.wstring());
  std::replace(encoded.begin(), encoded.end(), '\\', '/');
  return encoded;
}

std::wstring CurrentExecutablePath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  while (true) {
    const DWORD length = GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return L"";
    }
    if (length < buffer.size() - 1) {
      return std::wstring(buffer.data(), length);
    }
    buffer.resize(buffer.size() * 2);
  }
}

std::wstring FinalPathForHandle(HANDLE handle) {
  const DWORD required = GetFinalPathNameByHandleW(
      handle, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (required == 0) return L"";
  std::vector<wchar_t> buffer(static_cast<std::size_t>(required) + 1);
  const DWORD written = GetFinalPathNameByHandleW(
      handle, buffer.data(), static_cast<DWORD>(buffer.size()),
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (written == 0 || written >= buffer.size()) return L"";
  return std::wstring(buffer.data(), written);
}

std::wstring EnvironmentVariableValue(const wchar_t* name) {
  const DWORD required_length = GetEnvironmentVariableW(name, nullptr, 0);
  if (required_length == 0) {
    return L"";
  }
  std::vector<wchar_t> buffer(required_length);
  const DWORD written_length =
      GetEnvironmentVariableW(name, buffer.data(), required_length);
  if (written_length == 0 || written_length >= required_length) {
    return L"";
  }
  return std::wstring(buffer.data(), written_length);
}

bool EnvironmentVariableIsPresent(const wchar_t* name) {
  SetLastError(ERROR_SUCCESS);
  const DWORD required_length = GetEnvironmentVariableW(name, nullptr, 0);
  return required_length > 0 || GetLastError() != ERROR_ENVVAR_NOT_FOUND;
}

bool EnvironmentEntryHasName(const std::wstring& entry,
                             const wchar_t* name) {
  const std::size_t name_length = wcslen(name);
  return entry.size() > name_length && entry[name_length] == L'=' &&
         _wcsnicmp(entry.c_str(), name, name_length) == 0;
}

std::vector<wchar_t> RestartChildEnvironment(HANDLE parent_process,
                                             HANDLE ready_event) {
  LPWCH raw_environment = GetEnvironmentStringsW();
  if (raw_environment == nullptr) {
    throw std::runtime_error(
        "Windows restart environment is unavailable.");
  }
  std::vector<std::wstring> entries;
  for (const wchar_t* cursor = raw_environment; *cursor != L'\0';
       cursor += wcslen(cursor) + 1) {
    std::wstring entry(cursor);
    if (!EnvironmentEntryHasName(entry, kRestartParentHandleEnvironment) &&
        !EnvironmentEntryHasName(entry, kRestartReadyHandleEnvironment)) {
      entries.push_back(std::move(entry));
    }
  }
  FreeEnvironmentStringsW(raw_environment);
  entries.push_back(
      std::wstring(kRestartParentHandleEnvironment) + L"=" +
      std::to_wstring(reinterpret_cast<std::uintptr_t>(parent_process)));
  entries.push_back(
      std::wstring(kRestartReadyHandleEnvironment) + L"=" +
      std::to_wstring(reinterpret_cast<std::uintptr_t>(ready_event)));
  std::sort(entries.begin(), entries.end(),
            [](const std::wstring& left, const std::wstring& right) {
              return _wcsicmp(left.c_str(), right.c_str()) < 0;
            });

  std::size_t length = 1;
  for (const std::wstring& entry : entries) length += entry.size() + 1;
  std::vector<wchar_t> environment;
  environment.reserve(length);
  for (const std::wstring& entry : entries) {
    environment.insert(environment.end(), entry.begin(), entry.end());
    environment.push_back(L'\0');
  }
  environment.push_back(L'\0');
  return environment;
}

bool StrictInheritedHandle(const std::wstring& value, HANDLE* handle) {
  if (handle == nullptr || value.empty()) return false;
  std::uintptr_t parsed = 0;
  for (const wchar_t character : value) {
    if (character < L'0' || character > L'9') return false;
    const std::uintptr_t digit =
        static_cast<std::uintptr_t>(character - L'0');
    if (parsed >
        (std::numeric_limits<std::uintptr_t>::max() - digit) / 10) {
      return false;
    }
    parsed = parsed * 10 + digit;
  }
  if (parsed == 0) return false;
  const HANDLE candidate = reinterpret_cast<HANDLE>(parsed);
  DWORD flags = 0;
  if (!GetHandleInformation(candidate, &flags)) return false;
  *handle = candidate;
  return true;
}

std::wstring NormalizedDirectoryPath(const fs::path& path) {
  std::wstring value = path.lexically_normal().wstring();
  if (value.rfind(L"\\\\?\\", 0) == 0) {
    value.erase(0, 4);
  }
  while (!value.empty() && (value.back() == L'\\' || value.back() == L'/')) {
    value.pop_back();
  }
  return value;
}

bool PathEquals(const fs::path& first, const fs::path& second) {
  const std::wstring first_value = NormalizedDirectoryPath(first);
  const std::wstring second_value = NormalizedDirectoryPath(second);
  return !first_value.empty() && !second_value.empty() &&
         _wcsicmp(first_value.c_str(), second_value.c_str()) == 0;
}

bool IsSameOrChildPath(const fs::path& root, const fs::path& candidate) {
  const std::wstring root_value = NormalizedDirectoryPath(root);
  const std::wstring candidate_value = NormalizedDirectoryPath(candidate);
  if (root_value.empty() || candidate_value.empty()) {
    return false;
  }
  if (_wcsicmp(candidate_value.c_str(), root_value.c_str()) == 0) {
    return true;
  }
  const std::wstring root_with_slash = root_value + L"\\";
  return candidate_value.size() > root_with_slash.size() &&
         _wcsnicmp(candidate_value.c_str(), root_with_slash.c_str(),
                   root_with_slash.size()) == 0;
}

std::vector<std::wstring> ProtectedInstallRootPaths() {
  std::vector<std::wstring> roots;
  for (const int folder : {CSIDL_PROGRAM_FILES, CSIDL_PROGRAM_FILESX86}) {
    wchar_t value[MAX_PATH] = {};
    if (SUCCEEDED(SHGetFolderPathW(nullptr, folder, nullptr,
                                   SHGFP_TYPE_CURRENT, value)) &&
        value[0] != L'\0') {
      roots.emplace_back(value);
    }
  }
  for (const wchar_t* variable_name :
       {L"ProgramFiles", L"ProgramFiles(x86)", L"ProgramW6432"}) {
    const std::wstring value = EnvironmentVariableValue(variable_name);
    if (!value.empty()) {
      roots.push_back(value);
    }
  }
  return roots;
}

void AddEnvironmentRoot(const wchar_t* name,
                        std::vector<std::wstring>* roots) {
  const std::wstring value = EnvironmentVariableValue(name);
  if (!value.empty()) {
    roots->push_back(value);
  }
}

std::wstring KnownFolderPath(REFKNOWNFOLDERID folder_id) {
  PWSTR value = nullptr;
  const HRESULT result =
      SHGetKnownFolderPath(folder_id, KF_FLAG_DEFAULT, nullptr, &value);
  if (FAILED(result) || value == nullptr) {
    if (value != nullptr) {
      CoTaskMemFree(value);
    }
    return L"";
  }
  const std::wstring path(value);
  CoTaskMemFree(value);
  return path;
}

void AddKnownFolderRoot(REFKNOWNFOLDERID folder_id,
                        std::vector<std::wstring>* roots) {
  const std::wstring value = KnownFolderPath(folder_id);
  if (!value.empty()) {
    roots->push_back(value);
  }
}

void AddProfilePolicyRoots(const std::wstring& profile,
                           bool include_users_container,
                           std::vector<std::wstring>* exact_roots) {
  if (profile.empty()) {
    return;
  }
  exact_roots->push_back(profile);
  if (include_users_container) {
    const fs::path users_root = fs::path(profile).parent_path();
    if (!users_root.empty()) {
      exact_roots->push_back(users_root.wstring());
    }
  }
  exact_roots->push_back((fs::path(profile) / L"bin").wstring());
  exact_roots->push_back(
      (fs::path(profile) / L".local" / L"bin").wstring());
  exact_roots->push_back((fs::path(profile) / L"Desktop").wstring());
  exact_roots->push_back((fs::path(profile) / L"Downloads").wstring());
}

std::wstring WindowsDirectoryPath() {
  std::vector<wchar_t> buffer(32768);
  const UINT length =
      GetWindowsDirectoryW(buffer.data(), static_cast<UINT>(buffer.size()));
  return length == 0 || length >= buffer.size()
             ? std::wstring()
             : std::wstring(buffer.data(), length);
}

std::wstring SystemDirectoryPath() {
  std::vector<wchar_t> buffer(32768);
  const UINT length =
      GetSystemDirectoryW(buffer.data(), static_cast<UINT>(buffer.size()));
  return length == 0 || length >= buffer.size()
             ? std::wstring()
             : std::wstring(buffer.data(), length);
}

std::wstring TemporaryDirectoryPath() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length =
      GetTempPathW(static_cast<DWORD>(buffer.size()), buffer.data());
  return length == 0 || length >= buffer.size()
             ? std::wstring()
             : std::wstring(buffer.data(), length);
}

struct UnsafeInstallRootPolicy {
  std::vector<std::wstring> exact_roots;
  std::vector<std::wstring> tree_roots;
  bool authoritative_roots_available = false;
};

UnsafeInstallRootPolicy UnsafeInstallRootPaths() {
  UnsafeInstallRootPolicy policy;
  for (const std::wstring& program_files : ProtectedInstallRootPaths()) {
    policy.exact_roots.push_back(program_files);
  }
  const std::wstring known_program_data = KnownFolderPath(FOLDERID_ProgramData);
  const std::wstring known_public = KnownFolderPath(FOLDERID_Public);
  const std::wstring known_profile = KnownFolderPath(FOLDERID_Profile);
  policy.authoritative_roots_available =
      !known_program_data.empty() && !known_public.empty() &&
      !known_profile.empty();
  if (!known_program_data.empty()) {
    policy.tree_roots.push_back(known_program_data);
  }
  if (!known_public.empty()) {
    policy.tree_roots.push_back(known_public);
  }
  AddEnvironmentRoot(L"ProgramData", &policy.tree_roots);
  AddEnvironmentRoot(L"ALLUSERSPROFILE", &policy.tree_roots);
  AddEnvironmentRoot(L"PUBLIC", &policy.tree_roots);

  AddProfilePolicyRoots(known_profile, true, &policy.exact_roots);
  AddKnownFolderRoot(FOLDERID_Desktop, &policy.exact_roots);
  AddKnownFolderRoot(FOLDERID_Downloads, &policy.exact_roots);
  const std::wstring user_profile = EnvironmentVariableValue(L"USERPROFILE");
  AddProfilePolicyRoots(user_profile, false, &policy.exact_roots);
  const std::wstring windows = WindowsDirectoryPath();
  if (!windows.empty()) {
    policy.tree_roots.push_back(windows);
  }
  const std::wstring system = SystemDirectoryPath();
  if (!system.empty()) {
    policy.tree_roots.push_back(system);
  }
  const std::wstring temporary = TemporaryDirectoryPath();
  if (!temporary.empty()) {
    policy.tree_roots.push_back(temporary);
  }
  AddEnvironmentRoot(L"TEMP", &policy.tree_roots);
  AddEnvironmentRoot(L"TMP", &policy.tree_roots);
  return policy;
}

bool ReadRegistryString(HKEY key,
                        const wchar_t* value_name,
                        std::wstring* value) {
  DWORD size = 0;
  if (RegGetValueW(key, nullptr, value_name, RRF_RT_REG_SZ, nullptr, nullptr,
                   &size) != ERROR_SUCCESS ||
      size < sizeof(wchar_t)) {
    return false;
  }
  std::vector<wchar_t> buffer(size / sizeof(wchar_t));
  if (RegGetValueW(key, nullptr, value_name, RRF_RT_REG_SZ, nullptr,
                   buffer.data(), &size) != ERROR_SUCCESS) {
    return false;
  }
  *value = buffer.data();
  return true;
}

bool HasMatchingUninstallRecord(const std::wstring& canonical_target,
                                const std::wstring& expected_package_id) {
  return helper::FindCanonicalWindowsUninstallRecordProof(
             fs::path(canonical_target), WideToUtf8(expected_package_id),
             GetCurrentProcess())
      .has_value();
}

bool HasMatchingInstallIdentityMarker(
    const fs::path& canonical_target,
    const std::wstring& expected_package_id) {
  const fs::path marker =
      canonical_target / L".desktop_updater_install_identity.json";
  HANDLE marker_handle = CreateFileW(
      marker.wstring().c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr);
  if (marker_handle == INVALID_HANDLE_VALUE) {
    return false;
  }

  BY_HANDLE_FILE_INFORMATION information = {};
  const bool metadata_ok =
      GetFileInformationByHandle(marker_handle, &information) != FALSE;
  const bool safe_file =
      metadata_ok &&
      (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
      (information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
  std::array<char, kMaximumInstalledIdentityMarkerBytes + 1> buffer = {};
  DWORD bytes_read = 0;
  const bool read_ok =
      safe_file &&
      ReadFile(marker_handle, buffer.data(), static_cast<DWORD>(buffer.size()),
               &bytes_read, nullptr) != FALSE;
  const bool close_ok = CloseHandle(marker_handle) != FALSE;
  if (!read_ok || !close_ok ||
      bytes_read > kMaximumInstalledIdentityMarkerBytes) {
    return false;
  }
  const std::string contents(buffer.data(), bytes_read);
  return InstalledIdentityMarkerMatchesJson(contents, expected_package_id);
}

bool IsCanonicalRelativeExecutable(const fs::path& path) {
  if (path.empty() || path.is_absolute() || path.has_root_name()) {
    return false;
  }
  if (path.lexically_normal().native() != path.native()) {
    return false;
  }
  for (const fs::path& part : path) {
    if (part.empty() || part == L"." || part == L"..") {
      return false;
    }
  }
  return true;
}

WindowsPathComponentState ValidatePathComponentsImpl(
    const fs::path& staging_path) {
  fs::path current = staging_path.root_path();
  WindowsPathComponentState state = ClassifyWindowsPathComponentAttributes(
      GetFileAttributesW(current.c_str()));
  if (state != WindowsPathComponentState::kSafe) {
    return state;
  }
  for (const fs::path& component : staging_path.relative_path()) {
    current /= component;
    state = ClassifyWindowsPathComponentAttributes(
        GetFileAttributesW(current.c_str()));
    if (state == WindowsPathComponentState::kUnavailable ||
        state == WindowsPathComponentState::kReparsePoint) {
      return state;
    }
  }
  return WindowsPathComponentState::kSafe;
}

InstallResult ValidateStagingRoot(const InstallRequest& request) {
  if (request.staging_path.empty()) {
    return {true, ""};
  }
  const fs::path staging_path(request.staging_path);
  if (!staging_path.is_absolute() ||
      _wcsicmp(staging_path.wstring().c_str(),
               staging_path.lexically_normal().wstring().c_str()) != 0) {
    return {false, "Staged update root must be absolute and canonical."};
  }
  const WindowsPathComponentState component_state =
      ValidatePathComponentsImpl(staging_path);
  if (component_state == WindowsPathComponentState::kUnavailable) {
    return {false,
            "Staged update path components must exist and be readable."};
  }
  if (component_state == WindowsPathComponentState::kReparsePoint) {
    return {false,
            "Staged update path components must not be reparse points."};
  }
  const DWORD stage_attributes =
      GetFileAttributesW(request.staging_path.c_str());
  if (stage_attributes == INVALID_FILE_ATTRIBUTES ||
      (stage_attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
    return {false, "Staged update directory does not exist."};
  }
  if ((stage_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return {false, "Staged update root must not be a reparse point."};
  }
  return {true, ""};
}

InstallResult ProveInstallTarget(const InstallRequest& request,
                                 const fs::path& running_executable,
                                 InstallTargetProof* proof) {
  if (request.install_root.empty() ||
      request.executable_relative_path.empty() ||
      request.expected_package_id.empty()) {
    return {false,
            "Windows install target context and package identity are "
            "required; use a fresh installer for legacy layouts."};
  }
  const fs::path relative(request.executable_relative_path);
  if (!IsCanonicalRelativeExecutable(relative)) {
    return {false, "Windows executable path must be canonical and relative."};
  }
  std::error_code error;
  const fs::path canonical_root = fs::canonical(request.install_root, error);
  if (error ||
      _wcsicmp(canonical_root.wstring().c_str(),
               request.install_root.c_str()) != 0) {
    return {false, "Windows install root must already be canonical."};
  }
  const UnsafeInstallRootPolicy unsafe_roots = UnsafeInstallRootPaths();
  if (!unsafe_roots.authoritative_roots_available) {
    return {false,
            "Windows authoritative shared/profile roots are unavailable."};
  }
  if (IsUnsafeWindowsInstallRoot(canonical_root.wstring(),
                                 unsafe_roots.exact_roots,
                                 unsafe_roots.tree_roots)) {
    return {false, "Windows install root is a protected shared/system root."};
  }
  const fs::path canonical_executable =
      fs::canonical(canonical_root / relative, error);
  if (error ||
      _wcsicmp(canonical_executable.wstring().c_str(),
               running_executable.wstring().c_str()) != 0) {
    return {false, "Windows install target does not match the running app."};
  }
  const bool protected_target = IsKnownProtectedInstallDirectory(
      canonical_root.wstring(), ProtectedInstallRootPaths());
  if (!protected_target &&
      !PathEquals(canonical_root, canonical_executable.parent_path())) {
    return {false,
            "Windows ZIP installed identity cannot authorize an ancestor of "
            "the running executable; use its exact parent as install root."};
  }
  if (!request.staging_path.empty()) {
    const fs::path canonical_stage = fs::canonical(request.staging_path, error);
    if (error || IsSameOrChildPath(canonical_root, canonical_stage) ||
        IsSameOrChildPath(canonical_stage, canonical_root)) {
      return {false, "Windows staging path must not overlap install target."};
    }
  }
  const bool identity_matches =
      protected_target
          ? HasMatchingUninstallRecord(canonical_root.wstring(),
                                       request.expected_package_id)
          : HasMatchingInstallIdentityMarker(canonical_root,
                                             request.expected_package_id);
  if (!identity_matches) {
    return {false,
            protected_target
                ? "Windows Program Files target requires a matching uninstall "
                  "record and package identity."
                : "Windows ZIP target requires a matching installed identity "
                  "marker; use a fresh installer."};
  }
  if (proof != nullptr) {
    *proof = {canonical_root.wstring(), relative.wstring(),
              request.expected_package_id,
              protected_target
                  ? InstallTargetProofSource::kRegistryUninstallRecord
                  : InstallTargetProofSource::kInstalledIdentityMarker};
  }
  return {true, ""};
}

}  // namespace

InstallLaunchDecision ResolveInstallLaunchDecision(
    InstallElevationPolicy policy,
    bool target_is_protected,
    bool target_is_writable,
    bool process_is_elevated) {
  if (process_is_elevated) {
    return target_is_writable ? InstallLaunchDecision::kNormal
                              : InstallLaunchDecision::kReject;
  }
  if (policy == InstallElevationPolicy::kAlways) {
    return InstallLaunchDecision::kElevated;
  }
  if (policy == InstallElevationPolicy::kNever) {
    return target_is_writable ? InstallLaunchDecision::kNormal
                              : InstallLaunchDecision::kReject;
  }
  return target_is_protected || !target_is_writable
             ? InstallLaunchDecision::kElevated
             : InstallLaunchDecision::kNormal;
}

namespace {

bool IsTransactionId(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-' || value[14] != '4' ||
      std::string("89ab").find(value[19]) == std::string::npos) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const char byte = value[index];
    if (!(byte >= '0' && byte <= '9') && !(byte >= 'a' && byte <= 'f')) {
      return false;
    }
  }
  return true;
}

struct WindowsHelperClientContext {
  fs::path helper_path;
  helper::WindowsHelperPolicy policy;
  helper::ProtectedWindowsHelperEndpointV1 endpoint;
  bool portable = false;
};

struct PreparedWindowsHelperRequest {
  WindowsHelperClientContext helper;
  std::string nonce;
  std::string canonical_request;
};

struct ActiveWindowsHelperSession {
  InstallReservation reservation;
  std::unique_ptr<helper::WindowsElevatedHelperClientSession> session;
};

std::mutex& ActiveWindowsHelperSessionsMutex() {
  static std::mutex mutex;
  return mutex;
}

std::map<std::string, ActiveWindowsHelperSession>&
ActiveWindowsHelperSessions() {
  static std::map<std::string, ActiveWindowsHelperSession> sessions;
  return sessions;
}

bool ReservationsMatch(const InstallReservation& first,
                       const InstallReservation& second) {
  return first.transaction_id == second.transaction_id &&
         first.ready_token == second.ready_token &&
         first.response_digest_sha256 == second.response_digest_sha256 &&
         first.helper_endpoint_identity_sha256 ==
             second.helper_endpoint_identity_sha256 &&
         first.expires_at_unix_milliseconds ==
             second.expires_at_unix_milliseconds;
}

WindowsHelperClientContext LoadWindowsHelperClientContext(
    const helper::ProtectedWindowsHelperEndpointV1& endpoint,
    const std::string& expected_package_id) {
  ValidateConfiguredWindowsHelperPath(endpoint);
  const fs::path helper_path = endpoint.helper_path;
  const helper::VerifiedWindowsExecutable helper_identity =
      helper::VerifyWindowsExecutable(helper_path);
  if (helper_identity.sha256 != endpoint.helper_sha256 ||
      _wcsicmp(helper_identity.final_path.lexically_normal().c_str(),
               endpoint.helper_path.lexically_normal().c_str()) != 0) {
    throw std::runtime_error(
        "Registered Windows helper endpoint identity does not match.");
  }
  const fs::path policy_path = endpoint.policy_path;
  const std::string policy_json = CanonicalJsonFile(
      policy_path, kMaximumHelperPolicyBytes, "Windows helper policy");
  if (Sha256Hex(policy_json) != endpoint.policy_sha256) {
    throw std::runtime_error(
        "Registered Windows helper policy digest does not match.");
  }
  const runtime::internal::JsonValue policy_value =
      runtime::internal::ParseJson(policy_json);
  const std::string application_package_id =
      policy_value.at("applicationPackageId").string();
  if (!expected_package_id.empty() &&
      application_package_id != expected_package_id) {
    throw std::runtime_error(
        "Windows helper policy package identity does not match the app.");
  }
  if (application_package_id != endpoint.package_id ||
      policy_value.at("policyId").string() != endpoint.policy_id ||
      policy_value.at("helperServiceId").string() !=
          endpoint.helper_service_id) {
    throw std::runtime_error(
        "Windows helper policy does not match the registered endpoint.");
  }
  helper::WindowsHelperPolicy policy = helper::WindowsHelperPolicy::Load(
      policy_json, endpoint.policy_sha256, application_package_id,
      endpoint.helper_sha256);
  helper::ValidateWindowsHelperIdentity(helper_identity, policy, true);
  if (!helper::VerifyWindowsExecutableStillMatches(helper_path,
                                                   helper_identity)) {
    throw std::runtime_error(
        "Windows helper identity changed after policy validation.");
  }
  return {helper_identity.final_path, std::move(policy), endpoint};
}

WindowsHelperClientContext LoadPortableWindowsHelperClientContext(
    const fs::path& running_executable,
    const std::string& expected_package_id) {
  const fs::path helper_path =
      running_executable.parent_path() / kWindowsHelperExecutableName;
  const fs::path policy_path =
      running_executable.parent_path() / kWindowsHelperPolicyName;
  const helper::VerifiedWindowsExecutable helper_identity =
      helper::VerifyWindowsExecutable(helper_path);
  if (!PathEquals(helper_identity.final_path.parent_path(),
                  running_executable.parent_path()) ||
      _wcsicmp(helper_identity.final_path.filename().c_str(),
               kWindowsHelperExecutableName) != 0) {
    throw std::runtime_error(
        "Portable Windows helper is not app-adjacent.");
  }
  const std::string policy_json = CanonicalJsonFile(
      policy_path, kMaximumHelperPolicyBytes, "Windows helper policy");
  const runtime::internal::JsonValue policy_value =
      runtime::internal::ParseJson(policy_json);
  const std::string application_package_id =
      policy_value.at("applicationPackageId").string();
  if (!expected_package_id.empty() &&
      application_package_id != expected_package_id) {
    throw std::runtime_error(
        "Portable Windows policy package identity does not match the app.");
  }
  helper::WindowsHelperPolicy policy = helper::WindowsHelperPolicy::Load(
      policy_json, Sha256Hex(policy_json), application_package_id,
      helper_identity.sha256);
  if (!policy.is_portable()) {
    throw std::runtime_error(
        "App-adjacent Windows policy requests elevation authority.");
  }
  helper::ValidateWindowsHelperIdentity(helper_identity, policy, false);
  const helper::VerifiedWindowsExecutable caller_identity =
      helper::VerifyWindowsExecutable(running_executable);
  if (!caller_identity.signature_valid ||
      policy.application_signer_kind() != "sha256" ||
      caller_identity.sha256 != policy.application_signer_identity() ||
      !helper::VerifyWindowsExecutableStillMatches(running_executable,
                                                   caller_identity) ||
      !helper::VerifyWindowsExecutableStillMatches(helper_path,
                                                   helper_identity)) {
    throw std::runtime_error(
        "Running app or portable helper identity does not match policy.");
  }
  return {helper_identity.final_path, std::move(policy), {}, true};
}

WindowsHelperClientContext LoadFrozenPortableWindowsTransactionClientContext(
    const fs::path& running_executable,
    const std::string& transaction_id,
    const helper::ResolvedWindowsPortableTransactionEndpointV1& endpoint) {
  const helper::VerifiedWindowsExecutable helper_identity =
      helper::VerifyWindowsExecutable(endpoint.helper_path);
  if (helper_identity.sha256 != endpoint.locator.helper_sha256 ||
      !PathEquals(helper_identity.final_path, endpoint.helper_path)) {
    throw std::runtime_error(
        "Frozen portable Windows helper identity does not match.");
  }
  const std::string policy_json = CanonicalJsonFile(
      endpoint.policy_path, kMaximumHelperPolicyBytes,
      "Frozen portable Windows helper policy");
  if (Sha256Hex(policy_json) != endpoint.locator.policy_sha256) {
    throw std::runtime_error(
        "Frozen portable Windows policy digest does not match.");
  }
  const runtime::internal::JsonValue policy_value =
      runtime::internal::ParseJson(policy_json);
  if (policy_value.at("policyId").string() != endpoint.locator.policy_id ||
      policy_value.at("applicationPackageId").string() !=
          endpoint.locator.package_id) {
    throw std::runtime_error(
        "Frozen portable Windows policy authority changed.");
  }
  helper::WindowsHelperPolicy policy = helper::WindowsHelperPolicy::Load(
      policy_json, endpoint.locator.policy_sha256,
      endpoint.locator.package_id, endpoint.locator.helper_sha256);
  if (!policy.is_portable() ||
      helper::WindowsPortableIndexBindingKey(policy) !=
          endpoint.locator.index_binding_sha256) {
    throw std::runtime_error(
        "Frozen portable Windows generation binding changed.");
  }
  helper::ValidateWindowsHelperIdentity(helper_identity, policy, false);
  if (!helper::VerifyWindowsExecutableStillMatches(endpoint.helper_path,
                                                   helper_identity)) {
    throw std::runtime_error(
        "Frozen portable Windows helper changed after validation.");
  }

  helper::WindowsPortableTransactionStore store(
      policy, GetCurrentProcess(), false);
  const auto record = store.ReadRecord(transaction_id);
  if (!record.has_value()) {
    throw std::runtime_error(
        "Frozen portable Windows transaction record is unavailable.");
  }
  const helper::VerifiedWindowsExecutable caller_identity =
      helper::VerifyWindowsExecutable(running_executable);
  if (helper::ResolveWindowsPortableTransactionAuthority(
          endpoint.locator, policy, transaction_id, *record, caller_identity,
          running_executable,
          helper::VerifyWindowsExecutableStillMatches(running_executable,
                                                       caller_identity)) ==
      helper::WindowsPortableTransactionResolution::kReject) {
    throw std::runtime_error(
        "Running app is not a frozen portable transaction generation.");
  }
  return {helper_identity.final_path, std::move(policy), {}, true};
}

bool AdjacentPolicyDeclaresPortable(const fs::path& running_executable) {
  const fs::path helper_path =
      running_executable.parent_path() / kWindowsHelperExecutableName;
  const fs::path policy_path =
      running_executable.parent_path() / kWindowsHelperPolicyName;
  const DWORD helper_attributes = GetFileAttributesW(helper_path.c_str());
  const DWORD policy_attributes = GetFileAttributesW(policy_path.c_str());
  const DWORD policy_error = policy_attributes == INVALID_FILE_ATTRIBUTES
                                 ? GetLastError()
                                 : ERROR_SUCCESS;
  const bool policy_missing = policy_attributes == INVALID_FILE_ATTRIBUTES &&
                              (policy_error == ERROR_FILE_NOT_FOUND ||
                               policy_error == ERROR_PATH_NOT_FOUND);
  // The helper executable is bundled for protected installer flows as well.
  // Without an adjacent portable policy there is no portable authority to
  // probe, so continue to the independently registered protected endpoint.
  if (policy_missing) return false;
  if (helper_attributes == INVALID_FILE_ATTRIBUTES ||
      policy_attributes == INVALID_FILE_ATTRIBUTES ||
      (helper_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
      (policy_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
      (helper_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      (policy_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    throw std::runtime_error(
        "Adjacent Windows helper/policy layout is incomplete or unsafe.");
  }
  const std::string canonical = CanonicalJsonFile(
      policy_path, kMaximumHelperPolicyBytes, "Windows helper policy");
  const runtime::internal::JsonValue value =
      runtime::internal::ParseJson(canonical);
  const auto& roots = value.at("allowedInstallRoots").array();
  const std::string application_kind =
      value.at("allowedApplicationSigner").at("kind").string();
  const std::string helper_kind =
      value.at("allowedHelperSigner").at("kind").string();
  return roots.empty() && application_kind == "sha256" &&
         helper_kind == "sha256";
}

WindowsHelperClientContext LoadWindowsRecoveryClientContext(
    const fs::path& running_executable,
    const std::string& transaction_id) {
  const auto endpoint =
      helper::LoadProtectedWindowsTransactionEndpoint(transaction_id);
  if (!endpoint.has_value()) {
    throw std::runtime_error(
        "Protected Windows transaction endpoint is unavailable.");
  }
  WindowsHelperClientContext context =
      LoadWindowsHelperClientContext(*endpoint, endpoint->package_id);
  const helper::VerifiedWindowsExecutable caller_identity =
      helper::VerifyWindowsExecutable(running_executable);
  if (!caller_identity.signature_valid ||
      WideToUtf8(caller_identity.publisher) !=
          context.policy.application_publisher() ||
      !helper::VerifyWindowsExecutableStillMatches(running_executable,
                                                   caller_identity)) {
    throw std::runtime_error(
        "Running app identity does not match the sealed helper policy.");
  }
  return context;
}

PreparedWindowsHelperRequest BuildWindowsHelperRequest(
    const InstallRequest& request,
    const fs::path& running_executable,
    const InstallTargetProof& target_proof,
    const std::string& requested_transaction_id,
    bool portable) {
  using runtime::internal::BuildWindowsNativeInstallTransactionRequestV1;
  using runtime::internal::EncodeCanonicalNativeInstallTransactionRequestV1;
  using runtime::internal::VerifyStageProvenance;
  using runtime::internal::WindowsNativeInstallEvidenceV1;

  const std::string package_id = WideToUtf8(request.expected_package_id);
  WindowsHelperClientContext context = [&]() {
    if (portable) {
      if (target_proof.source !=
          InstallTargetProofSource::kInstalledIdentityMarker) {
        throw std::runtime_error(
            "Portable helper requires an app-owned identity marker.");
      }
      return LoadPortableWindowsHelperClientContext(running_executable,
                                                    package_id);
    }
    const auto endpoint = helper::LoadProtectedWindowsHelperEndpoint(
        package_id, ConfiguredWindowsHelperPath());
    if (!endpoint.has_value()) {
      throw std::runtime_error(
          "Protected Windows helper endpoint is not registered.");
    }
    return LoadWindowsHelperClientContext(*endpoint, package_id);
  }();
  if (context.portable != portable) {
    throw std::runtime_error("Windows helper execution mode changed.");
  }

  const fs::path target_path(target_proof.canonical_root);
  std::string installed_identity;
  if (target_proof.source ==
      InstallTargetProofSource::kInstalledIdentityMarker) {
    installed_identity = CanonicalJsonFile(
        target_path / kInstalledIdentityMarkerName,
        kMaximumInstalledIdentityMarkerBytes, "Installed identity marker");
    if (!InstalledIdentityMarkerMatchesJson(installed_identity,
                                            request.expected_package_id)) {
      throw std::runtime_error(
          "Installed identity marker does not match the package.");
    }
  } else {
    const auto registry_proof =
        helper::FindCanonicalWindowsUninstallRecordProof(target_path,
                                                          package_id,
                                                          GetCurrentProcess());
    if (!registry_proof.has_value()) {
      throw std::runtime_error(
          "Installed uninstall record identity proof is unavailable.");
    }
    installed_identity = *registry_proof;
  }
  const std::string installed_identity_sha256 = Sha256Hex(installed_identity);

  const fs::path stage_path(request.staging_path);
  const std::string expected_provenance_sha256 =
      WideToUtf8(request.expected_provenance_sha256);
  const runtime::internal::StageProvenanceMarker marker =
      VerifyStageProvenance(stage_path, expected_provenance_sha256,
                            runtime::internal::BCryptSha256);
  const std::string release_manifest = CanonicalJsonFile(
      stage_path / kStagedReleaseManifestName, kMaximumHelperMetadataBytes,
      "Staged release manifest", true);

  const helper::VerifiedWindowsExecutable caller_identity =
      helper::VerifyWindowsExecutable(running_executable);
  const bool caller_policy_matches =
      portable
          ? context.policy.application_signer_kind() == "sha256" &&
                caller_identity.sha256 ==
                    context.policy.application_signer_identity()
          : WideToUtf8(caller_identity.publisher) ==
                context.policy.application_publisher();
  if (!caller_identity.signature_valid || !caller_policy_matches ||
      !helper::VerifyWindowsExecutableStillMatches(running_executable,
                                                   caller_identity)) {
    throw std::runtime_error(
        "Running app identity does not match the sealed helper policy.");
  }

  const std::string transaction_id = requested_transaction_id.empty()
                                         ? NewTransactionId()
                                         : requested_transaction_id;
  if (!IsTransactionId(transaction_id)) {
    throw std::runtime_error("Generated install transaction ID is invalid.");
  }
  const std::string nonce = SecureRequestNonce();
  WindowsNativeInstallEvidenceV1 evidence;
  evidence.transaction_id = transaction_id;
  evidence.policy_id = context.policy.policy_id();
  evidence.package_id = package_id;
  evidence.target_path_hint = RequestPath(target_path);
  evidence.target_name_hint = RequestPath(target_path.filename());
  evidence.executable_relative_path =
      RequestPath(fs::path(target_proof.executable_relative_path));
  evidence.target_identity_proof_sha256 = installed_identity_sha256;
  evidence.current_version = "unknown";
  evidence.current_build_number = 0;
  evidence.current_package_identity_sha256 = installed_identity_sha256;
  evidence.stage_path_hint = RequestPath(stage_path);
  evidence.expected_provenance_sha256 = expected_provenance_sha256;
  evidence.expected_artifact_sha256 =
      WideToUtf8(request.expected_artifact_sha256);
  evidence.caller_process_id =
      static_cast<std::int64_t>(GetCurrentProcessId());
  evidence.caller_process_start_identity =
      helper::WindowsProcessStartIdentityString(
          CurrentProcessStartIdentity());
  evidence.caller_executable_sha256 = caller_identity.sha256;
  evidence.caller_signer_identity =
      WideToUtf8(caller_identity.publisher);
  evidence.request_nonce = nonce;
  runtime::internal::NativeInstallTransactionRequestV1 native_request =
      BuildWindowsNativeInstallTransactionRequestV1(
          release_manifest, marker, evidence, Sha256Hex);
  if (portable) {
    native_request.target.target_class = "sameUserWritable";
  }
  if (!context.policy.AllowsRequest(
          native_request.protocol_version, native_request.target.target_class,
          native_request.strategy, native_request.provider)) {
    throw std::runtime_error(
        "Windows helper policy rejects the requested target strategy.");
  }
  return {std::move(context), nonce,
          EncodeCanonicalNativeInstallTransactionRequestV1(native_request)};
}

InstallReservation PublicReservation(
    const runtime::internal::NativeInstallReservationV1& reservation) {
  return {reservation.transaction_id,
          reservation.ready_token,
          reservation.journal_sha256,
          reservation.helper_endpoint_identity_sha256,
          reservation.expires_at_unix_milliseconds};
}

std::string ElevationLaunchError(helper::ElevationLaunchResult result) {
  switch (result) {
    case helper::ElevationLaunchResult::kCancelled:
      return "Windows helper elevation was cancelled.";
    case helper::ElevationLaunchResult::kTimedOut:
      return "Windows helper startup timed out.";
    case helper::ElevationLaunchResult::kFailed:
      return "Windows helper elevation failed.";
    case helper::ElevationLaunchResult::kLaunched:
      return "Windows helper returned no authenticated session.";
  }
  return "Windows helper launch failed.";
}

InstallTransactionStatus EndpointUnavailableStatus(
    const std::string& transaction_id) {
  return {transaction_id, InstallTransactionState::kUnknown,
          InstallTransactionResultCode::kEndpointUnavailable,
          "Packaged Windows install helper endpoint is unavailable.", "",
          ""};
}

InstallTransactionState WindowsStateFromWire(const std::string& state) {
  if (state == "prepared" || state == "backupCreated" ||
      state == "targetActivated") {
    return InstallTransactionState::kPrepared;
  }
  if (state == "completed") return InstallTransactionState::kCompleted;
  if (state == "rolledBack") return InstallTransactionState::kRolledBack;
  if (state == "manualActionRequired") {
    return InstallTransactionState::kManualActionRequired;
  }
  return InstallTransactionState::kUnknown;
}

InstallTransactionResultCode WindowsResultFromWire(
    const std::string& result_code) {
  if (result_code == "completed" || result_code == "rolledBack") {
    return InstallTransactionResultCode::kSucceeded;
  }
  if (result_code == "recoveryRequired" ||
      result_code == "manualActionRequired" ||
      result_code == "journalCorrupt") {
    return InstallTransactionResultCode::kRecoveryRequired;
  }
  if (result_code == "relaunchFailure") {
    return InstallTransactionResultCode::kRelaunchFailure;
  }
  return InstallTransactionResultCode::kRejected;
}

InstallTransactionStatus RunWindowsPersistentOperation(
    const std::string& transaction_id,
    const std::string& operation) {
  try {
    const std::wstring executable_path = CurrentExecutablePath();
    if (executable_path.empty()) {
      return EndpointUnavailableStatus(transaction_id);
    }
    std::error_code canonical_error;
    const fs::path executable =
        fs::canonical(executable_path, canonical_error);
    if (canonical_error) {
      return EndpointUnavailableStatus(transaction_id);
    }
    std::optional<WindowsHelperClientContext> portable_context;
    helper::WindowsPortableTransactionProbe portable_probe =
        helper::WindowsPortableTransactionProbe::kAbsent;
    try {
      const auto frozen_endpoint =
          helper::LoadWindowsPortableTransactionEndpoint(transaction_id);
      if (frozen_endpoint.has_value()) {
        portable_context.emplace(
            LoadFrozenPortableWindowsTransactionClientContext(
                executable, transaction_id, *frozen_endpoint));
        portable_probe = helper::WindowsPortableTransactionProbe::kPresent;
      } else if (AdjacentPolicyDeclaresPortable(executable)) {
        // Compatibility for transactions created before the durable neutral
        // locator existed. New transactions always bind the frozen endpoint.
        portable_context.emplace(
            LoadPortableWindowsHelperClientContext(executable, ""));
        portable_probe = helper::ProbeWindowsPortableTransaction(
            portable_context->policy, transaction_id);
      }
    } catch (const std::exception&) {
      portable_context.reset();
      portable_probe =
          helper::WindowsPortableTransactionProbe::kBindingMismatch;
    }
    const auto protected_endpoint =
        helper::LoadProtectedWindowsTransactionEndpoint(transaction_id);
    const helper::WindowsTransactionLookupDecision lookup =
        helper::DecideWindowsTransactionLookup(
            portable_probe, protected_endpoint.has_value());
    if (lookup == helper::WindowsTransactionLookupDecision::kBindingMismatch) {
      throw std::runtime_error(
          "Portable and protected transaction authority conflicts.");
    }
    if (lookup == helper::WindowsTransactionLookupDecision::kUnavailable) {
      return EndpointUnavailableStatus(transaction_id);
    }
    WindowsHelperClientContext context =
        lookup == helper::WindowsTransactionLookupDecision::kPortable
            ? std::move(*portable_context)
            : LoadWindowsRecoveryClientContext(executable, transaction_id);
    const std::string nonce = SecureRequestNonce();
    const helper::WindowsPersistentRecoveryRequestV1 request{
        operation,
        1,
        context.policy.policy_id(),
        context.policy.application_package_id(),
        transaction_id,
        nonce,
    };
    const helper::WindowsElevatedRecoveryResponse response =
        context.portable
            ? helper::LaunchAuthenticatedPortableRecoveryRequest(
                  context.helper_path, context.policy, request,
                  kWindowsHelperStartupTimeoutMilliseconds)
            : helper::LaunchAuthenticatedElevatedRecoveryRequest(
                  context.helper_path, context.policy, request,
                  kWindowsHelperStartupTimeoutMilliseconds);
    if (response.result != helper::ElevationLaunchResult::kLaunched) {
      const bool cancelled =
          response.result == helper::ElevationLaunchResult::kCancelled;
      return {transaction_id,
              InstallTransactionState::kUnknown,
              cancelled ? InstallTransactionResultCode::kRejected
                        : InstallTransactionResultCode::kEndpointUnavailable,
              ElevationLaunchError(response.result), "", ""};
    }
    if (!response.is_recovery) {
      return {transaction_id,
              WindowsStateFromWire(response.status.state),
              WindowsResultFromWire(response.status.result_code),
              "Windows helper returned authoritative transaction status.",
              response.status.journal_sha256,
              response.helper_endpoint_identity_sha256};
    }
    InstallTransactionState state = InstallTransactionState::kUnknown;
    if (response.recovery.result_code == "completed") {
      state = InstallTransactionState::kCompleted;
    } else if (response.recovery.result_code == "rolledBack") {
      state = InstallTransactionState::kRolledBack;
    } else if (response.recovery.result_code == "manualActionRequired") {
      state = InstallTransactionState::kManualActionRequired;
    }
    return {transaction_id,
            state,
            WindowsResultFromWire(response.recovery.result_code),
            "Windows helper returned authoritative recovery status.",
            response.recovery.journal_sha256,
            response.helper_endpoint_identity_sha256};
  } catch (const std::exception&) {
    return {transaction_id,
            InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kAuthenticationFailed,
            "Windows helper recovery endpoint authentication failed.", "",
            ""};
  }
}

}  // namespace

InstallResult RestartCurrentApplication() {
  try {
    const std::wstring executable_path = CurrentExecutablePath();
    if (executable_path.empty()) {
      return {false, "Running Windows executable identity is unavailable."};
    }
    // Keep the loaded image's backing file closed against write/delete from
    // identity discovery through CreateProcessW. Windows also retains an
    // image section for the running executable; this explicit handle closes
    // the canonicalize-then-reopen race in the restart implementation.
    ScopedWindowsHandle executable_lock(CreateFileW(
        executable_path.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
        nullptr));
    BY_HANDLE_FILE_INFORMATION executable_information{};
    if (!executable_lock.valid() ||
        !GetFileInformationByHandle(executable_lock.get(),
                                    &executable_information) ||
        (executable_information.dwFileAttributes &
         (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
      return {false, "Running Windows executable identity is unavailable."};
    }
    const fs::path executable(FinalPathForHandle(executable_lock.get()));
    if (executable.empty() || !executable.is_absolute()) {
      return {false, "Running Windows executable identity is unavailable."};
    }

    HANDLE inherited_parent = nullptr;
    if (!DuplicateHandle(
            GetCurrentProcess(), GetCurrentProcess(), GetCurrentProcess(),
            &inherited_parent,
            SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, TRUE, 0)) {
      return {false, "Windows restart lifetime barrier failed."};
    }
    ScopedWindowsHandle parent_handle(inherited_parent);

    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;
    ScopedWindowsHandle ready_event(
        CreateEventW(&attributes, TRUE, FALSE, nullptr));
    if (!ready_event.valid()) {
      return {false, "Windows restart readiness proof failed."};
    }

    SIZE_T attribute_bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
    if (attribute_bytes == 0) {
      return {false, "Windows restart handle isolation failed."};
    }
    std::vector<unsigned char> attribute_storage(attribute_bytes);
    auto* attribute_list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
        attribute_storage.data());
    if (!InitializeProcThreadAttributeList(attribute_list, 1, 0,
                                           &attribute_bytes)) {
      return {false, "Windows restart handle isolation failed."};
    }
    struct AttributeListDestroyer {
      LPPROC_THREAD_ATTRIBUTE_LIST value;
      ~AttributeListDestroyer() { DeleteProcThreadAttributeList(value); }
    } attribute_owner{attribute_list};
    HANDLE inherited_handles[] = {parent_handle.get(), ready_event.get()};
    if (!UpdateProcThreadAttribute(
            attribute_list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            inherited_handles, sizeof(inherited_handles), nullptr, nullptr)) {
      return {false, "Windows restart handle isolation failed."};
    }

    std::vector<wchar_t> environment =
        RestartChildEnvironment(parent_handle.get(), ready_event.get());
    std::wstring command_line = L"\"" + executable.wstring() + L"\"";
    std::vector<wchar_t> mutable_command(command_line.begin(),
                                         command_line.end());
    mutable_command.push_back(L'\0');
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.lpAttributeList = attribute_list;
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(
            executable.c_str(), mutable_command.data(), nullptr, nullptr, TRUE,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            environment.data(), executable.parent_path().c_str(),
            &startup.StartupInfo, &process)) {
      return {false, "Windows restart process creation failed."};
    }
    ScopedWindowsHandle child_process(process.hProcess);
    ScopedWindowsHandle child_thread(process.hThread);

    if (!SetHandleInformation(parent_handle.get(), HANDLE_FLAG_INHERIT, 0) ||
        !SetHandleInformation(ready_event.get(), HANDLE_FLAG_INHERIT, 0)) {
      TerminateProcess(child_process.get(), ERROR_INVALID_HANDLE);
      WaitForSingleObject(child_process.get(), INFINITE);
      return {false, "Windows restart handle isolation failed."};
    }

    HANDLE readiness_handles[] = {ready_event.get(), child_process.get()};
    const DWORD readiness = WaitForMultipleObjects(
        2, readiness_handles, FALSE, kRestartReadinessTimeoutMilliseconds);
    if (readiness != WAIT_OBJECT_0 ||
        WaitForSingleObject(child_process.get(), 0) == WAIT_OBJECT_0) {
      TerminateProcess(child_process.get(), ERROR_TIMEOUT);
      WaitForSingleObject(child_process.get(), INFINITE);
      if (readiness == WAIT_TIMEOUT) {
        return {false, "Windows restart readiness timed out."};
      }
      return {false, "Windows restart readiness proof failed."};
    }
    return {true, ""};
  } catch (const std::exception& error) {
    return {false, std::string("Unable to schedule Windows restart: ") +
                       error.what()};
  }
}

bool AwaitRestartParentExitIfRequested() {
  const bool parent_present =
      EnvironmentVariableIsPresent(kRestartParentHandleEnvironment);
  const bool ready_present =
      EnvironmentVariableIsPresent(kRestartReadyHandleEnvironment);
  const std::wstring parent_value =
      EnvironmentVariableValue(kRestartParentHandleEnvironment);
  const std::wstring ready_value =
      EnvironmentVariableValue(kRestartReadyHandleEnvironment);
  if (!parent_present && !ready_present) return true;
  const bool parent_cleared =
      SetEnvironmentVariableW(kRestartParentHandleEnvironment, nullptr) !=
      FALSE;
  const bool ready_cleared =
      SetEnvironmentVariableW(kRestartReadyHandleEnvironment, nullptr) !=
      FALSE;
  if (!parent_cleared || !ready_cleared) return false;

  HANDLE raw_parent = nullptr;
  HANDLE raw_ready = nullptr;
  if (!StrictInheritedHandle(parent_value, &raw_parent) ||
      !StrictInheritedHandle(ready_value, &raw_ready) ||
      raw_parent == raw_ready || GetProcessId(raw_parent) == 0) {
    return false;
  }
  ScopedWindowsHandle parent_handle(raw_parent);
  ScopedWindowsHandle ready_event(raw_ready);
  if (!SetEvent(ready_event.get())) return false;
  ready_event.reset();
  return WaitForSingleObject(parent_handle.get(), INFINITE) == WAIT_OBJECT_0;
}

InstallResult PrepareInstallWithTransactionId(
    const InstallRequest& request,
    const std::string& transaction_id,
    InstallReservation* reservation,
    bool* recovery_required) {
  if (reservation == nullptr || recovery_required == nullptr) {
    return {false, "Install reservation output must not be null."};
  }
  *reservation = {};
  *recovery_required = false;
  const InstallResult staging = ValidateStagingRoot(request);
  if (!staging.ok) {
    return staging;
  }
  if (request.staging_path.empty()) {
    return {false, "Staged update root is required."};
  }
  const std::wstring executable_path = CurrentExecutablePath();
  if (executable_path.empty()) {
    return {false, "Unable to resolve executable path."};
  }
  std::error_code canonical_error;
  const fs::path executable =
      fs::canonical(executable_path, canonical_error);
  if (canonical_error) {
    return {false, "Unable to canonicalize executable path."};
  }
  InstallTargetProof target_proof;
  const InstallResult target =
      ProveInstallTarget(request, executable, &target_proof);
  if (!target.ok) {
    return target;
  }
  const bool protected_target =
      target_proof.source ==
      InstallTargetProofSource::kRegistryUninstallRecord;
  if (protected_target &&
      request.elevation_policy == InstallElevationPolicy::kNever) {
    return {false,
            "Windows protected install target requires the registered "
            "elevated helper endpoint."};
  }
  const bool portable =
      !protected_target &&
      request.elevation_policy != InstallElevationPolicy::kAlways;
  std::optional<PreparedWindowsHelperRequest> prepared;
  try {
    prepared.emplace(
        BuildWindowsHelperRequest(request, executable, target_proof,
                                  transaction_id, portable));
  } catch (const std::exception& error) {
    return {false, std::string("Windows helper preparation failed: ") +
                       error.what()};
  }
  try {
    helper::WindowsElevatedHelperLaunch launch =
        portable
            ? helper::LaunchAuthenticatedPortableHelper(
                  prepared->helper.helper_path, prepared->helper.policy,
                  prepared->nonce, prepared->canonical_request,
                  kWindowsHelperStartupTimeoutMilliseconds)
            : helper::LaunchAuthenticatedElevatedHelper(
                  prepared->helper.helper_path, prepared->helper.policy,
                  prepared->nonce, prepared->canonical_request,
                  kWindowsHelperStartupTimeoutMilliseconds);
    if (launch.result != helper::ElevationLaunchResult::kLaunched ||
        launch.session == nullptr) {
      const bool ambiguous_handoff =
          launch.result == helper::ElevationLaunchResult::kTimedOut ||
          launch.result == helper::ElevationLaunchResult::kLaunched;
      *recovery_required = ambiguous_handoff;
      return {false,
              portable && launch.result ==
                              helper::ElevationLaunchResult::kFailed
                  ? "Windows portable helper launch failed."
                  : ElevationLaunchError(launch.result)};
    }
    const InstallReservation public_reservation =
        PublicReservation(launch.session->reservation());
    if (!IsTransactionId(public_reservation.transaction_id) ||
        public_reservation.ready_token.empty() ||
        public_reservation.response_digest_sha256.size() != 64 ||
        public_reservation.helper_endpoint_identity_sha256.size() != 64) {
      *recovery_required = true;
      return {false, "Windows helper returned an invalid reservation."};
    }
    {
      std::lock_guard<std::mutex> lock(ActiveWindowsHelperSessionsMutex());
      const bool inserted =
          ActiveWindowsHelperSessions()
              .emplace(public_reservation.transaction_id,
                       ActiveWindowsHelperSession{
                           public_reservation, std::move(launch.session)})
              .second;
      if (!inserted) {
        *recovery_required = true;
        return {false,
                "Windows helper returned a duplicate transaction ID."};
      }
    }
    *reservation = public_reservation;
    return {true, ""};
  } catch (const std::exception& error) {
    *recovery_required = true;
    return {false, std::string("Windows helper preparation failed: ") +
                       error.what()};
  }
}

InstallResult PrepareInstall(const InstallRequest& request,
                             InstallReservation* reservation) {
  bool ignored_recovery_required = false;
  return PrepareInstallWithTransactionId(
      request, "", reservation, &ignored_recovery_required);
}

InstallTransactionStatus CommitAfterExit(
    const InstallReservation& reservation) {
  if (!IsTransactionId(reservation.transaction_id) ||
      reservation.ready_token.empty()) {
    return {reservation.transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kInvalidResponse,
            "Install reservation is invalid.", "", ""};
  }
  std::unique_ptr<helper::WindowsElevatedHelperClientSession> session;
  {
    std::lock_guard<std::mutex> lock(ActiveWindowsHelperSessionsMutex());
    auto active =
        ActiveWindowsHelperSessions().find(reservation.transaction_id);
    if (active == ActiveWindowsHelperSessions().end()) {
      return EndpointUnavailableStatus(reservation.transaction_id);
    }
    if (!ReservationsMatch(active->second.reservation, reservation)) {
      return {reservation.transaction_id,
              InstallTransactionState::kUnknown,
              InstallTransactionResultCode::kInvalidResponse,
              "Install reservation binding changed.", "", ""};
    }
    session = std::move(active->second.session);
    ActiveWindowsHelperSessions().erase(active);
  }
  try {
    const runtime::internal::NativeInstallReservationV1 acknowledged =
        session->CommitAfterExit();
    if (!ReservationsMatch(reservation, PublicReservation(acknowledged))) {
      return {reservation.transaction_id,
              InstallTransactionState::kUnknown,
              InstallTransactionResultCode::kInvalidResponse,
              "Windows helper commit acknowledgement changed.", "", ""};
    }
    return {reservation.transaction_id,
            InstallTransactionState::kCommitAccepted,
            InstallTransactionResultCode::kAccepted,
            "Windows helper accepted commit after caller exit.",
            reservation.response_digest_sha256,
            reservation.helper_endpoint_identity_sha256};
  } catch (const std::exception& error) {
    return {reservation.transaction_id,
            InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRecoveryRequired,
            std::string("Windows helper commit requires recovery: ") +
                error.what(),
            reservation.response_digest_sha256,
            reservation.helper_endpoint_identity_sha256};
  }
}

InstallTransactionStatus CancelReservation(
    const InstallReservation& reservation) {
  if (!IsTransactionId(reservation.transaction_id) ||
      reservation.ready_token.empty()) {
    return {reservation.transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kInvalidResponse,
            "Install reservation is invalid.", "", ""};
  }
  std::unique_ptr<helper::WindowsElevatedHelperClientSession> session;
  {
    std::lock_guard<std::mutex> lock(ActiveWindowsHelperSessionsMutex());
    auto active =
        ActiveWindowsHelperSessions().find(reservation.transaction_id);
    if (active == ActiveWindowsHelperSessions().end()) {
      return EndpointUnavailableStatus(reservation.transaction_id);
    }
    if (!ReservationsMatch(active->second.reservation, reservation)) {
      return {reservation.transaction_id,
              InstallTransactionState::kUnknown,
              InstallTransactionResultCode::kInvalidResponse,
              "Install reservation binding changed.", "", ""};
    }
    session = std::move(active->second.session);
    ActiveWindowsHelperSessions().erase(active);
  }
  try {
    const runtime::internal::NativeInstallRecoveryResultV1 cancelled =
        session->CancelReservation();
    if (cancelled.transaction_id != reservation.transaction_id ||
        cancelled.journal_sha256 !=
            reservation.response_digest_sha256 ||
        cancelled.result_code != "rolledBack" ||
        cancelled.verified_outcome != "oldTarget") {
      return {reservation.transaction_id,
              InstallTransactionState::kUnknown,
              InstallTransactionResultCode::kInvalidResponse,
              "Windows helper cancellation acknowledgement changed.", "",
              ""};
    }
    return {reservation.transaction_id,
            InstallTransactionState::kCancelled,
            InstallTransactionResultCode::kSucceeded,
            "Windows helper cancelled the prepared transaction.",
            reservation.response_digest_sha256,
            reservation.helper_endpoint_identity_sha256};
  } catch (const std::exception& error) {
    return {reservation.transaction_id,
            InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRecoveryRequired,
            std::string("Windows helper cancellation requires recovery: ") +
                error.what(),
            reservation.response_digest_sha256,
            reservation.helper_endpoint_identity_sha256};
  }
}

InstallTransactionStatus QueryTransaction(
    const std::string& transaction_id) {
  if (!IsTransactionId(transaction_id)) {
    return {transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRejected,
            "Transaction ID is invalid.", "", ""};
  }
  return RunWindowsPersistentOperation(transaction_id, "queryTransaction");
}

InstallTransactionStatus RecoverPendingInstall(
    const std::string& transaction_id) {
  if (!IsTransactionId(transaction_id)) {
    return {transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRejected,
            "Transaction ID is invalid.", "", ""};
  }
  return RunWindowsPersistentOperation(transaction_id,
                                       "recoverPendingInstall");
}

InstallTransactionStatus ResolvePendingInstallAfterExit(
    const std::string& transaction_id) {
  if (!IsTransactionId(transaction_id)) {
    return {transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRejected,
            "Transaction ID is invalid.", "", ""};
  }
  return RunWindowsPersistentOperation(
      transaction_id, "resolvePendingInstallAfterExit");
}

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request) {
  InstallReservation reservation;
  const InstallResult prepare = PrepareInstall(request, &reservation);
  if (!prepare.ok) return prepare;
  if (!IsTransactionId(reservation.transaction_id) ||
      reservation.ready_token.empty() ||
      reservation.response_digest_sha256.size() != 64 ||
      reservation.helper_endpoint_identity_sha256.size() != 64) {
    return {false, "Install helper returned an invalid reservation."};
  }
  const InstallTransactionStatus status = CommitAfterExit(reservation);
  const bool accepted =
      (status.state == InstallTransactionState::kCommitAccepted ||
       status.state == InstallTransactionState::kCompleted) &&
      (status.result_code == InstallTransactionResultCode::kAccepted ||
       status.result_code == InstallTransactionResultCode::kSucceeded) &&
      status.response_digest_sha256 == reservation.response_digest_sha256 &&
      status.helper_endpoint_identity_sha256 ==
          reservation.helper_endpoint_identity_sha256;
  return accepted
             ? InstallResult{true, ""}
             : InstallResult{false,
                             status.detail.empty()
                                 ? "Install helper commit was not accepted."
                                 : status.detail};
}

bool IsStrictChildPath(const std::wstring& root,
                       const std::wstring& candidate) {
  const std::wstring root_value = NormalizedDirectoryPath(fs::path(root));
  const std::wstring candidate_value =
      NormalizedDirectoryPath(fs::path(candidate));
  const std::wstring root_with_slash = root_value + L"\\";
  return candidate_value.size() > root_with_slash.size() &&
         _wcsnicmp(candidate_value.c_str(), root_with_slash.c_str(),
                   root_with_slash.size()) == 0;
}

bool RegistryRecordMatchesInstallTarget(
    const std::wstring& install_location,
    const std::wstring& package_id,
    const std::wstring& canonical_target,
    const std::wstring& expected_package_id) {
  if (install_location.empty() || package_id.empty() ||
      expected_package_id.empty()) {
    return false;
  }
  return _wcsicmp(
             NormalizedDirectoryPath(fs::path(install_location)).c_str(),
             NormalizedDirectoryPath(fs::path(canonical_target)).c_str()) ==
             0 &&
         package_id == expected_package_id;
}

bool IsUnsafeWindowsInstallRoot(
    const std::wstring& canonical_root,
    const std::vector<std::wstring>& exact_roots,
    const std::vector<std::wstring>& tree_roots) {
  const fs::path candidate(canonical_root);
  if (canonical_root.empty() ||
      PathEquals(candidate, candidate.root_path())) {
    return true;
  }
  for (const std::wstring& root : exact_roots) {
    if (!root.empty() && PathEquals(candidate, fs::path(root))) {
      return true;
    }
  }
  for (const std::wstring& root : tree_roots) {
    if (!root.empty() && IsSameOrChildPath(fs::path(root), candidate)) {
      return true;
    }
  }
  return false;
}

WindowsPathComponentState ClassifyWindowsPathComponentAttributes(
    std::uint32_t attributes) {
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    return WindowsPathComponentState::kUnavailable;
  }
  if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return WindowsPathComponentState::kReparsePoint;
  }
  return WindowsPathComponentState::kSafe;
}

bool InstalledIdentityMarkerMatchesJson(
    const std::string& contents,
    const std::wstring& expected_package_id) {
  if (contents.size() > kMaximumInstalledIdentityMarkerBytes ||
      expected_package_id.empty()) {
    return false;
  }
  try {
    const runtime::internal::JsonValue identity =
        runtime::internal::ParseJson(contents);
    if (identity.type() != runtime::internal::JsonValue::Type::kObject ||
        identity.object().size() != 2 ||
        identity.at("schemaVersion").integer() != 1) {
      return false;
    }
    const std::wstring& wide = expected_package_id;
    if (wide.size() > static_cast<std::size_t>(INT_MAX)) {
      return false;
    }
    const int utf8_size = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
        static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    if (utf8_size <= 0) {
      return false;
    }
    std::string expected_utf8(static_cast<std::size_t>(utf8_size), '\0');
    if (WideCharToMultiByte(
            CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
            static_cast<int>(wide.size()), &expected_utf8[0], utf8_size,
            nullptr, nullptr) != utf8_size) {
      return false;
    }
    return identity.at("packageId").string() == expected_utf8;
  } catch (const std::exception&) {
    return false;
  }
}

bool IsKnownProtectedInstallDirectory(
    const std::wstring& directory,
    const std::vector<std::wstring>& protected_roots) {
  for (const std::wstring& root : protected_roots) {
    if (IsSameOrChildPath(fs::path(root), fs::path(directory))) {
      return true;
    }
  }
  return false;
}

bool IsInstallerOwnedWindowsFile(const std::wstring& file_name) {
  const std::wstring name = fs::path(file_name).filename().wstring();
  if (name.empty()) {
    return false;
  }
  const size_t dot_position = name.rfind(L'.');
  if (dot_position == std::wstring::npos) {
    return false;
  }
  const std::wstring stem = name.substr(0, dot_position);
  const std::wstring extension = name.substr(dot_position);
  if (stem.size() != 8 || _wcsnicmp(stem.c_str(), L"unins", 5) != 0) {
    return false;
  }
  for (size_t index = 5; index < stem.size(); ++index) {
    if (stem[index] < L'0' || stem[index] > L'9') {
      return false;
    }
  }
  return _wcsicmp(extension.c_str(), L".exe") == 0 ||
         _wcsicmp(extension.c_str(), L".dat") == 0 ||
         _wcsicmp(extension.c_str(), L".msg") == 0;
}

}  // namespace native
}  // namespace desktop_updater
