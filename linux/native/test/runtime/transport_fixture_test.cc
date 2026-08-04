#include "sha256_openssl.h"
#include "transport_fixture_tests.h"
#include "update_transport_curl.h"

#include <cstdlib>
#include <exception>
#include <iostream>
#include <map>
#include <string>

int main() {
  const char* base_url = std::getenv("DESKTOP_UPDATER_TRANSPORT_FIXTURE_URL");
  const char* temporary = std::getenv("TMPDIR");
  if (base_url == nullptr) return 2;
  try {
    desktop_updater::runtime::internal::TransportOptions options;
    options.maximum_metadata_bytes = 32;
    options.request_headers_provider = [](const std::string&) {
      return std::map<std::string, std::string>{
          {"Authorization", "Bearer fixture"}};
    };
    desktop_updater::runtime::internal::CurlUpdateTransport transport(options);
    desktop_updater::runtime::internal::RunTransportFixtureTests(
        &transport, base_url, temporary == nullptr ? "/tmp" : temporary,
        desktop_updater::runtime::internal::OpenSSLSha256);
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
