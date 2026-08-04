#ifndef DESKTOP_UPDATER_RUNTIME_WINDOWS_NATIVE_INSTALL_REQUEST_BUILDER_H_
#define DESKTOP_UPDATER_RUNTIME_WINDOWS_NATIVE_INSTALL_REQUEST_BUILDER_H_

#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>

#include "native_install_request.h"
#include "stage_provenance.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

class WindowsNativeInstallRequestBuilderError : public std::runtime_error {
 public:
  explicit WindowsNativeInstallRequestBuilderError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct WindowsNativeInstallEvidenceV1 {
  std::string transaction_id;
  std::string policy_id;
  std::string package_id;
  std::string target_path_hint;
  std::string target_name_hint;
  std::string executable_relative_path;
  std::string target_identity_proof_sha256;
  std::string current_version;
  std::int64_t current_build_number = 0;
  std::string current_package_identity_sha256;
  std::string stage_path_hint;
  std::string expected_provenance_sha256;
  std::string expected_artifact_sha256;
  std::string expected_version;
  std::string expected_platform;
  std::string expected_channel;
  bool expected_build_number_present = false;
  std::int64_t expected_build_number = 0;
  std::int64_t caller_process_id = 0;
  std::string caller_process_start_identity;
  std::string caller_executable_sha256;
  std::string caller_signer_identity;
  std::string request_nonce;
};

using WindowsNativeInstallSha256 =
    std::function<std::string(const std::string& bytes)>;

NativeInstallTransactionRequestV1
BuildWindowsNativeInstallTransactionRequestV1(
    const std::string& release_manifest_json,
    const StageProvenanceMarker& marker,
    const WindowsNativeInstallEvidenceV1& evidence,
    const WindowsNativeInstallSha256& sha256);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_WINDOWS_NATIVE_INSTALL_REQUEST_BUILDER_H_
