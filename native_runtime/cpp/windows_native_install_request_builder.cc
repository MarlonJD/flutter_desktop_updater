#include "windows_native_install_request_builder.h"

#include <string>

#include "json_value.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

[[noreturn]] void Fail(const std::string& detail) {
  throw WindowsNativeInstallRequestBuilderError(detail);
}

bool IsSha256(const std::string& value) {
  if (value.size() != 64) return false;
  for (const unsigned char byte : value) {
    if (!((byte >= '0' && byte <= '9') ||
          (byte >= 'a' && byte <= 'f'))) {
      return false;
    }
  }
  return true;
}

std::string CanonicalManifest(const std::string& encoded) {
  std::string canonical = encoded;
  if (!canonical.empty() && canonical.back() == '\n') canonical.pop_back();
  if (canonical.empty()) Fail("release manifest is empty");
  const JsonValue parsed = ParseJson(canonical);
  if (EncodeCanonicalJson(parsed) != canonical) {
    Fail("release manifest is not canonical JSON");
  }
  return canonical;
}

}  // namespace

NativeInstallTransactionRequestV1
BuildWindowsNativeInstallTransactionRequestV1(
    const std::string& release_manifest_json,
    const StageProvenanceMarker& marker,
    const WindowsNativeInstallEvidenceV1& evidence,
    const WindowsNativeInstallSha256& sha256) {
  if (!sha256) Fail("Windows request SHA-256 function is required");
  try {
    const std::string canonical_manifest =
        CanonicalManifest(release_manifest_json);
    const JsonValue manifest = ParseJson(canonical_manifest);
    const JsonValue& artifact = manifest.at("artifact");
    const JsonValue& signature = manifest.at("signature");
    const std::string artifact_kind = artifact.at("kind").string();
    const std::string artifact_sha256 = artifact.at("sha256").string();
    const std::int64_t artifact_length = artifact.at("length").integer();
    const std::string descriptor_sha256 = sha256(canonical_manifest);
    const std::string ownership_nonce_sha256 = sha256(marker.nonce);

    if (manifest.at("schemaVersion").integer() != 3 ||
        manifest.at("platform").string() != "windows" ||
        manifest.at("packageId").string() != evidence.package_id ||
        marker.package_id != evidence.package_id ||
        marker.descriptor_sha256 != descriptor_sha256 ||
        marker.artifact_sha256 != artifact_sha256 ||
        evidence.expected_artifact_sha256 != artifact_sha256 ||
        !IsSha256(evidence.expected_provenance_sha256) ||
        !IsSha256(descriptor_sha256) ||
        !IsSha256(ownership_nonce_sha256) || artifact_length < 1 ||
        signature.at("algorithm").string() != "ed25519") {
      Fail("release manifest, stage, and caller evidence are not bound");
    }

    NativeInstallTransactionRequestV1 request;
    request.schema_version = 1;
    request.protocol_version = 1;
    request.transaction_id = evidence.transaction_id;
    request.policy_id = evidence.policy_id;
    request.package_id = evidence.package_id;
    if (artifact_kind == "zip") {
      request.strategy = "directoryReplace";
      request.provider = "platformDirectory";
    } else if (artifact_kind == "innoInstaller") {
      request.strategy = "verifiedInstallerHandoff";
      request.provider = "windowsInno";
    } else {
      Fail("Windows artifact has no native helper strategy");
    }
    request.target.target_class = "applicationDirectory";
    request.target.path_hint = evidence.target_path_hint;
    request.target.target_name_hint = evidence.target_name_hint;
    request.target.executable_relative_path =
        evidence.executable_relative_path;
    request.target.identity_proof_sha256 =
        evidence.target_identity_proof_sha256;
    request.current_identity.version = evidence.current_version;
    request.current_identity.build_number = evidence.current_build_number;
    request.current_identity.package_identity_sha256 =
        evidence.current_package_identity_sha256;
    request.desired_identity.version = manifest.at("version").string();
    const JsonValue* build_number = manifest.find("buildNumber");
    request.desired_identity.build_number =
        build_number == nullptr ? 0 : build_number->integer();
    request.desired_identity.package_identity_sha256 = descriptor_sha256;
    request.stage.path_hint = evidence.stage_path_hint;
    request.stage.ownership_nonce = ownership_nonce_sha256;
    request.stage.provenance_sha256 = evidence.expected_provenance_sha256;
    request.stage.artifact_sha256 = artifact_sha256;
    request.stage.artifact_length = artifact_length;
    request.signed_descriptor.canonical_sha256 = descriptor_sha256;
    request.signed_descriptor.signature_algorithm =
        signature.at("algorithm").string();
    request.signed_descriptor.key_id =
        signature.at("publicKeyId").string();
    request.signed_descriptor.signature_base64 =
        signature.at("value").string();
    request.caller.process_id = evidence.caller_process_id;
    request.caller.process_start_identity =
        evidence.caller_process_start_identity;
    request.caller.executable_sha256 = evidence.caller_executable_sha256;
    request.caller.package_id = evidence.package_id;
    request.caller.signer_identity = evidence.caller_signer_identity;
    request.request_nonce = evidence.request_nonce;
    request.diagnostics_destination.present = true;
    request.diagnostics_destination.kind = "platformLog";

    return ParseNativeInstallTransactionRequestV1(
        EncodeCanonicalNativeInstallTransactionRequestV1(request));
  } catch (const WindowsNativeInstallRequestBuilderError&) {
    throw;
  } catch (const std::exception& error) {
    Fail(std::string("invalid Windows native install evidence: ") +
         error.what());
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
