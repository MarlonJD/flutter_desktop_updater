#include "desktop_updater_plugin.h"

#include <VersionHelpers.h>
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <filesystem>
#include <sstream>
#include <string>
#include <variant>
#include <vector>

#include "desktop_updater_native.h"

namespace desktop_updater {
namespace {

namespace fs = std::filesystem;

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
  return value == nullptr ? L"" : Utf8ToWide(*value);
}

std::wstring StringFromArguments(const flutter::EncodableMap& arguments,
                                 const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) return L"";
  const auto* value = std::get_if<std::string>(&iterator->second);
  return value == nullptr ? L"" : Utf8ToWide(*value);
}

std::vector<std::wstring> StringListFromArguments(
    const flutter::EncodableMap& arguments,
    const char* key) {
  std::vector<std::wstring> result;
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) return result;
  const auto* values = std::get_if<flutter::EncodableList>(&iterator->second);
  if (values == nullptr) return result;
  for (const auto& value : *values) {
    if (const auto* text = std::get_if<std::string>(&value)) {
      result.push_back(Utf8ToWide(*text));
    }
  }
  return result;
}

bool ScheduleNativeInstall(
    const desktop_updater::native::InstallRequest& request,
    std::string* error) {
  const desktop_updater::native::InstallResult native_result =
      desktop_updater::native::ScheduleInstallAndRelaunch(request);
  if (!native_result.ok) {
    *error = native_result.error_message;
    return false;
  }
  return true;
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
    desktop_updater::native::InstallRequest request;
    request.request_elevation_if_needed = false;
    std::string error;
    if (!ScheduleNativeInstall(request, &error)) {
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

    desktop_updater::native::InstallRequest request;
    request.staging_path = Utf8ToWide(*staging_path);
    request.install_root = StringFromArguments(*arguments, "installRoot");
    request.executable_relative_path =
        StringFromArguments(*arguments, "executableRelativePath");
    request.expected_package_id = StringFromArguments(*arguments, "packageId");
    if (request.install_root.empty() &&
        request.executable_relative_path.empty()) {
      const fs::path current_executable(CurrentExecutablePath());
      request.install_root = current_executable.parent_path().wstring();
      request.executable_relative_path =
          current_executable.filename().wstring();
    }
    request.removed_files = RemovedFilesFromArguments(*arguments);
    request.diagnostics_log_path = DiagnosticsLogPathFromArguments(*arguments);
    request.expected_provenance_sha256 = StringFromArguments(
        *arguments, "stageProvenanceSha256");
    request.expected_artifact_sha256 = StringFromArguments(
        *arguments, "expectedArtifactSha256");
    request.allowed_signer_thumbprints = StringListFromArguments(
        *arguments, "allowedSignerThumbprints");
    request.request_elevation_if_needed = true;
    std::string error;
    if (!ScheduleNativeInstall(request, &error)) {
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
