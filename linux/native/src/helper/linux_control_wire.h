#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_CONTROL_WIRE_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_CONTROL_WIRE_H_

#include <cstdint>
#include <stdexcept>
#include <string>

namespace desktop_updater::helper {

class LinuxControlWireError : public std::runtime_error {
 public:
  explicit LinuxControlWireError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct LinuxControlRequestV1 {
  std::int64_t protocol_version = 1;
  std::string operation;
  std::string transaction_id;
  std::string request_nonce;
  std::int64_t caller_process_id = 0;
  std::string caller_process_start_identity;
  std::string caller_executable_sha256;
  std::string caller_signer_identity;
};

LinuxControlRequestV1 ParseLinuxControlRequestV1(
    const std::string& canonical_json);
std::string EncodeLinuxControlRequestV1(
    const LinuxControlRequestV1& request);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_CONTROL_WIRE_H_
