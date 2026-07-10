#include "sha256_bcrypt.h"
#include "transport_fixture_tests.h"
#include "update_transport_winhttp.h"

#include <cstdlib>
#include <exception>
#include <iostream>
#include <map>
#include <string>

int main() {
  const char* base_url = std::getenv("DESKTOP_UPDATER_TRANSPORT_FIXTURE_URL");
  const char* temporary = std::getenv("TEMP");
  if (base_url == nullptr || temporary == nullptr) return 2;
  try {
    desktop_updater::runtime::internal::TransportOptions options;
    options.maximum_metadata_bytes = 32;
    options.request_headers_provider = [](const std::string&) {
      return std::map<std::string, std::string>{
          {"Authorization", "Bearer fixture"}};
    };
    desktop_updater::runtime::internal::WinHttpUpdateTransport transport(options);
    desktop_updater::runtime::internal::RunTransportFixtureTests(
        &transport, base_url, temporary,
        desktop_updater::runtime::internal::BCryptSha256);
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
