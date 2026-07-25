#include "desktop_updater_plugin.h"

#include <windows.h>
#include <VersionHelpers.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <desktop_updater_native.h>

#include <memory>
#include <sstream>
#include <string>
#include <variant>
#include <vector>

namespace desktop_updater {
namespace native = ::desktop_updater_native;

namespace {

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
      removed_files.push_back(native::Utf8ToWide(*item));
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

  return native::Utf8ToWide(*value);
}

bool ReadCurrentVersionOrReturnError(
    std::wstring* product_version,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  std::string error;
  if (!native::ReadCurrentProductVersion(product_version, &error)) {
    result->Error("VersionError", error);
    return false;
  }
  return true;
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
    native::InstallRequest request;
    request.request_elevation_if_needed = false;
    const native::InstallResult install_result =
        native::ScheduleInstallAndRelaunch(request);
    if (!install_result.ok) {
      result->Error("RestartError", install_result.error);
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

    native::InstallRequest request;
    request.staging_path = native::Utf8ToWide(*staging_path);
    request.removed_files = RemovedFilesFromArguments(*arguments);
    request.diagnostics_log_path = DiagnosticsLogPathFromArguments(*arguments);
    request.request_elevation_if_needed = true;
    const native::InstallResult install_result =
        native::ScheduleInstallAndRelaunch(request);
    if (!install_result.ok) {
      result->Error("InstallError", install_result.error);
      return;
    }

    result->Success();
    ExitProcess(0);
  } else if (method_call.method_name().compare("getExecutablePath") == 0) {
    result->Success(
        flutter::EncodableValue(
            native::WideToUtf8(native::CurrentExecutablePath())));
  } else if (method_call.method_name().compare("getCurrentVersion") == 0) {
    std::wstring product_version;
    if (!ReadCurrentVersionOrReturnError(&product_version, result)) {
      return;
    }

    std::wstring build_number;
    const native::ProductVersionBuildParseResult parse_result =
        native::ParseProductVersionBuildNumber(product_version, &build_number);
    if (parse_result == native::ProductVersionBuildParseResult::kInvalid) {
      result->Error("VersionError", "Invalid product version format.");
      return;
    }

    if (parse_result ==
        native::ProductVersionBuildParseResult::kNoBuildNumber) {
      result->Success(flutter::EncodableValue());
      return;
    }

    result->Success(
        flutter::EncodableValue(native::WideToUtf8(build_number)));
  } else if (method_call.method_name().compare("getCurrentVersionInfo") ==
             0) {
    std::wstring product_version;
    if (!ReadCurrentVersionOrReturnError(&product_version, result)) {
      return;
    }

    std::wstring build_number;
    const native::ProductVersionBuildParseResult parse_result =
        native::ParseProductVersionBuildNumber(product_version, &build_number);
    if (parse_result == native::ProductVersionBuildParseResult::kInvalid) {
      result->Error("VersionError", "Invalid product version format.");
      return;
    }

    flutter::EncodableMap version_info;
    version_info[flutter::EncodableValue("version")] =
        flutter::EncodableValue(native::WideToUtf8(product_version));
    version_info[flutter::EncodableValue("buildNumber")] =
        parse_result == native::ProductVersionBuildParseResult::kBuildNumber
            ? flutter::EncodableValue(native::WideToUtf8(build_number))
            : flutter::EncodableValue();
    result->Success(flutter::EncodableValue(version_info));
  } else {
    result->NotImplemented();
  }
}

}  // namespace desktop_updater
