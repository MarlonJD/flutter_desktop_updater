#include "sha256_bcrypt.h"
#include "transport_fixture_tests.h"
#include "update_transport_winhttp.h"

#include <windows.h>

#include <cstdlib>
#include <exception>
#include <filesystem>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

int main() {
  const char* base_url = std::getenv("DESKTOP_UPDATER_TRANSPORT_FIXTURE_URL");
  if (base_url == nullptr) return 2;
  const std::filesystem::path test_root =
      std::filesystem::temp_directory_path() /
      ("desktop_updater_windows_transport_" +
       std::to_string(GetCurrentProcessId()));
  const std::filesystem::path unicode_temporary =
      test_root / std::filesystem::u8path(u8"güncelleme-日本");
  try {
    using desktop_updater::runtime::internal::ResolveRedirectURL;
    const std::string base(base_url);
    if (ResolveRedirectURL(base + "/redirect/root", "/metadata") !=
            base + "/metadata" ||
        ResolveRedirectURL(base + "/redirect/parent/child", "../metadata") !=
            base + "/redirect/metadata" ||
        ResolveRedirectURL("https://example.test/source", "//cdn.test/path") !=
            "https://cdn.test/path") {
      throw std::runtime_error("Relative redirect resolution differs.");
    }

    std::vector<std::string> header_urls;
    desktop_updater::runtime::internal::TransportOptions options;
    options.maximum_metadata_bytes = 32;
    options.request_headers_provider = [&header_urls](const std::string& url) {
      header_urls.push_back(url);
      return std::map<std::string, std::string>{
          {"Authorization", "Bearer fixture"}};
    };
    desktop_updater::runtime::internal::WinHttpUpdateTransport transport(options);
    const auto expect_metadata = [&transport, &base](const std::string& path) {
      const std::vector<std::uint8_t> bytes =
          transport.DownloadMetadata(base + path);
      if (std::string(bytes.begin(), bytes.end()) != "metadata") {
        throw std::runtime_error("Relative redirect metadata differs.");
      }
    };
    expect_metadata("/redirect/root");
    expect_metadata("/redirect/parent/child");
    expect_metadata("/redirect/scheme-relative");
    if (header_urls.empty() || header_urls.back() != base + "/metadata") {
      throw std::runtime_error(
          "Resolved redirect URL was not passed to the header provider.");
    }
    try {
      ResolveRedirectURL("https://127.0.0.1/source", base + "/metadata");
      throw std::runtime_error("HTTPS redirect downgrade was accepted.");
    } catch (const std::runtime_error& error) {
      if (std::string(error.what()) !=
          "HTTPS redirect downgrade is forbidden.") {
        throw;
      }
    }
    try {
      transport.DownloadMetadata(base + "/redirect/loop");
      throw std::runtime_error("Redirect loop longer than five was accepted.");
    } catch (const std::runtime_error& error) {
      if (std::string(error.what()) != "Update redirect limit exceeded.") {
        throw;
      }
    }

    std::filesystem::remove_all(test_root);
    std::filesystem::create_directories(unicode_temporary);
    desktop_updater::runtime::internal::RunTransportFixtureTests(
        &transport, base_url, unicode_temporary.u8string(),
        desktop_updater::runtime::internal::BCryptSha256);
    std::filesystem::remove_all(test_root);
    return 0;
  } catch (const std::exception& error) {
    std::error_code ignored;
    std::filesystem::remove_all(test_root, ignored);
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
