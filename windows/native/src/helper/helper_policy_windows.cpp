#include "helper_policy_windows.h"

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <regex>
#include <utility>

#include "install_helper_policy.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::HelperPolicyV1;
using desktop_updater::runtime::internal::ParseHelperPolicyV1;

constexpr char authenticodePublisher[] = "authenticodePublisher";
constexpr char portableElevationRejected[] = "portableElevationRejected";

bool IsSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char character) {
           return std::isdigit(character) != 0 ||
                  (character >= 'a' && character <= 'f');
         });
}

std::wstring Utf8ToWide(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) {
    throw WindowsHelperPolicyError(
        WindowsHelperPolicyError::Code::kInvalidPolicy,
        "invalid UTF-8 install root");
  }
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    throw WindowsHelperPolicyError(
        WindowsHelperPolicyError::Code::kInvalidPolicy,
        "failed to decode install root");
  }
  return result;
}

void ValidatePrivilegePolicy(const std::string& policy_id,
                             const std::string& application_package_id,
                             const std::string& helper_service_id,
                             const std::string& application_publisher,
                             const std::string& helper_publisher,
                             const std::string& helper_sha256,
                             const std::vector<std::wstring>& roots,
                             const std::vector<std::string>& target_classes,
                             const std::vector<WindowsReleaseRootPublicKey>&
                                 release_root_public_keys,
                             const std::vector<WindowsAllowedInstallStrategy>&
                                 allowed_strategies,
                             std::int64_t minimum_helper_protocol_version) {
  if (policy_id.empty() || application_package_id.empty() ||
      helper_service_id.empty() || application_publisher.empty() ||
      helper_publisher.empty() || !IsSha256(helper_sha256) ||
      target_classes.empty() || release_root_public_keys.empty() ||
      allowed_strategies.empty() || minimum_helper_protocol_version != 1) {
    throw WindowsHelperPolicyError(
        WindowsHelperPolicyError::Code::kInvalidPolicy,
        "Windows privileged policy requires exact publishers and helper digest");
  }
  if (roots.empty()) {
    throw WindowsHelperPolicyError(
        WindowsHelperPolicyError::Code::kPortableElevationRejected,
        portableElevationRejected);
  }
  for (const std::wstring& root : roots) {
    if (root.size() < 4 || root[1] != L':' ||
        (root[2] != L'\\' && root[2] != L'/')) {
      throw WindowsHelperPolicyError(
          WindowsHelperPolicyError::Code::kInvalidPolicy,
          "install roots must be fixed absolute Windows paths");
    }
  }
}

}  // namespace

WindowsHelperPolicyError::WindowsHelperPolicyError(
    Code code,
    const std::string& detail)
    : std::runtime_error(detail), code_(code) {}

WindowsHelperPolicy::WindowsHelperPolicy(
    std::string policy_id,
    std::string application_package_id,
    std::string helper_service_id,
    std::string application_publisher,
    std::string helper_publisher,
    std::string helper_sha256,
    std::vector<std::wstring> allowed_install_roots,
    std::vector<std::string> allowed_target_classes,
    std::vector<WindowsReleaseRootPublicKey> release_root_public_keys,
    std::vector<WindowsAllowedInstallStrategy> allowed_strategies,
    std::int64_t minimum_helper_protocol_version)
    : policy_id_(std::move(policy_id)),
      application_package_id_(std::move(application_package_id)),
      helper_service_id_(std::move(helper_service_id)),
      application_publisher_(std::move(application_publisher)),
      helper_publisher_(std::move(helper_publisher)),
      helper_sha256_(std::move(helper_sha256)),
      allowed_install_roots_(std::move(allowed_install_roots)),
      allowed_target_classes_(std::move(allowed_target_classes)),
      release_root_public_keys_(std::move(release_root_public_keys)),
      allowed_strategies_(std::move(allowed_strategies)),
      minimum_helper_protocol_version_(minimum_helper_protocol_version) {
  ValidatePrivilegePolicy(
      policy_id_, application_package_id_, helper_service_id_,
      application_publisher_, helper_publisher_, helper_sha256_,
      allowed_install_roots_, allowed_target_classes_,
      release_root_public_keys_, allowed_strategies_,
      minimum_helper_protocol_version_);
}

WindowsHelperPolicy WindowsHelperPolicy::Load(
    const std::string& canonical_json,
    const std::string& sealed_policy_sha256,
    const std::string& expected_application_package_id,
    const std::string& sealed_helper_sha256) {
  HelperPolicyV1 parsed = ParseHelperPolicyV1(
      canonical_json, expected_application_package_id, 1);
  if (parsed.canonical_sha256 != sealed_policy_sha256) {
    throw WindowsHelperPolicyError(
        WindowsHelperPolicyError::Code::kPolicyDigestMismatch,
        "sealed policy digest does not match canonical policy");
  }
  if (parsed.allowed_application_signer.kind != authenticodePublisher ||
      parsed.allowed_helper_signer.kind != authenticodePublisher) {
    throw WindowsHelperPolicyError(
        WindowsHelperPolicyError::Code::kPortableElevationRejected,
        portableElevationRejected);
  }

  std::vector<std::wstring> roots;
  roots.reserve(parsed.allowed_install_roots.size());
  for (const std::string& root : parsed.allowed_install_roots) {
    roots.push_back(Utf8ToWide(root));
  }
  std::vector<WindowsReleaseRootPublicKey> release_root_public_keys;
  release_root_public_keys.reserve(parsed.release_root_public_keys.size());
  for (const auto& key : parsed.release_root_public_keys) {
    release_root_public_keys.push_back(
        {key.key_id, key.algorithm, key.public_key_base64});
  }
  std::vector<WindowsAllowedInstallStrategy> allowed_strategies;
  allowed_strategies.reserve(parsed.allowed_strategies.size());
  for (const auto& strategy : parsed.allowed_strategies) {
    allowed_strategies.push_back({strategy.strategy, strategy.provider});
  }
  return WindowsHelperPolicy(
      parsed.policy_id, parsed.application_package_id,
      parsed.helper_service_id,
      parsed.allowed_application_signer.value,
      parsed.allowed_helper_signer.value, sealed_helper_sha256,
      std::move(roots), parsed.allowed_target_classes,
      std::move(release_root_public_keys), std::move(allowed_strategies),
      parsed.minimum_helper_protocol_version);
}

WindowsHelperPolicy WindowsHelperPolicy::ForTesting(
    std::string application_package_id,
    std::string application_publisher,
    std::string helper_publisher,
    std::string helper_sha256,
    std::vector<std::wstring> allowed_install_roots) {
  return WindowsHelperPolicy(
      "com.example.desktop-updater", std::move(application_package_id),
      "com.example.desktop-updater.helper",
      std::move(application_publisher), std::move(helper_publisher),
      std::move(helper_sha256), std::move(allowed_install_roots),
      {"applicationDirectory"},
      {{"test-release-root", "ed25519",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}},
      {{"directoryReplace", "platformDirectory"}}, 1);
}

bool WindowsHelperPolicy::AllowsRequest(
    std::int64_t protocol_version,
    const std::string& target_class,
    const std::string& strategy,
    const std::string& provider) const {
  if (protocol_version != 1 ||
      protocol_version < minimum_helper_protocol_version_ ||
      std::find(allowed_target_classes_.begin(),
                allowed_target_classes_.end(), target_class) ==
          allowed_target_classes_.end()) {
    return false;
  }
  return std::any_of(
      allowed_strategies_.begin(), allowed_strategies_.end(),
      [&](const WindowsAllowedInstallStrategy& allowed) {
        return allowed.strategy == strategy && allowed.provider == provider;
      });
}

WindowsHelperPolicyError::Code
WindowsHelperPolicy::PortableElevationErrorForTesting() {
  return WindowsHelperPolicyError::Code::kPortableElevationRejected;
}

}  // namespace desktop_updater::helper
