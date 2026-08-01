#include "artifact_stager_windows.h"

#include <windows.h>

#include <softpub.h>
#include <wincrypt.h>
#include <wintrust.h>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <vector>

#include "desktop_updater_native_c.h"
#include "sha256_bcrypt.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

void WriteReleaseManifest(const std::filesystem::path& destination_path,
                          const ReleaseDescriptor& descriptor,
                          const std::string& expected_package_id) {
  if (expected_package_id.empty() ||
      descriptor.package_id != expected_package_id ||
      descriptor.platform != "windows") {
    throw std::invalid_argument("expected_package_id does not match release.");
  }
  std::ofstream manifest(destination_path /
                             L".desktop_updater_release_manifest.json",
                         std::ios::binary);
  manifest << EncodeCanonicalJson(descriptor.raw);
  if (!manifest) throw std::runtime_error("Unable to write release manifest.");
}

std::string CertificateSHA256(const std::wstring& path) {
  HCERTSTORE store = nullptr;
  HCRYPTMSG message = nullptr;
  DWORD encoding = 0;
  DWORD content_type = 0;
  DWORD format_type = 0;
  if (!CryptQueryObject(CERT_QUERY_OBJECT_FILE, path.c_str(),
                        CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
                        CERT_QUERY_FORMAT_FLAG_BINARY, 0, &encoding,
                        &content_type, &format_type, &store, &message,
                        nullptr)) {
    throw std::runtime_error("Unable to read Authenticode signer.");
  }
  struct Handles {
    HCERTSTORE store;
    HCRYPTMSG message;
    ~Handles() {
      if (message != nullptr) CryptMsgClose(message);
      if (store != nullptr) CertCloseStore(store, 0);
    }
  } handles{store, message};

  DWORD signer_size = 0;
  if (!CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, nullptr,
                        &signer_size)) {
    throw std::runtime_error("Unable to size Authenticode signer data.");
  }
  std::vector<unsigned char> signer_bytes(signer_size);
  if (!CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0,
                        signer_bytes.data(), &signer_size)) {
    throw std::runtime_error("Unable to read Authenticode signer data.");
  }
  const auto* signer = reinterpret_cast<const CMSG_SIGNER_INFO*>(
      signer_bytes.data());
  CERT_INFO certificate_info{};
  certificate_info.Issuer = signer->Issuer;
  certificate_info.SerialNumber = signer->SerialNumber;
  PCCERT_CONTEXT certificate = CertFindCertificateInStore(
      store, encoding, 0, CERT_FIND_SUBJECT_CERT, &certificate_info, nullptr);
  if (certificate == nullptr) {
    throw std::runtime_error("Authenticode signer certificate is missing.");
  }
  struct Certificate {
    PCCERT_CONTEXT value;
    ~Certificate() { CertFreeCertificateContext(value); }
  } certificate_owner{certificate};
  DWORD hash_size = 0;
  if (!CertGetCertificateContextProperty(
          certificate, CERT_SHA256_HASH_PROP_ID, nullptr, &hash_size)) {
    throw std::runtime_error("Unable to size signer SHA-256 thumbprint.");
  }
  std::vector<unsigned char> hash(hash_size);
  if (!CertGetCertificateContextProperty(certificate,
                                         CERT_SHA256_HASH_PROP_ID,
                                         hash.data(), &hash_size)) {
    throw std::runtime_error("Unable to read signer SHA-256 thumbprint.");
  }
  std::ostringstream encoded;
  encoded << std::uppercase << std::hex << std::setfill('0');
  for (const unsigned char byte : hash) {
    encoded << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return encoded.str();
}

void VerifyAuthenticode(
    const std::wstring& path,
    const std::vector<std::string>& allowed_sha256_thumbprints) {
  if (allowed_sha256_thumbprints.empty()) {
    throw std::runtime_error(
        "innoInstaller requires allowed signer SHA-256 thumbprints.");
  }
  WINTRUST_FILE_INFO file{};
  file.cbStruct = sizeof(file);
  file.pcwszFilePath = path.c_str();
  WINTRUST_DATA trust{};
  trust.cbStruct = sizeof(trust);
  trust.dwUIChoice = WTD_UI_NONE;
  trust.fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN;
  trust.dwUnionChoice = WTD_CHOICE_FILE;
  trust.pFile = &file;
  trust.dwStateAction = WTD_STATEACTION_VERIFY;
  GUID policy = WINTRUST_ACTION_GENERIC_VERIFY_V2;
  const LONG result = WinVerifyTrust(nullptr, &policy, &trust);
  trust.dwStateAction = WTD_STATEACTION_CLOSE;
  WinVerifyTrust(nullptr, &policy, &trust);
  if (result != ERROR_SUCCESS) {
    throw std::runtime_error("innoInstaller Authenticode verification failed.");
  }
  const std::string signer = CertificateSHA256(path);
  const bool allowed = std::any_of(
      allowed_sha256_thumbprints.begin(), allowed_sha256_thumbprints.end(),
      [&signer](std::string thumbprint) {
        std::transform(thumbprint.begin(), thumbprint.end(),
                       thumbprint.begin(), [](unsigned char value) {
                         return static_cast<char>(std::toupper(value));
                       });
        return thumbprint == signer;
      });
  if (!allowed) {
    throw std::runtime_error(
        "innoInstaller signer SHA-256 thumbprint is not allowed.");
  }
}

std::vector<std::string> AuthenticodeThumbprints(
    const ReleaseDescriptor& descriptor) {
  const JsonValue& policy = descriptor.install.at("inno").at("authenticode");
  std::vector<std::string> result;
  const JsonValue* values = policy.find("sha256Thumbprints");
  if (values != nullptr) {
    for (const JsonValue& value : values->array()) {
      result.push_back(value.string());
    }
  }
  return result;
}

desktop_updater_install_elevation_policy_v1 ElevationPolicy(
    const ReleaseDescriptor& descriptor) {
  if (descriptor.artifact.kind != "innoInstaller") {
    return DESKTOP_UPDATER_INSTALL_ELEVATION_AUTO;
  }
  const std::string value =
      descriptor.install.at("inno").at("requiresElevation").string();
  if (value == "always") {
    return DESKTOP_UPDATER_INSTALL_ELEVATION_ALWAYS;
  }
  if (value == "never") {
    return DESKTOP_UPDATER_INSTALL_ELEVATION_NEVER;
  }
  if (value != "auto") {
    throw std::invalid_argument("Invalid signed Inno elevation policy.");
  }
  return DESKTOP_UPDATER_INSTALL_ELEVATION_AUTO;
}

}  // namespace

WindowsStagedArtifact StageWindowsZip(
    const std::filesystem::path& archive_path,
    const std::filesystem::path& destination_parent,
    const ReleaseDescriptor& descriptor,
    const std::string& expected_package_id,
    const ArchiveLimits& limits) {
  if (expected_package_id.empty() ||
      descriptor.package_id != expected_package_id ||
      descriptor.platform != "windows" || descriptor.artifact.kind != "zip") {
    throw std::invalid_argument("expected_package_id does not match release.");
  }
  const FilesystemOwnedStage stage = CreateOwnedStage(destination_parent);
  try {
    StageZipArchive(archive_path, stage.path, limits);
    std::filesystem::copy_file(
        archive_path, stage.path / L".desktop_updater_artifact.zip",
        std::filesystem::copy_options::overwrite_existing);
    WriteReleaseManifest(stage.path, descriptor, expected_package_id);
    const StageProvenanceState provenance = WriteStageProvenance(
        stage, expected_package_id,
        StageBytesToHex(BCryptSha256(EncodeCanonicalJson(descriptor.raw))),
        descriptor.artifact.sha256, BCryptSha256);
    return {stage.path, provenance};
  } catch (...) {
    try {
      RemoveStagingDirectory(stage.path);
    } catch (...) {
      // Preserve the staging failure that triggered cleanup.
    }
    throw;
  }
}

WindowsStagedArtifact StageWindowsInnoInstaller(
    const std::filesystem::path& installer_path,
    const std::filesystem::path& destination_parent,
    const ReleaseDescriptor& descriptor,
    const std::string& expected_package_id) {
  if (expected_package_id.empty() ||
      descriptor.package_id != expected_package_id ||
      descriptor.platform != "windows" ||
      descriptor.artifact.kind != "innoInstaller") {
    throw std::invalid_argument("expected_package_id does not match release.");
  }
  const JsonValue& policy =
      descriptor.install.at("inno").at("authenticode");
  const FilesystemOwnedStage stage = CreateOwnedStage(destination_parent);
  try {
    if (policy.at("required").boolean()) {
      VerifyAuthenticode(installer_path.wstring(),
                         AuthenticodeThumbprints(descriptor));
    }
    const std::filesystem::path destination = stage.path / L"installer.exe";
    std::filesystem::copy_file(
        installer_path, destination,
        std::filesystem::copy_options::overwrite_existing);
    WriteReleaseManifest(stage.path, descriptor, expected_package_id);
    const StageProvenanceState provenance = WriteStageProvenance(
        stage, expected_package_id,
        StageBytesToHex(BCryptSha256(EncodeCanonicalJson(descriptor.raw))),
        descriptor.artifact.sha256, BCryptSha256);
    return {stage.path, provenance};
  } catch (...) {
    try {
      RemoveStagingDirectory(stage.path);
    } catch (...) {
      // Preserve the staging failure that triggered cleanup.
    }
    throw;
  }
}

WindowsStagedArtifact StageWindowsZip(
    const std::string& archive_path,
    const std::string& destination_parent,
    const ReleaseDescriptor& descriptor,
    const std::string& expected_package_id,
    const ArchiveLimits& limits) {
  return StageWindowsZip(std::filesystem::u8path(archive_path),
                         std::filesystem::u8path(destination_parent),
                         descriptor, expected_package_id, limits);
}

WindowsStagedArtifact StageWindowsInnoInstaller(
    const std::wstring& installer_path,
    const std::string& destination_parent,
    const ReleaseDescriptor& descriptor,
    const std::string& expected_package_id) {
  return StageWindowsInnoInstaller(
      std::filesystem::path(installer_path),
      std::filesystem::u8path(destination_parent), descriptor,
      expected_package_id);
}

WindowsInstallHandoffResult HandoffWindowsInstall(
    const std::wstring& staging_path,
    const std::wstring& install_root,
    const std::wstring& executable_relative_path,
    const std::wstring& expected_package_id,
    const std::wstring& diagnostics_log_path,
    const std::vector<std::wstring>& removed_files,
    const std::string& expected_provenance_sha256,
    const ReleaseDescriptor& descriptor) {
  static_assert(sizeof(wchar_t) == sizeof(std::uint16_t),
                "Windows helper ABI requires UTF-16 wchar_t.");
  std::vector<const std::uint16_t*> removed_file_pointers;
  removed_file_pointers.reserve(removed_files.size());
  for (const std::wstring& file : removed_files) {
    removed_file_pointers.push_back(
        reinterpret_cast<const std::uint16_t*>(file.c_str()));
  }
  desktop_updater_install_request_v1 request{};
  request.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION;
  request.struct_size = sizeof(request);
  request.staging_path = reinterpret_cast<const std::uint16_t*>(
      staging_path.c_str());
  request.install_root = reinterpret_cast<const std::uint16_t*>(
      install_root.c_str());
  request.executable_relative_path = reinterpret_cast<const std::uint16_t*>(
      executable_relative_path.c_str());
  request.expected_package_id = reinterpret_cast<const std::uint16_t*>(
      expected_package_id.c_str());
  request.diagnostics_log_path = diagnostics_log_path.empty()
                                     ? nullptr
                                     : reinterpret_cast<const std::uint16_t*>(
                                           diagnostics_log_path.c_str());
  request.removed_files = removed_file_pointers.empty()
                              ? nullptr
                              : removed_file_pointers.data();
  request.removed_file_count = removed_file_pointers.size();
  const std::wstring expected_provenance(
      expected_provenance_sha256.begin(), expected_provenance_sha256.end());
  const std::wstring expected_artifact(descriptor.artifact.sha256.begin(),
                                       descriptor.artifact.sha256.end());
  std::vector<std::wstring> thumbprints;
  if (descriptor.artifact.kind == "innoInstaller") {
    for (const std::string& thumbprint : AuthenticodeThumbprints(descriptor)) {
      thumbprints.emplace_back(thumbprint.begin(), thumbprint.end());
    }
  }
  std::vector<const std::uint16_t*> thumbprint_pointers;
  for (const std::wstring& thumbprint : thumbprints) {
    thumbprint_pointers.push_back(
        reinterpret_cast<const std::uint16_t*>(thumbprint.c_str()));
  }
  request.expected_provenance_sha256 =
      reinterpret_cast<const std::uint16_t*>(expected_provenance.c_str());
  request.expected_artifact_sha256 =
      reinterpret_cast<const std::uint16_t*>(expected_artifact.c_str());
  request.allowed_signer_thumbprints = thumbprint_pointers.empty()
      ? nullptr : thumbprint_pointers.data();
  request.allowed_signer_thumbprint_count = thumbprint_pointers.size();
  request.elevation_policy = ElevationPolicy(descriptor);
  desktop_updater_result_v1 result =
      desktop_updater_schedule_install_and_relaunch_v1(&request);
  WindowsInstallHandoffResult handoff{
      result.ok != 0,
      result.error_message_utf8 == nullptr ? "" : result.error_message_utf8};
  desktop_updater_result_free_v1(&result);
  return handoff;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
