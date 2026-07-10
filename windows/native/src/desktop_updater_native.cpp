#include "desktop_updater_native.h"

#include <bcrypt.h>
#include <shellapi.h>
#include <windows.h>

#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace desktop_updater {
namespace native {
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

}  // namespace

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request) {
  const std::wstring executable_path = CurrentExecutablePath();
  if (executable_path.empty()) {
    return {false, "Unable to resolve executable path."};
  }
  const fs::path executable(executable_path);
  const fs::path target_directory = executable.parent_path();
  if (!request.staging_path.empty() &&
      !fs::is_directory(fs::path(request.staging_path))) {
    return {false, "Staged update directory does not exist."};
  }

  PowerShellLaunchMode launch_mode = PowerShellLaunchMode::kNormal;
  if (request.request_elevation_if_needed) {
    const bool target_is_protected = IsKnownProtectedInstallDirectory(
        target_directory.wstring(), ProtectedInstallRootPaths());
    const bool target_is_writable = CanWriteDirectory(target_directory);
    const bool process_is_elevated = IsProcessElevated();
    if (!target_is_writable && process_is_elevated) {
      return {false,
              "Target directory is not writable while running elevated."};
    }
    if (!process_is_elevated && (target_is_protected || !target_is_writable)) {
      launch_mode = PowerShellLaunchMode::kElevated;
    }
  }

  const fs::path script_path =
      fs::temp_directory_path() /
      (L"desktop_updater_" + std::to_wstring(GetCurrentProcessId()) + L".ps1");
  std::ostringstream script;
  script
      << "$ErrorActionPreference = 'Stop'\n"
      << "$scriptSelf = " << PowerShellQuote(script_path.wstring()) << "\n"
      << "$pidToWait = " << GetCurrentProcessId() << "\n"
      << "$staging = " << PowerShellQuote(request.staging_path) << "\n"
      << "$target = " << PowerShellQuote(target_directory.wstring()) << "\n"
      << "$exe = " << PowerShellQuote(executable_path) << "\n"
      << "$diagnosticsLog = "
      << PowerShellQuote(request.diagnostics_log_path) << "\n"
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
      << "function Test-InstallerOwnedWindowsFile([string]$Name) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }\n"
      << "  return $Name -imatch '^unins[0-9][0-9][0-9]\\.(exe|dat|msg)$'\n"
      << "}\n"
      << "function Remove-StagingDirectoryWithRetry([string]$Path) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($Path)) { return }\n"
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
      << "function Test-AuthenticodePolicy($installer, $Policy) {\n"
      << "  if ($null -eq $Policy -or $Policy.required -ne $true) { return }\n"
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
      << "    $allowed = @($Policy.sha256Thumbprints | ForEach-Object { ([string]$_).ToUpperInvariant() })\n"
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
      << "function Invoke-InnoInstallerUpdate($Descriptor) {\n"
      << "  $installer = Join-Path $staging 'installer.exe'\n"
      << "  $installerPath = [IO.Path]::GetFullPath($installer)\n"
      << "  if ([string]::IsNullOrWhiteSpace($stagingRootWithSlash) -or -not $installerPath.StartsWith($stagingRootWithSlash, [StringComparison]::OrdinalIgnoreCase)) {\n"
      << "    throw 'Installer path escapes staging root.'\n"
      << "  }\n"
      << "  if (-not (Test-Path -LiteralPath $installerPath)) { throw 'Staged Inno installer is missing.' }\n"
      << "  $installer = $installerPath\n"
      << "  $inno = $Descriptor.install.inno\n"
      << "  Test-AuthenticodePolicy -installer $installer -Policy $inno.authenticode\n"
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
      << "  $manifest = Join-Path $staging '.desktop_updater_release_manifest.json'\n"
      << "  if (Test-Path -LiteralPath $manifest) {\n"
      << "    try {\n"
      << "      $descriptor = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json\n"
      << "      if ($descriptor.install.strategy -eq 'innoInstaller') {\n"
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
