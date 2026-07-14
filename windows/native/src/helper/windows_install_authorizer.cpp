#include "windows_install_authorizer.h"

#include <windows.h>

#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cwctype>
#include <filesystem>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "helper_authenticode.h"
#include "json_value.h"
#include "windows_file_transaction.h"
#include "windows_relaunch_service.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::AuthorizedNativeInstallRequestV1;
using desktop_updater::runtime::internal::AuthorizeNativeInstallTransactionRequestV1;
using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::NativeInstallAuthorizationPolicyV1;
using desktop_updater::runtime::internal::NativeInstallPreparedTransactionV1;
using desktop_updater::runtime::internal::NativeInstallTransactionRequestV1;
using desktop_updater::runtime::internal::ParseJson;
using desktop_updater::runtime::internal::StageBytesToHex;
using desktop_updater::runtime::internal::StageProvenanceMarker;
using desktop_updater::runtime::internal::StageProvenanceState;
using desktop_updater::runtime::internal::VerifyStageProvenance;

constexpr std::size_t kMaximumHelperMetadataBytes = 16 * 1024 * 1024;

[[noreturn]] void Fail(const std::string& detail) {
  throw desktop_updater::runtime::internal::NativeInstallAuthorizationError(
      detail);
}

std::wstring Utf8ToWide(const std::string& value, const char* field) {
  if (value.empty() ||
      value.size() > static_cast<std::size_t>(
                         std::numeric_limits<int>::max())) {
    Fail(std::string(field) + " is invalid UTF-8");
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) Fail(std::string(field) + " is invalid UTF-8");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    Fail(std::string(field) + " UTF-8 conversion failed");
  }
  return result;
}

std::vector<std::uint8_t> BCryptSha256Bytes(const std::string& bytes) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0;
  DWORD received = 0;
  std::vector<unsigned char> object;
  std::vector<std::uint8_t> digest(32);
  auto cleanup = [&]() {
    if (hash != nullptr) BCryptDestroyHash(hash);
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  };
  auto fail = [&]() -> void {
    cleanup();
    Fail("Windows helper SHA-256 failed");
  };
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_size),
                        sizeof(object_size), &received, 0) < 0) {
    fail();
  }
  object.resize(object_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr,
                       0, 0) < 0) {
    fail();
  }
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const ULONG length = static_cast<ULONG>(std::min<std::size_t>(
        bytes.size() - offset,
        static_cast<std::size_t>(std::numeric_limits<ULONG>::max())));
    if (BCryptHashData(
            hash,
            reinterpret_cast<PUCHAR>(
                const_cast<char*>(bytes.data() + offset)),
            length, 0) < 0) {
      fail();
    }
    offset += length;
  }
  if (BCryptFinishHash(hash, digest.data(),
                       static_cast<ULONG>(digest.size()), 0) < 0) {
    fail();
  }
  cleanup();
  return digest;
}

std::string BCryptSha256Hex(const std::string& bytes) {
  return StageBytesToHex(BCryptSha256Bytes(bytes));
}

std::string ReadRegularFileNoReparse(const std::filesystem::path& path,
                                     std::size_t maximum_bytes) {
  UniqueWindowsHandle file(CreateFileW(
      path.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!file.valid()) Fail("helper metadata file is unavailable");
  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(file.get(), &information) ||
      (information.dwFileAttributes &
       (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
      information.nFileSizeHigh != 0 ||
      information.nFileSizeLow > maximum_bytes) {
    Fail("helper metadata file is not a bounded regular file");
  }
  std::string result(information.nFileSizeLow, '\0');
  std::size_t offset = 0;
  while (offset < result.size()) {
    DWORD count = 0;
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        result.size() - offset, 64 * 1024));
    if (!ReadFile(file.get(), result.data() + offset, requested, &count,
                  nullptr) ||
        count == 0 || count > requested) {
      Fail("helper metadata file read failed");
    }
    offset += count;
  }
  return result;
}

std::wstring NormalizePath(std::filesystem::path path) {
  std::wstring value = path.lexically_normal().wstring();
  if (value.rfind(L"\\\\?\\", 0) == 0) value.erase(0, 4);
  std::replace(value.begin(), value.end(), L'/', L'\\');
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  while (value.size() > 3 && value.back() == L'\\') value.pop_back();
  return value;
}

bool IsAtOrUnder(const std::filesystem::path& child,
                 const std::filesystem::path& root) {
  const std::wstring child_value = NormalizePath(child);
  const std::wstring root_value = NormalizePath(root);
  return !root_value.empty() &&
         (child_value == root_value ||
          (child_value.size() > root_value.size() &&
           child_value.compare(0, root_value.size(), root_value) == 0 &&
           child_value[root_value.size()] == L'\\'));
}

std::filesystem::path CanonicalDirectory(const std::string& encoded,
                                         const char* field) {
  const std::filesystem::path path =
      std::filesystem::path(Utf8ToWide(encoded, field));
  std::error_code error;
  const std::filesystem::path canonical =
      std::filesystem::canonical(path, error);
  if (error || canonical.empty() ||
      !std::filesystem::is_directory(canonical, error) || error) {
    Fail(std::string(field) + " is not a canonical directory");
  }
  return canonical;
}

void ValidateRelativeExecutable(const std::filesystem::path& path) {
  if (path.empty() || path.is_absolute() || path.has_root_name() ||
      path.lexically_normal() != path) {
    Fail("target executable path is not canonical relative");
  }
  for (const auto& component : path) {
    if (component.empty() || component == L"." || component == L"..") {
      Fail("target executable path escapes target");
    }
  }
}

void ValidateTargetAuthority(const std::filesystem::path& target,
                             const NativeInstallTransactionRequestV1& request,
                             const WindowsHelperPolicy& policy) {
  const bool allowed_root = std::any_of(
      policy.allowed_install_roots().begin(),
      policy.allowed_install_roots().end(),
      [&](const std::wstring& root) {
        return IsAtOrUnder(target, std::filesystem::path(root));
      });
  if (!allowed_root) Fail("target is outside sealed install roots");
  const std::wstring expected_name =
      Utf8ToWide(request.target.target_name_hint, "target name");
  if (_wcsicmp(target.filename().c_str(), expected_name.c_str()) != 0) {
    Fail("target name hint changed");
  }

  const std::filesystem::path executable_relative =
      std::filesystem::path(Utf8ToWide(
          request.target.executable_relative_path, "target executable"));
  ValidateRelativeExecutable(executable_relative);
  const std::filesystem::path executable_path = target / executable_relative;
  const VerifiedWindowsExecutable executable =
      VerifyWindowsExecutable(executable_path);
  if (!executable.signature_valid ||
      executable.publisher !=
          Utf8ToWide(policy.application_publisher(), "application publisher") ||
      !VerifyWindowsExecutableStillMatches(executable_path, executable)) {
    Fail("installed executable Authenticode identity mismatch");
  }

  const std::string marker = ReadRegularFileNoReparse(
      target / L".desktop_updater_install_identity.json", 64 * 1024);
  const JsonValue marker_value = ParseJson(marker);
  const auto& marker_object = marker_value.object();
  if (marker_object.size() != 2 ||
      marker_object.find("packageId") == marker_object.end() ||
      marker_object.find("schemaVersion") == marker_object.end() ||
      marker_value.at("schemaVersion").integer() != 1 ||
      marker_value.at("packageId").string() != request.package_id ||
      EncodeCanonicalJson(marker_value) != marker ||
      BCryptSha256Hex(marker) != request.target.identity_proof_sha256) {
    Fail("installed target identity marker mismatch");
  }
}

class WindowsDirectoryPreparedTransaction final
    : public NativeInstallPreparedTransactionV1 {
 public:
  WindowsDirectoryPreparedTransaction(
      std::filesystem::path target_path,
      std::filesystem::path stage_path,
      std::string transaction_id,
      WindowsVerifiedPayloadIdentity expected_payload_identity)
      : target_path_(std::move(target_path)),
        transaction_id_(std::move(transaction_id)),
        verifier_(expected_payload_identity),
        transaction_(target_path_, std::move(stage_path), transaction_id_,
                     GetCurrentProcessId(), expected_payload_identity,
                     verifier_),
        relaunch_service_(std::move(expected_payload_identity), verifier_,
                          launcher_) {}

  const std::string& transaction_id() const override {
    return transaction_id_;
  }

  std::string PrepareDurableJournal() override {
    transaction_.Prepare();
    return transaction_.prepared_journal_canonical();
  }

  void ExecuteAfterCallerExit() override {
    (void)transaction_.ExecutePrepared();
    relaunch_service_.Relaunch(target_path_);
  }

  void CancelPrepared() override { transaction_.CancelPrepared(); }

 private:
  std::filesystem::path target_path_;
  std::string transaction_id_;
  AuthenticodeWindowsPayloadVerifier verifier_;
  WindowsFileTransaction transaction_;
  CreateProcessWindowsLauncher launcher_;
  WindowsRelaunchService relaunch_service_;
};

}  // namespace

NativeInstallAuthorizationPolicyV1
BuildWindowsNativeInstallAuthorizationPolicy(
    const WindowsHelperPolicy& policy) {
  NativeInstallAuthorizationPolicyV1 result;
  result.policy_id = policy.policy_id();
  result.application_package_id = policy.application_package_id();
  result.allowed_target_classes = policy.allowed_target_classes();
  result.minimum_helper_protocol_version =
      policy.minimum_helper_protocol_version();
  result.release_root_public_keys.reserve(
      policy.release_root_public_keys().size());
  for (const auto& key : policy.release_root_public_keys()) {
    result.release_root_public_keys.push_back(
        {key.key_id, key.algorithm, key.public_key_base64});
  }
  result.allowed_strategies.reserve(policy.allowed_strategies().size());
  for (const auto& strategy : policy.allowed_strategies()) {
    result.allowed_strategies.push_back(
        {strategy.strategy, strategy.provider});
  }
  return result;
}

WindowsVerifiedPayloadIdentity BuildWindowsExpectedPayloadIdentity(
    const NativeInstallTransactionRequestV1& request,
    const StageProvenanceMarker& marker,
    const WindowsHelperPolicy& policy) {
  std::string executable_path = request.target.executable_relative_path;
  std::replace(executable_path.begin(), executable_path.end(), '\\', '/');
  const auto executable = std::find_if(
      marker.entries.begin(), marker.entries.end(),
      [&](const auto& entry) { return entry.path == executable_path; });
  if (executable == marker.entries.end() || executable->kind != "file" ||
      executable->length < 1 || executable->sha256.size() != 64 ||
      !std::all_of(executable->sha256.begin(), executable->sha256.end(),
                   [](unsigned char value) {
                     return std::isdigit(value) != 0 ||
                            (value >= 'a' && value <= 'f');
                   })) {
    Fail("staged executable is missing from frozen inventory");
  }
  return {
      request.package_id,
      policy.application_publisher(),
      request.signed_descriptor.canonical_sha256,
      request.stage.provenance_sha256,
      request.stage.artifact_sha256,
      Utf8ToWide(request.target.executable_relative_path,
                 "target executable"),
      executable->sha256,
  };
}

WindowsNativeInstallAuthorizer::WindowsNativeInstallAuthorizer(
    WindowsHelperPolicy policy)
    : policy_(std::move(policy)) {}

const std::string&
WindowsNativeInstallAuthorizer::helper_endpoint_identity_sha256() const {
  return policy_.helper_sha256();
}

std::unique_ptr<NativeInstallPreparedTransactionV1>
WindowsNativeInstallAuthorizer::Authorize(
    const NativeInstallTransactionRequestV1& request) {
  if (request.strategy != "directoryReplace" ||
      request.provider != "platformDirectory") {
    Fail("Windows provider transaction is not directory replacement");
  }
  const std::filesystem::path target =
      CanonicalDirectory(request.target.path_hint, "target path");
  const std::filesystem::path stage =
      CanonicalDirectory(request.stage.path_hint, "stage path");
  if (IsAtOrUnder(stage, target) || IsAtOrUnder(target, stage)) {
    Fail("stage and target paths overlap");
  }
  ValidateTargetAuthority(target, request, policy_);

  const StageProvenanceMarker marker = VerifyStageProvenance(
      stage, request.stage.provenance_sha256, BCryptSha256Bytes);
  const std::string release_manifest = ReadRegularFileNoReparse(
      stage / L".desktop_updater_release_manifest.json",
      kMaximumHelperMetadataBytes);
  const AuthorizedNativeInstallRequestV1 authorized =
      AuthorizeNativeInstallTransactionRequestV1(
          request, BuildWindowsNativeInstallAuthorizationPolicy(policy_),
          "windows", release_manifest, marker,
          request.stage.provenance_sha256, BCryptSha256Hex);
  if (authorized.descriptor.artifact.kind != "zip") {
    Fail("directory replacement requires a signed Windows ZIP descriptor");
  }
  WindowsVerifiedPayloadIdentity expected =
      BuildWindowsExpectedPayloadIdentity(request, marker, policy_);
  return std::make_unique<WindowsDirectoryPreparedTransaction>(
      target, stage, request.transaction_id, std::move(expected));
}

}  // namespace desktop_updater::helper
