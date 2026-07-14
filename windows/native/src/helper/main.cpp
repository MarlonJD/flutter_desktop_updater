#include <windows.h>

#include <shellapi.h>

#include <string>

#include "named_pipe_transport.h"
#include "windows_helper_bootstrap.h"
#include "windows_install_authorizer.h"
#include "windows_one_shot_transport.h"

namespace {

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

int Run(int argument_count, wchar_t** arguments) {
  if (argument_count == 2 && std::wstring(arguments[1]) == L"--version") {
    return 0;
  }
  if (argument_count != 5 || std::wstring(arguments[1]) != L"--pipe" ||
      std::wstring(arguments[3]) != L"--nonce") {
    return ERROR_BAD_ARGUMENTS;
  }
  if (!IsElevated()) return ERROR_ELEVATION_REQUIRED;

  const std::wstring pipe_name(arguments[2]);
  const std::wstring wide_nonce(arguments[4]);
  if (wide_nonce.size() != 43) return ERROR_BAD_ARGUMENTS;
  const std::string nonce(wide_nonce.begin(), wide_nonce.end());
  try {
    return desktop_updater::helper::ConnectElevatedHelperToCallerPipe(
        pipe_name, nonce, 30'000,
        [](HANDLE pipe, DWORD caller_process_id) {
          auto bootstrap =
              desktop_updater::helper::LoadWindowsHelperBootstrap(
                  caller_process_id);
          desktop_updater::helper::WindowsNativeInstallAuthorizer authorizer(
              bootstrap.policy());
          desktop_updater::helper::RunWindowsOneShotPipeSession(
              pipe, caller_process_id, bootstrap.policy(), authorizer,
              desktop_updater::helper::SecureWindowsReadyToken,
              desktop_updater::helper::WindowsHelperSha256Hex,
              desktop_updater::helper::WindowsHelperNowUnixMilliseconds,
              300'000, 30'000);
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
