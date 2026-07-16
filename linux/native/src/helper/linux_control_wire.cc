#include "linux_control_wire.h"

#include <algorithm>
#include <set>
#include <string>
#include <utility>

#include "json_value.h"

namespace desktop_updater::helper {
namespace {

using runtime::internal::EncodeCanonicalJson;
using runtime::internal::JsonValue;
using runtime::internal::ParseJson;

bool IsUuid(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-' || value[14] != '4' ||
      std::string("89ab").find(value[19]) == std::string::npos) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const unsigned char byte = value[index];
    if (!((byte >= '0' && byte <= '9') ||
          (byte >= 'a' && byte <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool IsNonce(const std::string& value) {
  return value.size() == 43 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return (byte >= 'A' && byte <= 'Z') ||
                  (byte >= 'a' && byte <= 'z') ||
                  (byte >= '0' && byte <= '9') || byte == '-' || byte == '_';
         });
}

bool IsSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return (byte >= '0' && byte <= '9') ||
                  (byte >= 'a' && byte <= 'f');
         });
}

void Validate(const LinuxControlRequestV1& request) {
  if (request.protocol_version != 1 ||
      (request.operation != "queryTransaction" &&
       request.operation != "recoverPendingInstall") ||
      !IsUuid(request.transaction_id) || !IsNonce(request.request_nonce) ||
      request.caller_process_id <= 0 ||
      request.caller_process_start_identity.rfind("linux:", 0) != 0 ||
      !IsSha256(request.caller_executable_sha256) ||
      request.caller_signer_identity != request.caller_executable_sha256) {
    throw LinuxControlWireError("Linux control request rejected");
  }
}

void RequireKeys(const JsonValue& value,
                 const std::set<std::string>& expected) {
  if (value.object().size() != expected.size()) {
    throw LinuxControlWireError("Linux control request fields rejected");
  }
  for (const std::string& key : expected) {
    if (value.find(key) == nullptr) {
      throw LinuxControlWireError("Linux control request fields rejected");
    }
  }
}

}  // namespace

LinuxControlRequestV1 ParseLinuxControlRequestV1(
    const std::string& canonical_json) {
  try {
    const JsonValue root = ParseJson(canonical_json);
    if (EncodeCanonicalJson(root) != canonical_json) {
      throw LinuxControlWireError("Linux control request is not canonical");
    }
    RequireKeys(root, {"caller", "operation", "protocolVersion",
                       "requestNonce", "transactionId"});
    const JsonValue& caller = root.at("caller");
    RequireKeys(caller, {"executableSha256", "processId",
                         "processStartIdentity", "signerIdentity"});
    LinuxControlRequestV1 request{
        root.at("protocolVersion").integer(),
        root.at("operation").string(),
        root.at("transactionId").string(),
        root.at("requestNonce").string(),
        caller.at("processId").integer(),
        caller.at("processStartIdentity").string(),
        caller.at("executableSha256").string(),
        caller.at("signerIdentity").string()};
    Validate(request);
    return request;
  } catch (const LinuxControlWireError&) {
    throw;
  } catch (const std::exception&) {
    throw LinuxControlWireError("Linux control request decode failed");
  }
}

std::string EncodeLinuxControlRequestV1(
    const LinuxControlRequestV1& request) {
  Validate(request);
  JsonValue::Object caller;
  caller.emplace("executableSha256",
                 JsonValue(request.caller_executable_sha256));
  caller.emplace("processId", JsonValue(request.caller_process_id));
  caller.emplace("processStartIdentity",
                 JsonValue(request.caller_process_start_identity));
  caller.emplace("signerIdentity",
                 JsonValue(request.caller_signer_identity));
  JsonValue::Object root;
  root.emplace("caller", JsonValue(std::move(caller)));
  root.emplace("operation", JsonValue(request.operation));
  root.emplace("protocolVersion", JsonValue(request.protocol_version));
  root.emplace("requestNonce", JsonValue(request.request_nonce));
  root.emplace("transactionId", JsonValue(request.transaction_id));
  return EncodeCanonicalJson(JsonValue(std::move(root)));
}

}  // namespace desktop_updater::helper
