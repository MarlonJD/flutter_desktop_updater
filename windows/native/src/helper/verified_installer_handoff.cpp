#include "install_strategy.h"

#include <windows.h>

#include <sstream>
#include <utility>

#include "helper_authenticode.h"

namespace desktop_updater::helper {
namespace {

void ValidateExpectation(const WindowsInstallerExpectation& expectation) {
  if (expectation.installer_path.empty() ||
      expectation.authenticode_publisher.empty() ||
      expectation.installer_sha256.size() != 64 ||
      expectation.package_id.empty() || expectation.expected_version.empty() ||
      expectation.installed_executable_path.empty() ||
      expectation.installed_executable_sha256.size() != 64) {
    throw WindowsInstallStrategyError("invalid Inno installer expectation");
  }
}

std::wstring Quote(const std::wstring& value) {
  std::wstring result = L"\"";
  std::size_t backslashes = 0;
  for (wchar_t character : value) {
    if (character == L'\\') {
      ++backslashes;
      continue;
    }
    if (character == L'\"') {
      result.append(backslashes * 2 + 1, L'\\');
      result.push_back(character);
      backslashes = 0;
      continue;
    }
    result.append(backslashes, L'\\');
    backslashes = 0;
    result.push_back(character);
  }
  result.append(backslashes * 2, L'\\');
  result.push_back(L'\"');
  return result;
}

void VerifyExecutable(const std::filesystem::path& path,
                      const std::wstring& publisher,
                      const std::string& sha256) {
  const auto verified = VerifyWindowsExecutable(path);
  if (!verified.signature_valid || verified.publisher != publisher ||
      verified.sha256 != sha256 ||
      !VerifyWindowsExecutableStillMatches(path, verified)) {
    throw WindowsInstallStrategyError(
        "Authenticode executable identity mismatch");
  }
}

}  // namespace

std::vector<std::wstring> FixedWindowsInnoArguments() {
  return {L"/VERYSILENT", L"/SUPPRESSMSGBOXES", L"/NORESTART", L"/SP-"};
}

void AuthenticodeWindowsInstallerVerifier::VerifyInstaller(
    const WindowsInstallerExpectation& expectation) {
  ValidateExpectation(expectation);
  VerifyExecutable(expectation.installer_path,
                   expectation.authenticode_publisher,
                   expectation.installer_sha256);
}

void AuthenticodeWindowsInstallerVerifier::VerifyInstalledPackage(
    const WindowsInstallerExpectation& expectation) {
  ValidateExpectation(expectation);
  VerifyExecutable(expectation.installed_executable_path,
                   expectation.authenticode_publisher,
                   expectation.installed_executable_sha256);
}

std::string CreateProcessWindowsInstallerRunner::Launch(
    const std::filesystem::path& verified_installer,
    const std::vector<std::wstring>& fixed_arguments) {
  if (fixed_arguments != FixedWindowsInnoArguments()) {
    throw WindowsInstallStrategyError("non-fixed Inno arguments rejected");
  }
  std::wstring command = Quote(verified_installer.wstring());
  for (const auto& argument : fixed_arguments) {
    command += L" " + Quote(argument);
  }
  std::vector<wchar_t> mutable_command(command.begin(), command.end());
  mutable_command.push_back(L'\0');
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(verified_installer.c_str(), mutable_command.data(),
                      nullptr, nullptr, FALSE, CREATE_UNICODE_ENVIRONMENT,
                      nullptr, verified_installer.parent_path().c_str(),
                      &startup, &process)) {
    throw WindowsInstallStrategyError("fixed Inno CreateProcessW failed");
  }
  CloseHandle(process.hThread);
  const DWORD process_id = process.dwProcessId;
  const DWORD wait = WaitForSingleObject(process.hProcess, INFINITE);
  DWORD exit_code = 1;
  const bool exited = wait == WAIT_OBJECT_0 &&
                      GetExitCodeProcess(process.hProcess, &exit_code) != FALSE;
  CloseHandle(process.hProcess);
  if (!exited || exit_code != 0) {
    throw WindowsInstallStrategyError("verified Inno installer failed");
  }
  return "inno-process:" + std::to_string(process_id);
}

WindowsInstallerTransaction ExecuteVerifiedWindowsInstallerHandoff(
    const WindowsInstallerExpectation& expectation,
    WindowsInstallerVerifier& verifier,
    WindowsFixedInstallerRunner& runner) {
  ValidateExpectation(expectation);
  verifier.VerifyInstaller(expectation);
  std::string identity =
      runner.Launch(expectation.installer_path, FixedWindowsInnoArguments());
  if (identity.empty()) {
    throw WindowsInstallStrategyError("provider transaction identity missing");
  }
  verifier.VerifyInstalledPackage(expectation);
  return {std::move(identity), true};
}

WindowsInstallerTransaction RecoverVerifiedWindowsInstallerHandoff(
    const WindowsInstallerExpectation& expectation,
    const std::string& transaction_identity,
    WindowsInstallerVerifier& verifier) {
  if (transaction_identity.empty()) return {transaction_identity, false};
  try {
    verifier.VerifyInstalledPackage(expectation);
    return {transaction_identity, true};
  } catch (const std::exception&) {
    return {transaction_identity, false};
  }
}

}  // namespace desktop_updater::helper
