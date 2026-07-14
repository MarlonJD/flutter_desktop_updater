#include "helper_authenticode.h"

#include <windows.h>

#include <aclapi.h>
#include <bcrypt.h>
#include <shlobj.h>
#include <softpub.h>
#include <wincrypt.h>
#include <wintrust.h>

#include <algorithm>
#include <array>
#include <cwctype>
#include <iomanip>
#include <memory>
#include <sstream>
#include <vector>

namespace desktop_updater::helper {
namespace {

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle = INVALID_HANDLE_VALUE)
      : handle_(handle) {}
  ~ScopedHandle() {
    if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(handle_);
    }
  }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
  HANDLE get() const { return handle_; }

 private:
  HANDLE handle_;
};

std::wstring Utf8ToWide(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) throw WindowsHelperTrustError("invalid publisher UTF-8");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    throw WindowsHelperTrustError("publisher UTF-8 conversion failed");
  }
  return result;
}

std::wstring FinalPath(HANDLE file) {
  const DWORD length = GetFinalPathNameByHandleW(
      file, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (length == 0) throw WindowsHelperTrustError("final helper path failed");
  std::wstring value(static_cast<std::size_t>(length), L'\0');
  const DWORD written = GetFinalPathNameByHandleW(
      file, value.data(), length,
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (written == 0 || written >= length) {
    throw WindowsHelperTrustError("final helper path changed");
  }
  value.resize(written);
  return value;
}

void ReadFileIdentity(HANDLE file,
                      std::uint64_t* volume_serial,
                      std::array<unsigned char, 16>* file_id) {
  FILE_ID_INFO info{};
  if (!GetFileInformationByHandleEx(file, FileIdInfo, &info, sizeof(info))) {
    throw WindowsHelperTrustError("GetFileInformationByHandleEx failed");
  }
  *volume_serial = info.VolumeSerialNumber;
  std::copy(std::begin(info.FileId.Identifier),
            std::end(info.FileId.Identifier), file_id->begin());
}

std::string Sha256(HANDLE file) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0;
  DWORD received = 0;
  std::vector<unsigned char> object;
  std::array<unsigned char, 32> digest{};
  auto fail = [&]() {
    if (hash != nullptr) BCryptDestroyHash(hash);
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
    throw WindowsHelperTrustError("helper SHA-256 failed");
  };

  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_size),
                        sizeof(object_size), &received, 0) < 0) {
    fail();
  }
  object.resize(object_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(), object_size,
                       nullptr, 0, 0) < 0) {
    fail();
  }
  LARGE_INTEGER start{};
  if (!SetFilePointerEx(file, start, nullptr, FILE_BEGIN)) fail();
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &count, nullptr)) {
      fail();
    }
    if (count == 0) break;
    if (BCryptHashData(hash, buffer.data(), count, 0) < 0) fail();
  }
  if (BCryptFinishHash(hash, digest.data(),
                       static_cast<ULONG>(digest.size()), 0) < 0) {
    fail();
  }
  BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);

  std::ostringstream encoded;
  encoded << std::hex << std::setfill('0');
  for (unsigned char byte : digest) {
    encoded << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return encoded.str();
}

bool VerifyAuthenticode(HANDLE file, const std::wstring& final_path) {
  WINTRUST_FILE_INFO file_info{};
  file_info.cbStruct = sizeof(file_info);
  file_info.pcwszFilePath = final_path.c_str();
  file_info.hFile = file;

  WINTRUST_DATA trust{};
  trust.cbStruct = sizeof(trust);
  trust.dwUIChoice = WTD_UI_NONE;
  trust.fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN;
  trust.dwUnionChoice = WTD_CHOICE_FILE;
  trust.pFile = &file_info;
  trust.dwStateAction = WTD_STATEACTION_VERIFY;
  trust.dwProvFlags = WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT;

  GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
  const LONG status = WinVerifyTrust(nullptr, &action, &trust);
  trust.dwStateAction = WTD_STATEACTION_CLOSE;
  WinVerifyTrust(nullptr, &action, &trust);
  return status == ERROR_SUCCESS;
}

std::wstring AuthenticodePublisher(const std::wstring& path) {
  HCERTSTORE store = nullptr;
  HCRYPTMSG message = nullptr;
  DWORD encoding = 0;
  DWORD content = 0;
  DWORD format = 0;
  if (!CryptQueryObject(CERT_QUERY_OBJECT_FILE, path.c_str(),
                        CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
                        CERT_QUERY_FORMAT_FLAG_BINARY, 0, &encoding, &content,
                        &format, &store, &message, nullptr)) {
    return {};
  }

  DWORD signer_size = 0;
  if (!CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, nullptr,
                        &signer_size)) {
    CryptMsgClose(message);
    CertCloseStore(store, 0);
    return {};
  }
  std::vector<unsigned char> signer_bytes(signer_size);
  if (!CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0,
                        signer_bytes.data(), &signer_size)) {
    CryptMsgClose(message);
    CertCloseStore(store, 0);
    return {};
  }
  const auto* signer =
      reinterpret_cast<const CMSG_SIGNER_INFO*>(signer_bytes.data());
  CERT_INFO certificate_info{};
  certificate_info.Issuer = signer->Issuer;
  certificate_info.SerialNumber = signer->SerialNumber;
  PCCERT_CONTEXT certificate = CertFindCertificateInStore(
      store, encoding, 0, CERT_FIND_SUBJECT_CERT, &certificate_info, nullptr);

  std::wstring result;
  if (certificate != nullptr) {
    const DWORD name_length = CertGetNameStringW(
        certificate, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, nullptr, 0);
    if (name_length > 1) {
      result.resize(name_length);
      CertGetNameStringW(certificate, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0,
                         nullptr, result.data(), name_length);
      result.resize(name_length - 1);
    }
    CertFreeCertificateContext(certificate);
  }
  CryptMsgClose(message);
  CertCloseStore(store, 0);
  return result;
}

std::wstring NormalizeForComparison(std::wstring path) {
  constexpr wchar_t extended_prefix[] = L"\\\\?\\";
  if (path.rfind(extended_prefix, 0) == 0) path.erase(0, 4);
  std::replace(path.begin(), path.end(), L'/', L'\\');
  std::transform(path.begin(), path.end(), path.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  while (path.size() > 3 && path.back() == L'\\') path.pop_back();
  return path;
}

bool IsUnder(const std::filesystem::path& child,
             const std::filesystem::path& root) {
  const std::wstring child_value = NormalizeForComparison(child.wstring());
  const std::wstring root_value = NormalizeForComparison(root.wstring());
  return child_value.size() > root_value.size() &&
         child_value.compare(0, root_value.size(), root_value) == 0 &&
         child_value[root_value.size()] == L'\\';
}

bool CurrentTokenCanWrite(const std::wstring& path) {
  PACL dacl = nullptr;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  const DWORD security_result = GetNamedSecurityInfoW(
      const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |
          DACL_SECURITY_INFORMATION,
      nullptr, nullptr, &dacl, nullptr, &descriptor);
  if (security_result != ERROR_SUCCESS || descriptor == nullptr) return true;
  std::unique_ptr<void, decltype(&LocalFree)> owned_descriptor(descriptor,
                                                               LocalFree);

  HANDLE process_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE,
                        &process_token)) {
    return true;
  }
  ScopedHandle process_token_owner(process_token);
  HANDLE impersonation_token = nullptr;
  if (!DuplicateToken(process_token, SecurityImpersonation,
                      &impersonation_token)) {
    return true;
  }
  ScopedHandle token_owner(impersonation_token);

  GENERIC_MAPPING mapping{FILE_GENERIC_READ, FILE_GENERIC_WRITE,
                          FILE_GENERIC_EXECUTE, FILE_ALL_ACCESS};
  DWORD desired = MAXIMUM_ALLOWED;
  std::array<unsigned char, sizeof(PRIVILEGE_SET) +
                                sizeof(LUID_AND_ATTRIBUTES) * 8>
      privileges{};
  DWORD privileges_size = static_cast<DWORD>(privileges.size());
  DWORD granted = 0;
  BOOL access = FALSE;
  if (!AccessCheck(descriptor, impersonation_token, desired, &mapping,
                   reinterpret_cast<PRIVILEGE_SET*>(privileges.data()),
                   &privileges_size, &granted, &access)) {
    return true;
  }
  constexpr DWORD write_authority =
      FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_DELETE_CHILD |
      FILE_WRITE_ATTRIBUTES | DELETE | WRITE_DAC | WRITE_OWNER;
  return access == TRUE && (granted & write_authority) != 0;
}

bool IsInstallerProtectedLocation(const std::filesystem::path& path) {
  bool under_known_root = false;
  for (const KNOWNFOLDERID* id : {&FOLDERID_ProgramFiles,
                                  &FOLDERID_ProgramFilesX86,
                                  &FOLDERID_Windows}) {
    PWSTR known_path = nullptr;
    if (SHGetKnownFolderPath(*id, KF_FLAG_DEFAULT, nullptr, &known_path) ==
        S_OK) {
      under_known_root = under_known_root || IsUnder(path, known_path);
      CoTaskMemFree(known_path);
    }
  }
  const bool installerProtectedLocation =
      under_known_root && !CurrentTokenCanWrite(path.parent_path().wstring());
  return installerProtectedLocation;
}

}  // namespace

VerifiedWindowsExecutable VerifyWindowsExecutable(
    const std::filesystem::path& path) {
  ScopedHandle file(CreateFileW(
      path.c_str(), GENERIC_READ | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) {
    throw WindowsHelperTrustError("cannot open fixed helper executable");
  }

  VerifiedWindowsExecutable result{};
  result.final_path = FinalPath(file.get());
  ReadFileIdentity(file.get(), &result.volume_serial, &result.file_id);
  result.sha256 = Sha256(file.get());
  result.signature_valid = VerifyAuthenticode(file.get(),
                                               result.final_path.wstring());
  result.publisher = AuthenticodePublisher(result.final_path.wstring());
  result.installer_protected_location =
      IsInstallerProtectedLocation(result.final_path);
  if (!VerifyWindowsExecutableStillMatches(path, result)) {
    throw WindowsHelperTrustError("helper replaced during verification");
  }
  return result;
}

void ValidateWindowsHelperIdentity(const VerifiedWindowsExecutable& identity,
                                   const WindowsHelperPolicy& policy,
                                   bool require_protected_location) {
  if (!identity.signature_valid) {
    throw WindowsHelperTrustError("unsigned or untrusted helper");
  }
  if (identity.publisher != Utf8ToWide(policy.helper_publisher())) {
    throw WindowsHelperTrustError("helper Authenticode publisher mismatch");
  }
  if (identity.sha256 != policy.helper_sha256()) {
    throw WindowsHelperTrustError("helper digest mismatch");
  }
  if (require_protected_location && !identity.installer_protected_location) {
    throw WindowsHelperTrustError("helper is in a user-writable location");
  }
  const bool root_allowed = std::any_of(
      policy.allowed_install_roots().begin(),
      policy.allowed_install_roots().end(),
      [&](const std::wstring& root) {
        return IsUnder(identity.final_path, root);
      });
  if (!root_allowed) {
    throw WindowsHelperTrustError("helper is outside sealed install roots");
  }
}

bool VerifyWindowsExecutableStillMatches(
    const std::filesystem::path& path,
    const VerifiedWindowsExecutable& identity) {
  ScopedHandle file(CreateFileW(
      path.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) return false;
  try {
    std::uint64_t volume_serial = 0;
    std::array<unsigned char, 16> file_id{};
    ReadFileIdentity(file.get(), &volume_serial, &file_id);
    return volume_serial == identity.volume_serial &&
           file_id == identity.file_id &&
           Sha256(file.get()) == identity.sha256 &&
           NormalizeForComparison(FinalPath(file.get())) ==
               NormalizeForComparison(identity.final_path.wstring());
  } catch (const WindowsHelperTrustError&) {
    return false;
  }
}

}  // namespace desktop_updater::helper
