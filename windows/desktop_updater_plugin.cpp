#include "desktop_updater_plugin.h"

#include <windows.h>
#include <VersionHelpers.h>

#pragma comment(lib, "Version.lib")

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <variant>
#include <vector>

namespace fs = std::filesystem;

namespace desktop_updater {
namespace {

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

std::string PowerShellQuote(const std::wstring& value) {
  std::string escaped = WideToUtf8(value);
  size_t pos = 0;
  while ((pos = escaped.find('\'', pos)) != std::string::npos) {
    escaped.replace(pos, 1, "''");
    pos += 2;
  }
  return "'" + escaped + "'";
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
                               const std::string& script) {
  std::ofstream file(script_path, std::ios::binary | std::ios::trunc);
  if (!file.is_open()) {
    return false;
  }

  const unsigned char bom[] = {0xEF, 0xBB, 0xBF};
  file.write(reinterpret_cast<const char*>(bom), sizeof(bom));
  file << script;
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

bool ScheduleInstallAndRelaunch(const std::wstring& staging_path,
                                const std::vector<std::wstring>& removed_files,
                                const std::wstring& diagnostics_log_path,
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

  const fs::path script_path = fs::temp_directory_path() /
      (L"desktop_updater_" + std::to_wstring(GetCurrentProcessId()) + L".ps1");

  std::ostringstream script;
  script
      << "$ErrorActionPreference = 'Stop'\n"
      << "$pidToWait = " << GetCurrentProcessId() << "\n"
      << "$staging = " << PowerShellQuote(staging_path) << "\n"
      << "$target = " << PowerShellQuote(target_directory.wstring()) << "\n"
      << "$exe = " << PowerShellQuote(executable_path) << "\n"
      << "$diagnosticsLog = " << PowerShellQuote(diagnostics_log_path) << "\n"
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
      << "Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue\n";

  if (!WriteUtf8PowerShellScript(script_path, script.str())) {
    *error = "Unable to write update helper script.";
    return false;
  }

  if (!StartDetachedPowerShell(script_path)) {
    *error = "Unable to start update helper script.";
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
  fs::path root_path(root);
  fs::path candidate_path(candidate);
  std::wstring root_value = root_path.lexically_normal().wstring();
  std::wstring candidate_value = candidate_path.lexically_normal().wstring();
  while (!root_value.empty() &&
         (root_value.back() == L'\\' || root_value.back() == L'/')) {
    root_value.pop_back();
  }
  while (!candidate_value.empty() &&
         (candidate_value.back() == L'\\' || candidate_value.back() == L'/')) {
    candidate_value.pop_back();
  }
  const std::wstring root_with_slash = root_value + L"\\";
  return candidate_value.size() > root_with_slash.size() &&
         _wcsnicmp(candidate_value.c_str(), root_with_slash.c_str(),
                   root_with_slash.size()) == 0;
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
    if (!ScheduleInstallAndRelaunch(L"", {}, L"", &error)) {
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
            DiagnosticsLogPathFromArguments(*arguments), &error)) {
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
