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

void ValidatePrivilegePolicy(const std::string& application_package_id,
                             const std::string& application_publisher,
                             const std::string& helper_publisher,
                             const std::string& helper_sha256,
                             const std::vector<std::wstring>& roots) {
  if (application_package_id.empty() || application_publisher.empty() ||
      helper_publisher.empty() || !IsSha256(helper_sha256)) {
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
    std::string application_package_id,
    std::string application_publisher,
    std::string helper_publisher,
    std::string helper_sha256,
    std::vector<std::wstring> allowed_install_roots)
    : application_package_id_(std::move(application_package_id)),
      application_publisher_(std::move(application_publisher)),
      helper_publisher_(std::move(helper_publisher)),
      helper_sha256_(std::move(helper_sha256)),
      allowed_install_roots_(std::move(allowed_install_roots)) {
  ValidatePrivilegePolicy(application_package_id_, application_publisher_,
                          helper_publisher_, helper_sha256_,
                          allowed_install_roots_);
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
  return WindowsHelperPolicy(
      parsed.application_package_id,
      parsed.allowed_application_signer.value,
      parsed.allowed_helper_signer.value, sealed_helper_sha256,
      std::move(roots));
}

WindowsHelperPolicy WindowsHelperPolicy::ForTesting(
    std::string application_package_id,
    std::string application_publisher,
    std::string helper_publisher,
    std::string helper_sha256,
    std::vector<std::wstring> allowed_install_roots) {
  return WindowsHelperPolicy(
      std::move(application_package_id), std::move(application_publisher),
      std::move(helper_publisher), std::move(helper_sha256),
      std::move(allowed_install_roots));
}

WindowsHelperPolicyError::Code
WindowsHelperPolicy::PortableElevationErrorForTesting() {
  return WindowsHelperPolicyError::Code::kPortableElevationRejected;
}

}  // namespace desktop_updater::helper
