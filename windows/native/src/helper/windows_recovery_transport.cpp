#include "windows_recovery_transport.h"

#include <algorithm>
#include <regex>
#include <set>
#include <utility>

#include "json_value.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::NativeInstallRecoveryResultV1;
using desktop_updater::runtime::internal::NativeInstallTransactionStatusV1;
using desktop_updater::runtime::internal::ParseJson;
using desktop_updater::runtime::internal::ParseNativeInstallRecoveryResultV1;
using desktop_updater::runtime::internal::ParseNativeInstallTransactionStatusV1;

const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

bool IsNonce(const std::string& nonce) {
  return nonce.size() == 43 &&
         std::all_of(nonce.begin(), nonce.end(), [](unsigned char value) {
           return (value >= 'A' && value <= 'Z') ||
                  (value >= 'a' && value <= 'z') ||
                  (value >= '0' && value <= '9') || value == '-' ||
                  value == '_';
         });
}

void Validate(const WindowsPersistentRecoveryRequestV1& request) {
  if ((request.operation != "queryTransaction" &&
       request.operation != "recoverPendingInstall" &&
       request.operation != "resolvePendingInstallAfterExit") ||
      request.protocol_version != 1 || request.policy_id.empty() ||
      request.package_id.empty() ||
      !std::regex_match(request.transaction_id, kTransactionId) ||
      !IsNonce(request.request_nonce)) {
    throw NamedPipeTransportError("invalid persistent recovery request");
  }
}

}  // namespace

bool WindowsPersistentRecoveryRequestV1::operator==(
    const WindowsPersistentRecoveryRequestV1& other) const {
  return operation == other.operation &&
         protocol_version == other.protocol_version &&
         policy_id == other.policy_id && package_id == other.package_id &&
         transaction_id == other.transaction_id &&
         request_nonce == other.request_nonce;
}

WindowsPersistentRecoveryRequestV1 ParseWindowsPersistentRecoveryRequestV1(
    const std::string& canonical_json) {
  try {
    const JsonValue value = ParseJson(canonical_json);
    if (EncodeCanonicalJson(value) != canonical_json) {
      throw NamedPipeTransportError(
          "persistent recovery request is not canonical JSON");
    }
    const auto& object = value.object();
    const std::set<std::string> expected = {
        "operation", "packageId", "policyId", "protocolVersion",
        "requestNonce", "transactionId"};
    std::set<std::string> actual;
    for (const auto& entry : object) actual.insert(entry.first);
    if (actual != expected) {
      throw NamedPipeTransportError(
          "persistent recovery request fields are invalid");
    }
    WindowsPersistentRecoveryRequestV1 request{
        value.at("operation").string(),
        value.at("protocolVersion").integer(),
        value.at("policyId").string(),
        value.at("packageId").string(),
        value.at("transactionId").string(),
        value.at("requestNonce").string(),
    };
    Validate(request);
    return request;
  } catch (const NamedPipeTransportError&) {
    throw;
  } catch (const std::exception&) {
    throw NamedPipeTransportError("persistent recovery request is invalid");
  }
}

std::string EncodeWindowsPersistentRecoveryRequestV1(
    const WindowsPersistentRecoveryRequestV1& request) {
  Validate(request);
  JsonValue::Object object;
  object.emplace("operation", JsonValue(request.operation));
  object.emplace("packageId", JsonValue(request.package_id));
  object.emplace("policyId", JsonValue(request.policy_id));
  object.emplace("protocolVersion", JsonValue(request.protocol_version));
  object.emplace("requestNonce", JsonValue(request.request_nonce));
  object.emplace("transactionId", JsonValue(request.transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

WindowsElevatedRecoveryResponse LaunchAuthenticatedElevatedRecoveryRequest(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const WindowsPersistentRecoveryRequestV1& request,
    DWORD timeout_millis) {
  Validate(request);
  if (request.policy_id != policy.policy_id() ||
      request.package_id != policy.application_package_id()) {
    throw NamedPipeTransportError(
        "persistent recovery request is not bound to sealed policy");
  }
  const WindowsElevatedHelperExchange exchange =
      LaunchAuthenticatedElevatedHelperExchange(
          fixed_helper_path, policy, request.request_nonce,
          EncodeWindowsPersistentRecoveryRequestV1(request), timeout_millis);
  if (exchange.result != ElevationLaunchResult::kLaunched) {
    return {exchange.result, request.operation == "recoverPendingInstall",
            {}, {}, ""};
  }
  if (exchange.helper_endpoint_identity_sha256 != policy.helper_sha256()) {
    throw NamedPipeTransportError(
        "persistent recovery helper identity changed");
  }
  WindowsElevatedRecoveryResponse result;
  result.result = exchange.result;
  result.is_recovery = request.operation == "recoverPendingInstall";
  result.helper_endpoint_identity_sha256 =
      exchange.helper_endpoint_identity_sha256;
  if (result.is_recovery) {
    result.recovery =
        ParseNativeInstallRecoveryResultV1(exchange.canonical_response);
    if (result.recovery.transaction_id != request.transaction_id) {
      throw NamedPipeTransportError(
          "persistent recovery response binding changed");
    }
  } else {
    result.status =
        ParseNativeInstallTransactionStatusV1(exchange.canonical_response);
    if (result.status.transaction_id != request.transaction_id) {
      throw NamedPipeTransportError(
          "persistent transaction status response binding changed");
    }
  }
  return result;
}

WindowsElevatedRecoveryResponse LaunchAuthenticatedPortableRecoveryRequest(
    const std::filesystem::path& fixed_helper_path,
    const WindowsHelperPolicy& policy,
    const WindowsPersistentRecoveryRequestV1& request,
    DWORD timeout_millis) {
  Validate(request);
  if (!policy.is_portable() || request.policy_id != policy.policy_id() ||
      request.package_id != policy.application_package_id()) {
    throw NamedPipeTransportError(
        "portable recovery request is not bound to sealed policy");
  }
  const WindowsElevatedHelperExchange exchange =
      LaunchAuthenticatedPortableHelperExchange(
          fixed_helper_path, policy, request.request_nonce,
          EncodeWindowsPersistentRecoveryRequestV1(request), timeout_millis);
  if (exchange.result != ElevationLaunchResult::kLaunched) {
    return {exchange.result, request.operation == "recoverPendingInstall",
            {}, {}, ""};
  }
  if (exchange.helper_endpoint_identity_sha256 != policy.helper_sha256()) {
    throw NamedPipeTransportError("portable recovery helper identity changed");
  }
  WindowsElevatedRecoveryResponse result;
  result.result = exchange.result;
  result.is_recovery = request.operation == "recoverPendingInstall";
  result.helper_endpoint_identity_sha256 =
      exchange.helper_endpoint_identity_sha256;
  if (result.is_recovery) {
    result.recovery =
        ParseNativeInstallRecoveryResultV1(exchange.canonical_response);
    if (result.recovery.transaction_id != request.transaction_id) {
      throw NamedPipeTransportError(
          "portable recovery response binding changed");
    }
  } else {
    result.status =
        ParseNativeInstallTransactionStatusV1(exchange.canonical_response);
    if (result.status.transaction_id != request.transaction_id) {
      throw NamedPipeTransportError(
          "portable transaction status response binding changed");
    }
  }
  return result;
}

}  // namespace desktop_updater::helper
