#include "windows_inno_transaction_journal.h"

#include <algorithm>
#include <cctype>
#include <limits>
#include <regex>
#include <set>
#include <utility>

#include "json_value.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;

constexpr std::size_t kMaximumJournalBytes = 1024 * 1024;
const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
const std::regex kSha256("^[0-9a-f]{64}$");

[[noreturn]] void Fail(const std::string& detail) {
  throw WindowsInnoTransactionJournalError(detail);
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty() ||
      value.size() >
          static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    Fail("protected Inno journal UTF-16 value is invalid");
  }
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) Fail("protected Inno journal UTF-16 value is invalid");
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), length,
                          nullptr, nullptr) != length) {
    Fail("protected Inno journal UTF-16 conversion failed");
  }
  return result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty() ||
      value.size() >
          static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    Fail("protected Inno journal UTF-8 value is invalid");
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) Fail("protected Inno journal UTF-8 value is invalid");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    Fail("protected Inno journal UTF-8 conversion failed");
  }
  return result;
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

bool SafeLeaf(const std::wstring& value) {
  return !value.empty() && value != L"." && value != L".." &&
         value.find_first_of(L"\\/:*?\"<>|") == std::wstring::npos &&
         value.back() != L'.' && value.back() != L' ';
}

void RequireExactKeys(const JsonValue& value,
                      const std::set<std::string>& expected) {
  const auto& object = value.object();
  if (object.size() != expected.size()) {
    Fail("protected Inno journal fields are invalid");
  }
  for (const std::string& key : expected) {
    if (object.find(key) == object.end()) {
      Fail("protected Inno journal fields are invalid");
    }
  }
}

void Validate(const ProtectedWindowsInnoJournal& journal) {
  const std::wstring expected_leaf =
      L".desktop-updater-inno-" +
      std::wstring(journal.transaction_id.begin(),
                   journal.transaction_id.end()) +
      L".exe";
  if (journal.schema_version != ProtectedWindowsInnoJournal::kSchemaVersion ||
      !std::regex_match(journal.transaction_id, kTransactionId) ||
      journal.package_id.empty() || !journal.target_path.is_absolute() ||
      journal.target_path.lexically_normal() != journal.target_path ||
      journal.target_path.filename().empty() ||
      journal.installer_leaf != expected_leaf ||
      !SafeLeaf(journal.installer_leaf) ||
      !std::regex_match(journal.installer_sha256, kSha256) ||
      journal.installer_length < 1 ||
      !std::regex_match(journal.descriptor_sha256, kSha256) ||
      !std::regex_match(journal.provenance_sha256, kSha256) ||
      journal.current_version.empty() || journal.current_build_number < 0 ||
      !std::regex_match(journal.current_executable_sha256, kSha256) ||
      journal.desired_version.empty() || journal.desired_build_number < 0 ||
      !journal.execution.inherit_install_directory ||
      !SafeRelativeExecutable(
          journal.execution.installed_executable_relative_path) ||
      !std::regex_match(journal.execution.installed_executable_sha256,
                        kSha256) ||
      !SafeLeaf(journal.execution.log_file_name) ||
      journal.execution.signer_certificate_sha256.empty() ||
      journal.owner_process_id == 0 ||
      journal.owner_process_start_identity == 0 ||
      journal.owner_process_start_identity >
          static_cast<std::uint64_t>(
              std::numeric_limits<std::int64_t>::max())) {
    Fail("protected Inno journal is invalid");
  }

  std::set<std::string> certificates;
  for (const std::string& certificate :
       journal.execution.signer_certificate_sha256) {
    if (!std::regex_match(certificate, kSha256) ||
        !certificates.insert(certificate).second) {
      Fail("protected Inno journal signer allowlist is invalid");
    }
  }
  static const std::set<std::wstring> kAllowedArguments = {
      L"/CLOSEAPPLICATIONS", L"/FORCECLOSEAPPLICATIONS", L"/NOCANCEL",
      L"/NORESTART", L"/SILENT", L"/SP-", L"/SUPPRESSMSGBOXES",
      L"/VERYSILENT"};
  std::set<std::wstring> arguments;
  bool has_silent = false;
  bool has_no_restart = false;
  for (const std::wstring& argument : journal.execution.silent_arguments) {
    if (kAllowedArguments.count(argument) == 0 ||
        !arguments.insert(argument).second) {
      Fail("protected Inno journal argument vector is invalid");
    }
    if (argument == L"/SILENT" || argument == L"/VERYSILENT") {
      if (has_silent) Fail("protected Inno journal has multiple silent modes");
      has_silent = true;
    }
    has_no_restart = has_no_restart || argument == L"/NORESTART";
  }
  if (!has_silent || !has_no_restart) {
    Fail("protected Inno journal argument vector is incomplete");
  }
}

}  // namespace

std::string ProtectedWindowsInnoJournal::EncodeCanonical() const {
  Validate(*this);
  JsonValue::Array arguments;
  for (const std::wstring& argument : execution.silent_arguments) {
    arguments.emplace_back(WideToUtf8(argument));
  }
  JsonValue::Array certificates;
  for (const std::string& certificate :
       execution.signer_certificate_sha256) {
    certificates.emplace_back(certificate);
  }
  JsonValue::Object object;
  object.emplace("currentBuildNumber", JsonValue(current_build_number));
  object.emplace("currentExecutableSha256",
                 JsonValue(current_executable_sha256));
  object.emplace("currentVersion", JsonValue(current_version));
  object.emplace("descriptorSha256", JsonValue(descriptor_sha256));
  object.emplace("desiredBuildNumber", JsonValue(desired_build_number));
  object.emplace("desiredExecutableSha256",
                 JsonValue(execution.installed_executable_sha256));
  object.emplace("desiredVersion", JsonValue(desired_version));
  object.emplace("executableRelativePath",
                 JsonValue(WideToUtf8(
                     execution.installed_executable_relative_path.wstring())));
  object.emplace("inheritInstallDirectory",
                 JsonValue(execution.inherit_install_directory));
  object.emplace("installerLeaf", JsonValue(WideToUtf8(installer_leaf)));
  object.emplace("installerLength", JsonValue(installer_length));
  object.emplace("installerSha256", JsonValue(installer_sha256));
  object.emplace("logFileName",
                 JsonValue(WideToUtf8(execution.log_file_name)));
  object.emplace("ownerProcessId",
                 JsonValue(static_cast<std::int64_t>(owner_process_id)));
  object.emplace("ownerProcessStartIdentity",
                 JsonValue(static_cast<std::int64_t>(
                     owner_process_start_identity)));
  object.emplace("packageId", JsonValue(package_id));
  object.emplace("provenanceSha256", JsonValue(provenance_sha256));
  object.emplace("relaunchAfterInstall",
                 JsonValue(execution.relaunch_after_install));
  object.emplace("schemaVersion", JsonValue(schema_version));
  object.emplace("signerCertificateSha256",
                 JsonValue(std::move(certificates)));
  object.emplace("silentArgs", JsonValue(std::move(arguments)));
  object.emplace("targetPath",
                 JsonValue(WideToUtf8(target_path.wstring())));
  object.emplace("transactionId", JsonValue(transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

ProtectedWindowsInnoJournal ProtectedWindowsInnoJournal::DecodeStrict(
    const std::string& canonical_json) {
  if (canonical_json.empty() || canonical_json.size() > kMaximumJournalBytes) {
    Fail("protected Inno journal length is invalid");
  }
  try {
    const JsonValue value = ParseJson(canonical_json);
    if (EncodeCanonicalJson(value) != canonical_json) {
      Fail("protected Inno journal is not canonical JSON");
    }
    RequireExactKeys(
        value,
        {"currentBuildNumber", "currentExecutableSha256", "currentVersion",
         "descriptorSha256", "desiredBuildNumber",
         "desiredExecutableSha256", "desiredVersion",
         "executableRelativePath", "inheritInstallDirectory",
         "installerLeaf", "installerLength", "installerSha256",
         "logFileName", "ownerProcessId", "ownerProcessStartIdentity",
         "packageId", "provenanceSha256", "relaunchAfterInstall",
         "schemaVersion", "signerCertificateSha256", "silentArgs",
         "targetPath", "transactionId"});
    ProtectedWindowsInnoJournal journal;
    journal.schema_version = value.at("schemaVersion").integer();
    journal.transaction_id = value.at("transactionId").string();
    journal.package_id = value.at("packageId").string();
    journal.target_path =
        std::filesystem::path(Utf8ToWide(value.at("targetPath").string()));
    journal.installer_leaf = Utf8ToWide(value.at("installerLeaf").string());
    journal.installer_sha256 = value.at("installerSha256").string();
    journal.installer_length = value.at("installerLength").integer();
    journal.descriptor_sha256 = value.at("descriptorSha256").string();
    journal.provenance_sha256 = value.at("provenanceSha256").string();
    journal.current_version = value.at("currentVersion").string();
    journal.current_build_number = value.at("currentBuildNumber").integer();
    journal.current_executable_sha256 =
        value.at("currentExecutableSha256").string();
    journal.desired_version = value.at("desiredVersion").string();
    journal.desired_build_number = value.at("desiredBuildNumber").integer();
    journal.execution.inherit_install_directory =
        value.at("inheritInstallDirectory").boolean();
    journal.execution.relaunch_after_install =
        value.at("relaunchAfterInstall").boolean();
    journal.execution.installed_executable_relative_path =
        std::filesystem::path(
            Utf8ToWide(value.at("executableRelativePath").string()));
    journal.execution.installed_executable_sha256 =
        value.at("desiredExecutableSha256").string();
    journal.execution.log_file_name =
        Utf8ToWide(value.at("logFileName").string());
    for (const JsonValue& argument : value.at("silentArgs").array()) {
      journal.execution.silent_arguments.push_back(
          Utf8ToWide(argument.string()));
    }
    for (const JsonValue& certificate :
         value.at("signerCertificateSha256").array()) {
      journal.execution.signer_certificate_sha256.push_back(
          certificate.string());
    }
    const std::int64_t owner_process_id =
        value.at("ownerProcessId").integer();
    if (owner_process_id <= 0 ||
        owner_process_id > std::numeric_limits<DWORD>::max()) {
      Fail("protected Inno journal owner process ID is invalid");
    }
    journal.owner_process_id = static_cast<DWORD>(owner_process_id);
    const std::int64_t owner_start =
        value.at("ownerProcessStartIdentity").integer();
    if (owner_start <= 0) {
      Fail("protected Inno journal owner start identity is invalid");
    }
    journal.owner_process_start_identity =
        static_cast<std::uint64_t>(owner_start);
    if (journal.EncodeCanonical() != canonical_json) {
      Fail("protected Inno journal encoding changed");
    }
    return journal;
  } catch (const WindowsInnoTransactionJournalError&) {
    throw;
  } catch (const std::exception&) {
    Fail("protected Inno journal is corrupt");
  }
}

ProtectedWindowsInnoExpectation
ProtectedWindowsInnoJournal::BuildExpectation() const {
  Validate(*this);
  ProtectedWindowsInnoExpectation result;
  result.installer_path = target_path.parent_path() / installer_leaf;
  result.installer_sha256 = installer_sha256;
  result.package_id = package_id;
  result.expected_version = desired_version;
  result.expected_build_number = desired_build_number;
  result.install_root = target_path;
  result.log_root = target_path.parent_path();
  result.execution = execution;
  return result;
}

ProtectedWindowsInnoRecoveryDecision DecideProtectedWindowsInnoRecovery(
    bool exact_owner_alive, bool desired_install_verified,
    bool old_install_verified) {
  if (exact_owner_alive) {
    return ProtectedWindowsInnoRecoveryDecision::kRecoveryRequired;
  }
  if (desired_install_verified == old_install_verified) {
    return ProtectedWindowsInnoRecoveryDecision::kManualActionRequired;
  }
  return desired_install_verified
             ? ProtectedWindowsInnoRecoveryDecision::kCompleted
             : ProtectedWindowsInnoRecoveryDecision::kRolledBack;
}

}  // namespace desktop_updater::helper
