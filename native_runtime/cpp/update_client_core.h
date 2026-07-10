#ifndef DESKTOP_UPDATER_RUNTIME_UPDATE_CLIENT_CORE_H_
#define DESKTOP_UPDATER_RUNTIME_UPDATE_CLIENT_CORE_H_

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "release_contract.h"
#include "update_transport.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

struct ClientConfiguration {
  std::string app_archive_url;
  std::string expected_package_id;
  std::string current_version;
  bool has_current_build_number = false;
  std::int64_t current_build_number = 0;
  std::string current_updater_version;
  std::string platform;
  std::string channel;
  std::string installation_identity;
  bool require_descriptor_signature = true;
  std::map<std::string, std::vector<std::uint8_t>> pinned_public_keys_by_id;
  std::function<bool(const std::string&, const std::string&)>
      minimum_os_resolver;
};

struct ClientCheckResult {
  std::string outcome = "invalidDescriptor";
  std::string message;
  std::string support_policy_status = "supported";
  bool has_selected_item = false;
  ReleaseIndexItem selected_item;
  bool has_descriptor = false;
  ReleaseDescriptor descriptor;
};

ClientCheckResult CheckForUpdateCore(const ClientConfiguration& configuration,
                                     UpdateTransport* transport,
                                     const Sha256Function& sha256);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_UPDATE_CLIENT_CORE_H_
