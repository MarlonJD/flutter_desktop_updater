#include "windows_relaunch_service.h"

#include <windows.h>

#include <bcrypt.h>
#include <userenv.h>
#include <winternl.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <iomanip>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "helper_authenticode.h"
#include "windows_archive_restage.h"
#include "windows_helper_diagnostics.h"
#include "json_value.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::JsonValue;

std::wstring Utf8ToWide(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) throw WindowsRelaunchError("invalid payload UTF-8");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    throw WindowsRelaunchError("payload UTF-8 conversion failed");
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) throw WindowsRelaunchError("invalid payload UTF-16");
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), length,
                          nullptr, nullptr) != length) {
    throw WindowsRelaunchError("payload UTF-16 conversion failed");
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

void RequireExactKeys(const JsonValue& value,
                      std::initializer_list<const char*> keys) {
  std::set<std::string> expected;
  for (const char* key : keys) expected.emplace(key);
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

bool ValidSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return std::isdigit(byte) != 0 || (byte >= 'a' && byte <= 'f');
         });
}

bool ValidNonce(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-' || value[14] != '4' ||
      std::string("89ab").find(value[19]) == std::string::npos) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const unsigned char byte = static_cast<unsigned char>(value[index]);
    if (std::isdigit(byte) == 0 && (byte < 'a' || byte > 'f')) return false;
  }
  return true;
}

void ValidateInventoryPath(const std::string& value) {
  if (value.empty() || value.front() == '/' || value.back() == '/' ||
      value.find('\\') != std::string::npos ||
      value.find(':') != std::string::npos ||
      value.find('\0') != std::string::npos) {
    throw WindowsRelaunchError("stage provenance path rejected");
  }
  std::size_t start = 0;
  for (;;) {
    const std::size_t slash = value.find('/', start);
    const std::string segment = value.substr(start, slash - start);
    if (segment.empty() || segment == "." || segment == ".." ||
        segment.back() == '.' || segment.back() == ' ') {
      throw WindowsRelaunchError("stage provenance path rejected");
    }
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
}

bool Utf8Less(const std::string& left, const std::string& right) {
  return std::lexicographical_compare(
      left.begin(), left.end(), right.begin(), right.end(),
      [](char first, char second) {
        return static_cast<unsigned char>(first) <
               static_cast<unsigned char>(second);
      });
}

struct StageInventoryEntry {
  std::string path;
  std::string kind;
  std::int64_t length = 0;
  std::string sha256;

  bool operator==(const StageInventoryEntry& other) const {
    return path == other.path && kind == other.kind &&
           length == other.length && sha256 == other.sha256;
  }
};

struct StageProvenance {
  std::string package_id;
  std::string descriptor_sha256;
  std::string artifact_sha256;
  std::vector<StageInventoryEntry> entries;
};

StageProvenance DecodeStageProvenance(const JsonValue& value) {
  RequireExactKeys(value, {"artifactSha256", "descriptorSha256", "entries",
                           "nonce", "packageId", "schemaVersion"});
  if (value.at("schemaVersion").integer() != 1 ||
      !ValidNonce(value.at("nonce").string())) {
    throw WindowsRelaunchError("stage provenance schema/nonce rejected");
  }
  StageProvenance result{
      value.at("packageId").string(),
      value.at("descriptorSha256").string(),
      value.at("artifactSha256").string(),
      {},
  };
  if (result.package_id.empty() || !ValidSha256(result.descriptor_sha256) ||
      !ValidSha256(result.artifact_sha256)) {
    throw WindowsRelaunchError("stage provenance identity rejected");
  }

  std::set<std::string> paths;
  std::string previous;
  for (const JsonValue& encoded : value.at("entries").array()) {
    const std::string kind = encoded.at("kind").string();
    if (kind == "file") {
      RequireExactKeys(encoded, {"kind", "length", "path", "sha256"});
    } else if (kind == "directory") {
      RequireExactKeys(encoded, {"kind", "length", "path"});
    } else {
      throw WindowsRelaunchError("stage provenance entry kind rejected");
    }
    StageInventoryEntry entry{
        encoded.at("path").string(),
        kind,
        encoded.at("length").integer(),
        kind == "file" ? encoded.at("sha256").string() : std::string(),
    };
    ValidateInventoryPath(entry.path);
    if (!paths.insert(entry.path).second ||
        (!previous.empty() && !Utf8Less(previous, entry.path)) ||
        (entry.kind == "file" &&
         (entry.length < 0 || !ValidSha256(entry.sha256))) ||
        (entry.kind == "directory" && entry.length != 0)) {
      throw WindowsRelaunchError("stage provenance inventory rejected");
    }
    previous = entry.path;
    result.entries.push_back(std::move(entry));
  }
  return result;
}

std::int64_t FileLength(HANDLE file) {
  FILE_STANDARD_INFO info{};
  if (!GetFileInformationByHandleEx(file, FileStandardInfo, &info,
                                    sizeof(info)) ||
      info.EndOfFile.QuadPart < 0) {
    throw WindowsRelaunchError("staged file length unavailable");
  }
  return info.EndOfFile.QuadPart;
}

void VerifyNoAlternateDataStreams(HANDLE object) {
  alignas(FILE_STREAM_INFO) std::array<unsigned char, 64 * 1024> buffer{};
  if (!GetFileInformationByHandleEx(object, FileStreamInfo, buffer.data(),
                                    static_cast<DWORD>(buffer.size()))) {
    const DWORD error = GetLastError();
    if (error == ERROR_HANDLE_EOF || error == ERROR_NO_MORE_FILES) return;
    throw WindowsRelaunchError("staged stream enumeration failed");
  }
  auto* stream = reinterpret_cast<FILE_STREAM_INFO*>(buffer.data());
  bool default_stream_seen = false;
  for (;;) {
    const std::wstring name(stream->StreamName,
                            stream->StreamNameLength / sizeof(wchar_t));
    if (name != L"::$DATA" || default_stream_seen) {
      throw WindowsRelaunchError("staged alternate data stream rejected");
    }
    default_stream_seen = true;
    if (stream->NextEntryOffset == 0) break;
    stream = reinterpret_cast<FILE_STREAM_INFO*>(
        reinterpret_cast<unsigned char*>(stream) + stream->NextEntryOffset);
  }
}

void EnumerateStageDirectory(
    HANDLE directory,
    const std::string& prefix,
    std::vector<StageInventoryEntry>* entries,
    std::vector<UniqueWindowsHandle>* retained_handles) {
  alignas(FILE_ID_BOTH_DIR_INFO)
      std::array<unsigned char, 64 * 1024> buffer{};
  bool restart = true;
  for (;;) {
    const auto info_class = restart ? FileIdBothDirectoryRestartInfo
                                    : FileIdBothDirectoryInfo;
    restart = false;
    if (!GetFileInformationByHandleEx(directory, info_class, buffer.data(),
                                      static_cast<DWORD>(buffer.size()))) {
      if (GetLastError() == ERROR_NO_MORE_FILES) break;
      throw WindowsRelaunchError("staged directory enumeration failed");
    }
    auto* encoded = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(buffer.data());
    for (;;) {
      const std::wstring name(encoded->FileName,
                              encoded->FileNameLength / sizeof(wchar_t));
      if (name != L"." && name != L"..") {
        const std::string utf8_name = WideToUtf8(name);
        const std::string path =
            prefix.empty() ? utf8_name : prefix + "/" + utf8_name;
        ValidateInventoryPath(path);
        if (path != ".desktop_updater_stage_provenance.json") {
          auto child = OpenRelativeNoReparse(
              directory, name, GENERIC_READ | FILE_READ_ATTRIBUTES |
                                   SYNCHRONIZE,
              FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
              FILE_SYNCHRONOUS_IO_NONALERT);
          const WindowsFileIdentity identity =
              ReadWindowsFileIdentity(child.get());
          VerifyNoAlternateDataStreams(child.get());
          if (identity.directory) {
            entries->push_back({path, "directory", 0, {}});
            EnumerateStageDirectory(child.get(), path, entries,
                                    retained_handles);
          } else {
            entries->push_back(
                {path, "file", FileLength(child.get()),
                 Sha256Handle(child.get())});
          }
          retained_handles->push_back(std::move(child));
        }
      }
      if (encoded->NextEntryOffset == 0) break;
      encoded = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(
          reinterpret_cast<unsigned char*>(encoded) +
          encoded->NextEntryOffset);
    }
  }
}

std::string VerifyCompleteStageInventory(
    HANDLE stage_root,
    const std::vector<StageInventoryEntry>& expected,
    const std::string& executable_path,
    std::vector<UniqueWindowsHandle>* retained_handles) {
  std::vector<StageInventoryEntry> actual;
  EnumerateStageDirectory(stage_root, {}, &actual, retained_handles);
  std::sort(actual.begin(), actual.end(),
            [](const StageInventoryEntry& left,
               const StageInventoryEntry& right) {
              return Utf8Less(left.path, right.path);
            });
  if (actual != expected) {
    throw WindowsRelaunchError("stage provenance inventory mismatch");
  }
  const auto executable = std::find_if(
      expected.begin(), expected.end(), [&](const StageInventoryEntry& entry) {
        return entry.path == executable_path;
      });
  if (executable == expected.end() || executable->kind != "file") {
    throw WindowsRelaunchError("signed executable missing from provenance");
  }
  return executable->sha256;
}

}  // namespace

AuthenticodeWindowsPayloadVerifier::AuthenticodeWindowsPayloadVerifier(
    WindowsVerifiedPayloadIdentity expectation)
    : expectation_(std::move(expectation)) {}

WindowsVerifiedPayloadIdentity AuthenticodeWindowsPayloadVerifier::Verify(
    HANDLE parent,
    const std::wstring& bundle_leaf) {
  std::string executable_inventory_path =
      WideToUtf8(expectation_.executable_relative_path);
  std::replace(executable_inventory_path.begin(),
               executable_inventory_path.end(), '\\', '/');
  ValidateInventoryPath(executable_inventory_path);
  std::vector<UniqueWindowsHandle> retained_handles;
  const WindowsPayloadSeal payload_seal = SealWindowsPayloadTree(
      parent, bundle_leaf, expectation_.package_id,
      expectation_.package_identity_sha256, expectation_.artifact_sha256,
      &retained_handles);
  if (payload_seal.sha256 != expectation_.payload_seal_sha256) {
    throw WindowsRelaunchError("helper payload seal mismatch");
  }
  const auto inventory_executable = std::find_if(
      payload_seal.entries.begin(), payload_seal.entries.end(),
      [&](const auto& entry) {
        return entry.path == executable_inventory_path &&
               entry.kind == "file";
      });
  if (inventory_executable == payload_seal.entries.end()) {
    throw WindowsRelaunchError("signed executable missing from payload seal");
  }

  auto executable = OpenRelativeNoReparse(
      parent, bundle_leaf + L"\\" + expectation_.executable_relative_path,
      GENERIC_READ | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
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
      inventory_executable->sha256 != executable_sha256 ||
      signed_executable.volume_serial != retained_identity.volume_serial ||
      signed_executable.file_id != retained_identity.file_id ||
      !VerifyWindowsExecutableStillMatches(executable_path,
                                           signed_executable)) {
    throw WindowsRelaunchError("payload Authenticode identity mismatch");
  }

  WindowsVerifiedPayloadIdentity observed{
      expectation_.package_id,
      expectation_.authenticode_publisher,
      expectation_.package_identity_sha256,
      expectation_.stage_provenance_sha256,
      expectation_.artifact_sha256,
      expectation_.executable_relative_path,
      executable_sha256,
      payload_seal.sha256,
  };
  if (observed != expectation_) {
    throw WindowsRelaunchError("payload package/provenance identity mismatch");
  }
  retained_handles.push_back(std::move(executable));
  retained_stage_handles_ = std::move(retained_handles);
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

CallerTokenWindowsLauncher::CallerTokenWindowsLauncher(
    HANDLE caller_process) {
  if (caller_process == nullptr) {
    throw WindowsRelaunchError("caller process token source is unavailable");
  }
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(caller_process, TOKEN_QUERY | TOKEN_DUPLICATE,
                        &raw_token)) {
    throw WindowsRelaunchError("caller process token cannot be opened");
  }
  UniqueWindowsHandle token(raw_token);
  HANDLE raw_primary = nullptr;
  constexpr DWORD desired_access =
      TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_QUERY |
      TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID;
  if (!DuplicateTokenEx(token.get(), desired_access, nullptr,
                        SecurityImpersonation, TokenPrimary, &raw_primary)) {
    throw WindowsRelaunchError(
        "caller process primary token cannot be duplicated");
  }
  caller_primary_token_.reset(raw_primary);
}

void CallerTokenWindowsLauncher::Launch(
    const std::filesystem::path& executable) {
  if (!caller_primary_token_.valid() || !executable.is_absolute() ||
      executable.filename().empty()) {
    throw WindowsRelaunchError("caller-token relaunch path is invalid");
  }
  void* environment = nullptr;
  if (!CreateEnvironmentBlock(&environment, caller_primary_token_.get(),
                              FALSE) ||
      environment == nullptr) {
    throw WindowsRelaunchError(
        "caller-token relaunch environment is unavailable");
  }
  struct EnvironmentDestroyer {
    void operator()(void* value) const {
      if (value != nullptr) DestroyEnvironmentBlock(value);
    }
  };
  std::unique_ptr<void, EnvironmentDestroyer> environment_owner(environment);
  std::wstring command_line = L"\"" + executable.wstring() + L"\"";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  const std::filesystem::path working_directory = executable.parent_path();
  if (!CreateProcessWithTokenW(
          caller_primary_token_.get(), LOGON_WITH_PROFILE,
          executable.c_str(), command_line.data(), CREATE_UNICODE_ENVIRONMENT,
          environment, working_directory.c_str(), &startup, &process)) {
    throw WindowsRelaunchError("caller-token process relaunch failed");
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
  RecordWindowsHelperEvent(WindowsHelperEvent::kRelaunchAttempt);
  launcher_.Launch(executable);
}

}  // namespace desktop_updater::helper
