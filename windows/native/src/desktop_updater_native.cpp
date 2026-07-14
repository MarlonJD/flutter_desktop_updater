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
#include <filesystem>
#include <iomanip>
#include <map>
#include <memory>
#include <mutex>
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
                              const char* description) {
  const std::string contents =
      ReadBoundedRegularFileNoReparse(path, maximum_bytes);
  const runtime::internal::JsonValue value =
      runtime::internal::ParseJson(contents);
  if (runtime::internal::EncodeCanonicalJson(value) != contents) {
    throw std::runtime_error(std::string(description) +
                             " must be canonical JSON.");
  }
  return contents;
}

fs::path FixedWindowsHelperPath(const fs::path& running_executable) {
  const std::string configured =
      DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR;
  if (!configured.empty()) {
    return fs::u8path(configured) / kWindowsHelperExecutableName;
  }
  return running_executable.parent_path() / kWindowsHelperExecutableName;
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

std::wstring NormalizedDirectoryPath(const fs::path& path) {
  std::wstring value = path.lexically_normal().wstring();
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
  constexpr const wchar_t* kUninstallPath =
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall";
  const REGSAM views[] = {KEY_WOW64_64KEY, KEY_WOW64_32KEY};
  for (const REGSAM view : views) {
    HKEY uninstall = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kUninstallPath, 0,
                      KEY_READ | view, &uninstall) != ERROR_SUCCESS) {
      continue;
    }
    DWORD index = 0;
    wchar_t key_name[256] = {};
    DWORD key_name_length = 256;
    while (RegEnumKeyExW(uninstall, index++, key_name, &key_name_length,
                         nullptr, nullptr, nullptr, nullptr) ==
           ERROR_SUCCESS) {
      HKEY record = nullptr;
      if (RegOpenKeyExW(uninstall, key_name, 0, KEY_READ, &record) ==
          ERROR_SUCCESS) {
        std::wstring install_location;
        std::wstring package_id;
        const bool matches =
            ReadRegistryString(record, L"InstallLocation",
                               &install_location) &&
            ReadRegistryString(record, L"DesktopUpdaterPackageId",
                               &package_id) &&
            RegistryRecordMatchesInstallTarget(
                install_location, package_id, canonical_target,
                expected_package_id);
        RegCloseKey(record);
        if (matches) {
          RegCloseKey(uninstall);
          return true;
        }
      }
      key_name_length = 256;
    }
    RegCloseKey(uninstall);
  }
  return false;
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
    const fs::path& running_executable,
    const std::string& expected_package_id) {
  const fs::path helper_path = FixedWindowsHelperPath(running_executable);
  const helper::VerifiedWindowsExecutable helper_identity =
      helper::VerifyWindowsExecutable(helper_path);
  const fs::path policy_path =
      helper_identity.final_path.parent_path() / kWindowsHelperPolicyName;
  const std::string policy_json = CanonicalJsonFile(
      policy_path, kMaximumHelperPolicyBytes, "Windows helper policy");
  const runtime::internal::JsonValue policy_value =
      runtime::internal::ParseJson(policy_json);
  const std::string application_package_id =
      policy_value.at("applicationPackageId").string();
  if (application_package_id != expected_package_id) {
    throw std::runtime_error(
        "Windows helper policy package identity does not match the app.");
  }
  helper::WindowsHelperPolicy policy = helper::WindowsHelperPolicy::Load(
      policy_json, Sha256Hex(policy_json), application_package_id,
      helper_identity.sha256);
  helper::ValidateWindowsHelperIdentity(helper_identity, policy, true);
  if (!helper::VerifyWindowsExecutableStillMatches(helper_path,
                                                   helper_identity)) {
    throw std::runtime_error(
        "Windows helper identity changed after policy validation.");
  }
  return {helper_identity.final_path, std::move(policy)};
}

PreparedWindowsHelperRequest BuildWindowsHelperRequest(
    const InstallRequest& request,
    const fs::path& running_executable,
    const InstallTargetProof& target_proof) {
  using runtime::internal::BuildWindowsNativeInstallTransactionRequestV1;
  using runtime::internal::EncodeCanonicalNativeInstallTransactionRequestV1;
  using runtime::internal::VerifyStageProvenance;
  using runtime::internal::WindowsNativeInstallEvidenceV1;

  const std::string package_id = WideToUtf8(request.expected_package_id);
  WindowsHelperClientContext context =
      LoadWindowsHelperClientContext(running_executable, package_id);

  const fs::path target_path(target_proof.canonical_root);
  const std::string installed_identity = CanonicalJsonFile(
      target_path / kInstalledIdentityMarkerName,
      kMaximumInstalledIdentityMarkerBytes, "Installed identity marker");
  if (!InstalledIdentityMarkerMatchesJson(installed_identity,
                                          request.expected_package_id)) {
    throw std::runtime_error(
        "Installed identity marker does not match the package.");
  }
  const std::string installed_identity_sha256 =
      Sha256Hex(installed_identity);

  const fs::path stage_path(request.staging_path);
  const std::string expected_provenance_sha256 =
      WideToUtf8(request.expected_provenance_sha256);
  const runtime::internal::StageProvenanceMarker marker =
      VerifyStageProvenance(stage_path, expected_provenance_sha256,
                            runtime::internal::BCryptSha256);
  const std::string release_manifest = CanonicalJsonFile(
      stage_path / kStagedReleaseManifestName, kMaximumHelperMetadataBytes,
      "Staged release manifest");

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

  const std::string transaction_id = NewTransactionId();
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
  const runtime::internal::NativeInstallTransactionRequestV1 native_request =
      BuildWindowsNativeInstallTransactionRequestV1(
          release_manifest, marker, evidence, Sha256Hex);
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

}  // namespace

InstallResult PrepareInstall(const InstallRequest& request,
                             InstallReservation* reservation) {
  if (reservation == nullptr) {
    return {false, "Install reservation output must not be null."};
  }
  *reservation = {};
  const InstallResult staging = ValidateStagingRoot(request);
  if (!staging.ok) {
    return staging;
  }
  if (request.staging_path.empty()) {
    return {false, "Staged update root is required."};
  }
  if (request.elevation_policy == InstallElevationPolicy::kNever) {
    return {false,
            "Windows native helper elevation is disabled by install policy; "
            "no unprivileged provider is available."};
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
  try {
    PreparedWindowsHelperRequest prepared =
        BuildWindowsHelperRequest(request, executable, target_proof);
    helper::WindowsElevatedHelperLaunch launch =
        helper::LaunchAuthenticatedElevatedHelper(
            prepared.helper.helper_path, prepared.helper.policy,
            prepared.nonce, prepared.canonical_request,
            kWindowsHelperStartupTimeoutMilliseconds);
    if (launch.result != helper::ElevationLaunchResult::kLaunched ||
        launch.session == nullptr) {
      return {false, ElevationLaunchError(launch.result)};
    }
    const InstallReservation public_reservation =
        PublicReservation(launch.session->reservation());
    if (!IsTransactionId(public_reservation.transaction_id) ||
        public_reservation.ready_token.empty() ||
        public_reservation.response_digest_sha256.size() != 64 ||
        public_reservation.helper_endpoint_identity_sha256.size() != 64) {
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
        return {false,
                "Windows helper returned a duplicate transaction ID."};
      }
    }
    *reservation = public_reservation;
    return {true, ""};
  } catch (const std::exception& error) {
    return {false, std::string("Windows helper preparation failed: ") +
                       error.what()};
  }
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
  return EndpointUnavailableStatus(transaction_id);
}

InstallTransactionStatus RecoverPendingInstall(
    const std::string& transaction_id) {
  if (!IsTransactionId(transaction_id)) {
    return {transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRejected,
            "Transaction ID is invalid.", "", ""};
  }
  return EndpointUnavailableStatus(transaction_id);
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
