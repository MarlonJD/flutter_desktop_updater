#include "desktop_updater_native.h"

#include <windows.h>
#include <bcrypt.h>
#include <knownfolders.h>
#include <objbase.h>
#include <shellapi.h>
#include <shlobj.h>

#include <array>
#include <climits>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

#include "json_value.h"

namespace fs = std::filesystem;

namespace desktop_updater {
namespace native {
namespace {

constexpr std::size_t kMaximumInstalledIdentityMarkerBytes = 64 * 1024;

enum class PowerShellLaunchMode {
  kNormal,
  kElevated,
};

std::wstring ElevationPolicyName(InstallElevationPolicy policy) {
  switch (policy) {
    case InstallElevationPolicy::kAlways:
      return L"always";
    case InstallElevationPolicy::kNever:
      return L"never";
    case InstallElevationPolicy::kAuto:
      return L"auto";
  }
  return L"";
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1, nullptr, 0);
  if (size <= 0) {
    return L"";
  }
  std::wstring result(size, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1,
                          result.data(), size) <= 0) {
    return L"";
  }
  result.pop_back();
  return result;
}

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

std::string WindowsErrorMessage(DWORD error_code) {
  if (error_code == 0) {
    return "";
  }
  wchar_t* message_buffer = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error_code, 0, reinterpret_cast<LPWSTR>(&message_buffer), 0,
      nullptr);
  if (length == 0 || message_buffer == nullptr) {
    return "Windows error " + std::to_string(error_code) + ".";
  }
  std::wstring message(message_buffer, length);
  LocalFree(message_buffer);
  while (!message.empty() &&
         (message.back() == L'\r' || message.back() == L'\n' ||
          message.back() == L' ' || message.back() == L'\t')) {
    message.pop_back();
  }
  return WideToUtf8(message);
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

std::string Utf8PowerShellScriptContents(const std::string& script) {
  std::string contents;
  contents.push_back(static_cast<char>(0xEF));
  contents.push_back(static_cast<char>(0xBB));
  contents.push_back(static_cast<char>(0xBF));
  contents.append(script);
  return contents;
}

std::string PowerShellQuote(const std::wstring& value) {
  std::string escaped = WideToUtf8(value);
  size_t position = 0;
  while ((position = escaped.find('\'', position)) != std::string::npos) {
    escaped.replace(position, 1, "''");
    position += 2;
  }
  return "'" + escaped + "'";
}

std::string Base64Encode(const unsigned char* data, size_t length) {
  static constexpr char table[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string encoded;
  encoded.reserve(((length + 2) / 3) * 4);
  for (size_t index = 0; index < length; index += 3) {
    const unsigned int first = data[index];
    const unsigned int second = index + 1 < length ? data[index + 1] : 0;
    const unsigned int third = index + 2 < length ? data[index + 2] : 0;
    const unsigned int triple = (first << 16) | (second << 8) | third;
    encoded.push_back(table[(triple >> 18) & 0x3F]);
    encoded.push_back(table[(triple >> 12) & 0x3F]);
    encoded.push_back(index + 1 < length ? table[(triple >> 6) & 0x3F] : '=');
    encoded.push_back(index + 2 < length ? table[triple & 0x3F] : '=');
  }
  return encoded;
}

std::string Base64EncodeWide(const std::wstring& value) {
  return Base64Encode(reinterpret_cast<const unsigned char*>(value.data()),
                      value.size() * sizeof(wchar_t));
}

bool Sha256Hex(const std::string& contents, std::string* hex_digest) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_length = 0;
  DWORD hash_length = 0;
  DWORD property_length = 0;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                  0) < 0) {
    return false;
  }
  auto close_algorithm = [&]() {
    if (algorithm != nullptr) {
      BCryptCloseAlgorithmProvider(algorithm, 0);
      algorithm = nullptr;
    }
  };
  if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_length),
                        sizeof(object_length), &property_length, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH,
                        reinterpret_cast<PUCHAR>(&hash_length),
                        sizeof(hash_length), &property_length, 0) < 0) {
    close_algorithm();
    return false;
  }
  std::vector<unsigned char> hash_object(object_length);
  std::vector<unsigned char> digest(hash_length);
  if (BCryptCreateHash(algorithm, &hash, hash_object.data(), object_length,
                       nullptr, 0, 0) < 0) {
    close_algorithm();
    return false;
  }
  const bool ok =
      BCryptHashData(
          hash,
          reinterpret_cast<PUCHAR>(const_cast<char*>(contents.data())),
          static_cast<ULONG>(contents.size()), 0) >= 0 &&
      BCryptFinishHash(hash, digest.data(), hash_length, 0) >= 0;
  BCryptDestroyHash(hash);
  close_algorithm();
  if (!ok) {
    return false;
  }
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (const unsigned char byte : digest) {
    stream << std::setw(2) << static_cast<int>(byte);
  }
  *hex_digest = stream.str();
  return true;
}

std::string PowerShellArray(const std::vector<std::wstring>& values) {
  if (values.empty()) {
    return "@()";
  }
  std::string result = "@(";
  for (size_t index = 0; index < values.size(); ++index) {
    if (index > 0) {
      result += ", ";
    }
    result += PowerShellQuote(values[index]);
  }
  result += ")";
  return result;
}

bool WriteUtf8PowerShellScript(const fs::path& script_path,
                               const std::string& script_contents) {
  HANDLE file = CreateFileW(script_path.wstring().c_str(), GENERIC_WRITE, 0,
                            nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  std::size_t offset = 0;
  bool ok = true;
  while (offset < script_contents.size()) {
    const std::size_t pending = script_contents.size() - offset;
    const DWORD remaining = static_cast<DWORD>(
        pending > static_cast<std::size_t>(MAXDWORD) ? MAXDWORD : pending);
    DWORD written = 0;
    if (!::WriteFile(file, script_contents.data() + offset, remaining,
                     &written, nullptr) || written == 0) {
      ok = false;
      break;
    }
    offset += written;
  }
  if (!CloseHandle(file)) {
    ok = false;
  }
  if (!ok) {
    DeleteFileW(script_path.wstring().c_str());
  }
  return ok;
}

std::wstring CreateUuidNonce() {
  unsigned char bytes[16] = {};
  if (BCryptGenRandom(nullptr, bytes, sizeof(bytes),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    return L"";
  }
  bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0f) | 0x40);
  bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3f) | 0x80);
  std::wostringstream nonce;
  nonce << std::hex << std::setfill(L'0');
  for (std::size_t index = 0; index < sizeof(bytes); ++index) {
    if (index == 4 || index == 6 || index == 8 || index == 10) {
      nonce << L'-';
    }
    nonce << std::setw(2) << static_cast<unsigned int>(bytes[index]);
  }
  return nonce.str();
}

bool StartDetachedPowerShell(const fs::path& script_path) {
  std::wstring command = L"powershell.exe -NoProfile -ExecutionPolicy Bypass "
                         L"-WindowStyle Hidden -File \"" +
                         script_path.wstring() + L"\"";
  std::vector<wchar_t> command_line(command.begin(), command.end());
  command_line.push_back(L'\0');
  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  PROCESS_INFORMATION process_info = {};
  const BOOL started = CreateProcessW(
      nullptr, command_line.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
      nullptr, nullptr, &startup_info, &process_info);
  if (started) {
    CloseHandle(process_info.hProcess);
    CloseHandle(process_info.hThread);
  }
  return started == TRUE;
}

std::wstring ElevatedPowerShellBootstrap(const fs::path& script_path,
                                         const std::string& expected_hash) {
  std::wostringstream bootstrap;
  bootstrap
      << L"$ErrorActionPreference='Stop'\n"
      << L"$scriptPath="
      << Utf8ToWide(PowerShellQuote(script_path.wstring())) << L"\n"
      << L"$expectedHash="
      << Utf8ToWide(PowerShellQuote(Utf8ToWide(expected_hash))) << L"\n"
      << L"$bytes=[IO.File]::ReadAllBytes($scriptPath)\n"
      << L"$sha=[Security.Cryptography.SHA256]::Create()\n"
      << L"try {\n"
      << L"  $actualHash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()\n"
      << L"} finally {\n"
      << L"  $sha.Dispose()\n"
      << L"}\n"
      << L"if ($actualHash -ne $expectedHash) {\n"
      << L"  throw 'desktop_updater elevated helper hash mismatch.'\n"
      << L"}\n"
      << L"$scriptText=[Text.Encoding]::UTF8.GetString($bytes)\n"
      << L"if ($scriptText.Length -gt 0 -and $scriptText[0] -eq [char]0xfeff) {\n"
      << L"  $scriptText=$scriptText.Substring(1)\n"
      << L"}\n"
      << L"Invoke-Expression $scriptText\n";
  return bootstrap.str();
}

bool StartElevatedPowerShell(const fs::path& script_path,
                             const std::string& script_contents,
                             std::string* error) {
  std::string expected_hash;
  if (!Sha256Hex(script_contents, &expected_hash)) {
    *error = "Unable to hash elevated update helper script.";
    return false;
  }
  const std::wstring bootstrap =
      ElevatedPowerShellBootstrap(script_path, expected_hash);
  const std::wstring parameters =
      L"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
      L"-EncodedCommand " +
      Utf8ToWide(Base64EncodeWide(bootstrap));
  SHELLEXECUTEINFOW execute_info = {};
  execute_info.cbSize = sizeof(execute_info);
  execute_info.fMask = SEE_MASK_NOCLOSEPROCESS;
  execute_info.lpVerb = L"runas";
  execute_info.lpFile = L"powershell.exe";
  execute_info.lpParameters = parameters.c_str();
  execute_info.nShow = SW_HIDE;
  if (!ShellExecuteExW(&execute_info)) {
    const DWORD error_code = GetLastError();
    *error = error_code == ERROR_CANCELLED
                 ? "User cancelled the Windows UAC update prompt."
                 : "Unable to start elevated update helper script: " +
                       WindowsErrorMessage(error_code);
    return false;
  }
  if (execute_info.hProcess != nullptr) {
    CloseHandle(execute_info.hProcess);
  }
  return true;
}

bool StartPowerShell(const fs::path& script_path,
                     const std::string& script_contents,
                     PowerShellLaunchMode launch_mode,
                     std::string* error) {
  if (launch_mode == PowerShellLaunchMode::kElevated) {
    return StartElevatedPowerShell(script_path, script_contents, error);
  }
  if (!StartDetachedPowerShell(script_path)) {
    *error = "Unable to start update helper script.";
    return false;
  }
  return true;
}

bool IsProcessElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_ELEVATION elevation = {};
  DWORD size = 0;
  const BOOL result =
      GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation),
                          &size);
  CloseHandle(token);
  return result == TRUE && elevation.TokenIsElevated != 0;
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

bool CanWriteDirectory(const fs::path& directory) {
  const fs::path probe_path =
      directory /
      (L".desktop_updater_write_probe_" +
       std::to_wstring(GetCurrentProcessId()) + L"_" +
       std::to_wstring(GetTickCount64()) + L".tmp");
  HANDLE file = CreateFileW(
      probe_path.wstring().c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_TEMPORARY | FILE_ATTRIBUTE_HIDDEN |
          FILE_FLAG_DELETE_ON_CLOSE,
      nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  CloseHandle(file);
  DeleteFileW(probe_path.wstring().c_str());
  return true;
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

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request) {
  const std::wstring executable_path = CurrentExecutablePath();
  if (executable_path.empty()) {
    return {false, "Unable to resolve executable path."};
  }
  std::error_code canonical_error;
  const fs::path executable = fs::canonical(executable_path, canonical_error);
  if (canonical_error) {
    return {false, "Unable to canonicalize executable path."};
  }
  fs::path target_directory = executable.parent_path();
  const InstallResult staging_root = ValidateStagingRoot(request);
  if (!staging_root.ok) {
    return staging_root;
  }
  InstallTargetProof target_proof;
  if (!request.staging_path.empty()) {
    const InstallResult target =
        ProveInstallTarget(request, executable, &target_proof);
    if (!target.ok) {
      return target;
    }
    target_directory = target_proof.canonical_root;
  }

  PowerShellLaunchMode launch_mode = PowerShellLaunchMode::kNormal;
  if (!request.staging_path.empty()) {
    const bool target_is_protected = IsKnownProtectedInstallDirectory(
        target_directory.wstring(), ProtectedInstallRootPaths());
    const bool target_is_writable = CanWriteDirectory(target_directory);
    const bool process_is_elevated = IsProcessElevated();
    const InstallLaunchDecision launch_decision =
        ResolveInstallLaunchDecision(request.elevation_policy,
                                     target_is_protected, target_is_writable,
                                     process_is_elevated);
    if (launch_decision == InstallLaunchDecision::kReject) {
      return {false,
              process_is_elevated
                  ? "Target directory is not writable while running elevated."
                  : "Signed install policy forbids required UAC elevation."};
    }
    if (launch_decision == InstallLaunchDecision::kElevated) {
      launch_mode = PowerShellLaunchMode::kElevated;
    }
  }

  const std::wstring helper_diagnostics_log_path =
      launch_mode == PowerShellLaunchMode::kElevated
          ? L""
          : request.diagnostics_log_path;

  const std::wstring nonce = CreateUuidNonce();
  if (nonce.empty()) {
    return {false, "Unable to generate update helper nonce."};
  }
  const fs::path script_path = fs::temp_directory_path() /
      (L"desktop_updater_" + std::to_wstring(GetCurrentProcessId()) + L"_" +
       nonce + L".ps1");
  std::ostringstream script;
  script
      << "$ErrorActionPreference = 'Stop'\n"
      << "$scriptSelf = " << PowerShellQuote(script_path.wstring()) << "\n"
      << "$pidToWait = " << GetCurrentProcessId() << "\n"
      << "$staging = " << PowerShellQuote(request.staging_path) << "\n"
      << "$target = " << PowerShellQuote(target_directory.wstring()) << "\n"
      << "$exe = " << PowerShellQuote(executable.wstring()) << "\n"
      << "$diagnosticsLog = "
      << PowerShellQuote(helper_diagnostics_log_path) << "\n"
      << "$expected_provenance_sha256 = "
      << PowerShellQuote(request.expected_provenance_sha256) << "\n"
      << "$expectedPackageId = "
      << PowerShellQuote(request.expected_package_id) << "\n"
      << "$expectedArtifactSha256 = "
      << PowerShellQuote(request.expected_artifact_sha256) << "\n"
      << "$expectedElevationPolicy = "
      << PowerShellQuote(ElevationPolicyName(request.elevation_policy)) << "\n"
      << "$allowedSignerThumbprints = @(";
  for (std::size_t index = 0;
       index < request.allowed_signer_thumbprints.size(); ++index) {
    if (index != 0) script << ",";
    script << PowerShellQuote(request.allowed_signer_thumbprints[index]);
  }
  script << ")\n"
      << "$elevationReason = "
      << PowerShellQuote(launch_mode == PowerShellLaunchMode::kElevated
                             ? L"Target directory is protected or not writable. Requesting UAC elevation."
                             : L"")
      << "\n"
      << "$removed = " << PowerShellArray(request.removed_files) << "\n"
      << "$skipRelaunch = $env:DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH\n"
      << "function Write-DiagnosticsEvent([string]$Event) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($diagnosticsLog)) { return }\n"
      << "  try {\n"
      << "    $timestamp = [DateTime]::UtcNow.ToString('o')\n"
      << "    $line = @{timestamp=$timestamp; event=$Event} | ConvertTo-Json -Compress\n"
      << "    Add-Content -LiteralPath $diagnosticsLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue\n"
      << "  } catch {}\n"
      << "}\n"
      << "if (-not [string]::IsNullOrWhiteSpace($elevationReason)) {\n"
      << "  Write-DiagnosticsEvent 'elevation requested'\n"
      << "}\n"
      << "Write-DiagnosticsEvent 'helper scheduled'\n"
      << "Write-DiagnosticsEvent 'waiting for parent process'\n"
      << "while (Get-Process -Id $pidToWait -ErrorAction SilentlyContinue) {\n"
      << "  Start-Sleep -Milliseconds 500\n"
      << "}\n"
      << "Write-DiagnosticsEvent 'parent process exited'\n"
      << "$targetRoot = [IO.Path]::GetFullPath($target).TrimEnd('\\')\n"
      << "$targetRootWithSlash = $targetRoot + '\\'\n"
      << "$stagingRoot = ''\n"
      << "$stagingRootWithSlash = ''\n"
      << "if (-not [string]::IsNullOrWhiteSpace($staging)) {\n"
      << "  $stagingRoot = [IO.Path]::GetFullPath($staging).TrimEnd('\\')\n"
      << "  $stagingRootWithSlash = $stagingRoot + '\\'\n"
      << "}\n"
      << "function Get-NormalizedDirectory([string]$value) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($value)) { return '' }\n"
      << "  try { return [IO.Path]::GetFullPath($value.Trim('\"')).TrimEnd('\\') } catch { return '' }\n"
      << "}\n"
      << "function Update-UninstallDisplayVersion([string]$Version) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($Version)) { return }\n"
      << "  $roots = @(\n"
      << "    'Registry::HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall',\n"
      << "    'Registry::HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall',\n"
      << "    'Registry::HKEY_LOCAL_MACHINE\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall'\n"
      << "  )\n"
      << "  foreach ($root in $roots) {\n"
      << "    if (-not (Test-Path -LiteralPath $root)) { continue }\n"
      << "    foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {\n"
      << "      try {\n"
      << "        $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop\n"
      << "        $installLocation = ''\n"
      << "        if ($null -ne $props.InstallLocation) { $installLocation = [string]$props.InstallLocation }\n"
      << "        $installedPackageId = ''\n"
      << "        if ($null -ne $props.DesktopUpdaterPackageId) { $installedPackageId = [string]$props.DesktopUpdaterPackageId }\n"
      << "        $installRoot = Get-NormalizedDirectory $installLocation\n"
      << "        $isMatch = $false\n"
      << "        if (-not [string]::IsNullOrWhiteSpace($installRoot)) {\n"
      << "          $isMatch = $installRoot.Equals($targetRoot, [StringComparison]::OrdinalIgnoreCase) -and $installedPackageId.Equals($expectedPackageId, [StringComparison]::Ordinal)\n"
      << "        }\n"
      << "        if ($isMatch) {\n"
      << "          Set-ItemProperty -LiteralPath $key.PSPath -Name 'DisplayVersion' -Value $Version -ErrorAction Stop\n"
      << "          return\n"
      << "        }\n"
      << "      } catch {\n"
      << "        continue\n"
      << "      }\n"
      << "    }\n"
      << "  }\n"
      << "}\n"
      << "function Test-InstallerOwnedWindowsFile([string]$Name) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }\n"
      << "  return $Name -imatch '^unins[0-9][0-9][0-9]\\.(exe|dat|msg)$'\n"
      << "}\n"
      << "function Remove-StagingDirectoryWithRetry([string]$Path) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($Path)) { return }\n"
      << "  $ownedName = [IO.Path]::GetFileName($Path)\n"
      << "  if ($null -eq $provenance -or $ownedName -ne ('desktop_updater_stage_' + [string]$provenance.nonce)) { throw 'Refusing to delete non-owned staging path.' }\n"
      << "  Write-DiagnosticsEvent 'cleanup start'\n"
      << "  if (-not (Test-Path -LiteralPath $Path)) {\n"
      << "    Write-DiagnosticsEvent 'cleanup success'\n"
      << "    return\n"
      << "  }\n"
      << "  $cleanupDeadline = (Get-Date).AddSeconds(30)\n"
      << "  while ($true) {\n"
      << "    try {\n"
      << "      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop\n"
      << "      Write-DiagnosticsEvent 'cleanup success'\n"
      << "      return\n"
      << "    } catch {\n"
      << "      if ((Get-Date) -gt $cleanupDeadline) {\n"
      << "        Write-DiagnosticsEvent 'cleanup failure'\n"
      << "        return\n"
      << "      }\n"
      << "      Write-DiagnosticsEvent 'cleanup retry'\n"
      << "      Start-Sleep -Milliseconds 500\n"
      << "    }\n"
      << "  }\n"
      << "}\n"
      << "function Test-AuthenticodePolicy($installer) {\n"
      << "  if ($allowedSignerThumbprints.Count -eq 0) { return }\n"
      << "  try {\n"
      << "    $signature = Get-AuthenticodeSignature -FilePath $installer -ErrorAction Stop\n"
      << "    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {\n"
      << "      Write-DiagnosticsEvent 'inno authenticode failure'\n"
      << "      throw 'Installer Authenticode signature is not valid.'\n"
      << "    }\n"
      << "    $certificateThumbprint = ([string]$signature.SignerCertificate.Thumbprint).ToUpperInvariant()\n"
      << "    $sha256 = [Security.Cryptography.SHA256]::Create()\n"
      << "    try {\n"
      << "      $actual = [BitConverter]::ToString($sha256.ComputeHash($signature.SignerCertificate.GetRawCertData())).Replace('-', '').ToUpperInvariant()\n"
      << "    } finally {\n"
      << "      $sha256.Dispose()\n"
      << "    }\n"
      << "    $allowed = @($allowedSignerThumbprints | ForEach-Object { ([string]$_).ToUpperInvariant() })\n"
      << "    if ($allowed.Count -gt 0 -and -not ($allowed -contains $actual)) {\n"
      << "      Write-DiagnosticsEvent 'inno authenticode failure'\n"
      << "      throw 'Installer Authenticode thumbprint is not trusted.'\n"
      << "    }\n"
      << "    Write-DiagnosticsEvent 'inno authenticode verified'\n"
      << "  } catch {\n"
      << "    Write-DiagnosticsEvent 'inno authenticode failure'\n"
      << "    throw\n"
      << "  }\n"
      << "}\n"
      << "function Test-StageProvenance {\n"
      << "  Write-DiagnosticsEvent 'stage provenance validation'\n"
      << "  try {\n"
      << "    if ([string]::IsNullOrWhiteSpace($expected_provenance_sha256) -or [string]::IsNullOrWhiteSpace($stagingRoot)) { throw 'Expected stage provenance is missing.' }\n"
      << "    $stageItem = Get-Item -LiteralPath $stagingRoot -Force -ErrorAction Stop\n"
      << "    if (($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Stage root is a reparse point.' }\n"
      << "    $marker = Join-Path $stagingRoot '.desktop_updater_stage_provenance.json'\n"
      << "    $markerItem = Get-Item -LiteralPath $marker -Force -ErrorAction Stop\n"
      << "    if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Stage marker is a reparse point.' }\n"
      << "    $markerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $marker).Hash.ToLowerInvariant()\n"
      << "    if ($markerHash -ne $expected_provenance_sha256.ToLowerInvariant()) { throw 'Stage provenance digest changed.' }\n"
      << "    $script:provenance = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json\n"
      << "    if ($provenance.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$provenance.nonce)) { throw 'Stage provenance is invalid.' }\n"
      << "    if (-not ([string]$provenance.packageId).Equals($expectedPackageId, [StringComparison]::Ordinal)) { throw 'Stage provenance package identity changed.' }\n"
      << "    $ownedName = [IO.Path]::GetFileName($stagingRoot)\n"
      << "    if ($ownedName -ne ('desktop_updater_stage_' + [string]$provenance.nonce)) { throw 'Stage nonce does not own root.' }\n"
      << "    $entryCount = 0\n"
      << "    foreach ($entry in @($provenance.entries)) {\n"
      << "      $entryCount++\n"
      << "      $candidate = [IO.Path]::GetFullPath((Join-Path $stagingRoot ([string]$entry.path)))\n"
      << "      if (-not $candidate.StartsWith($stagingRootWithSlash, [StringComparison]::OrdinalIgnoreCase)) { throw 'Stage entry escapes root.' }\n"
      << "      $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop\n"
      << "      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Stage reparse entry is unsafe.' }\n"
      << "      if ($entry.kind -eq 'directory') { if (-not $item.PSIsContainer) { throw 'Stage directory changed.' } }\n"
      << "      elseif ($entry.kind -eq 'file') {\n"
      << "        if ($item.PSIsContainer -or $item.Length -ne [int64]$entry.length) { throw 'Stage file changed.' }\n"
      << "        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash.ToLowerInvariant()\n"
      << "        if ($actual -ne ([string]$entry.sha256).ToLowerInvariant()) { throw 'Stage file digest changed.' }\n"
      << "      } else { throw 'Unsupported Windows stage entry.' }\n"
      << "    }\n"
      << "    $actualCount = @(Get-ChildItem -LiteralPath $stagingRoot -Force -Recurse | Where-Object { $_.FullName -ne $marker }).Count\n"
      << "    if ($actualCount -ne $entryCount) { throw 'Stage inventory entry count changed.' }\n"
      << "    Write-DiagnosticsEvent 'stage provenance validation success'\n"
      << "    return $true\n"
      << "  } catch {\n"
      << "    Write-DiagnosticsEvent 'stage provenance validation failure'\n"
      << "    throw\n"
      << "  }\n"
      << "}\n"
      << "function Invoke-InnoInstallerUpdate($Descriptor) {\n"
      << "  $installer = Join-Path $staging 'installer.exe'\n"
      << "  $installerPath = [IO.Path]::GetFullPath($installer)\n"
      << "  if ([string]::IsNullOrWhiteSpace($stagingRootWithSlash) -or -not $installerPath.StartsWith($stagingRootWithSlash, [StringComparison]::OrdinalIgnoreCase)) {\n"
      << "    throw 'Installer path escapes staging root.'\n"
      << "  }\n"
      << "  if (-not (Test-Path -LiteralPath $installerPath)) { throw 'Staged Inno installer is missing.' }\n"
      << "  $installer = $installerPath\n"
      << "  $artifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()\n"
      << "  if ([string]::IsNullOrWhiteSpace($expectedArtifactSha256) -or $artifactHash -ne $expectedArtifactSha256.ToLowerInvariant()) { throw 'Installer artifact SHA-256 changed.' }\n"
      << "  $inno = $Descriptor.install.inno\n"
      << "  Test-AuthenticodePolicy -installer $installer\n"
      << "  $logFileName = [string]$inno.logFileName\n"
      << "  if ([string]::IsNullOrWhiteSpace($logFileName)) { $logFileName = 'desktop_updater_inno_install.log' }\n"
      << "  $logPath = Join-Path ([IO.Path]::GetTempPath()) $logFileName\n"
      << "  $args = New-Object System.Collections.Generic.List[string]\n"
      << "  foreach ($arg in @($inno.silentArgs)) {\n"
      << "    if (-not [string]::IsNullOrWhiteSpace($arg)) { [void]$args.Add([string]$arg) }\n"
      << "  }\n"
      << "  if ($inno.inheritInstallDirectory -eq $true) { [void]$args.Add('/DIR=' + $targetRoot) }\n"
      << "  [void]$args.Add('/LOG=' + $logPath)\n"
      << "  Write-DiagnosticsEvent 'inno installer start'\n"
      << "  $process = Start-Process -FilePath $installer -ArgumentList $args.ToArray() -Wait -PassThru\n"
      << "  if ($process.ExitCode -ne 0) {\n"
      << "    Write-DiagnosticsEvent ('inno installer failure exitCode=' + $process.ExitCode)\n"
      << "    throw ('Inno installer failed with exit code ' + $process.ExitCode)\n"
      << "  }\n"
      << "  Write-DiagnosticsEvent 'inno installer success'\n"
      << "  Remove-StagingDirectoryWithRetry $stagingRoot\n"
      << "  if ($inno.relaunchAfterInstall -eq $true -and $skipRelaunch -ne '1') {\n"
      << "    Write-DiagnosticsEvent 'inno relaunch attempt'\n"
      << "    Start-Process -WorkingDirectory $target -FilePath $exe\n"
      << "  }\n"
      << "  Remove-Item -LiteralPath $scriptSelf -Force -ErrorAction SilentlyContinue\n"
      << "  exit 0\n"
      << "}\n"
      << "if (-not [string]::IsNullOrWhiteSpace($staging)) {\n"
      << "  Test-StageProvenance\n"
      << "  $manifest = Join-Path $staging '.desktop_updater_release_manifest.json'\n"
      << "  if (Test-Path -LiteralPath $manifest) {\n"
      << "    try {\n"
      << "      $descriptor = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json\n"
      << "      if (-not ([string]$descriptor.packageId).Equals($expectedPackageId, [StringComparison]::Ordinal)) { throw 'Release descriptor package identity changed.' }\n"
      << "      if ($descriptor.install.strategy -eq 'innoInstaller') {\n"
      << "        $manifestElevationPolicy = [string]$descriptor.install.inno.requiresElevation\n"
      << "        if ([string]::IsNullOrWhiteSpace($manifestElevationPolicy)) { $manifestElevationPolicy = 'auto' }\n"
      << "        if (-not $manifestElevationPolicy.Equals($expectedElevationPolicy, [StringComparison]::Ordinal)) { throw 'Release descriptor elevation policy changed.' }\n"
      << "        Write-DiagnosticsEvent 'inno manifest loaded'\n"
      << "        Invoke-InnoInstallerUpdate $descriptor\n"
      << "      }\n"
      << "    } catch {\n"
      << "      Write-DiagnosticsEvent 'inno manifest failure'\n"
      << "      throw\n"
      << "    }\n"
      << "  }\n"
      << "}\n"
      << "$backup = Join-Path ([IO.Path]::GetTempPath()) ('desktop_updater_backup_' + $pidToWait)\n"
      << "if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }\n"
      << "$backupReady = $false\n"
      << "try {\n"
      << "Write-DiagnosticsEvent 'backup start'\n"
      << "try {\n"
      << "  Copy-Item -LiteralPath $target -Destination $backup -Recurse -Force\n"
      << "  $backupReady = $true\n"
      << "  Write-DiagnosticsEvent 'backup success'\n"
      << "} catch {\n"
      << "  Write-DiagnosticsEvent 'backup failure'\n"
      << "  throw\n"
      << "}\n"
      << "foreach ($relative in $removed) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($relative)) { continue }\n"
      << "  $candidate = [IO.Path]::GetFullPath((Join-Path $target $relative))\n"
      << "  if (-not $candidate.StartsWith($targetRootWithSlash, [StringComparison]::OrdinalIgnoreCase)) {\n"
      << "    throw \"Removed file escapes app root: $relative\"\n"
      << "  }\n"
      << "  if (Test-Path -LiteralPath $candidate) {\n"
      << "    Remove-Item -LiteralPath $candidate -Recurse -Force\n"
      << "  }\n"
      << "}\n"
      << "if (-not [string]::IsNullOrWhiteSpace($staging)) {\n"
      << "  Write-DiagnosticsEvent 'staging path validation'\n"
      << "  $deadline = (Get-Date).AddSeconds(90)\n"
      << "  while ($true) {\n"
      << "    try {\n"
      << "      Write-DiagnosticsEvent 'move start'\n"
      << "      Get-ChildItem -LiteralPath $target -Force | ForEach-Object {\n"
      << "        if ($_.PSIsContainer -or -not (Test-InstallerOwnedWindowsFile $_.Name)) {\n"
      << "          Remove-Item -LiteralPath $_.FullName -Recurse -Force\n"
      << "        } else {\n"
      << "          Write-DiagnosticsEvent ('preserve installer file ' + $_.Name)\n"
      << "        }\n"
      << "      }\n"
      << "      Get-ChildItem -LiteralPath $staging -Force | ForEach-Object {\n"
      << "        Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force\n"
      << "      }\n"
      << "      $manifest = Join-Path $staging '.desktop_updater_release_manifest.json'\n"
      << "      if (Test-Path -LiteralPath $manifest) {\n"
      << "        try {\n"
      << "          $descriptor = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json\n"
      << "          if ($null -ne $descriptor.version) {\n"
      << "            Update-UninstallDisplayVersion -Version ([string]$descriptor.version)\n"
      << "          }\n"
      << "        } catch {\n"
      << "        }\n"
      << "      }\n"
      << "      $targetManifest = Join-Path $target '.desktop_updater_release_manifest.json'\n"
      << "      Remove-Item -LiteralPath $targetManifest -Force -ErrorAction SilentlyContinue\n"
      << "      $targetProvenance = Join-Path $target '.desktop_updater_stage_provenance.json'\n"
      << "      Remove-Item -LiteralPath $targetProvenance -Force -ErrorAction SilentlyContinue\n"
      << "      $targetArtifact = Join-Path $target '.desktop_updater_artifact.zip'\n"
      << "      Remove-Item -LiteralPath $targetArtifact -Force -ErrorAction SilentlyContinue\n"
      << "      Write-DiagnosticsEvent 'move success'\n"
      << "      break\n"
      << "    } catch {\n"
      << "      if ((Get-Date) -gt $deadline) {\n"
      << "        Write-DiagnosticsEvent 'move failure'\n"
      << "        throw\n"
      << "      }\n"
      << "      Start-Sleep -Seconds 1\n"
      << "    }\n"
      << "  }\n"
      << "  Remove-StagingDirectoryWithRetry -Path $staging\n"
      << "}\n"
      << "Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue\n"
      << "} catch {\n"
      << "  if ($backupReady -and (Test-Path -LiteralPath $backup)) {\n"
      << "    Write-DiagnosticsEvent 'rollback start'\n"
      << "    try {\n"
      << "      Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue\n"
      << "      Copy-Item -LiteralPath $backup -Destination $target -Recurse -Force -ErrorAction Stop\n"
      << "      Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue\n"
      << "      Write-DiagnosticsEvent 'rollback success'\n"
      << "    } catch {\n"
      << "      Write-DiagnosticsEvent 'rollback failure'\n"
      << "    }\n"
      << "  }\n"
      << "  throw\n"
      << "}\n"
      << "if ($skipRelaunch -ne '1') {\n"
      << "  Write-DiagnosticsEvent 'relaunch attempt'\n"
      << "  Start-Process -FilePath $exe -WorkingDirectory $target\n"
      << "}\n"
      << "Remove-Item -LiteralPath $scriptSelf -Force -ErrorAction SilentlyContinue\n";

  const std::string script_contents =
      Utf8PowerShellScriptContents(script.str());
  if (!WriteUtf8PowerShellScript(script_path, script_contents)) {
    return {false, "Unable to write update helper script."};
  }
  std::string error;
  if (!StartPowerShell(script_path, script_contents, launch_mode, &error)) {
    DeleteFileW(script_path.wstring().c_str());
    return {false, error};
  }
  return {true, ""};
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
