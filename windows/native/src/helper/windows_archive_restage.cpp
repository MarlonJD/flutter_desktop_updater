#include "windows_archive_restage.h"

#include <objbase.h>
#include <winternl.h>

#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <climits>
#include <cstdio>
#include <cstring>
#include <cwctype>
#include <limits>
#include <map>
#include <memory>
#include <regex>
#include <set>
#include <sstream>
#include <utility>

#include "json_value.h"
#include "miniz.h"
#include "windows_helper_bootstrap.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;
using desktop_updater::runtime::internal::StageBytesToHex;
using desktop_updater::runtime::internal::StageProvenanceEntry;
using desktop_updater::runtime::internal::StageProvenanceMarker;

constexpr wchar_t kArtifactLeaf[] = L".desktop_updater_artifact.zip";
constexpr char kArtifactControlName[] = ".desktop_updater_artifact.zip";
constexpr char kManifestControlName[] =
    ".desktop_updater_release_manifest.json";
constexpr char kProvenanceControlName[] =
    ".desktop_updater_stage_provenance.json";
constexpr std::size_t kMaximumArchivePathBytes = 32767;
constexpr std::size_t kMaximumArchiveDepth = 256;
constexpr std::size_t kMaximumPayloadPathBytes = 64 * 1024 * 1024;
constexpr std::size_t kMaximumPayloadSealBytes = 64 * 1024 * 1024;
constexpr std::size_t kMaximumPayloadEntries = 100000;
constexpr std::size_t kMaximumRecoveryWorkUnits = 1000000;
constexpr std::int64_t kMaximumArchiveEntries = 100000;
constexpr std::int64_t kMaximumExpandedBytes =
    INT64_C(8) * 1024 * 1024 * 1024;
constexpr std::int64_t kMaximumSingleEntryBytes =
    INT64_C(4) * 1024 * 1024 * 1024;
const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
const std::regex kSha256("^[0-9a-f]{64}$");

[[noreturn]] void Fail(const std::string& detail) {
  throw WindowsArchiveRestageError(detail);
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty() || value.size() > static_cast<std::size_t>(INT_MAX)) {
    Fail("ZIP path is not bounded UTF-8");
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) Fail("ZIP path is not valid UTF-8");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    Fail("ZIP path UTF-8 conversion failed");
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty() || value.size() > static_cast<std::size_t>(INT_MAX)) {
    Fail("Windows path is not bounded UTF-16");
  }
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) Fail("Windows path is not valid UTF-16");
  std::string result(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length, nullptr, nullptr) != length) {
    Fail("Windows path UTF-16 conversion failed");
  }
  return result;
}

std::wstring LowercaseInvariant(const std::wstring& value) {
  const int length = LCMapStringEx(
      LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr, 0);
  if (length <= 0) Fail("Windows case-folding failed");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, value.data(),
                    static_cast<int>(value.size()), result.data(), length,
                    nullptr, nullptr, 0) != length) {
    Fail("Windows case-folding changed");
  }
  return result;
}

bool IsReservedControlComponent(const std::wstring& component) {
  const std::wstring lowered = LowercaseInvariant(component);
  return lowered == Utf8ToWide(kArtifactControlName) ||
         lowered == Utf8ToWide(kManifestControlName) ||
         lowered == Utf8ToWide(kProvenanceControlName);
}

bool IsDosDeviceName(const std::wstring& component) {
  std::wstring base = component.substr(0, component.find(L'.'));
  std::transform(base.begin(), base.end(), base.begin(),
                 [](wchar_t value) { return std::towupper(value); });
  if (base == L"CON" || base == L"PRN" || base == L"AUX" ||
      base == L"NUL" || base == L"CLOCK$") {
    return true;
  }
  if (base.size() == 4 && base[3] >= L'1' && base[3] <= L'9' &&
      (base.rfind(L"COM", 0) == 0 || base.rfind(L"LPT", 0) == 0)) {
    return true;
  }
  return false;
}

struct SafeArchivePath {
  std::string utf8;
  std::wstring windows;
  std::vector<std::wstring> components;
  std::string comparison_key;
};

SafeArchivePath ValidateArchivePath(const std::string& raw,
                                    bool directory,
                                    bool reject_root_control_name = true) {
  if (raw.empty() || raw.size() > kMaximumArchivePathBytes ||
      raw.front() == '/' || raw.front() == '\\' ||
      raw.find('\\') != std::string::npos ||
      raw.find(':') != std::string::npos ||
      raw.find('\0') != std::string::npos ||
      (raw.size() >= 2 && std::isalpha(
                              static_cast<unsigned char>(raw[0])) != 0 &&
       raw[1] == ':')) {
    Fail("ZIP absolute, drive, UNC, ADS, or malformed path rejected");
  }
  std::string normalized = raw;
  if (directory) {
    if (normalized.back() != '/' ||
        (normalized.size() > 1 &&
         normalized[normalized.size() - 2] == '/')) {
      Fail("ZIP directory path is not canonical");
    }
    normalized.pop_back();
  } else if (normalized.back() == '/') {
    Fail("ZIP file path has a directory suffix");
  }
  if (normalized.empty()) Fail("ZIP root entry rejected");

  SafeArchivePath result;
  result.utf8 = normalized;
  std::size_t start = 0;
  while (start <= normalized.size()) {
    const std::size_t slash = normalized.find('/', start);
    const std::string encoded = normalized.substr(start, slash - start);
    if (encoded.empty() || encoded == "." || encoded == "..") {
      Fail("ZIP traversal or non-canonical segment rejected");
    }
    const std::wstring component = Utf8ToWide(encoded);
    if (component.empty() || component.size() > 255 ||
        component.back() == L'.' || component.back() == L' ' ||
        IsDosDeviceName(component) ||
        std::any_of(component.begin(), component.end(), [](wchar_t value) {
          return value < 0x20 || value == L'<' || value == L'>' ||
                 value == L'"' || value == L'|' || value == L'?' ||
                 value == L'*' || value == L':' || value == L'/' ||
                 value == L'\\';
        })) {
      Fail("ZIP reserved, device, trailing, or invalid segment rejected");
    }
    result.components.push_back(component);
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  if (result.components.empty() ||
      result.components.size() > kMaximumArchiveDepth) {
    Fail("ZIP path depth rejected");
  }
  for (const std::wstring& component : result.components) {
    if (!result.windows.empty()) result.windows.push_back(L'\\');
    result.windows += component;
  }
  if (reject_root_control_name && result.components.size() == 1 &&
      IsReservedControlComponent(result.components.front())) {
    Fail("ZIP root control-plane name rejected");
  }
  result.comparison_key = WideToUtf8(LowercaseInvariant(result.windows));
  return result;
}

void VerifyNoAlternateDataStreams(HANDLE object) {
  alignas(FILE_STREAM_INFO) std::array<unsigned char, 64 * 1024> buffer{};
  if (!GetFileInformationByHandleEx(object, FileStreamInfo, buffer.data(),
                                    static_cast<DWORD>(buffer.size()))) {
    const DWORD error = GetLastError();
    if (error == ERROR_HANDLE_EOF || error == ERROR_NO_MORE_FILES) return;
    Fail("filesystem stream enumeration failed");
  }
  auto* stream = reinterpret_cast<FILE_STREAM_INFO*>(buffer.data());
  bool default_stream_seen = false;
  for (;;) {
    const std::wstring name(stream->StreamName,
                            stream->StreamNameLength / sizeof(wchar_t));
    if (name != L"::$DATA" || default_stream_seen) {
      Fail("alternate data stream rejected");
    }
    default_stream_seen = true;
    if (stream->NextEntryOffset == 0) break;
    stream = reinterpret_cast<FILE_STREAM_INFO*>(
        reinterpret_cast<unsigned char*>(stream) + stream->NextEntryOffset);
  }
}

std::int64_t FileLength(HANDLE file) {
  FILE_STANDARD_INFO information{};
  if (!GetFileInformationByHandleEx(file, FileStandardInfo, &information,
                                    sizeof(information)) ||
      information.EndOfFile.QuadPart < 0) {
    Fail("file length query failed");
  }
  return information.EndOfFile.QuadPart;
}

class Sha256Stream {
 public:
  Sha256Stream() {
    DWORD object_size = 0;
    DWORD received = 0;
    if (BCryptOpenAlgorithmProvider(&algorithm_, BCRYPT_SHA256_ALGORITHM,
                                    nullptr, 0) < 0 ||
        BCryptGetProperty(algorithm_, BCRYPT_OBJECT_LENGTH,
                          reinterpret_cast<PUCHAR>(&object_size),
                          sizeof(object_size), &received, 0) < 0) {
      Fail("SHA-256 provider setup failed");
    }
    object_.resize(object_size);
    if (BCryptCreateHash(algorithm_, &hash_, object_.data(), object_size,
                         nullptr, 0, 0) < 0) {
      Fail("SHA-256 state creation failed");
    }
  }

  ~Sha256Stream() {
    if (hash_ != nullptr) BCryptDestroyHash(hash_);
    if (algorithm_ != nullptr) BCryptCloseAlgorithmProvider(algorithm_, 0);
  }

  void Update(const void* bytes, std::size_t length) {
    const auto* cursor = static_cast<const unsigned char*>(bytes);
    while (length > 0) {
      const ULONG chunk = static_cast<ULONG>(std::min<std::size_t>(
          length, static_cast<std::size_t>(ULONG_MAX)));
      if (BCryptHashData(hash_, const_cast<PUCHAR>(cursor), chunk, 0) < 0) {
        Fail("SHA-256 update failed");
      }
      cursor += chunk;
      length -= chunk;
    }
  }

  std::string Finish() {
    if (finished_) Fail("SHA-256 state was finalized twice");
    std::vector<std::uint8_t> digest(32);
    if (BCryptFinishHash(hash_, digest.data(),
                         static_cast<ULONG>(digest.size()), 0) < 0) {
      Fail("SHA-256 finalization failed");
    }
    finished_ = true;
    return StageBytesToHex(digest);
  }

 private:
  BCRYPT_ALG_HANDLE algorithm_ = nullptr;
  BCRYPT_HASH_HANDLE hash_ = nullptr;
  std::vector<unsigned char> object_;
  bool finished_ = false;
};

std::string Sha256Bytes(const std::string& bytes) {
  Sha256Stream hash;
  hash.Update(bytes.data(), bytes.size());
  return hash.Finish();
}

std::string Sha256Handle(HANDLE file) {
  LARGE_INTEGER beginning{};
  if (!SetFilePointerEx(file, beginning, nullptr, FILE_BEGIN)) {
    Fail("SHA-256 file seek failed");
  }
  Sha256Stream hash;
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &count, nullptr)) {
      Fail("SHA-256 file read failed");
    }
    if (count == 0) return hash.Finish();
    hash.Update(buffer.data(), count);
  }
}

std::string ReadHandleUtf8(HANDLE file, std::size_t maximum_bytes) {
  LARGE_INTEGER beginning{};
  if (!SetFilePointerEx(file, beginning, nullptr, FILE_BEGIN)) {
    Fail("restage control read seek failed");
  }
  std::string result;
  std::array<char, 4096> buffer{};
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &count, nullptr)) {
      Fail("restage control read failed");
    }
    if (count == 0) return result;
    if (result.size() + count > maximum_bytes) {
      Fail("restage control exceeds size limit");
    }
    result.append(buffer.data(), count);
  }
}

void WriteAll(HANDLE file, const std::string& bytes) {
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    DWORD written = 0;
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        bytes.size() - offset, static_cast<std::size_t>(MAXDWORD)));
    if (!WriteFile(file, bytes.data() + offset, requested, &written,
                   nullptr) ||
        written == 0) {
      Fail("restage control write failed");
    }
    offset += written;
  }
  if (!SetEndOfFile(file) || !FlushFileBuffers(file)) {
    Fail("restage control durability flush failed");
  }
}

std::string RandomUuidV4() {
  GUID guid{};
  if (CoCreateGuid(&guid) != S_OK) Fail("restage nonce generation failed");
  std::array<wchar_t, 64> encoded{};
  const int length =
      StringFromGUID2(guid, encoded.data(), static_cast<int>(encoded.size()));
  if (length != 39) Fail("restage nonce encoding failed");
  std::wstring value(encoded.data() + 1, encoded.data() + 37);
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  const std::string utf8 = WideToUtf8(value);
  if (!std::regex_match(utf8, kTransactionId)) {
    Fail("restage nonce is not UUIDv4");
  }
  return utf8;
}

std::wstring CallerUserSid(HANDLE caller_process) {
  if (caller_process == nullptr) {
    Fail("portable restage caller process is unavailable");
  }
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(caller_process, TOKEN_QUERY, &raw_token)) {
    Fail("portable restage caller token is unavailable");
  }
  UniqueWindowsHandle token(raw_token);
  DWORD length = 0;
  GetTokenInformation(token.get(), TokenUser, nullptr, 0, &length);
  if (length == 0) Fail("portable restage caller SID size failed");
  std::vector<unsigned char> storage(length);
  if (!GetTokenInformation(token.get(), TokenUser, storage.data(), length,
                           &length)) {
    Fail("portable restage caller SID query failed");
  }
  const auto* user = reinterpret_cast<const TOKEN_USER*>(storage.data());
  wchar_t* raw_sid = nullptr;
  if (!ConvertSidToStringSidW(user->User.Sid, &raw_sid) ||
      raw_sid == nullptr) {
    Fail("portable restage caller SID conversion failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> sid(raw_sid, LocalFree);
  return std::wstring(raw_sid);
}

std::wstring SecuritySddl(WindowsArchiveRestageAuthority authority,
                          HANDLE caller_process) {
  if (authority == WindowsArchiveRestageAuthority::kInstallerProtected) {
    return L"O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
           L"(A;OICI;GRGX;;;BU)";
  }
  const std::wstring caller_sid = CallerUserSid(caller_process);
  return L"O:" + caller_sid + L"G:" + caller_sid +
         L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + caller_sid + L")";
}

void VerifyObjectSecurity(HANDLE object,
                          WindowsArchiveRestageAuthority authority,
                          HANDLE caller_process) {
  const std::wstring expected_sddl = SecuritySddl(authority, caller_process);
  PSECURITY_DESCRIPTOR raw_expected = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          expected_sddl.c_str(), SDDL_REVISION_1, &raw_expected, nullptr) ||
      raw_expected == nullptr) {
    Fail("expected restage security descriptor construction failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> expected_descriptor(
      raw_expected, LocalFree);
  PSID expected_owner = nullptr;
  PSID expected_group = nullptr;
  PACL expected_dacl = nullptr;
  BOOL expected_defaulted = FALSE;
  BOOL expected_present = FALSE;
  if (!GetSecurityDescriptorOwner(raw_expected, &expected_owner,
                                  &expected_defaulted) ||
      !GetSecurityDescriptorGroup(raw_expected, &expected_group,
                                  &expected_defaulted) ||
      !GetSecurityDescriptorDacl(raw_expected, &expected_present,
                                 &expected_dacl, &expected_defaulted) ||
      expected_owner == nullptr || expected_group == nullptr ||
      !expected_present || expected_dacl == nullptr) {
    Fail("expected restage security descriptor is incomplete");
  }

  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PSID owner = nullptr;
  PSID group = nullptr;
  PACL dacl = nullptr;
  const DWORD result = GetSecurityInfo(
      object, SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |
          DACL_SECURITY_INFORMATION,
      &owner, &group, &dacl, nullptr, &raw_descriptor);
  if (result != ERROR_SUCCESS || raw_descriptor == nullptr || owner == nullptr ||
      group == nullptr || dacl == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    Fail("restage security descriptor readback failed");
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!GetSecurityDescriptorControl(raw_descriptor, &control, &revision) ||
      (control & SE_DACL_PROTECTED) == 0) {
    Fail("restage DACL is not protected");
  }
  if (EqualSid(owner, expected_owner) == FALSE ||
      EqualSid(group, expected_group) == FALSE ||
      dacl->AceCount != expected_dacl->AceCount ||
      dacl->AclRevision != expected_dacl->AclRevision) {
    Fail("restage owner, group, or exact DACL changed");
  }
  for (DWORD index = 0; index < expected_dacl->AceCount; ++index) {
    void* raw_ace = nullptr;
    void* raw_expected_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace) || raw_ace == nullptr ||
        !GetAce(expected_dacl, index, &raw_expected_ace) ||
        raw_expected_ace == nullptr) {
      Fail("restage DACL readback is malformed");
    }
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    const auto* expected_header =
        static_cast<const ACE_HEADER*>(raw_expected_ace);
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE ||
        expected_header->AceType != ACCESS_ALLOWED_ACE_TYPE ||
        header->AceFlags != expected_header->AceFlags ||
        header->AceSize != expected_header->AceSize) {
      Fail("restage DACL ACE type, flags, or size changed");
    }
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    const auto* expected_ace =
        static_cast<const ACCESS_ALLOWED_ACE*>(raw_expected_ace);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    PSID expected_sid = const_cast<DWORD*>(&expected_ace->SidStart);
    if (ace->Mask != expected_ace->Mask ||
        EqualSid(sid, expected_sid) == FALSE) {
      Fail("restage DACL ACE mask or SID changed");
    }
  }
}

class ExactCreateSecurityDescriptor {
 public:
  ExactCreateSecurityDescriptor(WindowsArchiveRestageAuthority authority,
                                HANDLE caller_process) {
    const std::wstring sddl = SecuritySddl(authority, caller_process);
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.c_str(), SDDL_REVISION_1, &descriptor_, nullptr) ||
        descriptor_ == nullptr) {
      Fail("restage create security descriptor construction failed");
    }
    if (!IsValidSecurityDescriptor(descriptor_) ||
        GetSecurityDescriptorLength(descriptor_) == 0) {
      LocalFree(descriptor_);
      descriptor_ = nullptr;
      Fail("restage create security descriptor is invalid");
    }
  }

  ~ExactCreateSecurityDescriptor() {
    if (descriptor_ != nullptr) LocalFree(descriptor_);
  }

  ExactCreateSecurityDescriptor(const ExactCreateSecurityDescriptor&) =
      delete;
  ExactCreateSecurityDescriptor& operator=(
      const ExactCreateSecurityDescriptor&) = delete;

  PSECURITY_DESCRIPTOR get() const { return descriptor_; }

 private:
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
};

std::string AuthorityName(WindowsArchiveRestageAuthority authority) {
  return authority == WindowsArchiveRestageAuthority::kInstallerProtected
             ? "installerProtected"
             : "portableExactCaller";
}

struct RestageControlRecord {
  std::string transaction_id;
  std::string nonce;
  std::string package_id;
  std::string descriptor_sha256;
  std::string artifact_sha256;
  std::string authority;
};

std::string EncodeRestageControl(const RestageControlRecord& record) {
  JsonValue::Object value;
  value.emplace("artifactSha256", JsonValue(record.artifact_sha256));
  value.emplace("authority", JsonValue(record.authority));
  value.emplace("descriptorSha256", JsonValue(record.descriptor_sha256));
  value.emplace("nonce", JsonValue(record.nonce));
  value.emplace("packageId", JsonValue(record.package_id));
  value.emplace("schemaVersion", JsonValue(static_cast<std::int64_t>(1)));
  value.emplace("transactionId", JsonValue(record.transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(value)));
}

RestageControlRecord DecodeRestageControl(const std::string& encoded) {
  const JsonValue value = ParseJson(encoded);
  if (EncodeCanonicalJson(value) != encoded || value.object().size() != 7 ||
      value.find("artifactSha256") == nullptr ||
      value.find("authority") == nullptr ||
      value.find("descriptorSha256") == nullptr ||
      value.find("nonce") == nullptr || value.find("packageId") == nullptr ||
      value.find("schemaVersion") == nullptr ||
      value.find("transactionId") == nullptr ||
      value.at("schemaVersion").integer() != 1) {
    Fail("restage control record is not canonical schema v1");
  }
  RestageControlRecord result{
      value.at("transactionId").string(),
      value.at("nonce").string(),
      value.at("packageId").string(),
      value.at("descriptorSha256").string(),
      value.at("artifactSha256").string(),
      value.at("authority").string(),
  };
  if (!std::regex_match(result.transaction_id, kTransactionId) ||
      !std::regex_match(result.nonce, kTransactionId) ||
      result.package_id.empty() ||
      !std::regex_match(result.descriptor_sha256, kSha256) ||
      !std::regex_match(result.artifact_sha256, kSha256) ||
      (result.authority != "installerProtected" &&
       result.authority != "portableExactCaller")) {
    Fail("restage control authority binding is invalid");
  }
  return result;
}

std::wstring RestageControlLeaf(const std::string& transaction_id) {
  return L".desktop-updater-" +
         std::wstring(transaction_id.begin(), transaction_id.end()) +
         L".restage.json";
}

std::wstring RestageArchiveLeaf(const std::string& nonce) {
  return L".desktop-updater-restage-" +
         std::wstring(nonce.begin(), nonce.end()) + L".zip";
}

std::wstring RestagePayloadLeaf(const std::string& nonce) {
  return L"desktop_updater_stage_" +
         std::wstring(nonce.begin(), nonce.end());
}

struct VerifiedRecoveryNode {
  UniqueWindowsHandle handle;
  WindowsFileIdentity identity;
  std::size_t depth = 0;
  std::string path;
};

void ConsumeRecoveryWork(std::size_t amount,
                         const WindowsArchiveRestageLimits& limits,
                         std::size_t* work) {
  if (work == nullptr || amount > limits.maximum_recovery_work_units ||
      *work > limits.maximum_recovery_work_units - amount) {
    Fail("restage recovery work limit exceeded");
  }
  *work += amount;
}

void VerifyAndDeleteBoundedPartialTree(
    HANDLE parent,
    UniqueWindowsHandle root,
    const WindowsFileIdentity& expected_root_identity,
    WindowsArchiveRestageAuthority authority,
    HANDLE caller_process,
    const WindowsArchiveRestageLimits& limits) {
  const WindowsFileIdentity root_identity =
      ReadWindowsFileIdentity(root.get());
  if (root_identity != expected_root_identity || !root_identity.directory) {
    Fail("restage recovery root identity changed");
  }

  std::size_t work = 0;
  ConsumeRecoveryWork(1, limits, &work);
  VerifyObjectSecurity(root.get(), authority, caller_process);
  VerifyNoAlternateDataStreams(root.get());

  std::vector<VerifiedRecoveryNode> nodes;
  nodes.reserve(static_cast<std::size_t>(limits.maximum_archive_entries) + 1);
  nodes.push_back({std::move(root), root_identity, 0, std::string()});
  std::size_t descendant_count = 0;
  std::size_t path_bytes = 0;

  for (std::size_t cursor = 0; cursor < nodes.size(); ++cursor) {
    if (!nodes[cursor].identity.directory) continue;
    const HANDLE directory = nodes[cursor].handle.get();
    const std::size_t directory_depth = nodes[cursor].depth;
    const std::string prefix = nodes[cursor].path;
    alignas(FILE_ID_BOTH_DIR_INFO)
        std::array<unsigned char, 64 * 1024> buffer{};
    bool restart = true;
    for (;;) {
      ConsumeRecoveryWork(1, limits, &work);
      const auto information_class =
          restart ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo;
      restart = false;
      if (!GetFileInformationByHandleEx(
              directory, information_class, buffer.data(),
              static_cast<DWORD>(buffer.size()))) {
        if (GetLastError() == ERROR_NO_MORE_FILES) break;
        Fail("partial restage enumeration failed");
      }
      auto* entry = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(buffer.data());
      for (;;) {
        ConsumeRecoveryWork(1, limits, &work);
        const std::wstring name(entry->FileName,
                                entry->FileNameLength / sizeof(wchar_t));
        if (name != L"." && name != L"..") {
          if (descendant_count >=
              static_cast<std::size_t>(limits.maximum_archive_entries)) {
            Fail("restage recovery entry limit exceeded");
          }
          const std::size_t child_depth = directory_depth + 1;
          if (child_depth > limits.maximum_recovery_depth) {
            Fail("restage recovery depth limit exceeded");
          }
          const std::string encoded_name = WideToUtf8(name);
          const std::size_t separator = prefix.empty() ? 0 : 1;
          if (prefix.size() > kMaximumArchivePathBytes - separator ||
              encoded_name.size() >
                  kMaximumArchivePathBytes - prefix.size() - separator) {
            Fail("restage recovery path length exceeded");
          }
          const std::size_t child_path_size =
              prefix.size() + separator + encoded_name.size();
          if (child_path_size > limits.maximum_payload_path_bytes ||
              path_bytes >
                  limits.maximum_payload_path_bytes - child_path_size) {
            Fail("restage recovery cumulative path limit exceeded");
          }
          path_bytes += child_path_size;
          std::string child_path = prefix;
          if (!child_path.empty()) child_path.push_back('/');
          child_path += encoded_name;

          ConsumeRecoveryWork(1, limits, &work);
          auto child = OpenRelativeNoReparse(
              directory, name,
              GENERIC_READ | DELETE | FILE_LIST_DIRECTORY |
                  FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
              0, FILE_OPEN, FILE_SYNCHRONOUS_IO_NONALERT);
          const WindowsFileIdentity identity =
              ReadWindowsFileIdentity(child.get());
          VerifyObjectSecurity(child.get(), authority, caller_process);
          VerifyNoAlternateDataStreams(child.get());
          ++descendant_count;
          nodes.push_back({std::move(child), identity, child_depth,
                           std::move(child_path)});
        }
        if (entry->NextEntryOffset == 0) break;
        entry = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(
            reinterpret_cast<unsigned char*>(entry) +
            entry->NextEntryOffset);
      }
    }
  }

  // Reserve the complete post-order deletion and parent durability work
  // before touching any verified entry. Budget exhaustion therefore leaves
  // the stale tree and durable control evidence entirely intact.
  ConsumeRecoveryWork(nodes.size() + 1, limits, &work);
  for (std::size_t index = nodes.size(); index > 0; --index) {
    DeleteHandleExact(nodes[index - 1].handle.get());
    nodes[index - 1].handle.reset();
  }
  FlushWindowsDirectory(parent);
}

void DeleteOptionalRestageFile(HANDLE parent,
                               const std::wstring& leaf,
                               WindowsArchiveRestageAuthority authority,
                               HANDLE caller_process) {
  if (!ExistsRelativeNoReparse(parent, leaf)) return;
  auto file = OpenRelativeNoReparse(
      parent, leaf,
      GENERIC_READ | DELETE | FILE_READ_ATTRIBUTES | READ_CONTROL |
          SYNCHRONIZE,
      0, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  VerifyObjectSecurity(file.get(), authority, caller_process);
  VerifyNoAlternateDataStreams(file.get());
  if (ReadWindowsFileIdentity(file.get()).directory) {
    Fail("restage control artifact is not a file");
  }
  DeleteHandleExact(file.get());
  file.reset();
  FlushWindowsDirectory(parent);
}

void CleanupPriorRestage(
    HANDLE parent,
    const std::string& transaction_id,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    WindowsArchiveRestageAuthority authority,
    HANDLE caller_process,
    const WindowsArchiveRestageLimits& limits) {
  const std::wstring control_leaf = RestageControlLeaf(transaction_id);
  const std::wstring next_leaf = control_leaf + L".next";
  DeleteOptionalRestageFile(parent, next_leaf, authority, caller_process);
  if (!ExistsRelativeNoReparse(parent, control_leaf)) return;
  auto control = OpenRelativeNoReparse(
      parent, control_leaf,
      GENERIC_READ | DELETE | FILE_READ_ATTRIBUTES | READ_CONTROL |
          SYNCHRONIZE,
      0, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  VerifyObjectSecurity(control.get(), authority, caller_process);
  VerifyNoAlternateDataStreams(control.get());
  const RestageControlRecord record =
      DecodeRestageControl(ReadHandleUtf8(control.get(), 64 * 1024));
  if (record.transaction_id != transaction_id ||
      record.package_id != package_id ||
      record.descriptor_sha256 != descriptor_sha256 ||
      record.artifact_sha256 != artifact_sha256 ||
      record.authority != AuthorityName(authority)) {
    Fail("existing restage control record binding changed");
  }

  const std::wstring payload_leaf = RestagePayloadLeaf(record.nonce);
  if (ExistsRelativeNoReparse(parent, payload_leaf)) {
    auto payload = OpenRelativeNoReparse(
        parent, payload_leaf,
        GENERIC_READ | DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES |
            READ_CONTROL | SYNCHRONIZE,
        0, FILE_OPEN,
        FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
    const WindowsFileIdentity identity =
        ReadWindowsFileIdentity(payload.get());
    VerifyAndDeleteBoundedPartialTree(
        parent, std::move(payload), identity, authority, caller_process,
        limits);
  }
  const std::wstring archive_leaf = RestageArchiveLeaf(record.nonce);
  DeleteOptionalRestageFile(parent, archive_leaf, authority, caller_process);
  DeleteHandleExact(control.get());
  control.reset();
  FlushWindowsDirectory(parent);
}

UniqueWindowsHandle CreateRestageControl(
    HANDLE parent,
    const RestageControlRecord& record,
    WindowsArchiveRestageAuthority authority,
    HANDLE caller_process,
    PSECURITY_DESCRIPTOR create_security_descriptor,
    WindowsArchiveRestageFaultInjector* fault_injector) {
  const std::wstring final_leaf = RestageControlLeaf(record.transaction_id);
  const std::wstring next_leaf = final_leaf + L".next";
  auto control = OpenRelativeNoReparse(
      parent, next_leaf,
      GENERIC_READ | GENERIC_WRITE | DELETE | FILE_READ_ATTRIBUTES |
          READ_CONTROL | WRITE_DAC | WRITE_OWNER | SYNCHRONIZE,
      0, FILE_CREATE,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH,
      FILE_ATTRIBUTE_HIDDEN, create_security_descriptor);
  if (fault_injector != nullptr) {
    fault_injector->Hit(
        WindowsArchiveRestageFaultPoint::kAfterControlFileCreate);
  }
  auto delete_uncommitted = [&]() {
    try {
      DeleteHandleExact(control.get());
      control.reset();
      FlushWindowsDirectory(parent);
    } catch (...) {
    }
  };
  try {
    VerifyObjectSecurity(control.get(), authority, caller_process);
    WriteAll(control.get(), EncodeRestageControl(record));
  } catch (...) {
    delete_uncommitted();
    throw;
  }
  if (fault_injector != nullptr) {
    fault_injector->Hit(
        WindowsArchiveRestageFaultPoint::
            kAfterControlFileFlushBeforeRename);
  }
  try {
    RenameHandleRelative(control.get(), parent, final_leaf, false);
  } catch (...) {
    delete_uncommitted();
    throw;
  }
  if (fault_injector != nullptr) {
    fault_injector->Hit(
        WindowsArchiveRestageFaultPoint::
            kAfterControlRenameBeforeDirectoryFlush);
  }
  // Once the exact, flushed record has been renamed, any directory-flush
  // failure leaves it intact for strict retry reconciliation.
  FlushWindowsDirectory(parent);
  return control;
}

UniqueWindowsHandle OpenAbsoluteDirectoryNoReparse(
    const std::filesystem::path& path,
    ACCESS_MASK desired_access) {
  UniqueWindowsHandle directory(CreateFileW(
      path.c_str(), desired_access,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!directory.valid()) Fail("absolute directory open failed");
  const WindowsFileIdentity identity =
      ReadWindowsFileIdentity(directory.get());
  if (!identity.directory) Fail("absolute path is not a directory");
  VerifyNoAlternateDataStreams(directory.get());
  return directory;
}

std::string ReadArchiveName(mz_zip_archive* archive, mz_uint index) {
  const mz_uint required =
      mz_zip_reader_get_filename(archive, index, nullptr, 0);
  if (required < 2 || required > kMaximumArchivePathBytes + 1) {
    Fail("ZIP filename length rejected");
  }
  std::vector<char> buffer(required, '\0');
  if (mz_zip_reader_get_filename(archive, index, buffer.data(), required) !=
          required ||
      buffer.back() != '\0' ||
      std::memchr(buffer.data(), '\0', required - 1) != nullptr) {
    Fail("ZIP filename encoding rejected");
  }
  return std::string(buffer.data(), required - 1);
}

struct ArchiveEntry {
  mz_uint index = 0;
  SafeArchivePath path;
  bool directory = false;
  std::uint64_t uncompressed_size = 0;
};

struct PathRecord {
  SafeArchivePath path;
  bool directory = false;
  bool explicit_entry = false;
};

SafeArchivePath PrefixPath(const SafeArchivePath& path,
                           std::size_t count) {
  SafeArchivePath result;
  result.components.assign(path.components.begin(),
                           path.components.begin() + count);
  for (const std::wstring& component : result.components) {
    if (!result.windows.empty()) result.windows.push_back(L'\\');
    result.windows += component;
    if (!result.utf8.empty()) result.utf8.push_back('/');
    result.utf8 += WideToUtf8(component);
  }
  result.comparison_key = WideToUtf8(LowercaseInvariant(result.windows));
  return result;
}

void AddBoundedBytes(std::size_t amount,
                     std::size_t maximum,
                     const char* detail,
                     std::size_t* total) {
  if (total == nullptr || amount > maximum || *total > maximum - amount) {
    Fail(detail);
  }
  *total += amount;
}

std::size_t SafeArchivePathStorageBytes(const SafeArchivePath& path) {
  std::size_t result = sizeof(SafeArchivePath);
  auto add = [&](std::size_t count, std::size_t width) {
    if (count > (std::numeric_limits<std::size_t>::max() - result) / width) {
      Fail("ZIP path storage size overflow");
    }
    result += count * width;
  };
  add(path.utf8.size(), sizeof(char));
  add(path.windows.size(), sizeof(wchar_t));
  add(path.comparison_key.size(), sizeof(char));
  add(path.components.size(), sizeof(std::wstring));
  for (const std::wstring& component : path.components) {
    add(component.size(), sizeof(wchar_t));
  }
  return result;
}

void ValidateRestageLimits(const WindowsArchiveRestageLimits& limits) {
  if (limits.maximum_archive_entries <= 0 ||
      limits.maximum_archive_entries > kMaximumArchiveEntries ||
      limits.maximum_uncompressed_bytes <= 0 ||
      limits.maximum_uncompressed_bytes > kMaximumExpandedBytes ||
      limits.maximum_single_entry_bytes <= 0 ||
      limits.maximum_single_entry_bytes > kMaximumSingleEntryBytes ||
      limits.maximum_payload_path_bytes == 0 ||
      limits.maximum_payload_path_bytes > kMaximumPayloadPathBytes ||
      limits.maximum_payload_seal_bytes == 0 ||
      limits.maximum_payload_seal_bytes > kMaximumPayloadSealBytes ||
      limits.maximum_recovery_depth == 0 ||
      limits.maximum_recovery_depth > kMaximumArchiveDepth ||
      limits.maximum_recovery_work_units == 0 ||
      limits.maximum_recovery_work_units > kMaximumRecoveryWorkUnits) {
    Fail("archive restage limits exceed immutable hard bounds");
  }
}

std::vector<ArchiveEntry> PreflightArchive(
    mz_zip_archive* archive,
    const WindowsArchiveRestageLimits& limits,
    std::map<std::string, PathRecord>* paths) {
  ValidateRestageLimits(limits);
  const mz_uint count = mz_zip_reader_get_num_files(archive);
  if (count == 0 ||
      count > static_cast<mz_uint64>(limits.maximum_archive_entries)) {
    Fail("ZIP entry count limit exceeded");
  }
  std::uint64_t total = 0;
  std::size_t path_storage_bytes = 0;
  std::vector<ArchiveEntry> result;
  result.reserve(count);
  for (mz_uint index = 0; index < count; ++index) {
    mz_zip_archive_file_stat stat{};
    if (!mz_zip_reader_file_stat(archive, index, &stat) ||
        stat.m_is_encrypted || !stat.m_is_supported ||
        (stat.m_method != 0 && stat.m_method != MZ_DEFLATED)) {
      Fail("ZIP encrypted or unsupported method rejected");
    }
    const bool directory = stat.m_is_directory != 0;
    const std::uint32_t mode = stat.m_external_attr >> 16;
    const std::uint32_t type = mode & 0170000;
    if ((stat.m_external_attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
        type == 0120000 ||
        (directory && type != 0 && type != 0040000) ||
        (!directory && type != 0 && type != 0100000) ||
        (directory && stat.m_uncomp_size != 0)) {
      Fail("ZIP symlink, reparse, hardlink, or unsupported type rejected");
    }
    if (stat.m_uncomp_size >
        static_cast<mz_uint64>(limits.maximum_single_entry_bytes)) {
      Fail("ZIP single-entry expansion limit exceeded");
    }
    const std::uint64_t maximum_total =
        static_cast<std::uint64_t>(limits.maximum_uncompressed_bytes);
    if (stat.m_uncomp_size > maximum_total ||
        total > maximum_total - stat.m_uncomp_size) {
      Fail("ZIP total expansion limit exceeded");
    }
    total += stat.m_uncomp_size;
    SafeArchivePath path =
        ValidateArchivePath(ReadArchiveName(archive, index), directory);

    AddBoundedBytes(SafeArchivePathStorageBytes(path),
                    limits.maximum_payload_path_bytes,
                    "ZIP cumulative path storage limit exceeded",
                    &path_storage_bytes);

    for (std::size_t depth = 1; depth < path.components.size(); ++depth) {
      SafeArchivePath parent = PrefixPath(path, depth);
      auto position = paths->find(parent.comparison_key);
      const bool inserted = position == paths->end();
      if (inserted) {
        AddBoundedBytes(SafeArchivePathStorageBytes(parent),
                        limits.maximum_payload_path_bytes,
                        "ZIP cumulative path storage limit exceeded",
                        &path_storage_bytes);
        AddBoundedBytes(parent.comparison_key.size(),
                        limits.maximum_payload_path_bytes,
                        "ZIP cumulative path storage limit exceeded",
                        &path_storage_bytes);
        position = paths
                       ->emplace(parent.comparison_key,
                                 PathRecord{parent, true, false})
                       .first;
      }
      if (!inserted &&
          (!position->second.directory ||
           position->second.path.windows != parent.windows)) {
        Fail("ZIP case-insensitive parent collision rejected");
      }
    }
    auto existing = paths->find(path.comparison_key);
    if (existing == paths->end()) {
      AddBoundedBytes(SafeArchivePathStorageBytes(path),
                      limits.maximum_payload_path_bytes,
                      "ZIP cumulative path storage limit exceeded",
                      &path_storage_bytes);
      AddBoundedBytes(path.comparison_key.size(),
                      limits.maximum_payload_path_bytes,
                      "ZIP cumulative path storage limit exceeded",
                      &path_storage_bytes);
      paths->emplace(path.comparison_key,
                     PathRecord{path, directory, true});
    } else {
      if (existing->second.path.windows != path.windows ||
          existing->second.directory != directory ||
          existing->second.explicit_entry || !directory) {
        Fail("ZIP duplicate or case-insensitive collision rejected");
      }
      existing->second.explicit_entry = true;
    }
    result.push_back({index, std::move(path), directory,
                      stat.m_uncomp_size});
  }
  return result;
}

size_t ReadZipHandle(void* opaque,
                     mz_uint64 offset,
                     void* output,
                     size_t length) {
  HANDLE file = static_cast<HANDLE>(opaque);
  if (file == nullptr || file == INVALID_HANDLE_VALUE ||
      length > static_cast<std::size_t>(MAXDWORD)) {
    return 0;
  }
  LARGE_INTEGER position{};
  position.QuadPart = static_cast<LONGLONG>(offset);
  if (!SetFilePointerEx(file, position, nullptr, FILE_BEGIN)) return 0;
  DWORD count = 0;
  if (!ReadFile(file, output, static_cast<DWORD>(length), &count, nullptr)) {
    return 0;
  }
  return count;
}

struct ExtractionSink {
  HANDLE file = INVALID_HANDLE_VALUE;
  std::uint64_t offset = 0;
};

size_t WriteExtractedBytes(void* opaque,
                           mz_uint64 offset,
                           const void* bytes,
                           size_t length) {
  auto* sink = static_cast<ExtractionSink*>(opaque);
  if (sink == nullptr || sink->file == INVALID_HANDLE_VALUE ||
      offset != sink->offset ||
      length > static_cast<std::size_t>(MAXDWORD)) {
    return 0;
  }
  DWORD written = 0;
  if (!WriteFile(sink->file, bytes, static_cast<DWORD>(length), &written,
                 nullptr) ||
      written != length) {
    return 0;
  }
  sink->offset += written;
  return written;
}

std::string CanonicalPayloadSeal(
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    const std::vector<StageProvenanceEntry>& entries) {
  JsonValue::Array encoded_entries;
  for (const StageProvenanceEntry& entry : entries) {
    JsonValue::Object encoded;
    encoded.emplace("kind", JsonValue(entry.kind));
    encoded.emplace("length", JsonValue(entry.length));
    encoded.emplace("path", JsonValue(entry.path));
    if (entry.kind == "file") {
      encoded.emplace("sha256", JsonValue(entry.sha256));
    }
    encoded_entries.emplace_back(JsonValue(std::move(encoded)));
  }
  JsonValue::Object root;
  root.emplace("artifactSha256", JsonValue(artifact_sha256));
  root.emplace("descriptorSha256", JsonValue(descriptor_sha256));
  root.emplace("entries", JsonValue(std::move(encoded_entries)));
  root.emplace("packageId", JsonValue(package_id));
  root.emplace("schemaVersion", JsonValue(static_cast<std::int64_t>(1)));
  return EncodeCanonicalJson(JsonValue(std::move(root)));
}

void RequirePayloadSealBudget(
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    const std::vector<StageProvenanceEntry>& entries,
    std::size_t maximum_bytes) {
  // This intentionally overestimates canonical JSON punctuation, keys,
  // integer text, and container bookkeeping. The full JsonValue tree is not
  // allocated until the complete seal is proven to fit the caller's bound.
  std::size_t total = 512;
  auto add_string = [&](const std::string& value) {
    std::size_t encoded = 2;
    for (const unsigned char byte : value) {
      const std::size_t width =
          byte < 0x20 ? 6 : (byte == '"' || byte == '\\' ? 2 : 1);
      AddBoundedBytes(width, maximum_bytes,
                      "payload seal byte limit exceeded", &encoded);
    }
    AddBoundedBytes(encoded, maximum_bytes,
                    "payload seal byte limit exceeded", &total);
  };
  if (total > maximum_bytes) {
    Fail("payload seal byte limit exceeded");
  }
  add_string(package_id);
  add_string(descriptor_sha256);
  add_string(artifact_sha256);
  for (const StageProvenanceEntry& entry : entries) {
    AddBoundedBytes(256, maximum_bytes,
                    "payload seal byte limit exceeded", &total);
    add_string(entry.path);
    add_string(entry.kind);
    if (entry.kind == "file") add_string(entry.sha256);
  }
}

WindowsPayloadSeal BuildPayloadSeal(
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    std::vector<StageProvenanceEntry> entries,
    std::size_t maximum_bytes) {
  std::sort(entries.begin(), entries.end(),
            [](const StageProvenanceEntry& left,
               const StageProvenanceEntry& right) {
              return std::lexicographical_compare(
                  left.path.begin(), left.path.end(), right.path.begin(),
                  right.path.end(), [](char first, char second) {
                    return static_cast<unsigned char>(first) <
                           static_cast<unsigned char>(second);
                  });
            });
  RequirePayloadSealBudget(package_id, descriptor_sha256, artifact_sha256,
                           entries, maximum_bytes);
  const std::string canonical = CanonicalPayloadSeal(
      package_id, descriptor_sha256, artifact_sha256, entries);
  if (canonical.size() > maximum_bytes) {
    Fail("payload seal byte limit exceeded");
  }
  return {std::move(entries), Sha256Bytes(canonical)};
}

std::wstring ParentPath(const std::wstring& path) {
  const std::size_t slash = path.find_last_of(L'\\');
  return slash == std::wstring::npos ? std::wstring()
                                     : path.substr(0, slash);
}

std::wstring LeafName(const std::wstring& path) {
  const std::size_t slash = path.find_last_of(L'\\');
  return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

HANDLE DirectoryHandle(
    const std::wstring& path,
    HANDLE root,
    const std::map<std::wstring, std::size_t>& directory_indices,
    const std::vector<UniqueWindowsHandle>& handles) {
  if (path.empty()) return root;
  const auto found = directory_indices.find(path);
  if (found == directory_indices.end()) Fail("ZIP parent directory missing");
  return handles[found->second].get();
}

void EnumeratePayload(
    HANDLE directory,
    const std::string& prefix,
    std::vector<StageProvenanceEntry>* entries,
    std::vector<UniqueWindowsHandle>* retained_handles,
    std::size_t depth,
    std::uint64_t* total_bytes,
    std::size_t* total_path_bytes,
    std::size_t maximum_path_bytes,
    ULONG child_share_access) {
  if (depth > kMaximumArchiveDepth ||
      entries->size() >= kMaximumPayloadEntries) {
    Fail("activated payload traversal limit exceeded");
  }
  alignas(FILE_ID_BOTH_DIR_INFO)
      std::array<unsigned char, 64 * 1024> buffer{};
  bool restart = true;
  for (;;) {
    const auto information_class =
        restart ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo;
    restart = false;
    if (!GetFileInformationByHandleEx(directory, information_class,
                                      buffer.data(),
                                      static_cast<DWORD>(buffer.size()))) {
      if (GetLastError() == ERROR_NO_MORE_FILES) break;
      Fail("activated payload enumeration failed");
    }
    auto* encoded = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(buffer.data());
    for (;;) {
      const std::wstring name(encoded->FileName,
                              encoded->FileNameLength / sizeof(wchar_t));
      if (name != L"." && name != L"..") {
        const SafeArchivePath component =
            ValidateArchivePath(WideToUtf8(name), false, prefix.empty());
        if (component.components.size() != 1) {
          Fail("activated payload component is not canonical");
        }
        if ((!prefix.empty() &&
             prefix.size() > kMaximumArchivePathBytes - 1) ||
            component.utf8.size() >
                kMaximumArchivePathBytes -
                    (prefix.empty() ? 0 : prefix.size() + 1)) {
          Fail("activated payload path length limit exceeded");
        }
        const std::string path = prefix.empty()
                                     ? component.utf8
                                     : prefix + "/" + component.utf8;
        AddBoundedBytes(path.size(), maximum_path_bytes,
                        "activated payload cumulative path limit exceeded",
                        total_path_bytes);
        auto child = OpenRelativeNoReparse(
            directory, name,
            GENERIC_READ | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
            child_share_access, FILE_OPEN,
            FILE_SYNCHRONOUS_IO_NONALERT);
        const WindowsFileIdentity identity =
            ReadWindowsFileIdentity(child.get());
        VerifyNoAlternateDataStreams(child.get());
        if (identity.directory) {
          entries->push_back({path, "directory", 0, {}, {}});
          EnumeratePayload(child.get(), path, entries, retained_handles,
                           depth + 1, total_bytes, total_path_bytes,
                           maximum_path_bytes, child_share_access);
        } else {
          const std::int64_t length = FileLength(child.get());
          if (length < 0 ||
              static_cast<std::uint64_t>(length) >
                  static_cast<std::uint64_t>(kMaximumSingleEntryBytes) ||
              *total_bytes >
                  static_cast<std::uint64_t>(kMaximumExpandedBytes) -
                      static_cast<std::uint64_t>(length)) {
            Fail("activated payload size limit exceeded");
          }
          *total_bytes += static_cast<std::uint64_t>(length);
          entries->push_back(
              {path, "file", length, Sha256Handle(child.get()), {}});
        }
        retained_handles->push_back(std::move(child));
        if (entries->size() > kMaximumPayloadEntries) {
          Fail("activated payload entry limit exceeded");
        }
      }
      if (encoded->NextEntryOffset == 0) break;
      encoded = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(
          reinterpret_cast<unsigned char*>(encoded) +
          encoded->NextEntryOffset);
    }
  }
}

WindowsPayloadSeal SealWindowsPayloadHandleBounded(
    HANDLE bundle,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    std::vector<UniqueWindowsHandle>* retained_handles,
    std::size_t maximum_path_bytes,
    std::size_t maximum_seal_bytes,
    ULONG child_share_access) {
  if (bundle == nullptr || bundle == INVALID_HANDLE_VALUE ||
      package_id.empty() ||
      !std::regex_match(descriptor_sha256, kSha256) ||
      !std::regex_match(artifact_sha256, kSha256) ||
      retained_handles == nullptr || maximum_path_bytes == 0 ||
      maximum_path_bytes > kMaximumPayloadPathBytes ||
      maximum_seal_bytes == 0 ||
      maximum_seal_bytes > kMaximumPayloadSealBytes) {
    Fail("payload seal input is invalid");
  }
  VerifyNoAlternateDataStreams(bundle);
  std::vector<StageProvenanceEntry> entries;
  std::uint64_t total_bytes = 0;
  std::size_t total_path_bytes = 0;
  EnumeratePayload(bundle, {}, &entries, retained_handles, 0, &total_bytes,
                   &total_path_bytes, maximum_path_bytes,
                   child_share_access);
  return BuildPayloadSeal(package_id, descriptor_sha256, artifact_sha256,
                          std::move(entries), maximum_seal_bytes);
}

WindowsPayloadSeal SealWindowsPayloadTreeBounded(
    HANDLE parent,
    const std::wstring& bundle_leaf,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    std::vector<UniqueWindowsHandle>* retained_handles,
    std::size_t maximum_path_bytes,
    std::size_t maximum_seal_bytes) {
  if (parent == nullptr || parent == INVALID_HANDLE_VALUE ||
      bundle_leaf.empty()) {
    Fail("payload seal input is invalid");
  }
  auto bundle = OpenRelativeNoReparse(
      parent, bundle_leaf,
      GENERIC_READ | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES |
          READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  WindowsPayloadSeal result = SealWindowsPayloadHandleBounded(
      bundle.get(), package_id, descriptor_sha256, artifact_sha256,
      retained_handles, maximum_path_bytes, maximum_seal_bytes,
      FILE_SHARE_READ | FILE_SHARE_DELETE);
  retained_handles->push_back(std::move(bundle));
  return result;
}

}  // namespace

struct WindowsVerifiedArchiveRestage::Impl {
  std::filesystem::path path;
  std::wstring leaf;
  StageProvenanceMarker provenance;
  std::string payload_seal_sha256;
  UniqueWindowsHandle parent;
  UniqueWindowsHandle root;
  UniqueWindowsHandle archive;
  UniqueWindowsHandle control;
  WindowsFileIdentity root_identity;
  std::vector<UniqueWindowsHandle> retained_handles;
  WindowsArchiveRestageFaultInjector* fault_injector = nullptr;
  bool cleanup_armed = true;

  ~Impl() {
    if (!cleanup_armed || !parent.valid()) return;
    retained_handles.clear();
    root.reset();
    if (!leaf.empty()) {
      try {
        DeleteTreeRelative(parent.get(), leaf, root_identity);
      } catch (...) {
        // A transaction may already have atomically moved the exact retained
        // tree. Cleanup must never chase a replacement path.
      }
    }
    if (archive.valid()) {
      try {
        DeleteHandleExact(archive.get());
      } catch (...) {
      }
      archive.reset();
    }
    if (control.valid()) {
      try {
        DeleteHandleExact(control.get());
      } catch (...) {
      }
      control.reset();
      try {
        FlushWindowsDirectory(parent.get());
      } catch (...) {
      }
    }
  }
};

WindowsVerifiedArchiveRestage::WindowsVerifiedArchiveRestage(
    std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

WindowsVerifiedArchiveRestage::WindowsVerifiedArchiveRestage(
    WindowsVerifiedArchiveRestage&&) noexcept = default;

WindowsVerifiedArchiveRestage& WindowsVerifiedArchiveRestage::operator=(
    WindowsVerifiedArchiveRestage&&) noexcept = default;

WindowsVerifiedArchiveRestage::~WindowsVerifiedArchiveRestage() = default;

const std::filesystem::path& WindowsVerifiedArchiveRestage::path() const {
  if (!impl_) Fail("archive restage result is empty");
  return impl_->path;
}

const StageProvenanceMarker& WindowsVerifiedArchiveRestage::provenance()
    const {
  if (!impl_) Fail("archive restage result is empty");
  return impl_->provenance;
}

const std::string& WindowsVerifiedArchiveRestage::payload_seal_sha256()
    const {
  if (!impl_) Fail("archive restage result is empty");
  return impl_->payload_seal_sha256;
}

HANDLE WindowsVerifiedArchiveRestage::parent_handle() const {
  if (!impl_ || !impl_->parent.valid()) {
    Fail("archive restage parent authority is empty");
  }
  return impl_->parent.get();
}

HANDLE WindowsVerifiedArchiveRestage::root_handle() const {
  if (!impl_ || !impl_->root.valid()) {
    Fail("archive restage root authority is empty");
  }
  return impl_->root.get();
}

void WindowsVerifiedArchiveRestage::ReleaseToTransaction() {
  if (!impl_) Fail("archive restage result is empty");
  // The caller invokes this only after its durable journal owns the exact
  // payload identity. From this point on, no cleanup failure may re-arm the
  // destructor and erase journal-referenced recovery state.
  impl_->cleanup_armed = false;
  if (impl_->fault_injector != nullptr) {
    impl_->fault_injector->Hit(
        WindowsArchiveRestageFaultPoint::kDuringPostJournalControlCleanup);
  }
  if (impl_->control.valid()) {
    DeleteHandleExact(impl_->control.get());
    impl_->control.reset();
    FlushWindowsDirectory(impl_->parent.get());
  }
}

WindowsVerifiedArchiveRestage RestageVerifiedWindowsZip(
    const std::filesystem::path& caller_stage,
    const std::filesystem::path& target_parent,
    const std::string& transaction_id,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    std::int64_t artifact_length,
    const std::string& canonical_release_manifest,
    WindowsArchiveRestageAuthority authority,
    HANDLE caller_process,
    const WindowsArchiveRestageLimits& limits,
    WindowsArchiveRestageFaultInjector* fault_injector) {
  ValidateRestageLimits(limits);
  if (!std::regex_match(transaction_id, kTransactionId) ||
      package_id.empty() || !std::regex_match(descriptor_sha256, kSha256) ||
      !std::regex_match(artifact_sha256, kSha256) || artifact_length <= 0 ||
      canonical_release_manifest.empty() ||
      EncodeCanonicalJson(ParseJson(canonical_release_manifest)) !=
          canonical_release_manifest ||
      Sha256Bytes(canonical_release_manifest) != descriptor_sha256) {
    Fail("signed archive restage binding is invalid");
  }

  auto result = std::make_unique<WindowsVerifiedArchiveRestage::Impl>();
  result->fault_injector = fault_injector;
  ExactCreateSecurityDescriptor create_security(authority, caller_process);
  auto caller_root = OpenAbsoluteDirectoryNoReparse(
      caller_stage, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE);
  auto source_archive = OpenRelativeNoReparse(
      caller_root.get(), kArtifactLeaf,
      GENERIC_READ | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  const WindowsFileIdentity source_identity =
      ReadWindowsFileIdentity(source_archive.get());
  VerifyNoAlternateDataStreams(source_archive.get());
  if (source_identity.directory || FileLength(source_archive.get()) !=
                                       artifact_length) {
    Fail("retained signed ZIP length changed");
  }

  constexpr ACCESS_MASK kParentAccess =
      FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY |
      FILE_TRAVERSE | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES |
      READ_CONTROL | WRITE_DAC | WRITE_OWNER | SYNCHRONIZE;
  result->parent =
      OpenAbsoluteDirectoryNoReparse(target_parent, kParentAccess);

  CleanupPriorRestage(result->parent.get(), transaction_id, package_id,
                      descriptor_sha256, artifact_sha256, authority,
                      caller_process, limits);
  const std::string restage_nonce = RandomUuidV4();
  result->control = CreateRestageControl(
      result->parent.get(),
      {transaction_id, restage_nonce, package_id, descriptor_sha256,
       artifact_sha256, AuthorityName(authority)},
      authority, caller_process, create_security.get(), fault_injector);
  auto hit = [&](WindowsArchiveRestageFaultPoint point) {
    if (fault_injector == nullptr) return;
    try {
      fault_injector->Hit(point);
    } catch (...) {
      // Model a process crash: close retained handles while intentionally
      // leaving the durable control record and exact helper-owned artifacts
      // for the next invocation to recover.
      result->cleanup_armed = false;
      throw;
    }
  };

  const std::wstring archive_leaf = RestageArchiveLeaf(restage_nonce);
  result->archive = OpenRelativeNoReparse(
      result->parent.get(), archive_leaf,
      GENERIC_READ | GENERIC_WRITE | DELETE | FILE_READ_ATTRIBUTES |
          READ_CONTROL | WRITE_DAC | WRITE_OWNER | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_CREATE,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH,
      FILE_ATTRIBUTE_HIDDEN, create_security.get());
  hit(WindowsArchiveRestageFaultPoint::kAfterArchiveFileCreate);
  VerifyObjectSecurity(result->archive.get(), authority, caller_process);

  LARGE_INTEGER beginning{};
  if (!SetFilePointerEx(source_archive.get(), beginning, nullptr, FILE_BEGIN)) {
    Fail("retained signed ZIP seek failed");
  }
  Sha256Stream copied_hash;
  std::int64_t copied_length = 0;
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(source_archive.get(), buffer.data(),
                  static_cast<DWORD>(buffer.size()), &count, nullptr)) {
      Fail("retained signed ZIP read failed");
    }
    if (count == 0) break;
    DWORD written = 0;
    if (!WriteFile(result->archive.get(), buffer.data(), count, &written,
                   nullptr) ||
        written != count) {
      Fail("protected signed ZIP copy failed");
    }
    copied_hash.Update(buffer.data(), count);
    if (copied_length > INT64_MAX - count) {
      Fail("protected signed ZIP copy length overflow");
    }
    copied_length += count;
    hit(WindowsArchiveRestageFaultPoint::kDuringArchiveCopy);
  }
  if (!FlushFileBuffers(result->archive.get()) ||
      copied_length != artifact_length ||
      copied_hash.Finish() != artifact_sha256 ||
      ReadWindowsFileIdentity(source_archive.get()) != source_identity ||
      FileLength(result->archive.get()) != artifact_length ||
      Sha256Handle(result->archive.get()) != artifact_sha256) {
    Fail("protected signed ZIP digest or retained identity mismatch");
  }
  VerifyNoAlternateDataStreams(result->archive.get());
  DeleteHandleExact(result->archive.get());
  FlushWindowsDirectory(result->parent.get());
  hit(WindowsArchiveRestageFaultPoint::kAfterArchiveCopyBeforePreflight);

  result->leaf = RestagePayloadLeaf(restage_nonce);
  result->root = OpenRelativeNoReparse(
      result->parent.get(), result->leaf,
      GENERIC_READ | GENERIC_WRITE | DELETE | FILE_LIST_DIRECTORY |
          FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_TRAVERSE |
          FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | READ_CONTROL |
          WRITE_DAC | WRITE_OWNER | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_CREATE,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH,
      FILE_ATTRIBUTE_HIDDEN, create_security.get());
  hit(WindowsArchiveRestageFaultPoint::kAfterPayloadRootDirectoryCreate);
  result->root_identity = ReadWindowsFileIdentity(result->root.get());
  VerifyObjectSecurity(result->root.get(), authority, caller_process);
  result->path = target_parent / result->leaf;

  mz_zip_archive archive{};
  archive.m_pRead = ReadZipHandle;
  archive.m_pIO_opaque = result->archive.get();
  if (!mz_zip_reader_init(&archive,
                          static_cast<mz_uint64>(artifact_length), 0)) {
    Fail("protected signed ZIP reader initialization failed");
  }
  try {
    std::map<std::string, PathRecord> paths;
    const std::vector<ArchiveEntry> entries =
        PreflightArchive(&archive, limits, &paths);
    std::vector<const PathRecord*> directories;
    for (const auto& entry : paths) {
      if (entry.second.directory) directories.push_back(&entry.second);
    }
    std::sort(directories.begin(), directories.end(),
              [](const PathRecord* left, const PathRecord* right) {
                if (left->path.components.size() !=
                    right->path.components.size()) {
                  return left->path.components.size() <
                         right->path.components.size();
                }
                return left->path.utf8 < right->path.utf8;
              });

    std::map<std::wstring, std::size_t> directory_indices;
    std::vector<StageProvenanceEntry> payload_entries;
    for (const PathRecord* directory : directories) {
      const std::wstring parent_path = ParentPath(directory->path.windows);
      HANDLE parent_handle = DirectoryHandle(
          parent_path, result->root.get(), directory_indices,
          result->retained_handles);
      auto handle = OpenRelativeNoReparse(
          parent_handle, LeafName(directory->path.windows),
          GENERIC_READ | GENERIC_WRITE | DELETE | FILE_LIST_DIRECTORY |
              FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_TRAVERSE |
              FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | READ_CONTROL |
              WRITE_DAC | WRITE_OWNER | SYNCHRONIZE,
          FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_CREATE,
          FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
              FILE_WRITE_THROUGH,
          FILE_ATTRIBUTE_NORMAL, create_security.get());
      hit(WindowsArchiveRestageFaultPoint::kAfterPayloadDirectoryCreate);
      VerifyObjectSecurity(handle.get(), authority, caller_process);
      VerifyNoAlternateDataStreams(handle.get());
      if (!ReadWindowsFileIdentity(handle.get()).directory) {
        Fail("helper-created ZIP directory identity changed");
      }
      const std::size_t handle_index = result->retained_handles.size();
      result->retained_handles.push_back(std::move(handle));
      directory_indices.emplace(directory->path.windows, handle_index);
      payload_entries.push_back(
          {directory->path.utf8, "directory", 0, {}, {}});
    }

    for (const ArchiveEntry& entry : entries) {
      if (entry.directory) continue;
      const std::wstring parent_path = ParentPath(entry.path.windows);
      HANDLE parent_handle = DirectoryHandle(
          parent_path, result->root.get(), directory_indices,
          result->retained_handles);
      auto file = OpenRelativeNoReparse(
          parent_handle, LeafName(entry.path.windows),
          GENERIC_READ | GENERIC_WRITE | DELETE | FILE_READ_ATTRIBUTES |
              FILE_WRITE_ATTRIBUTES | READ_CONTROL | WRITE_DAC |
              WRITE_OWNER | SYNCHRONIZE,
          FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_CREATE,
          FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
              FILE_WRITE_THROUGH,
          FILE_ATTRIBUTE_NORMAL, create_security.get());
      hit(WindowsArchiveRestageFaultPoint::kAfterPayloadFileCreate);
      VerifyObjectSecurity(file.get(), authority, caller_process);
      ExtractionSink sink{file.get(), 0};
      if (!mz_zip_reader_extract_to_callback(
              &archive, entry.index, WriteExtractedBytes, &sink, 0) ||
          sink.offset != entry.uncompressed_size ||
          !FlushFileBuffers(file.get()) ||
          FileLength(file.get()) !=
              static_cast<std::int64_t>(entry.uncompressed_size)) {
        Fail("protected ZIP extraction failed");
      }
      VerifyNoAlternateDataStreams(file.get());
      const WindowsFileIdentity identity = ReadWindowsFileIdentity(file.get());
      if (identity.directory || identity.number_of_links != 1) {
        Fail("helper-created ZIP file identity changed");
      }
      payload_entries.push_back(
          {entry.path.utf8, "file",
           static_cast<std::int64_t>(entry.uncompressed_size),
           Sha256Handle(file.get()), {}});
      result->retained_handles.push_back(std::move(file));
      hit(WindowsArchiveRestageFaultPoint::kDuringExtraction);
    }
    mz_zip_reader_end(&archive);
    FlushWindowsDirectory(result->root.get());
    FlushWindowsDirectory(result->parent.get());

    hit(WindowsArchiveRestageFaultPoint::kBeforePayloadSeal);
    WindowsPayloadSeal seal = BuildPayloadSeal(
        package_id, descriptor_sha256, artifact_sha256,
        std::move(payload_entries), limits.maximum_payload_seal_bytes);
    auto retained_root = OpenRelativeNoReparse(
        result->parent.get(), result->leaf,
        GENERIC_READ | DELETE | FILE_LIST_DIRECTORY | FILE_TRAVERSE |
            FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
        FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
    if (ReadWindowsFileIdentity(retained_root.get()) != result->root_identity) {
      Fail("extracted payload root identity changed");
    }
    std::vector<UniqueWindowsHandle> retained_handles;
    const WindowsPayloadSeal actual = SealWindowsPayloadHandleBounded(
        retained_root.get(), package_id, descriptor_sha256, artifact_sha256,
        &retained_handles, limits.maximum_payload_path_bytes,
        limits.maximum_payload_seal_bytes,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
    if (actual.sha256 != seal.sha256) {
      Fail("extracted payload differs from signed ZIP inventory");
    }
    result->retained_handles = std::move(retained_handles);
    result->root = std::move(retained_root);
    result->provenance = {restage_nonce, package_id, descriptor_sha256,
                          artifact_sha256, seal.entries};
    result->payload_seal_sha256 = std::move(seal.sha256);
    hit(WindowsArchiveRestageFaultPoint::
            kAfterExtractionBeforeTransactionJournal);
  } catch (...) {
    mz_zip_reader_end(&archive);
    throw;
  }
  return WindowsVerifiedArchiveRestage(std::move(result));
}

WindowsPayloadSeal SealWindowsPayloadTree(
    HANDLE parent,
    const std::wstring& bundle_leaf,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    std::vector<UniqueWindowsHandle>* retained_handles) {
  return SealWindowsPayloadTreeBounded(
      parent, bundle_leaf, package_id, descriptor_sha256, artifact_sha256,
      retained_handles, kMaximumPayloadPathBytes,
      kMaximumPayloadSealBytes);
}

void VerifyWindowsArchiveRestageSecurity(
    HANDLE object,
    WindowsArchiveRestageAuthority authority,
    HANDLE caller_process) {
  VerifyObjectSecurity(object, authority, caller_process);
}

}  // namespace desktop_updater::helper
