#ifndef DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_WIRE_H_
#define DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_WIRE_H_

#include <cstdint>
#include <stdexcept>
#include <string>

namespace desktop_updater {
namespace runtime {
namespace internal {

class NativeInstallWireError : public std::runtime_error {
 public:
  explicit NativeInstallWireError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct NativeInstallReservationV1 {
  std::int64_t protocol_version = 0;
  std::string transaction_id;
  std::string ready_token;
  std::string journal_sha256;
  std::string helper_endpoint_identity_sha256;
  std::int64_t expires_at_unix_milliseconds = 0;

  bool operator==(const NativeInstallReservationV1& other) const;
};

struct NativeInstallWireCommandV1 {
  std::string operation;
  std::int64_t protocol_version = 0;
  std::string transaction_id;
  std::string ready_token;
  std::string journal_sha256;
  std::string helper_endpoint_identity_sha256;

  bool operator==(const NativeInstallWireCommandV1& other) const;
};

struct NativeInstallTransactionStatusV1 {
  std::int64_t protocol_version = 0;
  std::string transaction_id;
  std::string state;
  std::string result_code;
  std::string journal_sha256;

  bool operator==(const NativeInstallTransactionStatusV1& other) const;
};

struct NativeInstallRecoveryResultV1 {
  std::int64_t protocol_version = 0;
  std::string transaction_id;
  std::string result_code;
  std::string verified_outcome;
  std::string journal_sha256;

  bool operator==(const NativeInstallRecoveryResultV1& other) const;
};

NativeInstallReservationV1 ParseNativeInstallReservationV1(
    const std::string& canonical_json);
std::string EncodeNativeInstallReservationV1(
    const NativeInstallReservationV1& reservation);

NativeInstallWireCommandV1 ParseNativeInstallWireCommandV1(
    const std::string& canonical_json);
std::string EncodeNativeInstallWireCommandV1(
    const NativeInstallWireCommandV1& command);

NativeInstallTransactionStatusV1 ParseNativeInstallTransactionStatusV1(
    const std::string& canonical_json);
std::string EncodeNativeInstallTransactionStatusV1(
    const NativeInstallTransactionStatusV1& status);

NativeInstallRecoveryResultV1 ParseNativeInstallRecoveryResultV1(
    const std::string& canonical_json);
std::string EncodeNativeInstallRecoveryResultV1(
    const NativeInstallRecoveryResultV1& result);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_WIRE_H_
