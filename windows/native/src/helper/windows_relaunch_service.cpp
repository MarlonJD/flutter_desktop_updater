#include "windows_relaunch_service.h"

#include <windows.h>

#include <bcrypt.h>
#include <winternl.h>

#include <array>
#include <iomanip>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "helper_authenticode.h"
#include "json_value.h"

namespace desktop_updater::helper {
namespace {

std::wstring Utf8ToWide(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) throw WindowsRelaunchError("invalid publisher UTF-8");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    throw WindowsRelaunchError("publisher conversion failed");
  }
  return result;
}

UniqueWindowsHandle OpenApplicationParent(
    const std::filesystem::path& parent) {
  HANDLE handle = CreateFileW(
      parent.c_str(), FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    throw WindowsRelaunchError("application parent unavailable");
  }
  UniqueWindowsHandle result(handle);
  const auto identity = ReadWindowsFileIdentity(result.get());
  if (!identity.directory ||
      (identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    throw WindowsRelaunchError("application parent is not authoritative");
  }
  return result;
}

std::string Sha256Handle(HANDLE file) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0;
  DWORD received = 0;
  std::vector<unsigned char> object;
  std::array<unsigned char, 32> digest{};
  auto cleanup = [&]() {
    if (hash != nullptr) BCryptDestroyHash(hash);
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  };
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_size),
                        sizeof(object_size), &received, 0) < 0) {
    cleanup();
    throw WindowsRelaunchError("payload SHA-256 setup failed");
  }
  object.resize(object_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr, 0,
                       0) < 0) {
    cleanup();
    throw WindowsRelaunchError("payload SHA-256 creation failed");
  }
  LARGE_INTEGER start{};
  if (!SetFilePointerEx(file, start, nullptr, FILE_BEGIN)) {
    cleanup();
    throw WindowsRelaunchError("payload SHA-256 seek failed");
  }
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &count, nullptr)) {
      cleanup();
      throw WindowsRelaunchError("payload SHA-256 read failed");
    }
    if (count == 0) break;
    if (BCryptHashData(hash, buffer.data(), count, 0) < 0) {
      cleanup();
      throw WindowsRelaunchError("payload SHA-256 update failed");
    }
  }
  if (BCryptFinishHash(hash, digest.data(),
                       static_cast<ULONG>(digest.size()), 0) < 0) {
    cleanup();
    throw WindowsRelaunchError("payload SHA-256 finalization failed");
  }
  cleanup();
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (unsigned char byte : digest) {
    output << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return output.str();
}

std::string ReadHandleUtf8(HANDLE file, std::size_t maximum_bytes) {
  LARGE_INTEGER start{};
  if (!SetFilePointerEx(file, start, nullptr, FILE_BEGIN)) {
    throw WindowsRelaunchError("payload read seek failed");
  }
  std::string result;
  std::array<char, 4096> buffer{};
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &count, nullptr)) {
      throw WindowsRelaunchError("payload read failed");
    }
    if (count == 0) return result;
    if (result.size() + count > maximum_bytes) {
      throw WindowsRelaunchError("payload file exceeds size limit");
    }
    result.append(buffer.data(), count);
  }
}

std::filesystem::path FinalPath(HANDLE file) {
  std::vector<wchar_t> buffer(32 * 1024);
  const DWORD length = GetFinalPathNameByHandleW(
      file, buffer.data(), static_cast<DWORD>(buffer.size()),
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (length == 0 || length >= buffer.size()) {
    throw WindowsRelaunchError("payload final path unavailable");
  }
  return std::filesystem::path(buffer.data(), buffer.data() + length);
}

void RequireProvenanceKeys(
    const desktop_updater::runtime::internal::JsonValue& value) {
  const std::set<std::string> expected = {
      "artifactSha256", "packageId", "packageIdentitySha256", "schemaVersion"};
  const auto& object = value.object();
  if (object.size() != expected.size()) {
    throw WindowsRelaunchError("stage provenance fields rejected");
  }
  for (const auto& key : expected) {
    if (object.find(key) == object.end()) {
      throw WindowsRelaunchError("stage provenance fields rejected");
    }
  }
}

}  // namespace

AuthenticodeWindowsPayloadVerifier::AuthenticodeWindowsPayloadVerifier(
    WindowsVerifiedPayloadIdentity expectation)
    : expectation_(std::move(expectation)) {}

WindowsVerifiedPayloadIdentity AuthenticodeWindowsPayloadVerifier::Verify(
    HANDLE parent,
    const std::wstring& bundle_leaf) {
  const std::wstring provenance_relative =
      bundle_leaf + L"\\desktop-updater-stage-provenance.json";
  auto provenance = OpenRelativeNoReparse(
      parent, provenance_relative, GENERIC_READ | FILE_READ_ATTRIBUTES |
                                       SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  const std::string provenance_json =
      ReadHandleUtf8(provenance.get(), 64 * 1024);
  const std::string provenance_sha256 = Sha256Handle(provenance.get());
  const auto provenance_value =
      desktop_updater::runtime::internal::ParseJson(provenance_json);
  if (desktop_updater::runtime::internal::EncodeCanonicalJson(
          provenance_value) != provenance_json) {
    throw WindowsRelaunchError("stage provenance is not canonical JSON");
  }
  RequireProvenanceKeys(provenance_value);
  if (provenance_value.at("schemaVersion").integer() != 1) {
    throw WindowsRelaunchError("stage provenance schema rejected");
  }

  const std::wstring executable_relative =
      bundle_leaf + L"\\" + expectation_.executable_relative_path;
  auto executable = OpenRelativeNoReparse(
      parent, executable_relative, GENERIC_READ | FILE_READ_ATTRIBUTES |
                                       SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  const WindowsFileIdentity retained_identity =
      ReadWindowsFileIdentity(executable.get());
  const std::string executable_sha256 = Sha256Handle(executable.get());
  const std::filesystem::path executable_path = FinalPath(executable.get());
  const VerifiedWindowsExecutable signed_executable =
      VerifyWindowsExecutable(executable_path);
  if (!signed_executable.signature_valid ||
      signed_executable.publisher !=
          Utf8ToWide(expectation_.authenticode_publisher) ||
      signed_executable.sha256 != executable_sha256 ||
      signed_executable.volume_serial != retained_identity.volume_serial ||
      signed_executable.file_id != retained_identity.file_id ||
      !VerifyWindowsExecutableStillMatches(executable_path,
                                           signed_executable)) {
    throw WindowsRelaunchError("payload Authenticode identity mismatch");
  }

  WindowsVerifiedPayloadIdentity observed{
      provenance_value.at("packageId").string(),
      expectation_.authenticode_publisher,
      provenance_value.at("packageIdentitySha256").string(),
      provenance_sha256,
      provenance_value.at("artifactSha256").string(),
      expectation_.executable_relative_path,
      executable_sha256,
  };
  if (observed != expectation_) {
    throw WindowsRelaunchError("payload package/provenance identity mismatch");
  }
  return observed;
}

void CreateProcessWindowsLauncher::Launch(
    const std::filesystem::path& executable) {
  std::wstring command_line = L"\"" + executable.wstring() + L"\"";
  std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
  mutable_command.push_back(L'\0');
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(executable.c_str(), mutable_command.data(), nullptr,
                      nullptr, FALSE, CREATE_UNICODE_ENVIRONMENT, nullptr,
                      executable.parent_path().c_str(), &startup, &process)) {
    throw WindowsRelaunchError("CreateProcessW verified relaunch failed");
  }
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
}

WindowsRelaunchService::WindowsRelaunchService(
    WindowsVerifiedPayloadIdentity expected_payload_identity,
    WindowsInstallPayloadVerifier& verifier,
    WindowsProcessLauncher& launcher)
    : expected_payload_identity_(std::move(expected_payload_identity)),
      verifier_(verifier),
      launcher_(launcher) {}

void WindowsRelaunchService::Relaunch(
    const std::filesystem::path& application_path) {
  const auto application =
      std::filesystem::absolute(application_path).lexically_normal();
  auto parent = OpenApplicationParent(application.parent_path());
  if (verifier_.Verify(parent.get(), application.filename().wstring()) !=
      expected_payload_identity_) {
    throw WindowsRelaunchError("activated payload identity mismatch");
  }
  const std::wstring relative_executable =
      application.filename().wstring() + L"\\" +
      expected_payload_identity_.executable_relative_path;
  auto executable_handle = OpenRelativeNoReparse(
      parent.get(), relative_executable, GENERIC_READ | FILE_READ_ATTRIBUTES |
                                             SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);

  std::vector<wchar_t> final_path(32 * 1024);
  const DWORD length = GetFinalPathNameByHandleW(
      executable_handle.get(), final_path.data(),
      static_cast<DWORD>(final_path.size()),
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (length == 0 || length >= final_path.size()) {
    throw WindowsRelaunchError("verified executable final path unavailable");
  }
  const std::filesystem::path executable(final_path.data(),
                                         final_path.data() + length);
  const VerifiedWindowsExecutable verified =
      VerifyWindowsExecutable(executable);
  if (!verified.signature_valid ||
      verified.publisher !=
          Utf8ToWide(expected_payload_identity_.authenticode_publisher) ||
      verified.sha256 != expected_payload_identity_.executable_sha256 ||
      !VerifyWindowsExecutableStillMatches(executable, verified)) {
    throw WindowsRelaunchError("executable Authenticode proof mismatch");
  }
  launcher_.Launch(executable);
}

}  // namespace desktop_updater::helper
