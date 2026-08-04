#include "linux_native_install_request_builder.h"

#include <algorithm>
#include <string>

#include "json_value.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

[[noreturn]] void Fail(const std::string& detail) {
  throw LinuxNativeInstallRequestBuilderError(detail);
}

bool IsSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return (byte >= '0' && byte <= '9') ||
                  (byte >= 'a' && byte <= 'f');
         });
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

NativeInstallTransactionRequestV1 BuildLinuxNativeInstallTransactionRequestV1(
    const std::string& release_manifest_json,
    const StageProvenanceBinding& stage_binding,
    const LinuxNativeInstallEvidenceV1& evidence,
    const LinuxNativeInstallSha256& sha256) {
  if (!sha256) Fail("Linux request SHA-256 function is required");
  try {
    const StageProvenanceMarker& marker = stage_binding.marker;
    const std::string canonical_manifest =
        CanonicalManifest(release_manifest_json);
    const JsonValue manifest = ParseJson(canonical_manifest);
    const JsonValue canonical_stage = ParseJson(stage_binding.canonical_json);
    const JsonValue& artifact = manifest.at("artifact");
    const JsonValue& signature = manifest.at("signature");
    const std::string artifact_sha256 = artifact.at("sha256").string();
    const std::int64_t artifact_length = artifact.at("length").integer();
    const JsonValue* build_number = manifest.find("buildNumber");
    const bool manifest_build_number_present =
        build_number != nullptr && build_number->type() != JsonValue::Type::kNull;
    if (!evidence.expected_version.empty() &&
        (manifest.at("version").string() != evidence.expected_version ||
         manifest.at("platform").string() != evidence.expected_platform ||
         manifest.at("channel").string() != evidence.expected_channel ||
         manifest_build_number_present != evidence.expected_build_number_present ||
         (manifest_build_number_present &&
          build_number->integer() != evidence.expected_build_number))) {
      Fail("release descriptor version, build, and channel are not bound");
    }
    const std::string descriptor_sha256 = sha256(canonical_manifest);
    const std::string provenance_sha256 = sha256(stage_binding.canonical_json);
    const std::string ownership_nonce_sha256 = sha256(marker.nonce);

    if (stage_binding.canonical_json.empty() ||
        EncodeCanonicalJson(canonical_stage) != stage_binding.canonical_json ||
        canonical_stage.object().size() != 6 ||
        canonical_stage.at("schemaVersion").integer() != 1 ||
        canonical_stage.at("nonce").string() != marker.nonce ||
        canonical_stage.at("packageId").string() != marker.package_id ||
        canonical_stage.at("descriptorSha256").string() !=
            marker.descriptor_sha256 ||
        canonical_stage.at("artifactSha256").string() !=
            marker.artifact_sha256 ||
        canonical_stage.at("entries").type() != JsonValue::Type::kArray ||
        manifest.at("schemaVersion").integer() != 3 ||
        manifest.at("platform").string() != "linux" ||
        manifest.at("packageId").string() != evidence.package_id ||
        artifact.at("kind").string() != "zip" ||
        manifest.at("install").at("strategy").string() !=
            "wholeDirectoryReplace" ||
        marker.package_id != evidence.package_id ||
        marker.descriptor_sha256 != descriptor_sha256 ||
        marker.artifact_sha256 != artifact_sha256 ||
        evidence.expected_artifact_sha256 != artifact_sha256 ||
        evidence.expected_provenance_sha256 != provenance_sha256 ||
        !IsSha256(provenance_sha256) ||
        !IsSha256(evidence.target_identity_proof_sha256) ||
        !IsSha256(evidence.current_package_identity_sha256) ||
        !IsSha256(evidence.caller_executable_sha256) ||
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
    request.strategy = "directoryReplace";
    request.provider = "platformDirectory";
    request.target.target_class = evidence.target_class;
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
    request.diagnostics_destination = {true, "platformLog", {}};

    return ParseNativeInstallTransactionRequestV1(
        EncodeCanonicalNativeInstallTransactionRequestV1(request));
  } catch (const LinuxNativeInstallRequestBuilderError&) {
    throw;
  } catch (const std::exception& error) {
    Fail(std::string("invalid Linux native install evidence: ") +
         error.what());
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
