#include <gtest/gtest.h>

#include <string>

#include "windows_protected_helper_locator.h"

namespace desktop_updater::helper {
namespace {

ProtectedWindowsHelperEndpointV1 Endpoint() {
  return {ProtectedWindowsHelperEndpointV1::kSchemaVersion,
          "com.example.desktop-updater.privileged",
          "com.example.app",
          "com.example.desktop-updater.helper",
          std::filesystem::path(
              L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\1"
              L"\\desktop_updater_install_helper.exe"),
          std::filesystem::path(
              L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\1"
              L"\\desktop_updater_helper_policy.json"),
          std::string(64, 'a'),
          std::string(64, 'b')};
}

TEST(WindowsProtectedHelperLocator, CanonicalEndpointRoundTrips) {
  const auto endpoint = Endpoint();
  const std::string encoded = endpoint.EncodeCanonical();
  EXPECT_EQ(endpoint,
            ProtectedWindowsHelperEndpointV1::DecodeStrict(encoded));
  EXPECT_EQ('{', encoded.front());
  EXPECT_EQ('}', encoded.back());
}

TEST(WindowsProtectedHelperLocator, RejectsMutableOrAmbiguousBindings) {
  auto endpoint = Endpoint();
  endpoint.policy_path = L"C:\\Users\\caller\\policy.json";
  EXPECT_THROW(endpoint.EncodeCanonical(),
               WindowsProtectedHelperLocatorError);

  endpoint = Endpoint();
  endpoint.helper_sha256 = std::string(64, 'A');
  EXPECT_THROW(endpoint.EncodeCanonical(),
               WindowsProtectedHelperLocatorError);

  EXPECT_THROW(
      ProtectedWindowsTransactionEndpointRegistryPath("not-a-uuid"),
      WindowsProtectedHelperLocatorError);
}

TEST(WindowsProtectedHelperLocator, RegistryNamesAreExactAndNonEnumerable) {
  const auto first = Endpoint();
  auto second = first;
  second.helper_path =
      L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\2"
      L"\\desktop_updater_install_helper.exe";
  second.policy_path =
      L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\2"
      L"\\desktop_updater_helper_policy.json";
  second.helper_sha256 = std::string(64, 'c');
  second.policy_sha256 = std::string(64, 'd');
  const std::wstring package =
      ProtectedWindowsEndpointPackageRegistryPath("com.example.app");
  const std::wstring endpoint = ProtectedWindowsEndpointRegistryPath(
      "com.example.app", first.helper_path);
  const std::wstring second_endpoint = ProtectedWindowsEndpointRegistryPath(
      "com.example.app", second.helper_path);
  const std::wstring transaction =
      ProtectedWindowsTransactionEndpointRegistryPath(
          "00000000-0000-4000-8000-000000000025");
  EXPECT_EQ(64U, package.substr(package.find_last_of(L'\\') + 1).size());
  EXPECT_EQ(package + L"\\", endpoint.substr(0, package.size() + 1));
  EXPECT_EQ(64U, endpoint.substr(endpoint.find_last_of(L'\\') + 1).size());
  EXPECT_NE(endpoint, second_endpoint);
  EXPECT_NE(std::wstring::npos, transaction.find(L"TransactionEndpoints"));
  EXPECT_EQ(std::wstring::npos, transaction.find(L"*"));

  const std::wstring sddl = BuildProtectedWindowsRegistrySddl();
  EXPECT_NE(std::wstring::npos, sddl.find(L"(A;;KA;;;SY)"));
  EXPECT_NE(std::wstring::npos, sddl.find(L"(A;;KA;;;BA)"));
  EXPECT_NE(std::wstring::npos, sddl.find(L"(A;;KR;;;AU)"));
  EXPECT_EQ(std::wstring::npos, sddl.find(L";;;WD"));
}

}  // namespace
}  // namespace desktop_updater::helper
