#include "windows_inno_policy.h"

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <set>

#include "helper_authenticode.h"
#include "windows_uninstall_record_proof.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ReleaseDescriptor;

[[noreturn]] void Fail(const std::string& detail) {
  throw WindowsInnoPolicyError(detail);
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) Fail("Inno descriptor string is empty");
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) Fail("Inno descriptor string is not UTF-8");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    Fail("Inno descriptor UTF-8 conversion failed");
  }
  return result;
}

std::string LowerSha256(const std::string& value) {
  if (value.size() != 64 ||
      !std::all_of(value.begin(), value.end(), [](unsigned char byte) {
        return std::isdigit(byte) != 0 ||
               (byte >= 'a' && byte <= 'f') ||
               (byte >= 'A' && byte <= 'F');
      })) {
    Fail("Inno signer certificate SHA-256 is invalid");
  }
  std::string result = value;
  std::transform(result.begin(), result.end(), result.begin(),
                 [](unsigned char byte) {
                   return static_cast<char>(std::tolower(byte));
                 });
  return result;
}

bool SafeLogLeaf(const std::wstring& value) {
  return !value.empty() && value != L"." && value != L".." &&
         value.find_first_of(L"\\/:*?\"<>|") == std::wstring::npos &&
         value.back() != L'.' && value.back() != L' ';
}

bool SafeRelativeExecutable(const std::filesystem::path& value) {
  if (value.empty() || value.is_absolute() ||
      value.lexically_normal() != value || value.filename().empty() ||
      _wcsicmp(value.extension().c_str(), L".exe") != 0) {
    return false;
  }
  for (const auto& segment : value) {
    const std::wstring text = segment.wstring();
    if (text.empty() || text == L"." || text == L".." ||
        text.find_first_of(L":*?\"<>|") != std::wstring::npos ||
        text.back() == L'.' || text.back() == L' ') {
      return false;
    }
  }
  return true;
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

void ValidateExpectation(const ProtectedWindowsInnoExpectation& expectation) {
  const std::filesystem::path installed =
      (expectation.install_root /
       expectation.execution.installed_executable_relative_path)
          .lexically_normal();
  if (expectation.installer_path.empty() ||
      expectation.installer_sha256.size() != 64 ||
      expectation.package_id.empty() || expectation.expected_version.empty() ||
      expectation.expected_build_number < 0 ||
      !expectation.install_root.is_absolute() ||
      expectation.install_root.lexically_normal() != expectation.install_root ||
      !SafeRelativeExecutable(
          expectation.execution.installed_executable_relative_path) ||
      expectation.execution.installed_executable_sha256.size() != 64 ||
      installed.parent_path().empty() ||
      expectation.execution.signer_certificate_sha256.empty()) {
    Fail("protected Inno expectation is invalid");
  }
  const std::wstring root = expectation.install_root.wstring() + L"\\";
  if (installed.wstring().size() <= root.size() ||
      _wcsnicmp(installed.wstring().c_str(), root.c_str(), root.size()) != 0) {
    Fail("protected Inno executable escapes install root");
  }
}

void VerifyAllowedCertificate(
    const std::filesystem::path& executable,
    const std::vector<std::string>& allowed,
    const std::string& expected_file_sha256 = "") {
  const VerifiedWindowsExecutable identity =
      VerifyWindowsExecutable(executable);
  if (!identity.signature_valid ||
      (!expected_file_sha256.empty() &&
       identity.sha256 != expected_file_sha256) ||
      std::find(allowed.begin(), allowed.end(),
                identity.signer_certificate_sha256) == allowed.end() ||
      !VerifyWindowsExecutableStillMatches(executable, identity)) {
    Fail("protected Inno Authenticode identity mismatch");
  }
}

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE value = nullptr) : value_(value) {}
  ~ScopedHandle() {
    if (value_ != nullptr && value_ != INVALID_HANDLE_VALUE) {
      CloseHandle(value_);
    }
  }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
  HANDLE get() const { return value_; }

 private:
  HANDLE value_;
};

}  // namespace

ProtectedWindowsInnoExecutionPolicy ParseProtectedWindowsInnoExecutionPolicy(
    const ReleaseDescriptor& descriptor) {
  if (descriptor.platform != "windows" ||
      descriptor.artifact.kind != "innoInstaller" ||
      descriptor.install.at("strategy").string() != "innoInstaller") {
    Fail("signed descriptor is not a Windows Inno installer");
  }
  const JsonValue& inno = descriptor.install.at("inno");
  ProtectedWindowsInnoExecutionPolicy result;
  result.inherit_install_directory =
      inno.at("inheritInstallDirectory").boolean();
  result.relaunch_after_install = inno.at("relaunchAfterInstall").boolean();
  result.installed_executable_relative_path = std::filesystem::path(
      Utf8ToWide(inno.at("installedExecutableRelativePath").string()));
  result.installed_executable_sha256 =
      LowerSha256(inno.at("installedExecutableSha256").string());
  result.log_file_name = Utf8ToWide(inno.at("logFileName").string());
  if (!result.inherit_install_directory ||
      !SafeRelativeExecutable(result.installed_executable_relative_path) ||
      !SafeLogLeaf(result.log_file_name) ||
      inno.at("requiresElevation").string() != "always") {
    Fail("Inno descriptor does not require protected helper authority");
  }

  const JsonValue& authenticode = inno.at("authenticode");
  if (!authenticode.at("required").boolean()) {
    Fail("protected Inno handoff requires Authenticode");
  }
  const JsonValue* raw_thumbprints =
      authenticode.find("sha256Thumbprints");
  if (raw_thumbprints == nullptr || raw_thumbprints->array().empty()) {
    Fail("protected Inno handoff requires a signer certificate allowlist");
  }
  std::set<std::string> unique_thumbprints;
  for (const JsonValue& value : raw_thumbprints->array()) {
    const std::string thumbprint = LowerSha256(value.string());
    if (!unique_thumbprints.insert(thumbprint).second) {
      Fail("duplicate Inno signer certificate SHA-256");
    }
    result.signer_certificate_sha256.push_back(thumbprint);
  }

  static const std::set<std::string> kAllowedArguments = {
      "/CLOSEAPPLICATIONS", "/FORCECLOSEAPPLICATIONS", "/NOCANCEL",
      "/NORESTART", "/SILENT", "/SP-", "/SUPPRESSMSGBOXES",
      "/VERYSILENT"};
  std::set<std::string> unique_arguments;
  bool has_silent_mode = false;
  bool has_no_restart = false;
  for (const JsonValue& value : inno.at("silentArgs").array()) {
    const std::string argument = value.string();
    if (kAllowedArguments.count(argument) == 0 ||
        !unique_arguments.insert(argument).second) {
      Fail("signed Inno argument vector is not fixed and safe");
    }
    if (argument == "/SILENT" || argument == "/VERYSILENT") {
      if (has_silent_mode) Fail("multiple Inno silent modes are rejected");
      has_silent_mode = true;
    }
    has_no_restart = has_no_restart || argument == "/NORESTART";
    result.silent_arguments.push_back(Utf8ToWide(argument));
  }
  if (!has_silent_mode || !has_no_restart) {
    Fail("Inno handoff must be silent and suppress automatic restart");
  }
  return result;
}

std::vector<std::wstring> BuildProtectedWindowsInnoArguments(
    const ProtectedWindowsInnoExecutionPolicy& policy,
    const std::filesystem::path& install_root,
    const std::filesystem::path& log_root) {
  if (!policy.inherit_install_directory || !install_root.is_absolute() ||
      install_root.lexically_normal() != install_root ||
      !log_root.is_absolute() || log_root.lexically_normal() != log_root ||
      !SafeLogLeaf(policy.log_file_name)) {
    Fail("Inno execution paths are not canonical absolute paths");
  }
  std::vector<std::wstring> result = policy.silent_arguments;
  result.push_back(L"/DIR=" + install_root.wstring());
  result.push_back(L"/LOG=" +
                   (log_root / policy.log_file_name).wstring());
  return result;
}

void AuthenticodeProtectedWindowsInnoVerifier::VerifyInstaller(
    const ProtectedWindowsInnoExpectation& expectation) {
  ValidateExpectation(expectation);
  VerifyAllowedCertificate(expectation.installer_path,
                           expectation.execution.signer_certificate_sha256,
                           expectation.installer_sha256);
}

void AuthenticodeProtectedWindowsInnoVerifier::VerifyInstalledPackage(
    const ProtectedWindowsInnoExpectation& expectation) {
  ValidateExpectation(expectation);
  const std::filesystem::path executable =
      expectation.install_root /
      expectation.execution.installed_executable_relative_path;
  VerifyAllowedCertificate(executable,
                           expectation.execution.signer_certificate_sha256,
                           expectation.execution.installed_executable_sha256);
  if (!FindCanonicalWindowsUninstallRecordVersionBuildProofForTrustedHost(
           expectation.install_root, expectation.package_id,
           expectation.expected_version, expectation.expected_build_number)
           .has_value()) {
    Fail("protected Inno package identity, version, or build mismatch");
  }
}

std::string CreateProcessProtectedWindowsInnoRunner::Launch(
    const ProtectedWindowsInnoExpectation& expectation) {
  ValidateExpectation(expectation);
  const std::vector<std::wstring> arguments =
      BuildProtectedWindowsInnoArguments(
          expectation.execution, expectation.install_root,
          expectation.log_root);
  std::wstring command = Quote(expectation.installer_path.wstring());
  for (const std::wstring& argument : arguments) {
    command += L" " + Quote(argument);
  }
  std::vector<wchar_t> mutable_command(command.begin(), command.end());
  mutable_command.push_back(L'\0');

  ScopedHandle job(CreateJobObjectW(nullptr, nullptr));
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (job.get() == nullptr ||
      !SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation,
                               &limits, sizeof(limits))) {
    Fail("protected Inno kill-on-close job creation failed");
  }
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(expectation.installer_path.c_str(),
                      mutable_command.data(), nullptr, nullptr, FALSE,
                      CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                      nullptr, expectation.installer_path.parent_path().c_str(),
                      &startup, &process)) {
    Fail("protected fixed Inno CreateProcessW failed");
  }
  ScopedHandle process_handle(process.hProcess);
  ScopedHandle thread_handle(process.hThread);
  if (!AssignProcessToJobObject(job.get(), process_handle.get()) ||
      ResumeThread(thread_handle.get()) == static_cast<DWORD>(-1)) {
    TerminateProcess(process_handle.get(), ERROR_PROCESS_ABORTED);
    WaitForSingleObject(process_handle.get(), INFINITE);
    Fail("protected Inno process containment failed");
  }
  const DWORD process_id = process.dwProcessId;
  const DWORD wait = WaitForSingleObject(process_handle.get(), INFINITE);
  DWORD exit_code = ERROR_PROCESS_ABORTED;
  if (wait != WAIT_OBJECT_0 ||
      !GetExitCodeProcess(process_handle.get(), &exit_code) ||
      exit_code != ERROR_SUCCESS) {
    Fail("protected Inno installer failed");
  }
  return "inno-process:" + std::to_string(process_id);
}

ProtectedWindowsInnoTransactionResult ExecuteProtectedWindowsInnoHandoff(
    const ProtectedWindowsInnoExpectation& expectation,
    ProtectedWindowsInnoVerifier& verifier,
    ProtectedWindowsInnoRunner& runner) {
  ValidateExpectation(expectation);
  verifier.VerifyInstaller(expectation);
  std::string identity = runner.Launch(expectation);
  if (identity.empty()) Fail("protected Inno transaction identity missing");
  verifier.VerifyInstalledPackage(expectation);
  return {std::move(identity), true};
}

}  // namespace desktop_updater::helper
