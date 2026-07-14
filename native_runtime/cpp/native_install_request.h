#ifndef DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_REQUEST_H_
#define DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_REQUEST_H_

#include <cstdint>
#include <stdexcept>
#include <string>

namespace desktop_updater {
namespace runtime {
namespace internal {

class NativeInstallProtocolError : public std::runtime_error {
 public:
  explicit NativeInstallProtocolError(std::string code);

  const std::string& code() const { return code_; }

 private:
  std::string code_;
};

struct NativeInstallTargetV1 {
  std::string target_class;
  std::string path_hint;
  std::string target_name_hint;
  std::string executable_relative_path;
  std::string identity_proof_sha256;
};

struct NativeInstallVersionIdentityV1 {
  std::string version;
  std::int64_t build_number = 0;
  std::string package_identity_sha256;
};

struct NativeInstallStageV1 {
  std::string path_hint;
  std::string ownership_nonce;
  std::string provenance_sha256;
  std::string artifact_sha256;
  std::int64_t artifact_length = 0;
};

struct NativeInstallSignedDescriptorV1 {
  std::string canonical_sha256;
  std::string signature_algorithm;
  std::string key_id;
  std::string signature_base64;
};

struct NativeInstallCallerV1 {
  std::int64_t process_id = 0;
  std::string process_start_identity;
  std::string executable_sha256;
  std::string package_id;
  std::string signer_identity;
};

struct NativeInstallDiagnosticsDestinationV1 {
  bool present = false;
  std::string kind;
  std::string stream;
};

struct NativeInstallTransactionRequestV1 {
  std::int64_t schema_version = 0;
  std::int64_t protocol_version = 0;
  std::string transaction_id;
  std::string policy_id;
  std::string package_id;
  std::string strategy;
  std::string provider;
  NativeInstallTargetV1 target;
  NativeInstallVersionIdentityV1 current_identity;
  NativeInstallVersionIdentityV1 desired_identity;
  NativeInstallStageV1 stage;
  NativeInstallSignedDescriptorV1 signed_descriptor;
  NativeInstallCallerV1 caller;
  std::string request_nonce;
  NativeInstallDiagnosticsDestinationV1 diagnostics_destination;
};

NativeInstallTransactionRequestV1 ParseNativeInstallTransactionRequestV1(
    const std::string& canonical_json);
std::string EncodeCanonicalNativeInstallTransactionRequestV1(
    const NativeInstallTransactionRequestV1& request);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_REQUEST_H_
