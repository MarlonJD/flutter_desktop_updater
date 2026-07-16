#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_PROTECTED_HELPER_LOCATOR_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_PROTECTED_HELPER_LOCATOR_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>

namespace desktop_updater::helper {

class WindowsProtectedHelperLocatorError : public std::runtime_error {
 public:
  explicit WindowsProtectedHelperLocatorError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct ProtectedWindowsHelperEndpointV1 {
  static constexpr std::int64_t kSchemaVersion = 1;

  std::int64_t schema_version = kSchemaVersion;
  std::string policy_id;
  std::string package_id;
  std::string helper_service_id;
  std::filesystem::path helper_path;
  std::filesystem::path policy_path;
  std::string helper_sha256;
  std::string policy_sha256;

  std::string EncodeCanonical() const;
  static ProtectedWindowsHelperEndpointV1 DecodeStrict(
      const std::string& canonical_json);
  bool operator==(const ProtectedWindowsHelperEndpointV1& other) const;
};

std::wstring BuildProtectedWindowsRegistrySddl();
std::wstring ProtectedWindowsEndpointPackageRegistryPath(
    const std::string& package_id);
std::wstring ProtectedWindowsEndpointRegistryPath(
    const std::string& package_id,
    const std::filesystem::path& helper_path);
std::wstring ProtectedWindowsTransactionEndpointRegistryPath(
    const std::string& transaction_id);

void RegisterProtectedWindowsHelperEndpoint(
    const ProtectedWindowsHelperEndpointV1& endpoint);
std::optional<ProtectedWindowsHelperEndpointV1>
LoadProtectedWindowsHelperEndpoint(
    const std::string& package_id,
    const std::filesystem::path& helper_path);

void BindProtectedWindowsTransactionEndpoint(
    const std::string& transaction_id,
    const ProtectedWindowsHelperEndpointV1& endpoint);
std::optional<ProtectedWindowsHelperEndpointV1>
LoadProtectedWindowsTransactionEndpoint(const std::string& transaction_id);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_PROTECTED_HELPER_LOCATOR_H_
