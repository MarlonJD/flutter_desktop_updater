#include "desktop_updater_plugin.h"

#include <VersionHelpers.h>
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <filesystem>
#include <memory>
#include <regex>
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

bool ReadRequiredInstallString(const flutter::EncodableMap& arguments,
                               const char* key,
                               std::wstring* value,
                               std::string* error) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    *error = std::string(key) + " is required.";
    return false;
  }
  const auto* text = std::get_if<std::string>(&iterator->second);
  if (text == nullptr || text->empty()) {
    *error = std::string(key) + " must be a non-empty string.";
    return false;
  }
  *value = Utf8ToWide(*text);
  if (value->empty()) {
    *error = std::string(key) + " must contain valid UTF-8.";
    return false;
  }
  return true;
}

bool HandoffNativeInstall(
    const desktop_updater::native::InstallRequest& request,
    const std::string& request_transaction_id,
    std::string* error,
    bool* recovery_required) {
  *recovery_required = false;
  desktop_updater::native::InstallReservation reservation;
  const desktop_updater::native::InstallResult prepared =
      desktop_updater::native::PrepareInstall(
          request, request_transaction_id, &reservation);
  if (!prepared.ok) {
    *error = prepared.error_message;
    return false;
  }
  const desktop_updater::native::InstallTransactionStatus status =
      desktop_updater::native::CommitAfterExit(reservation);
  if (!IsAcceptedInstallHandoff(reservation, status)) {
    *error = status.detail.empty()
                 ? "Native install helper commit was not accepted."
                 : status.detail;
    *recovery_required = true;
    return false;
  }
  return true;
}

flutter::EncodableValue RecoveryRequiredErrorDetails() {
  flutter::EncodableMap details;
  details[flutter::EncodableValue("recoveryRequired")] =
      flutter::EncodableValue(true);
  return flutter::EncodableValue(details);
}

std::string TransactionStateName(
    desktop_updater::native::InstallTransactionState state) {
  using State = desktop_updater::native::InstallTransactionState;
  switch (state) {
    case State::kPrepared: return "prepared";
    case State::kCommitAccepted: return "commitAccepted";
    case State::kCompleted: return "completed";
    case State::kCancelled: return "cancelled";
    case State::kExpired: return "expired";
    case State::kRolledBack: return "rolledBack";
    case State::kManualActionRequired: return "manualActionRequired";
    case State::kUnknown: return "unknown";
  }
  return "unknown";
}

std::string TransactionResultName(
    desktop_updater::native::InstallTransactionResultCode code) {
  using Code = desktop_updater::native::InstallTransactionResultCode;
  switch (code) {
    case Code::kAccepted: return "accepted";
    case Code::kSucceeded: return "succeeded";
    case Code::kRejected: return "rejected";
    case Code::kEndpointUnavailable: return "endpointUnavailable";
    case Code::kAuthenticationFailed: return "authenticationFailed";
    case Code::kInvalidResponse: return "invalidResponse";
    case Code::kRecoveryRequired: return "recoveryRequired";
    case Code::kRelaunchFailure: return "relaunchFailure";
    case Code::kNone: return "none";
  }
  return "none";
}

flutter::EncodableValue TransactionStatusValue(
    const desktop_updater::native::InstallTransactionStatus& status) {
  flutter::EncodableMap value;
  value[flutter::EncodableValue("transactionId")] =
      flutter::EncodableValue(status.transaction_id);
  value[flutter::EncodableValue("state")] =
      flutter::EncodableValue(TransactionStateName(status.state));
  value[flutter::EncodableValue("resultCode")] =
      flutter::EncodableValue(TransactionResultName(status.result_code));
  value[flutter::EncodableValue("detail")] =
      flutter::EncodableValue(status.detail);
  value[flutter::EncodableValue("responseDigestSha256")] =
      flutter::EncodableValue(status.response_digest_sha256);
  value[flutter::EncodableValue("helperEndpointIdentitySha256")] =
      flutter::EncodableValue(status.helper_endpoint_identity_sha256);
  return flutter::EncodableValue(value);
}

bool ReadTransactionId(const flutter::EncodableValue* arguments,
                       std::string* transaction_id) {
  const auto* values =
      arguments == nullptr
          ? nullptr
          : std::get_if<flutter::EncodableMap>(arguments);
  if (values == nullptr) return false;
  const auto entry = values->find(flutter::EncodableValue("transactionId"));
  if (entry == values->end()) return false;
  const auto* value = std::get_if<std::string>(&entry->second);
  if (value == nullptr || value->empty()) return false;
  *transaction_id = *value;
  return true;
}

}  // namespace

bool IsCanonicalInstallTransactionId(const std::string& transaction_id) {
  static const std::regex transaction_id_pattern(
      "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-"
      "[0-9a-f]{12}$");
  return std::regex_match(transaction_id, transaction_id_pattern);
}

bool IsAcceptedInstallHandoff(
    const native::InstallReservation& reservation,
    const native::InstallTransactionStatus& status) {
  const bool accepted_state =
      status.state == native::InstallTransactionState::kCommitAccepted ||
      status.state == native::InstallTransactionState::kCompleted;
  const bool accepted_result =
      status.result_code == native::InstallTransactionResultCode::kAccepted ||
      status.result_code == native::InstallTransactionResultCode::kSucceeded;
  return accepted_state && accepted_result &&
         status.transaction_id == reservation.transaction_id &&
         status.response_digest_sha256 == reservation.response_digest_sha256 &&
         status.helper_endpoint_identity_sha256 ==
             reservation.helper_endpoint_identity_sha256;
}

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
  if (!desktop_updater::native::AwaitRestartParentExitIfRequested()) {
    ExitProcess(ERROR_INVALID_DATA);
  }
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
    const desktop_updater::native::InstallResult restart =
        desktop_updater::native::RestartCurrentApplication();
    if (!restart.ok) {
      result->Error("RestartError", restart.error_message);
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
    if (arguments->size() != 5) {
      result->Error("InvalidArguments",
                    "installUpdate expects exactly five arguments.");
      return;
    }

    desktop_updater::native::InstallRequest request;
    std::wstring transaction_id;
    std::string argument_error;
    if (!ReadRequiredInstallString(*arguments, "stagingPath",
                                   &request.staging_path, &argument_error) ||
        !ReadRequiredInstallString(*arguments, "expectedPackageId",
                                   &request.expected_package_id,
                                   &argument_error) ||
        !ReadRequiredInstallString(*arguments, "expectedArtifactSha256",
                                   &request.expected_artifact_sha256,
                                   &argument_error) ||
        !ReadRequiredInstallString(*arguments, "stageProvenanceSha256",
                                   &request.expected_provenance_sha256,
                                   &argument_error) ||
        !ReadRequiredInstallString(*arguments, "transactionId",
                                   &transaction_id, &argument_error)) {
      result->Error("InvalidArguments", argument_error);
      return;
    }

    const std::string request_transaction_id = WideToUtf8(transaction_id);
    if (!IsCanonicalInstallTransactionId(request_transaction_id)) {
      result->Error(
          "InvalidArguments",
          "transactionId must be a canonical lowercase UUIDv4.");
      return;
    }
    const fs::path current_executable(CurrentExecutablePath());
    if (current_executable.empty() ||
        current_executable.parent_path().empty() ||
        current_executable.filename().empty()) {
      result->Error("InstallError",
                    "Unable to derive the running Windows install target.");
      return;
    }
    request.install_root = current_executable.parent_path().wstring();
    request.executable_relative_path = current_executable.filename().wstring();

    std::string error;
    bool recovery_required = false;
    if (!HandoffNativeInstall(request, request_transaction_id, &error,
                              &recovery_required)) {
      if (recovery_required) {
        result->Error("InstallError", error, RecoveryRequiredErrorDetails());
      } else {
        result->Error("InstallError", error);
      }
      return;
    }
    result->Success();
    ExitProcess(0);
  } else if (method_call.method_name().compare("queryInstallTransaction") ==
             0 ||
             method_call.method_name().compare(
                 "resolvePendingInstallTransactionAfterExit") == 0) {
    std::string transaction_id;
    if (!ReadTransactionId(method_call.arguments(), &transaction_id)) {
      result->Error("InvalidArguments", "transactionId must be a string.");
      return;
    }
    const bool query =
        method_call.method_name().compare("queryInstallTransaction") == 0;
    const bool resolve_after_exit =
        method_call.method_name().compare(
            "resolvePendingInstallTransactionAfterExit") == 0;
    const native::InstallTransactionStatus status =
        query ? native::QueryTransaction(transaction_id)
              : native::ResolvePendingInstallAfterExit(transaction_id);
    result->Success(TransactionStatusValue(status));
    if (resolve_after_exit &&
        status.state == native::InstallTransactionState::kPrepared &&
        status.result_code ==
            native::InstallTransactionResultCode::kRecoveryRequired) {
      ExitProcess(0);
    }
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
