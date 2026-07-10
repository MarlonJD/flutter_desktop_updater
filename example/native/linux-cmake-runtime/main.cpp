#include <cstdint>
#include <iostream>
#include <map>
#include <string>
#include <vector>

#include "desktop_updater_runtime.h"

int main() {
  desktop_updater::runtime::RuntimeConfiguration configuration;
  configuration.app_archive_url =
      "https://updates.example.test/app-archive.json";
  configuration.expected_package_id = "com.example.native-contract";
  configuration.current_version = "2.7.0";
  configuration.has_current_build_number = true;
  configuration.current_build_number = 270;
  configuration.current_updater_version = "2.7.0";
  configuration.platform = "linux";
  configuration.installation_identity = "external-cmake-consumer";
  configuration.pinned_public_keys_by_id["native-contract-stable"] =
      std::vector<std::uint8_t>(32, 1);
  configuration.minimum_os_resolver =
      [](const std::string&, const std::string&) { return true; };
  configuration.request_headers_provider = [](const std::string&) {
    return std::map<std::string, std::string>();
  };

  const desktop_updater::runtime::RuntimeConfigurationValidation validation =
      desktop_updater::runtime::ValidateRuntimeConfiguration(configuration);
  const desktop_updater::runtime::RuntimeOutcome outcome =
      desktop_updater::runtime::RuntimeOutcome::kNoUpdate;
  if (!validation.ok) {
    std::cerr << validation.error << std::endl;
    return 1;
  }
  std::cout << "desktop_updater Linux runtime API compiled: "
            << static_cast<int>(outcome) << std::endl;
  return 0;
}
