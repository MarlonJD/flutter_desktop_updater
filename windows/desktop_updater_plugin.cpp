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
                                std::string* error) {
  const std::wstring executable_path = CurrentExecutablePath();
  if (executable_path.empty()) {
    *error = "Unable to resolve executable path.";
    return false;
  }

  const fs::path executable(executable_path);
  const fs::path target_directory = executable.parent_path();
  if (!staging_path.empty() && !fs::exists(fs::path(staging_path))) {
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
      << "$removed = " << PowerShellArray(removed_files) << "\n"
      << "$skipRelaunch = $env:DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH\n"
      << "while (Get-Process -Id $pidToWait -ErrorAction SilentlyContinue) {\n"
      << "  Start-Sleep -Milliseconds 500\n"
      << "}\n"
      << "$targetRoot = [IO.Path]::GetFullPath($target).TrimEnd('\\\\')\n"
      << "$targetRootWithSlash = $targetRoot + '\\'\n"
      << "foreach ($relative in $removed) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($relative)) { continue }\n"
      << "  $candidate = [IO.Path]::GetFullPath((Join-Path $target $relative))\n"
      << "  if (($candidate.Equals($targetRoot, [StringComparison]::OrdinalIgnoreCase) -or "
         "$candidate.StartsWith($targetRootWithSlash, [StringComparison]::OrdinalIgnoreCase)) "
         "-and (Test-Path -LiteralPath $candidate)) {\n"
      << "    Remove-Item -LiteralPath $candidate -Recurse -Force\n"
      << "  }\n"
      << "}\n"
      << "if (-not [string]::IsNullOrWhiteSpace($staging)) {\n"
      << "  $deadline = (Get-Date).AddSeconds(90)\n"
      << "  while ($true) {\n"
      << "    try {\n"
      << "      Get-ChildItem -LiteralPath $staging -Force | ForEach-Object {\n"
      << "        Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force\n"
      << "      }\n"
      << "      break\n"
      << "    } catch {\n"
      << "      if ((Get-Date) -gt $deadline) { throw }\n"
      << "      Start-Sleep -Seconds 1\n"
      << "    }\n"
      << "  }\n"
      << "  Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue\n"
      << "}\n"
      << "if ($skipRelaunch -ne '1') {\n"
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

}  // namespace

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
    if (!ScheduleInstallAndRelaunch(L"", {}, &error)) {
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
            &error)) {
      result->Error("InstallError", error);
      return;
    }

    result->Success();
    ExitProcess(0);
  } else if (method_call.method_name().compare("getExecutablePath") == 0) {
    result->Success(flutter::EncodableValue(WideToUtf8(CurrentExecutablePath())));
  } else if (method_call.method_name().compare("getCurrentVersion") == 0) {
    const std::wstring executable_path = CurrentExecutablePath();
    DWORD version_handle = 0;
    const DWORD version_size =
        GetFileVersionInfoSizeW(executable_path.c_str(), &version_handle);

    if (version_size == 0) {
      result->Error("VersionError", "Unable to get version size.");
      return;
    }

    std::vector<BYTE> version_data(version_size);
    if (!GetFileVersionInfoW(executable_path.c_str(), version_handle,
                             version_size, version_data.data())) {
      result->Error("VersionError", "Unable to get version info.");
      return;
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
      result->Error("VersionError", "Unable to get translation info.");
      return;
    }

    wchar_t sub_block[50];
    swprintf_s(sub_block, L"\\StringFileInfo\\%04x%04x\\ProductVersion",
               translation[0].language, translation[0].code_page);

    LPBYTE buffer = nullptr;
    UINT size = 0;
    if (!VerQueryValueW(version_data.data(), sub_block,
                        reinterpret_cast<LPVOID*>(&buffer), &size)) {
      result->Error("VersionError", "Unable to query product version.");
      return;
    }

    std::wstring product_version(reinterpret_cast<wchar_t*>(buffer));
    const size_t plus_position = product_version.find(L'+');
    if (plus_position == std::wstring::npos ||
        plus_position + 1 >= product_version.length()) {
      result->Error("VersionError", "Invalid product version format.");
      return;
    }

    std::wstring build_number = product_version.substr(plus_position + 1);
    const size_t last_character = build_number.find_last_not_of(L" \t\r\n");
    if (last_character == std::wstring::npos) {
      result->Error("VersionError", "Invalid product version format.");
      return;
    }
    build_number.erase(last_character + 1);
    result->Success(flutter::EncodableValue(WideToUtf8(build_number)));
  } else {
    result->NotImplemented();
  }
}

}  // namespace desktop_updater
