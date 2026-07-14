#include "native_install_authorization.h"

#include <algorithm>
#include <map>
#include <string>
#include <vector>

#include "json_value.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

[[noreturn]] void Fail(const std::string& detail) {
  throw NativeInstallAuthorizationError(detail);
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
  const JsonValue parsed = ParseJson(canonical);
  if (canonical.empty() || EncodeCanonicalJson(parsed) != canonical) {
    Fail("release manifest is not canonical JSON");
  }
  return canonical;
}

bool AllowsTarget(const NativeInstallAuthorizationPolicyV1& policy,
                  const std::string& target_class) {
  return std::find(policy.allowed_target_classes.begin(),
                   policy.allowed_target_classes.end(), target_class) !=
         policy.allowed_target_classes.end();
}

bool AllowsStrategy(const NativeInstallAuthorizationPolicyV1& policy,
                    const std::string& strategy,
                    const std::string& provider) {
  return std::any_of(
      policy.allowed_strategies.begin(), policy.allowed_strategies.end(),
      [&](const NativeInstallAuthorizationStrategyV1& allowed) {
        return allowed.strategy == strategy && allowed.provider == provider;
      });
}

bool ArtifactMatchesRequest(const std::string& platform,
                            const std::string& artifact_kind,
                            const std::string& strategy,
                            const std::string& provider) {
  if (platform == "windows") {
    return (artifact_kind == "zip" && strategy == "directoryReplace" &&
            provider == "platformDirectory") ||
           (artifact_kind == "innoInstaller" &&
            strategy == "verifiedInstallerHandoff" &&
            provider == "windowsInno");
  }
  if (platform == "macos") {
    return ((artifact_kind == "zip" || artifact_kind == "dmg") &&
            strategy == "directoryReplace" &&
            provider == "platformDirectory") ||
           (artifact_kind == "pkgInstaller" &&
            strategy == "verifiedInstallerHandoff" &&
            provider == "macosInstaller");
  }
  if (platform == "linux") {
    return artifact_kind == "zip" && strategy == "directoryReplace" &&
           provider == "platformDirectory";
  }
  return false;
}

}  // namespace

AuthorizedNativeInstallRequestV1 AuthorizeNativeInstallTransactionRequestV1(
    const NativeInstallTransactionRequestV1& request,
    const NativeInstallAuthorizationPolicyV1& policy,
    const std::string& expected_platform,
    const std::string& release_manifest_json,
    const StageProvenanceMarker& marker,
    const std::string& marker_sha256,
    const NativeInstallAuthorizationSha256& sha256) {
  if (!sha256) Fail("authorization SHA-256 function is required");
  try {
    if (request.protocol_version != 1 ||
        request.protocol_version < policy.minimum_helper_protocol_version ||
        request.policy_id != policy.policy_id ||
        request.package_id != policy.application_package_id ||
        !AllowsTarget(policy, request.target.target_class) ||
        !AllowsStrategy(policy, request.strategy, request.provider)) {
      Fail("sealed helper policy denied request");
    }

    const std::string canonical_manifest =
        CanonicalManifest(release_manifest_json);
    const ReleaseDescriptor descriptor =
        ParseReleaseDescriptor(canonical_manifest);
    if (EncodeCanonicalJson(descriptor.raw) != canonical_manifest) {
      Fail("release descriptor normalization changed staged bytes");
    }
    const std::string descriptor_sha256 = sha256(canonical_manifest);
    const std::string ownership_nonce_sha256 = sha256(marker.nonce);
    if (!IsSha256(descriptor_sha256) ||
        !IsSha256(ownership_nonce_sha256) || !IsSha256(marker_sha256) ||
        descriptor.platform != expected_platform ||
        descriptor.package_id != request.package_id ||
        marker.package_id != request.package_id ||
        marker.descriptor_sha256 != descriptor_sha256 ||
        marker.artifact_sha256 != descriptor.artifact.sha256 ||
        request.stage.ownership_nonce != ownership_nonce_sha256 ||
        request.stage.provenance_sha256 != marker_sha256 ||
        request.stage.artifact_sha256 != descriptor.artifact.sha256 ||
        request.stage.artifact_length != descriptor.artifact.length ||
        !ArtifactMatchesRequest(expected_platform, descriptor.artifact.kind,
                                request.strategy, request.provider)) {
      Fail("stage, descriptor, and request binding mismatch");
    }

    if (!descriptor.has_signature ||
        request.signed_descriptor.canonical_sha256 != descriptor_sha256 ||
        request.signed_descriptor.signature_algorithm !=
            descriptor.signature.algorithm ||
        request.signed_descriptor.key_id != descriptor.signature.public_key_id ||
        request.signed_descriptor.signature_base64 !=
            descriptor.signature.value ||
        request.desired_identity.version != descriptor.version ||
        request.desired_identity.build_number !=
            (descriptor.has_build_number ? descriptor.build_number : 0) ||
        request.desired_identity.package_identity_sha256 !=
            descriptor_sha256) {
      Fail("signed descriptor request fields changed");
    }

    std::map<std::string, std::vector<std::uint8_t>> trusted_keys;
    for (const auto& key : policy.release_root_public_keys) {
      if (key.algorithm != "ed25519") {
        Fail("unsupported sealed release-root algorithm");
      }
      std::vector<std::uint8_t> decoded = DecodeBase64(key.public_key_base64);
      if (decoded.size() != 32 ||
          !trusted_keys.emplace(key.key_id, std::move(decoded)).second) {
        Fail("invalid sealed release-root key");
      }
    }
    if (!VerifyDescriptorSignature(descriptor, trusted_keys)) {
      Fail("release descriptor signature rejected");
    }
    return {descriptor};
  } catch (const NativeInstallAuthorizationError&) {
    throw;
  } catch (const std::exception& error) {
    Fail(std::string("native install authorization failed: ") + error.what());
  }
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
