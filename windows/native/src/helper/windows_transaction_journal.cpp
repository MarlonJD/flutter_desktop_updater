#include "windows_transaction_journal.h"

#include <winternl.h>

#include <algorithm>
#include <cctype>
#include <climits>
#include <cstddef>
#include <cstring>
#include <cwctype>
#include <iomanip>
#include <regex>
#include <set>
#include <sstream>
#include <utility>

#include "json_value.h"

#ifndef OBJ_DONT_REPARSE
#define OBJ_DONT_REPARSE 0x00001000L
#endif

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonError;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;

using NtCreateFileFunction = NTSTATUS(NTAPI*)(
    PHANDLE,
    ACCESS_MASK,
    POBJECT_ATTRIBUTES,
    PIO_STATUS_BLOCK,
    PLARGE_INTEGER,
    ULONG,
    ULONG,
    ULONG,
    ULONG,
    PVOID,
    ULONG);
using RtlNtStatusToDosErrorFunction = ULONG(WINAPI*)(NTSTATUS);

const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
const std::regex kSha256("^[0-9a-f]{64}$");

NtCreateFileFunction ResolveNtCreateFile() {
  const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) return nullptr;
  return reinterpret_cast<NtCreateFileFunction>(
      GetProcAddress(ntdll, "NtCreateFile"));
}

DWORD NtStatusToError(NTSTATUS status) {
  const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  const auto convert = ntdll == nullptr
                           ? nullptr
                           : reinterpret_cast<RtlNtStatusToDosErrorFunction>(
                                 GetProcAddress(ntdll,
                                                "RtlNtStatusToDosError"));
  return convert == nullptr ? ERROR_ACCESS_DENIED : convert(status);
}

[[noreturn]] void ThrowOpenError(DWORD error, const char* detail) {
  SetLastError(error);
  WindowsTransactionJournalError::Code code =
      WindowsTransactionJournalError::Code::kPersistenceFailed;
  if (error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION) {
    code = WindowsTransactionJournalError::Code::kSharingViolation;
  } else if (error == ERROR_CANT_ACCESS_FILE || error == ERROR_REPARSE_TAG_INVALID ||
             error == ERROR_REPARSE_TAG_MISMATCH) {
    code = WindowsTransactionJournalError::Code::kReparsePoint;
  }
  throw WindowsTransactionJournalError(code, detail);
}

void ValidateSimpleName(const std::wstring& value) {
  static constexpr wchar_t invalid[] = L"\\/:*?\"<>|";
  if (value.empty() || value == L"." || value == L".." ||
      value.find_first_of(invalid) != std::wstring::npos ||
      value.back() == L'.' || value.back() == L' ') {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "alternateDataStreamRejected: expected one Windows path component");
  }
}

std::wstring Utf8ToWide(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "invalid journal UTF-8");
  }
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "journal UTF-8 conversion failed");
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "invalid Windows Unicode path");
  }
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length, nullptr, nullptr) != length) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "Windows path UTF-8 conversion failed");
  }
  return result;
}

std::string FileIdHex(const std::array<unsigned char, 16>& bytes) {
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (unsigned char byte : bytes) {
    output << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return output.str();
}

std::array<unsigned char, 16> ParseFileId(const std::string& value) {
  if (value.size() != 32) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "invalid journal file ID");
  }
  std::array<unsigned char, 16> result{};
  for (std::size_t index = 0; index < result.size(); ++index) {
    const std::string byte = value.substr(index * 2, 2);
    if (!std::all_of(byte.begin(), byte.end(), [](unsigned char character) {
          return std::isxdigit(character) != 0;
        })) {
      throw WindowsTransactionJournalError(
          WindowsTransactionJournalError::Code::kInvalidJournal,
          "invalid journal file ID");
    }
    result[index] = static_cast<unsigned char>(std::stoul(byte, nullptr, 16));
  }
  return result;
}

JsonValue EncodeIdentity(const WindowsFileIdentity& identity) {
  JsonValue::Object object;
  object.emplace("attributes",
                 JsonValue(static_cast<std::int64_t>(identity.attributes)));
  object.emplace("directory", JsonValue(identity.directory));
  object.emplace("fileId", JsonValue(FileIdHex(identity.file_id)));
  object.emplace("numberOfLinks",
                 JsonValue(static_cast<std::int64_t>(identity.number_of_links)));
  object.emplace("volumeSerial",
                 JsonValue(static_cast<std::int64_t>(identity.volume_serial)));
  return JsonValue(std::move(object));
}

JsonValue EncodePayload(const WindowsVerifiedPayloadIdentity& identity) {
  JsonValue::Object object;
  object.emplace("artifactSha256", JsonValue(identity.artifact_sha256));
  object.emplace("authenticodePublisher",
                 JsonValue(identity.authenticode_publisher));
  object.emplace("executableRelativePath",
                 JsonValue(WideToUtf8(identity.executable_relative_path)));
  object.emplace("executableSha256", JsonValue(identity.executable_sha256));
  object.emplace("packageId", JsonValue(identity.package_id));
  object.emplace("packageIdentitySha256",
                 JsonValue(identity.package_identity_sha256));
  object.emplace("stageProvenanceSha256",
                 JsonValue(identity.stage_provenance_sha256));
  return JsonValue(std::move(object));
}

void RequireKeys(const JsonValue& value,
                 const std::set<std::string>& expected) {
  const auto& object = value.object();
  if (object.size() != expected.size()) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "journal has unknown or missing fields");
  }
  for (const std::string& key : expected) {
    if (object.find(key) == object.end()) {
      throw WindowsTransactionJournalError(
          WindowsTransactionJournalError::Code::kInvalidJournal,
          "journal has unknown or missing fields");
    }
  }
}

WindowsFileIdentity DecodeIdentity(const JsonValue& value) {
  RequireKeys(value, {"attributes", "directory", "fileId", "numberOfLinks",
                      "volumeSerial"});
  WindowsFileIdentity identity;
  identity.attributes = static_cast<DWORD>(value.at("attributes").integer());
  identity.directory = value.at("directory").boolean();
  identity.file_id = ParseFileId(value.at("fileId").string());
  identity.number_of_links =
      static_cast<DWORD>(value.at("numberOfLinks").integer());
  identity.volume_serial =
      static_cast<std::uint64_t>(value.at("volumeSerial").integer());
  return identity;
}

void ValidateSha(const std::string& value) {
  if (!std::regex_match(value, kSha256)) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "invalid journal SHA-256");
  }
}

WindowsVerifiedPayloadIdentity DecodePayload(const JsonValue& value) {
  RequireKeys(value,
              {"artifactSha256", "authenticodePublisher",
               "executableRelativePath", "executableSha256", "packageId",
               "packageIdentitySha256", "stageProvenanceSha256"});
  WindowsVerifiedPayloadIdentity identity{
      value.at("packageId").string(),
      value.at("authenticodePublisher").string(),
      value.at("packageIdentitySha256").string(),
      value.at("stageProvenanceSha256").string(),
      value.at("artifactSha256").string(),
      Utf8ToWide(value.at("executableRelativePath").string()),
      value.at("executableSha256").string(),
  };
  if (identity.package_id.empty() || identity.authenticode_publisher.empty() ||
      identity.executable_relative_path.empty()) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "empty payload identity field");
  }
  ValidateSha(identity.package_identity_sha256);
  ValidateSha(identity.stage_provenance_sha256);
  ValidateSha(identity.artifact_sha256);
  ValidateSha(identity.executable_sha256);
  return identity;
}

std::string StateName(WindowsTransactionState state) {
  switch (state) {
    case WindowsTransactionState::kPrepared:
      return "prepared";
    case WindowsTransactionState::kBackupCreated:
      return "backupCreated";
    case WindowsTransactionState::kTargetActivated:
      return "targetActivated";
    case WindowsTransactionState::kCompleted:
      return "completed";
    case WindowsTransactionState::kManualActionRequired:
      return "manualActionRequired";
  }
  return "manualActionRequired";
}

WindowsTransactionState ParseState(const std::string& state) {
  if (state == "prepared") return WindowsTransactionState::kPrepared;
  if (state == "backupCreated") {
    return WindowsTransactionState::kBackupCreated;
  }
  if (state == "targetActivated") {
    return WindowsTransactionState::kTargetActivated;
  }
  if (state == "completed") return WindowsTransactionState::kCompleted;
  if (state == "manualActionRequired") {
    return WindowsTransactionState::kManualActionRequired;
  }
  throw WindowsTransactionJournalError(
      WindowsTransactionJournalError::Code::kInvalidJournal,
      "unknown journal state");
}

void WriteAll(HANDLE file, const std::string& contents) {
  std::size_t offset = 0;
  while (offset < contents.size()) {
    DWORD written = 0;
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        contents.size() - offset, static_cast<std::size_t>(MAXDWORD)));
    if (!WriteFile(file, contents.data() + offset, requested, &written,
                   nullptr) ||
        written == 0) {
      throw WindowsTransactionJournalError(
          WindowsTransactionJournalError::Code::kPersistenceFailed,
          "journal write failed or was short");
    }
    offset += written;
  }
}

void DeleteObjectRecursive(HANDLE object) {
  const WindowsFileIdentity identity = ReadWindowsFileIdentity(object);
  if (identity.directory) {
    std::array<unsigned char, 64 * 1024> buffer{};
    bool restart = true;
    for (;;) {
      const auto info_class = restart ? FileIdBothDirectoryRestartInfo
                                      : FileIdBothDirectoryInfo;
      restart = false;
      if (!GetFileInformationByHandleEx(object, info_class, buffer.data(),
                                        static_cast<DWORD>(buffer.size()))) {
        if (GetLastError() == ERROR_NO_MORE_FILES) break;
        throw WindowsTransactionJournalError(
            WindowsTransactionJournalError::Code::kPersistenceFailed,
            "relative directory enumeration failed");
      }
      auto* entry = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(buffer.data());
      for (;;) {
        std::wstring name(entry->FileName,
                          entry->FileNameLength / sizeof(wchar_t));
        if (name != L"." && name != L"..") {
          auto child = OpenRelativeNoReparse(
              object, name,
              DELETE | FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY |
                  SYNCHRONIZE,
              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
              FILE_OPEN, FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT);
          DeleteObjectRecursive(child.get());
        }
        if (entry->NextEntryOffset == 0) break;
        entry = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(
            reinterpret_cast<unsigned char*>(entry) + entry->NextEntryOffset);
      }
    }
  }
  DeleteHandleExact(object);
}

}  // namespace

UniqueWindowsHandle::~UniqueWindowsHandle() { reset(); }

UniqueWindowsHandle::UniqueWindowsHandle(UniqueWindowsHandle&& other) noexcept
    : handle_(other.release()) {}

UniqueWindowsHandle& UniqueWindowsHandle::operator=(
    UniqueWindowsHandle&& other) noexcept {
  if (this != &other) reset(other.release());
  return *this;
}

HANDLE UniqueWindowsHandle::release() {
  HANDLE result = handle_;
  handle_ = INVALID_HANDLE_VALUE;
  return result;
}

void UniqueWindowsHandle::reset(HANDLE handle) {
  if (valid()) CloseHandle(handle_);
  handle_ = handle;
}

bool WindowsFileIdentity::operator==(const WindowsFileIdentity& other) const {
  return volume_serial == other.volume_serial && file_id == other.file_id &&
         directory == other.directory;
}

bool WindowsVerifiedPayloadIdentity::operator==(
    const WindowsVerifiedPayloadIdentity& other) const {
  return package_id == other.package_id &&
         authenticode_publisher == other.authenticode_publisher &&
         package_identity_sha256 == other.package_identity_sha256 &&
         stage_provenance_sha256 == other.stage_provenance_sha256 &&
         artifact_sha256 == other.artifact_sha256 &&
         executable_relative_path == other.executable_relative_path &&
         executable_sha256 == other.executable_sha256;
}

WindowsTransactionPaths WindowsTransactionPaths::Create(
    const std::wstring& target_name,
    const std::string& transaction_id) {
  ValidateSimpleName(target_name);
  if (!std::regex_match(transaction_id, kTransactionId)) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "transaction ID must be a lowercase UUIDv4");
  }
  const std::wstring wide_transaction(transaction_id.begin(),
                                      transaction_id.end());
  const std::wstring prefix = L"." + target_name + L".desktop-updater-" +
                              wide_transaction;
  return {target_name,
          transaction_id,
          prefix + L".prepared",
          prefix + L".backup",
          prefix + L".journal.json",
          prefix + L".journal.json.next",
          L"." + target_name + L".desktop-updater.lock"};
}

std::vector<WindowsTransactionFaultPoint>
WindowsTransactionCrashInjectionPoints() {
  return {
      WindowsTransactionFaultPoint::kBeforePreparedJournalFlush,
      WindowsTransactionFaultPoint::kAfterPreparedJournalFlush,
      WindowsTransactionFaultPoint::kBeforeStageRename,
      WindowsTransactionFaultPoint::kAfterStageRenameBeforeDirectoryFlush,
      WindowsTransactionFaultPoint::kAfterStageRename,
      WindowsTransactionFaultPoint::kBeforeBackupRename,
      WindowsTransactionFaultPoint::kAfterBackupRenameBeforeDirectoryFlush,
      WindowsTransactionFaultPoint::kAfterBackupRename,
      WindowsTransactionFaultPoint::kBeforeBackupCreatedJournalFlush,
      WindowsTransactionFaultPoint::kAfterBackupCreatedJournalFlush,
      WindowsTransactionFaultPoint::kBeforeActivationRename,
      WindowsTransactionFaultPoint::kAfterActivationRenameBeforeDirectoryFlush,
      WindowsTransactionFaultPoint::kAfterActivationRename,
      WindowsTransactionFaultPoint::kBeforeTargetActivatedJournalFlush,
      WindowsTransactionFaultPoint::kAfterTargetActivatedJournalFlush,
      WindowsTransactionFaultPoint::kBeforeCompletedJournalFlush,
      WindowsTransactionFaultPoint::kAfterCompletedJournalFlush,
  };
}

std::string WindowsTransactionJournal::EncodeCanonical() const {
  JsonValue::Object object;
  object.emplace("backupName", JsonValue(WideToUtf8(backup_name)));
  object.emplace("expectedPayloadIdentity",
                 EncodePayload(expected_payload_identity));
  object.emplace("lockName", JsonValue(WideToUtf8(lock_name)));
  object.emplace("originalStageName",
                 JsonValue(WideToUtf8(original_stage_name)));
  object.emplace("ownerProcessId",
                 JsonValue(static_cast<std::int64_t>(owner_process_id)));
  object.emplace(
      "ownerProcessStartIdentity",
      JsonValue(static_cast<std::int64_t>(owner_process_start_identity)));
  object.emplace("parentIdentity", EncodeIdentity(parent_identity));
  object.emplace("preparedName", JsonValue(WideToUtf8(prepared_name)));
  object.emplace("schemaVersion", JsonValue(schema_version));
  object.emplace("stageIdentity", EncodeIdentity(stage_identity));
  object.emplace("state", JsonValue(StateName(state)));
  object.emplace("targetIdentity", EncodeIdentity(target_identity));
  object.emplace("targetName", JsonValue(WideToUtf8(target_name)));
  object.emplace("transactionId", JsonValue(transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

WindowsTransactionJournal WindowsTransactionJournal::DecodeStrict(
    const std::string& json) {
  if (json.empty() || json.size() > 64 * 1024) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "journal length rejected");
  }
  try {
    const JsonValue value = ParseJson(json);
    if (EncodeCanonicalJson(value) != json) {
      throw WindowsTransactionJournalError(
          WindowsTransactionJournalError::Code::kInvalidJournal,
          "journal is not canonical JSON");
    }
    RequireKeys(value,
                {"backupName", "expectedPayloadIdentity", "lockName",
                 "originalStageName", "ownerProcessId",
                 "ownerProcessStartIdentity", "parentIdentity",
                 "preparedName", "schemaVersion", "stageIdentity", "state",
                 "targetIdentity", "targetName", "transactionId"});
    WindowsTransactionJournal journal;
    journal.schema_version = value.at("schemaVersion").integer();
    journal.transaction_id = value.at("transactionId").string();
    journal.owner_process_id =
        static_cast<DWORD>(value.at("ownerProcessId").integer());
    journal.owner_process_start_identity = static_cast<std::uint64_t>(
        value.at("ownerProcessStartIdentity").integer());
    journal.target_name = Utf8ToWide(value.at("targetName").string());
    journal.original_stage_name =
        Utf8ToWide(value.at("originalStageName").string());
    journal.prepared_name = Utf8ToWide(value.at("preparedName").string());
    journal.backup_name = Utf8ToWide(value.at("backupName").string());
    journal.lock_name = Utf8ToWide(value.at("lockName").string());
    journal.parent_identity = DecodeIdentity(value.at("parentIdentity"));
    journal.target_identity = DecodeIdentity(value.at("targetIdentity"));
    journal.stage_identity = DecodeIdentity(value.at("stageIdentity"));
    journal.expected_payload_identity =
        DecodePayload(value.at("expectedPayloadIdentity"));
    journal.state = ParseState(value.at("state").string());
    const WindowsTransactionPaths paths = WindowsTransactionPaths::Create(
        journal.target_name, journal.transaction_id);
    ValidateSimpleName(journal.original_stage_name);
    if (journal.schema_version != kSchemaVersion ||
        journal.owner_process_id == 0 ||
        journal.owner_process_start_identity == 0 ||
        journal.original_stage_name == journal.target_name ||
        journal.prepared_name != paths.prepared_name ||
        journal.backup_name != paths.backup_name ||
        journal.lock_name != paths.lock_name) {
      throw WindowsTransactionJournalError(
          WindowsTransactionJournalError::Code::kInvalidJournal,
          "journal authority fields do not match derived values");
    }
    return journal;
  } catch (const WindowsTransactionJournalError&) {
    throw;
  } catch (const JsonError&) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "journal JSON is corrupt or torn");
  } catch (const std::exception&) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "journal decoding failed");
  }
}

UniqueWindowsHandle OpenRelativeNoReparse(
    HANDLE RootDirectory,
    const std::wstring& relative_path,
    ACCESS_MASK desired_access,
    ULONG share_access,
    ULONG create_disposition,
    ULONG create_options,
    ULONG file_attributes) {
  if (RootDirectory == nullptr || RootDirectory == INVALID_HANDLE_VALUE ||
      relative_path.empty() || relative_path.front() == L'\\' ||
      relative_path.front() == L'/' || relative_path.find(L':') !=
                                             std::wstring::npos) {
    ThrowOpenError(ERROR_INVALID_NAME, "relative authority path rejected");
  }
  UNICODE_STRING name{};
  if (relative_path.size() > USHRT_MAX / sizeof(wchar_t)) {
    ThrowOpenError(ERROR_FILENAME_EXCED_RANGE, "relative path is too long");
  }
  name.Buffer = const_cast<PWSTR>(relative_path.data());
  name.Length = static_cast<USHORT>(relative_path.size() * sizeof(wchar_t));
  name.MaximumLength = name.Length;
  OBJECT_ATTRIBUTES attributes{};
  InitializeObjectAttributes(&attributes, &name,
                             OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE,
                             RootDirectory, nullptr);
  IO_STATUS_BLOCK status_block{};
  HANDLE handle = INVALID_HANDLE_VALUE;
  const auto nt_create_file = ResolveNtCreateFile();
  if (nt_create_file == nullptr) {
    ThrowOpenError(ERROR_PROC_NOT_FOUND, "NtCreateFile is unavailable");
  }
  const NTSTATUS status = nt_create_file(
      &handle, desired_access, &attributes, &status_block, nullptr,
      file_attributes, share_access, create_disposition,
      create_options | FILE_OPEN_REPARSE_POINT, nullptr, 0);
  if (status < 0) {
    ThrowOpenError(NtStatusToError(status), "NtCreateFile relative open failed");
  }
  UniqueWindowsHandle result(handle);
  const WindowsFileIdentity identity = ReadWindowsFileIdentity(result.get());
  if ((identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    ThrowOpenError(ERROR_CANT_ACCESS_FILE,
                   "relative path resolved to a reparse point");
  }
  return result;
}

WindowsFileIdentity ReadWindowsFileIdentity(HANDLE handle) {
  FILE_ID_INFO file_id{};
  FILE_STANDARD_INFO standard{};
  FILE_ATTRIBUTE_TAG_INFO attributes{};
  if (!GetFileInformationByHandleEx(handle, FileIdInfo, &file_id,
                                    sizeof(file_id)) ||
      !GetFileInformationByHandleEx(handle, FileStandardInfo, &standard,
                                    sizeof(standard)) ||
      !GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &attributes,
                                    sizeof(attributes))) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kPersistenceFailed,
        "file identity query failed");
  }
  WindowsFileIdentity result;
  result.volume_serial = file_id.VolumeSerialNumber;
  std::copy(std::begin(file_id.FileId.Identifier),
            std::end(file_id.FileId.Identifier), result.file_id.begin());
  result.attributes = attributes.FileAttributes;
  result.number_of_links = standard.NumberOfLinks;
  result.directory = (attributes.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  if ((attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kReparsePoint,
        "reparse-point identity rejected");
  }
  ValidateWindowsLinkCount(result.directory, result.number_of_links);
  return result;
}

void ValidateWindowsLinkCount(bool directory, DWORD NumberOfLinks) {
  if (!directory && NumberOfLinks != 1) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kReparsePoint,
        "hard-linked mutation object rejected");
  }
}

bool ExistsRelativeNoReparse(HANDLE parent,
                             const std::wstring& relative_path) {
  try {
    auto handle = OpenRelativeNoReparse(
        parent, relative_path, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
        FILE_SYNCHRONOUS_IO_NONALERT);
    return handle.valid();
  } catch (const WindowsTransactionJournalError&) {
    const DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
      return false;
    }
    throw;
  }
}

std::string ReadUtf8FileRelative(HANDLE parent,
                                 const std::wstring& relative_path,
                                 std::size_t maximum_bytes) {
  auto file = OpenRelativeNoReparse(
      parent, relative_path, GENERIC_READ | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  std::string result;
  std::array<char, 4096> buffer{};
  for (;;) {
    DWORD read = 0;
    if (!ReadFile(file.get(), buffer.data(), static_cast<DWORD>(buffer.size()),
                  &read, nullptr)) {
      throw WindowsTransactionJournalError(
          WindowsTransactionJournalError::Code::kInvalidJournal,
          "relative file read failed");
    }
    if (read == 0) return result;
    if (result.size() + read > maximum_bytes) {
      throw WindowsTransactionJournalError(
          WindowsTransactionJournalError::Code::kInvalidJournal,
          "relative file exceeds size limit");
    }
    result.append(buffer.data(), read);
  }
}

void RenameHandleRelative(HANDLE source,
                          HANDLE RootDirectory,
                          const std::wstring& destination,
                          bool replace_existing) {
  ValidateSimpleName(destination);
  const DWORD name_bytes =
      static_cast<DWORD>(destination.size() * sizeof(wchar_t));
  std::vector<unsigned char> storage(
      offsetof(FILE_RENAME_INFO, FileName) + name_bytes);
  auto* info = reinterpret_cast<FILE_RENAME_INFO*>(storage.data());
  info->Flags = replace_existing ? FILE_RENAME_FLAG_REPLACE_IF_EXISTS : 0;
  info->RootDirectory = RootDirectory;
  info->FileNameLength = name_bytes;
  std::memcpy(info->FileName, destination.data(), name_bytes);
  if (SetFileInformationByHandle(source, FileRenameInfoEx, info,
                                 static_cast<DWORD>(storage.size()))) {
    return;
  }
  const DWORD extended_error = GetLastError();
  if (extended_error != ERROR_INVALID_PARAMETER &&
      extended_error != ERROR_NOT_SUPPORTED) {
    ThrowOpenError(extended_error, "handle-relative rename failed");
  }
  info->ReplaceIfExists = replace_existing ? TRUE : FALSE;
  if (!SetFileInformationByHandle(source, FileRenameInfo, info,
                                  static_cast<DWORD>(storage.size()))) {
    ThrowOpenError(GetLastError(), "handle-relative rename fallback failed");
  }
}

void DeleteHandleExact(HANDLE handle) {
  FILE_DISPOSITION_INFO_EX extended{};
  extended.Flags = FILE_DISPOSITION_FLAG_DELETE |
                   FILE_DISPOSITION_FLAG_POSIX_SEMANTICS |
                   FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE;
  if (SetFileInformationByHandle(handle, FileDispositionInfoEx, &extended,
                                 sizeof(extended))) {
    return;
  }
  const DWORD extended_error = GetLastError();
  if (extended_error != ERROR_INVALID_PARAMETER &&
      extended_error != ERROR_NOT_SUPPORTED) {
    ThrowOpenError(extended_error, "exact handle deletion failed");
  }
  FILE_DISPOSITION_INFO fallback{};
  fallback.DeleteFile = TRUE;
  if (!SetFileInformationByHandle(handle, FileDispositionInfo, &fallback,
                                  sizeof(fallback))) {
    ThrowOpenError(GetLastError(), "exact handle deletion fallback failed");
  }
}

void DeleteTreeRelative(HANDLE parent,
                        const std::wstring& leaf,
                        const WindowsFileIdentity& expected_identity) {
  auto object = OpenRelativeNoReparse(
      parent, leaf,
      DELETE | FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_SYNCHRONOUS_IO_NONALERT);
  if (ReadWindowsFileIdentity(object.get()) != expected_identity) {
    throw WindowsTransactionJournalError(
        WindowsTransactionJournalError::Code::kInvalidJournal,
        "backupIdentityMismatch");
  }
  DeleteObjectRecursive(object.get());
  FlushWindowsDirectory(parent);
}

void FlushWindowsDirectory(HANDLE directory) {
  if (FlushFileBuffers(directory)) return;
  const DWORD error = GetLastError();
  if (error == ERROR_INVALID_FUNCTION || error == ERROR_INVALID_HANDLE ||
      error == ERROR_NOT_SUPPORTED || error == ERROR_ACCESS_DENIED) {
    return;
  }
  ThrowOpenError(error, "containing directory flush failed");
}

DurableWindowsTransactionJournalStore::DurableWindowsTransactionJournalStore(
    HANDLE parent,
    WindowsTransactionPaths paths,
    WindowsTransactionFaultInjector* fault_injector)
    : parent_(parent),
      paths_(std::move(paths)),
      fault_injector_(fault_injector == nullptr ? &no_faults_
                                               : fault_injector) {}

std::optional<WindowsTransactionJournal>
DurableWindowsTransactionJournalStore::Load() const {
  if (!ExistsRelativeNoReparse(parent_, paths_.journal_name)) {
    return std::nullopt;
  }
  return WindowsTransactionJournal::DecodeStrict(
      ReadUtf8FileRelative(parent_, paths_.journal_name, 64 * 1024));
}

std::pair<WindowsTransactionFaultPoint, WindowsTransactionFaultPoint>
DurableWindowsTransactionJournalStore::FaultPoints(
    WindowsTransactionState state) const {
  switch (state) {
    case WindowsTransactionState::kPrepared:
      return {WindowsTransactionFaultPoint::kBeforePreparedJournalFlush,
              WindowsTransactionFaultPoint::kAfterPreparedJournalFlush};
    case WindowsTransactionState::kBackupCreated:
      return {
          WindowsTransactionFaultPoint::kBeforeBackupCreatedJournalFlush,
          WindowsTransactionFaultPoint::kAfterBackupCreatedJournalFlush};
    case WindowsTransactionState::kTargetActivated:
      return {
          WindowsTransactionFaultPoint::kBeforeTargetActivatedJournalFlush,
          WindowsTransactionFaultPoint::kAfterTargetActivatedJournalFlush};
    case WindowsTransactionState::kCompleted:
    case WindowsTransactionState::kManualActionRequired:
      return {WindowsTransactionFaultPoint::kBeforeCompletedJournalFlush,
              WindowsTransactionFaultPoint::kAfterCompletedJournalFlush};
  }
  return {WindowsTransactionFaultPoint::kBeforeCompletedJournalFlush,
          WindowsTransactionFaultPoint::kAfterCompletedJournalFlush};
}

void DurableWindowsTransactionJournalStore::Persist(
    const WindowsTransactionJournal& journal) {
  const auto points = FaultPoints(journal.state);
  fault_injector_->Hit(points.first);
  fault_injector_->Hit(WindowsTransactionFaultPoint::kDiskFull);
  const std::string contents = journal.EncodeCanonical();
  auto next = OpenRelativeNoReparse(
      parent_, paths_.journal_next_name,
      GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_CREATE,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH);
  fault_injector_->Hit(WindowsTransactionFaultPoint::kShortJournalWrite);
  WriteAll(next.get(), contents);
  fault_injector_->Hit(WindowsTransactionFaultPoint::kFileFlushFailure);
  if (!FlushFileBuffers(next.get())) {
    ThrowOpenError(GetLastError(), "FlushFileBuffers journal failure");
  }
  RenameHandleRelative(next.get(), parent_, paths_.journal_name, true);
  fault_injector_->Hit(WindowsTransactionFaultPoint::kDirectoryFlushFailure);
  FlushWindowsDirectory(parent_);
  fault_injector_->Hit(points.second);
}

void DurableWindowsTransactionJournalStore::Remove() {
  if (!ExistsRelativeNoReparse(parent_, paths_.journal_name)) return;
  auto journal = OpenRelativeNoReparse(
      parent_, paths_.journal_name, DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  DeleteHandleExact(journal.get());
  FlushWindowsDirectory(parent_);
}

}  // namespace desktop_updater::helper
