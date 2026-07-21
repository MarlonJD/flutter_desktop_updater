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

bool EnvironmentHandleWasNotInherited(const wchar_t* handle_name,
                                      const wchar_t* event_name) {
  const std::wstring encoded = EnvironmentValue(handle_name);
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
  const HANDLE candidate = reinterpret_cast<HANDLE>(value);
  if (value == 0) return false;
  if (!GetHandleInformation(candidate, &flags)) {
    return GetLastError() == ERROR_INVALID_HANDLE;
  }
  const std::wstring expected_name = EnvironmentValue(event_name);
  if (expected_name.empty()) return false;
  const HANDLE reference =
      OpenEventW(SYNCHRONIZE, FALSE, expected_name.c_str());
  if (reference == nullptr) {
    return GetLastError() == ERROR_FILE_NOT_FOUND;
  }
  using CompareObjectHandlesFunction = BOOL(WINAPI*)(HANDLE, HANDLE);
  const HMODULE kernelbase = GetModuleHandleW(L"kernelbase.dll");
  const auto compare =
      kernelbase == nullptr
          ? nullptr
          : reinterpret_cast<CompareObjectHandlesFunction>(
                GetProcAddress(kernelbase, "CompareObjectHandles"));
  const bool same_object =
      compare != nullptr && compare(candidate, reference) != FALSE;
  CloseHandle(reference);
  return compare != nullptr && !same_object;
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
                   (EnvironmentHandleWasNotInherited(
                        L"DESKTOP_UPDATER_TEST_RESTART_UNRELATED_HANDLE",
                        L"DESKTOP_UPDATER_TEST_RESTART_UNRELATED_EVENT")
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
    const std::wstring unrelated_name =
        L"Local\\DesktopUpdaterRestartUnrelated-" +
        std::to_wstring(GetCurrentProcessId()) + L"-" +
        std::to_wstring(GetTickCount64());
    const HANDLE unrelated =
        CreateEventW(&attributes, TRUE, FALSE, unrelated_name.c_str());
    if (unrelated == nullptr) return 6;
    SetEnvironmentVariableW(
        L"DESKTOP_UPDATER_TEST_RESTART_UNRELATED_HANDLE",
        std::to_wstring(reinterpret_cast<std::uintptr_t>(unrelated)).c_str());
    SetEnvironmentVariableW(L"DESKTOP_UPDATER_TEST_RESTART_UNRELATED_EVENT",
                            unrelated_name.c_str());
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
