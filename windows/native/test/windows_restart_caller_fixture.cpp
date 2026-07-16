#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

#include "desktop_updater_native.h"

namespace {

std::wstring EnvironmentValue(const wchar_t* name) {
  const DWORD required = GetEnvironmentVariableW(name, nullptr, 0);
  if (required == 0) return L"";
  std::vector<wchar_t> buffer(required);
  const DWORD written =
      GetEnvironmentVariableW(name, buffer.data(), required);
  return written > 0 && written < required
             ? std::wstring(buffer.data(), written)
             : L"";
}

bool WriteProof(const std::filesystem::path& path,
                const std::string& value) {
  const std::filesystem::path temporary = path.wstring() + L".tmp";
  std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
  output << value;
  output.close();
  return output.good() &&
         MoveFileExW(temporary.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

std::filesystem::path CurrentExecutablePath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  for (;;) {
    const DWORD length = GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) return {};
    if (length < buffer.size() - 1) {
      return std::filesystem::path(std::wstring(buffer.data(), length));
    }
    if (buffer.size() >
        static_cast<std::size_t>(std::numeric_limits<DWORD>::max() / 2)) {
      return {};
    }
    buffer.resize(buffer.size() * 2);
  }
}

bool EnvironmentHandleIsClosed(const wchar_t* name) {
  const std::wstring encoded = EnvironmentValue(name);
  if (encoded.empty()) return false;
  std::uintptr_t value = 0;
  for (const wchar_t character : encoded) {
    if (character < L'0' || character > L'9') return false;
    const std::uintptr_t digit = character - L'0';
    if (value > (std::numeric_limits<std::uintptr_t>::max() - digit) / 10) {
      return false;
    }
    value = value * 10 + digit;
  }
  DWORD flags = 0;
  SetLastError(ERROR_SUCCESS);
  return value != 0 &&
         !GetHandleInformation(reinterpret_cast<HANDLE>(value), &flags) &&
         GetLastError() == ERROR_INVALID_HANDLE;
}

}  // namespace

int wmain(int argument_count, wchar_t** arguments) {
  if (!desktop_updater::native::AwaitRestartParentExitIfRequested()) {
    return 5;
  }
  const std::filesystem::path proof(
      EnvironmentValue(L"DESKTOP_UPDATER_TEST_RESTART_PROOF"));
  const std::filesystem::path exit_proof(
      EnvironmentValue(L"DESKTOP_UPDATER_TEST_RESTART_EXIT_PROOF"));

  if (argument_count == 1 && !proof.empty()) {
    const bool exact_executable =
        std::filesystem::equivalent(
            CurrentExecutablePath(),
            std::filesystem::path(EnvironmentValue(
                L"DESKTOP_UPDATER_TEST_RESTART_EXECUTABLE")));
    return WriteProof(
               proof,
               std::string(std::filesystem::exists(exit_proof)
                               ? "restarted-after-exit\n"
                               : "restarted-before-exit\n") +
                   "unrelated-handle-closed=" +
                   (EnvironmentHandleIsClosed(
                        L"DESKTOP_UPDATER_TEST_RESTART_UNRELATED_HANDLE")
                        ? "true\n"
                        : "false\n") +
                   "exact-executable=" +
                   (exact_executable ? "true\n" : "false\n"))
               ? 0
               : 3;
  }

  if (argument_count == 2 && std::wstring(arguments[1]) == L"--restart") {
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;
    const HANDLE unrelated = CreateEventW(&attributes, TRUE, FALSE, nullptr);
    if (unrelated == nullptr) return 6;
    SetEnvironmentVariableW(
        L"DESKTOP_UPDATER_TEST_RESTART_UNRELATED_HANDLE",
        std::to_wstring(reinterpret_cast<std::uintptr_t>(unrelated)).c_str());
    SetEnvironmentVariableW(
        L"DESKTOP_UPDATER_TEST_RESTART_EXECUTABLE",
        CurrentExecutablePath().c_str());
    const auto result =
        desktop_updater::native::RestartCurrentApplication();
    if (!result.ok) {
      CloseHandle(unrelated);
      std::cerr << result.error_message << '\n';
      return 1;
    }
    Sleep(300);
    const bool wrote_exit =
        WriteProof(exit_proof, "old-process-exiting\n");
    CloseHandle(unrelated);
    return wrote_exit ? 0 : 4;
  }

  return 2;
}
