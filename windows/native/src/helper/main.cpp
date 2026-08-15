#include <windows.h>

#include <shellapi.h>

#include <string>

#include "named_pipe_transport.h"
#include "windows_helper_bootstrap.h"
#include "windows_helper_diagnostics.h"
#include "windows_install_authorizer.h"
#include "windows_one_shot_transport.h"
#include "windows_persistent_recovery.h"
#include "windows_portable_recovery_host.h"
#include "windows_recovery_host.h"
#include "windows_recovery_transport.h"

#ifndef ERROR_ELEVATION_REQUIRED
#define ERROR_ELEVATION_REQUIRED 740L
#endif

namespace {

constexpr DWORD kWindowsProtectedHelperStartupTimeoutMilliseconds =
    30 * 1000;
constexpr DWORD kWindowsPortableHelperStartupTimeoutMilliseconds =
    desktop_updater::helper::kPortableWindowsHelperStartupTimeoutMilliseconds;

bool IsElevated() {
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
    return false;
  }
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  const bool elevated =
      GetTokenInformation(raw_token, TokenElevation, &elevation,
                          sizeof(elevation), &size) != FALSE &&
      elevation.TokenIsElevated != 0;
  CloseHandle(raw_token);
  return elevated;
}

bool TryReadExactAsciiArgument(const wchar_t* value,
                               std::size_t expected_length,
                               std::string* result) {
  if (value == nullptr || result == nullptr) return false;
  const std::wstring wide(value);
  if (wide.size() != expected_length) return false;
  std::string ascii;
  ascii.reserve(wide.size());
  for (wchar_t character : wide) {
    if (character > 0x7f) return false;
    ascii.push_back(static_cast<char>(character));
  }
  *result = ascii;
  return true;
}

int Run(int argument_count, wchar_t** arguments) {
  if (argument_count == 2 && std::wstring(arguments[1]) == L"--version") {
    return 0;
  }
  if (argument_count == 2 &&
      std::wstring(arguments[1]) == L"--register-endpoint") {
    if (!IsElevated()) return ERROR_ELEVATION_REQUIRED;
    try {
      auto bootstrap =
          desktop_updater::helper::LoadWindowsHelperBootstrapForRegistration();
      desktop_updater::helper::RegisterProtectedWindowsHelperEndpoint(
          bootstrap.endpoint());
      return ERROR_SUCCESS;
    } catch (const std::exception&) {
      return ERROR_ACCESS_DENIED;
    }
  }
  if (argument_count == 2 &&
      std::wstring(arguments[1]) == L"--validate-endpoint") {
    if (!IsElevated()) return ERROR_ELEVATION_REQUIRED;
    try {
      (void)desktop_updater::helper::
          LoadWindowsHelperBootstrapForRegistration();
      return ERROR_SUCCESS;
    } catch (const std::exception&) {
      return ERROR_ACCESS_DENIED;
    }
  }
  if (argument_count == 3 &&
      std::wstring(arguments[1]) == L"--portable-recover-current") {
    if (IsElevated()) return ERROR_ELEVATION_REQUIRED;
    std::string transaction_id;
    if (!TryReadExactAsciiArgument(arguments[2], 36, &transaction_id)) {
      return ERROR_BAD_ARGUMENTS;
    }
    try {
      auto bootstrap = desktop_updater::helper::
          LoadPortableWindowsRecoveryHostBootstrap();
      desktop_updater::helper::RecordWindowsHelperEvent(
          desktop_updater::helper::WindowsHelperEvent::kHelperScheduled);
      auto definition = desktop_updater::helper::
          BuildPortableWindowsRecoveryHostTaskDefinition(
              bootstrap.endpoint, transaction_id, std::string(43, 'A'));
      desktop_updater::helper::WindowsPersistentRecoveryService recovery(
          bootstrap.policy);
      desktop_updater::helper::
          TaskSchedulerPortableWindowsRecoveryHostController controller;
      desktop_updater::runtime::internal::NativeInstallRecoveryResultV1
          result;
      (void)desktop_updater::helper::
          RunPortableWindowsAutonomousRecoveryBoundary(
              controller, definition,
              [&bootstrap, &definition, &recovery, &result,
               &transaction_id]() {
                result = recovery.RecoverAutonomously(
                    transaction_id,
                    [&bootstrap, &definition, &transaction_id](
                        const std::string& recovery_ready_nonce) {
                      definition = desktop_updater::helper::
                          BuildPortableWindowsRecoveryHostTaskDefinition(
                              bootstrap.endpoint, transaction_id,
                              recovery_ready_nonce);
                      desktop_updater::helper::
                          SignalPortableWindowsRecoveryHostReady(definition);
                      desktop_updater::helper::RecordWindowsHelperEvent(
                          desktop_updater::helper::WindowsHelperEvent::
                              kPortableStagePayloadIdentityFailure);
                    });
                return desktop_updater::helper::
                    PortableWindowsRecoveryResolution{
                        result.result_code, result.verified_outcome};
              });
      if (result.result_code == "completed" ||
          result.result_code == "rolledBack" ||
          result.result_code == "relaunchFailure") {
        return ERROR_SUCCESS;
      }
      return result.result_code == "helperUnavailable"
                 ? ERROR_FILE_NOT_FOUND
                 : ERROR_RETRY;
    } catch (const std::exception&) {
      desktop_updater::helper::RecordWindowsHelperEvent(
          desktop_updater::helper::WindowsHelperEvent::
              kPortablePreparationFailure);
      return ERROR_ACCESS_DENIED;
    }
  }
  if (argument_count == 3 &&
      std::wstring(arguments[1]) == L"--recover-current") {
    std::string transaction_id;
    if (!TryReadExactAsciiArgument(arguments[2], 36, &transaction_id)) {
      return ERROR_BAD_ARGUMENTS;
    }
    try {
      auto bootstrap = desktop_updater::helper::
          LoadWindowsHelperBootstrapForAutonomousRecovery(transaction_id);
      desktop_updater::helper::RecordWindowsHelperEvent(
          desktop_updater::helper::WindowsHelperEvent::kHelperScheduled);
      auto definition =
          desktop_updater::helper::BuildWindowsRecoveryHostTaskDefinition(
              bootstrap.endpoint(), transaction_id, std::string(43, 'A'));
      desktop_updater::helper::WindowsPersistentRecoveryService recovery(
          bootstrap.policy());
      const auto result = recovery.RecoverAutonomously(
          transaction_id,
          [&bootstrap, &definition, &transaction_id](
              const std::string& recovery_ready_nonce) {
            definition = desktop_updater::helper::
                BuildWindowsRecoveryHostTaskDefinition(
                    bootstrap.endpoint(), transaction_id,
                    recovery_ready_nonce);
            desktop_updater::helper::SignalWindowsRecoveryHostReady(
                definition);
          });
      if (result.result_code != "recoveryRequired") {
        desktop_updater::helper::TaskSchedulerWindowsRecoveryHostController()
            .Disarm(definition);
      }
      if (result.result_code == "completed" ||
          result.result_code == "rolledBack" ||
          result.result_code == "relaunchFailure" ||
          result.result_code == "manualActionRequired") {
        return ERROR_SUCCESS;
      }
      return result.result_code == "helperUnavailable"
                 ? ERROR_FILE_NOT_FOUND
                 : ERROR_RETRY;
    } catch (const std::exception&) {
      return ERROR_ACCESS_DENIED;
    }
  }
  if (argument_count == 5 &&
      std::wstring(arguments[1]) == L"--portable-pipe" &&
      std::wstring(arguments[3]) == L"--nonce") {
    const std::wstring pipe_name(arguments[2]);
    std::string nonce;
    if (!TryReadExactAsciiArgument(arguments[4], 43, &nonce)) {
      return ERROR_BAD_ARGUMENTS;
    }
    enum class PortablePipeStage {
      kConnect,
      kBootstrap,
      kRecoveryHost,
      kSession,
    };
    PortablePipeStage stage = PortablePipeStage::kConnect;
    try {
      return desktop_updater::helper::ConnectPortableHelperToCallerPipe(
          pipe_name, nonce, kWindowsPortableHelperStartupTimeoutMilliseconds,
          [&nonce, &stage](HANDLE pipe,
                           DWORD caller_process_id,
                           HANDLE caller_process) {
            stage = PortablePipeStage::kBootstrap;
            auto bootstrap = desktop_updater::helper::
                LoadPortableWindowsHelperBootstrap(caller_process_id);
            stage = PortablePipeStage::kRecoveryHost;
            const auto recovery_endpoint = desktop_updater::helper::
                ProvisionPortableWindowsRecoveryHost(
                    bootstrap.policy(), bootstrap.helper_identity(),
                    bootstrap.helper_file(), bootstrap.policy_file(),
                    caller_process);
            bootstrap.ReleaseRetainedHandles();
            stage = PortablePipeStage::kSession;
            desktop_updater::helper::RecordWindowsHelperEvent(
                desktop_updater::helper::WindowsHelperEvent::kHelperScheduled);
            desktop_updater::helper::WindowsPortableInstallAuthorizer
                authorizer(bootstrap.policy(), recovery_endpoint,
                           caller_process);
            desktop_updater::helper::RunWindowsPersistentRecoveryPipeSession(
                pipe, caller_process_id, caller_process, nonce,
                bootstrap.policy(), authorizer,
                desktop_updater::helper::SecureWindowsReadyToken,
                desktop_updater::helper::WindowsHelperSha256Hex,
                desktop_updater::helper::WindowsHelperNowUnixMilliseconds,
                300'000,
                kWindowsPortableHelperStartupTimeoutMilliseconds);
          });
    } catch (const std::exception&) {
      using desktop_updater::helper::RecordWindowsHelperEvent;
      using desktop_updater::helper::WindowsHelperEvent;
      switch (stage) {
        case PortablePipeStage::kBootstrap:
          RecordWindowsHelperEvent(
              WindowsHelperEvent::kPortableBootstrapFailure);
          break;
        case PortablePipeStage::kRecoveryHost:
          RecordWindowsHelperEvent(
              WindowsHelperEvent::kPortableRecoveryHostFailure);
          break;
        case PortablePipeStage::kSession:
          RecordWindowsHelperEvent(
              WindowsHelperEvent::kPortableSessionFailure);
          break;
        case PortablePipeStage::kConnect:
          break;
      }
      return ERROR_ACCESS_DENIED;
    }
  }
  if (argument_count != 5 || std::wstring(arguments[1]) != L"--pipe" ||
      std::wstring(arguments[3]) != L"--nonce") {
    return ERROR_BAD_ARGUMENTS;
  }
  if (!IsElevated()) return ERROR_ELEVATION_REQUIRED;

  const std::wstring pipe_name(arguments[2]);
  std::string nonce;
  if (!TryReadExactAsciiArgument(arguments[4], 43, &nonce)) {
    return ERROR_BAD_ARGUMENTS;
  }
  try {
    return desktop_updater::helper::ConnectElevatedHelperToCallerPipe(
        pipe_name, nonce, kWindowsProtectedHelperStartupTimeoutMilliseconds,
        [&nonce](HANDLE pipe,
                 DWORD caller_process_id,
                 HANDLE caller_process) {
          auto bootstrap =
              desktop_updater::helper::LoadWindowsHelperBootstrap(
                  caller_process_id);
          desktop_updater::helper::RecordWindowsHelperEvent(
              desktop_updater::helper::WindowsHelperEvent::kHelperScheduled);
          desktop_updater::helper::WindowsNativeInstallAuthorizer authorizer(
              bootstrap.policy(), bootstrap.endpoint(), caller_process);
          desktop_updater::helper::RunWindowsPersistentRecoveryPipeSession(
              pipe, caller_process_id, caller_process, nonce,
              bootstrap.policy(), authorizer,
              desktop_updater::helper::SecureWindowsReadyToken,
              desktop_updater::helper::WindowsHelperSha256Hex,
              desktop_updater::helper::WindowsHelperNowUnixMilliseconds,
              300'000, kWindowsProtectedHelperStartupTimeoutMilliseconds);
        });
  } catch (const std::exception&) {
    return ERROR_ACCESS_DENIED;
  }
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  int argument_count = 0;
  LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &argument_count);
  if (arguments == nullptr) return ERROR_BAD_ARGUMENTS;
  const int result = Run(argument_count, arguments);
  LocalFree(arguments);
  return result;
}
