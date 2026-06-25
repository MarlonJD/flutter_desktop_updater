#include "desktop_updater_plugin.h"

#include <windows.h>
#include <VersionHelpers.h>
#include <bcrypt.h>
#include <shellapi.h>

#pragma comment(lib, "Bcrypt.lib")
#pragma comment(lib, "Shell32.lib")
#pragma comment(lib, "Version.lib")

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <string>
#include <variant>
#include <vector>

namespace fs = std::filesystem;

namespace desktop_updater {
namespace {

enum class PowerShellLaunchMode {
  kNormal,
  kElevated,
};

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }

  const int size = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1, nullptr, 0);
  if (size <= 0) {
    return L"";
  }

  std::wstring result(size - 1, L'\0');
  MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1, result.data(), size);
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

  std::string result(size - 1, '\0');
  WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), -1, result.data(), size, nullptr, nullptr);
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
  size_t pos = 0;
  while ((pos = escaped.find('\'', pos)) != std::string::npos) {
    escaped.replace(pos, 1, "''");
    pos += 2;
  }
  return "'" + escaped + "'";
}

std::string Base64Encode(const unsigned char* data, size_t length) {
  static constexpr char table[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string encoded;
  encoded.reserve(((length + 2) / 3) * 4);

  for (size_t i = 0; i < length; i += 3) {
    const unsigned int octet_a = data[i];
    const unsigned int octet_b = i + 1 < length ? data[i + 1] : 0;
    const unsigned int octet_c = i + 2 < length ? data[i + 2] : 0;
    const unsigned int triple = (octet_a << 16) | (octet_b << 8) | octet_c;

    encoded.push_back(table[(triple >> 18) & 0x3F]);
    encoded.push_back(table[(triple >> 12) & 0x3F]);
    encoded.push_back(i + 1 < length ? table[(triple >> 6) & 0x3F] : '=');
    encoded.push_back(i + 2 < length ? table[triple & 0x3F] : '=');
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

  bool ok = BCryptHashData(
                hash,
                reinterpret_cast<PUCHAR>(
                    const_cast<char*>(contents.data())),
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
  for (size_t i = 0; i < values.size(); ++i) {
    if (i > 0) {
      result += ", ";
    }
    result += PowerShellQuote(values[i]);
  }
  result += ")";
  return result;
}

bool WriteUtf8PowerShellScript(const fs::path& script_path,
                               const std::string& script_contents) {
  std::ofstream file(script_path, std::ios::binary | std::ios::trunc);
  if (!file.is_open()) {
    return false;
  }

  file << script_contents;
  return file.good();
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
      << Utf8ToWide(PowerShellQuote(Utf8ToWide(expected_hash)))
      << L"\n"
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
    if (error_code == ERROR_CANCELLED) {
      *error = "User cancelled the Windows UAC update prompt.";
    } else {
      *error = "Unable to start elevated update helper script: " +
               WindowsErrorMessage(error_code);
    }
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
  for (const wchar_t* variable_name :
       {L"ProgramFiles", L"ProgramFiles(x86)", L"ProgramW6432"}) {
    const std::wstring value = EnvironmentVariableValue(variable_name);
    if (!value.empty()) {
      roots.push_back(value);
    }
  }
  return roots;
}

bool IsKnownProtectedInstallDirectory(const fs::path& directory) {
  return IsKnownProtectedInstallDirectoryForTesting(
      directory.wstring(), ProtectedInstallRootPaths());
}

bool CanWriteDirectory(const fs::path& directory) {
  const fs::path probe_path = directory /
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

bool ScheduleInstallAndRelaunch(const std::wstring& staging_path,
                                const std::vector<std::wstring>& removed_files,
                                const std::wstring& diagnostics_log_path,
                                bool request_elevation_if_needed,
                                std::string* error) {
  const std::wstring executable_path = CurrentExecutablePath();
  if (executable_path.empty()) {
    *error = "Unable to resolve executable path.";
    return false;
  }

  const fs::path executable(executable_path);
  const fs::path target_directory = executable.parent_path();
  if (!staging_path.empty() && !fs::is_directory(fs::path(staging_path))) {
    *error = "Staged update directory does not exist.";
    return false;
  }

  PowerShellLaunchMode launch_mode = PowerShellLaunchMode::kNormal;
  if (request_elevation_if_needed) {
    const bool target_is_protected =
        IsKnownProtectedInstallDirectory(target_directory);
    const bool target_is_writable = CanWriteDirectory(target_directory);
    const bool process_is_elevated = IsProcessElevated();
    if (!target_is_writable && process_is_elevated) {
      *error = "Target directory is not writable while running elevated.";
      return false;
    }
    if (!process_is_elevated && (target_is_protected || !target_is_writable)) {
      launch_mode = PowerShellLaunchMode::kElevated;
    }
  }

  const fs::path script_path = fs::temp_directory_path() /
      (L"desktop_updater_" + std::to_wstring(GetCurrentProcessId()) + L".ps1");

  std::ostringstream script;
  script
      << "$ErrorActionPreference = 'Stop'\n"
      << "$scriptSelf = " << PowerShellQuote(script_path.wstring()) << "\n"
      << "$pidToWait = " << GetCurrentProcessId() << "\n"
      << "$staging = " << PowerShellQuote(staging_path) << "\n"
      << "$target = " << PowerShellQuote(target_directory.wstring()) << "\n"
      << "$exe = " << PowerShellQuote(executable_path) << "\n"
      << "$diagnosticsLog = " << PowerShellQuote(diagnostics_log_path) << "\n"
      << "$elevationReason = "
      << PowerShellQuote(launch_mode == PowerShellLaunchMode::kElevated
                             ? L"Target directory is protected or not writable. Requesting UAC elevation."
                             : L"")
      << "\n"
      << "$removed = " << PowerShellArray(removed_files) << "\n"
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
      << "$targetRoot = [IO.Path]::GetFullPath($target).TrimEnd('\\\\')\n"
      << "$targetRootWithSlash = $targetRoot + '\\'\n"
      << "function Get-NormalizedDirectory([string]$value) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($value)) { return '' }\n"
      << "  try { return [IO.Path]::GetFullPath($value.Trim('\"')).TrimEnd('\\\\') } catch { return '' }\n"
      << "}\n"
      << "function Update-UninstallDisplayVersion([string]$Version) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($Version)) { return }\n"
      << "  $targetRootLower = $targetRoot.ToLowerInvariant()\n"
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
      << "        $uninstallString = ''\n"
      << "        if ($null -ne $props.UninstallString) { $uninstallString = [string]$props.UninstallString }\n"
      << "        $installRoot = Get-NormalizedDirectory $installLocation\n"
      << "        $isMatch = $false\n"
      << "        if (-not [string]::IsNullOrWhiteSpace($installRoot)) {\n"
      << "          $isMatch = $installRoot.Equals($targetRoot, [StringComparison]::OrdinalIgnoreCase)\n"
      << "        }\n"
      << "        if (-not $isMatch -and -not [string]::IsNullOrWhiteSpace($uninstallString)) {\n"
      << "          $isMatch = $uninstallString.ToLowerInvariant().Contains($targetRootLower)\n"
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
      << "$backup = Join-Path ([IO.Path]::GetTempPath()) "
         "('desktop_updater_backup_' + $pidToWait)\n"
      << "if (Test-Path -LiteralPath $backup) { "
         "Remove-Item -LiteralPath $backup -Recurse -Force }\n"
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
      << "  if (-not $candidate.StartsWith($targetRootWithSlash, "
         "[StringComparison]::OrdinalIgnoreCase)) {\n"
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
      << "        Remove-Item -LiteralPath $_.FullName -Recurse -Force\n"
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
      << "  Write-DiagnosticsEvent 'cleanup start'\n"
      << "  try {\n"
      << "    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop\n"
      << "    Write-DiagnosticsEvent 'cleanup success'\n"
      << "  } catch {\n"
      << "    Write-DiagnosticsEvent 'cleanup failure'\n"
      << "  }\n"
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

  const std::string script_contents = Utf8PowerShellScriptContents(script.str());
  if (!WriteUtf8PowerShellScript(script_path, script_contents)) {
    *error = "Unable to write update helper script.";
    return false;
  }

  if (!StartPowerShell(script_path, script_contents, launch_mode, error)) {
    DeleteFileW(script_path.wstring().c_str());
    return false;
  }

  return true;
}

bool ReadCurrentProductVersion(std::wstring* product_version,
                               std::string* error) {
  const std::wstring executable_path = CurrentExecutablePath();
  DWORD version_handle = 0;
  const DWORD version_size =
      GetFileVersionInfoSizeW(executable_path.c_str(), &version_handle);

  if (version_size == 0) {
    *error = "Unable to get version size.";
    return false;
  }

  std::vector<BYTE> version_data(version_size);
  if (!GetFileVersionInfoW(executable_path.c_str(), version_handle,
                           version_size, version_data.data())) {
    *error = "Unable to get version info.";
    return false;
  }

  struct LanguageAndCodePage {
    WORD language;
    WORD code_page;
  }* translation;

  UINT translation_size = 0;
  if (!VerQueryValueW(version_data.data(), L"\\VarFileInfo\\Translation",
                      reinterpret_cast<LPVOID*>(&translation),
                      &translation_size) ||
      translation_size < sizeof(LanguageAndCodePage)) {
    *error = "Unable to get translation info.";
    return false;
  }

  wchar_t sub_block[50];
  swprintf_s(sub_block, L"\\StringFileInfo\\%04x%04x\\ProductVersion",
             translation[0].language, translation[0].code_page);

  LPBYTE buffer = nullptr;
  UINT size = 0;
  if (!VerQueryValueW(version_data.data(), sub_block,
                      reinterpret_cast<LPVOID*>(&buffer), &size)) {
    *error = "Unable to query product version.";
    return false;
  }

  *product_version = std::wstring(reinterpret_cast<wchar_t*>(buffer));
  return true;
}

std::vector<std::wstring> RemovedFilesFromArguments(
    const flutter::EncodableMap& arguments) {
  std::vector<std::wstring> removed_files;
  const auto iterator =
      arguments.find(flutter::EncodableValue("removedFiles"));
  if (iterator == arguments.end()) {
    return removed_files;
  }

  const auto* list = std::get_if<flutter::EncodableList>(&iterator->second);
  if (list == nullptr) {
    return removed_files;
  }

  for (const auto& value : *list) {
    if (const auto* item = std::get_if<std::string>(&value)) {
      removed_files.push_back(Utf8ToWide(*item));
    }
  }

  return removed_files;
}

std::wstring DiagnosticsLogPathFromArguments(
    const flutter::EncodableMap& arguments) {
  const auto iterator =
      arguments.find(flutter::EncodableValue("diagnosticsLogPath"));
  if (iterator == arguments.end()) {
    return L"";
  }

  const auto* value = std::get_if<std::string>(&iterator->second);
  if (value == nullptr) {
    return L"";
  }

  return Utf8ToWide(*value);
}

}  // namespace

ProductVersionBuildParseResult ParseProductVersionBuildNumber(
    const std::wstring& product_version,
    std::wstring* build_number) {
  build_number->clear();
  const size_t plus_position = product_version.find(L'+');
  if (plus_position == std::wstring::npos) {
    return ProductVersionBuildParseResult::kNoBuildNumber;
  }

  if (plus_position + 1 >= product_version.length()) {
    return ProductVersionBuildParseResult::kInvalid;
  }

  *build_number = product_version.substr(plus_position + 1);
  const size_t last_character = build_number->find_last_not_of(L" \t\r\n");
  if (last_character == std::wstring::npos) {
    build_number->clear();
    return ProductVersionBuildParseResult::kInvalid;
  }

  build_number->erase(last_character + 1);
  return ProductVersionBuildParseResult::kBuildNumber;
}

bool IsStrictChildPathForTesting(const std::wstring& root,
                                 const std::wstring& candidate) {
  const std::wstring root_value = NormalizedDirectoryPath(fs::path(root));
  const std::wstring candidate_value =
      NormalizedDirectoryPath(fs::path(candidate));
  const std::wstring root_with_slash = root_value + L"\\";
  return candidate_value.size() > root_with_slash.size() &&
         _wcsnicmp(candidate_value.c_str(), root_with_slash.c_str(),
                   root_with_slash.size()) == 0;
}

bool IsKnownProtectedInstallDirectoryForTesting(
    const std::wstring& directory,
    const std::vector<std::wstring>& protected_roots) {
  for (const std::wstring& root : protected_roots) {
    if (IsSameOrChildPath(fs::path(root), fs::path(directory))) {
      return true;
    }
  }
  return false;
}

// static
void DesktopUpdaterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "desktop_updater",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<DesktopUpdaterPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

DesktopUpdaterPlugin::DesktopUpdaterPlugin() {}

DesktopUpdaterPlugin::~DesktopUpdaterPlugin() {}

void DesktopUpdaterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("getPlatformVersion") == 0) {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(flutter::EncodableValue(version_stream.str()));
  } else if (method_call.method_name().compare("restartApp") == 0) {
    std::string error;
    if (!ScheduleInstallAndRelaunch(L"", {}, L"", false, &error)) {
      result->Error("RestartError", error);
      return;
    }
    result->Success();
    ExitProcess(0);
  } else if (method_call.method_name().compare("installUpdate") == 0) {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (arguments == nullptr) {
      result->Error("InvalidArguments", "installUpdate expects a map.");
      return;
    }

    const auto staging_iterator =
        arguments->find(flutter::EncodableValue("stagingPath"));
    if (staging_iterator == arguments->end()) {
      result->Error("InvalidArguments", "stagingPath is required.");
      return;
    }

    const auto* staging_path =
        std::get_if<std::string>(&staging_iterator->second);
    if (staging_path == nullptr || staging_path->empty()) {
      result->Error("InvalidArguments", "stagingPath must be a string.");
      return;
    }

    std::string error;
    if (!ScheduleInstallAndRelaunch(
            Utf8ToWide(*staging_path), RemovedFilesFromArguments(*arguments),
            DiagnosticsLogPathFromArguments(*arguments), true, &error)) {
      result->Error("InstallError", error);
      return;
    }

    result->Success();
    ExitProcess(0);
  } else if (method_call.method_name().compare("getExecutablePath") == 0) {
    result->Success(flutter::EncodableValue(WideToUtf8(CurrentExecutablePath())));
  } else if (method_call.method_name().compare("getCurrentVersion") == 0) {
    std::wstring product_version;
    std::string error;
    if (!ReadCurrentProductVersion(&product_version, &error)) {
      result->Error("VersionError", error);
      return;
    }

    std::wstring build_number;
    const ProductVersionBuildParseResult parse_result =
        ParseProductVersionBuildNumber(product_version, &build_number);
    if (parse_result == ProductVersionBuildParseResult::kInvalid) {
      result->Error("VersionError", "Invalid product version format.");
      return;
    }

    if (parse_result == ProductVersionBuildParseResult::kNoBuildNumber) {
      result->Success(flutter::EncodableValue());
      return;
    }

    result->Success(flutter::EncodableValue(WideToUtf8(build_number)));
  } else if (method_call.method_name().compare("getCurrentVersionInfo") == 0) {
    std::wstring product_version;
    std::string error;
    if (!ReadCurrentProductVersion(&product_version, &error)) {
      result->Error("VersionError", error);
      return;
    }

    std::wstring build_number;
    const ProductVersionBuildParseResult parse_result =
        ParseProductVersionBuildNumber(product_version, &build_number);
    if (parse_result == ProductVersionBuildParseResult::kInvalid) {
      result->Error("VersionError", "Invalid product version format.");
      return;
    }

    flutter::EncodableMap version_info;
    version_info[flutter::EncodableValue("version")] =
        flutter::EncodableValue(WideToUtf8(product_version));
    version_info[flutter::EncodableValue("buildNumber")] =
        parse_result == ProductVersionBuildParseResult::kBuildNumber
            ? flutter::EncodableValue(WideToUtf8(build_number))
            : flutter::EncodableValue();
    result->Success(flutter::EncodableValue(version_info));
  } else {
    result->NotImplemented();
  }
}

}  // namespace desktop_updater
