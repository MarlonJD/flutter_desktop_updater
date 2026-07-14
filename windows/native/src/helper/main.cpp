#include <windows.h>

#include <shellapi.h>

#include <string>

#include "named_pipe_transport.h"

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
        pipe_name, nonce, 30'000);
  } catch (const desktop_updater::helper::NamedPipeTransportError&) {
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
