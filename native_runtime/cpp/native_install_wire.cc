#include "native_install_wire.h"

#include <algorithm>
#include <initializer_list>
#include <set>
#include <string>
#include <utility>

#include "json_value.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

[[noreturn]] void Fail(const std::string& detail) {
  throw NativeInstallWireError(detail);
}

const JsonValue::Object& ParseCanonicalObject(
    const std::string& canonical_json,
    JsonValue* owner) {
  try {
    *owner = ParseJson(canonical_json);
    if (EncodeCanonicalJson(*owner) != canonical_json) {
      Fail("nonCanonicalJson");
    }
    return owner->object();
  } catch (const NativeInstallWireError&) {
    throw;
  } catch (const std::exception&) {
    Fail("invalidJson");
  }
}

void RequireExactKeys(const JsonValue::Object& object,
                      std::initializer_list<const char*> keys) {
  std::set<std::string> expected;
  for (const char* key : keys) expected.emplace(key);
  if (object.size() != expected.size()) Fail("unknownOrMissingField");
  for (const std::string& key : expected) {
    if (object.find(key) == object.end()) Fail("unknownOrMissingField");
  }
}

const JsonValue& At(const JsonValue::Object& object, const char* key) {
  return object.at(key);
}

bool IsLowercaseUuid(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-') {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const unsigned char byte = static_cast<unsigned char>(value[index]);
    if (!((byte >= '0' && byte <= '9') ||
          (byte >= 'a' && byte <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool IsSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return (byte >= '0' && byte <= '9') ||
                  (byte >= 'a' && byte <= 'f');
         });
}

bool IsReadyToken(const std::string& value) {
  return value.size() == 43 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return (byte >= 'A' && byte <= 'Z') ||
                  (byte >= 'a' && byte <= 'z') ||
                  (byte >= '0' && byte <= '9') || byte == '-' || byte == '_';
         });
}

void ValidateProtocolAndTransaction(std::int64_t protocol_version,
                                    const std::string& transaction_id) {
  if (protocol_version != 1) Fail("unsupportedProtocolVersion");
  if (!IsLowercaseUuid(transaction_id)) Fail("invalidTransactionId");
}

void ValidateReservation(const NativeInstallReservationV1& value) {
  ValidateProtocolAndTransaction(value.protocol_version,
                                 value.transaction_id);
  if (!IsReadyToken(value.ready_token)) Fail("invalidReadyToken");
  if (!IsSha256(value.journal_sha256)) Fail("invalidJournalSha256");
  if (!IsSha256(value.helper_endpoint_identity_sha256)) {
    Fail("invalidHelperEndpointIdentitySha256");
  }
  if (value.expires_at_unix_milliseconds < 0) Fail("invalidExpiry");
}

void ValidateCommand(const NativeInstallWireCommandV1& value) {
  ValidateProtocolAndTransaction(value.protocol_version,
                                 value.transaction_id);
  if (value.operation != "commitAfterExit" &&
      value.operation != "cancelReservation") {
    Fail("unsupportedOperation");
  }
  if (!IsReadyToken(value.ready_token) ||
      !IsSha256(value.journal_sha256) ||
      !IsSha256(value.helper_endpoint_identity_sha256)) {
    Fail("invalidCommandBinding");
  }
}

const std::set<std::string> kStates = {
    "prepared",          "backupCreated", "targetActivated",
    "managerStarted",    "verificationPending",
    "completed",         "rolledBack",    "manualActionRequired",
};

const std::set<std::string> kResultCodes = {
    "helperUnavailable",      "helperTrustFailure",
    "authorizationDenied",    "targetValidationFailure",
    "stageProvenanceFailure", "transactionBusy",
    "journalCorrupt",         "recoveryRequired",
    "rolledBack",             "externalManagerPending",
    "manualActionRequired",   "packageManagerFailure",
    "relaunchFailure",        "completed",
};

void ValidateStatus(const NativeInstallTransactionStatusV1& value) {
  ValidateProtocolAndTransaction(value.protocol_version,
                                 value.transaction_id);
  if (kStates.count(value.state) == 0 ||
      kResultCodes.count(value.result_code) == 0 ||
      !IsSha256(value.journal_sha256)) {
    Fail("invalidTransactionStatus");
  }
}

void ValidateRecovery(const NativeInstallRecoveryResultV1& value) {
  ValidateProtocolAndTransaction(value.protocol_version,
                                 value.transaction_id);
  if (kResultCodes.count(value.result_code) == 0 ||
      (value.verified_outcome != "oldTarget" &&
       value.verified_outcome != "newTarget" &&
       value.verified_outcome != "none") ||
      !IsSha256(value.journal_sha256)) {
    Fail("invalidRecoveryResult");
  }
}

}  // namespace

bool NativeInstallReservationV1::operator==(
    const NativeInstallReservationV1& other) const {
  return protocol_version == other.protocol_version &&
         transaction_id == other.transaction_id &&
         ready_token == other.ready_token &&
         journal_sha256 == other.journal_sha256 &&
         helper_endpoint_identity_sha256 ==
             other.helper_endpoint_identity_sha256 &&
         expires_at_unix_milliseconds ==
             other.expires_at_unix_milliseconds;
}

bool NativeInstallWireCommandV1::operator==(
    const NativeInstallWireCommandV1& other) const {
  return operation == other.operation &&
         protocol_version == other.protocol_version &&
         transaction_id == other.transaction_id &&
         ready_token == other.ready_token &&
         journal_sha256 == other.journal_sha256 &&
         helper_endpoint_identity_sha256 ==
             other.helper_endpoint_identity_sha256;
}

bool NativeInstallTransactionStatusV1::operator==(
    const NativeInstallTransactionStatusV1& other) const {
  return protocol_version == other.protocol_version &&
         transaction_id == other.transaction_id && state == other.state &&
         result_code == other.result_code &&
         journal_sha256 == other.journal_sha256;
}

bool NativeInstallRecoveryResultV1::operator==(
    const NativeInstallRecoveryResultV1& other) const {
  return protocol_version == other.protocol_version &&
         transaction_id == other.transaction_id &&
         result_code == other.result_code &&
         verified_outcome == other.verified_outcome &&
         journal_sha256 == other.journal_sha256;
}

NativeInstallReservationV1 ParseNativeInstallReservationV1(
    const std::string& canonical_json) {
  try {
    JsonValue owner;
    const auto& object = ParseCanonicalObject(canonical_json, &owner);
    RequireExactKeys(object,
                     {"protocolVersion", "transactionId", "readyToken",
                      "journalSha256", "helperEndpointIdentitySha256",
                      "expiresAtUnixMilliseconds"});
    NativeInstallReservationV1 value{
        At(object, "protocolVersion").integer(),
        At(object, "transactionId").string(),
        At(object, "readyToken").string(),
        At(object, "journalSha256").string(),
        At(object, "helperEndpointIdentitySha256").string(),
        At(object, "expiresAtUnixMilliseconds").integer(),
    };
    ValidateReservation(value);
    return value;
  } catch (const NativeInstallWireError&) {
    throw;
  } catch (const std::exception&) {
    Fail("invalidReservation");
  }
}

std::string EncodeNativeInstallReservationV1(
    const NativeInstallReservationV1& value) {
  ValidateReservation(value);
  JsonValue::Object object;
  object.emplace("protocolVersion", JsonValue(value.protocol_version));
  object.emplace("transactionId", JsonValue(value.transaction_id));
  object.emplace("readyToken", JsonValue(value.ready_token));
  object.emplace("journalSha256", JsonValue(value.journal_sha256));
  object.emplace("helperEndpointIdentitySha256",
                 JsonValue(value.helper_endpoint_identity_sha256));
  object.emplace("expiresAtUnixMilliseconds",
                 JsonValue(value.expires_at_unix_milliseconds));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

NativeInstallWireCommandV1 ParseNativeInstallWireCommandV1(
    const std::string& canonical_json) {
  try {
    JsonValue owner;
    const auto& object = ParseCanonicalObject(canonical_json, &owner);
    RequireExactKeys(object,
                     {"operation", "protocolVersion", "transactionId",
                      "readyToken", "journalSha256",
                      "helperEndpointIdentitySha256"});
    NativeInstallWireCommandV1 value{
        At(object, "operation").string(),
        At(object, "protocolVersion").integer(),
        At(object, "transactionId").string(),
        At(object, "readyToken").string(),
        At(object, "journalSha256").string(),
        At(object, "helperEndpointIdentitySha256").string(),
    };
    ValidateCommand(value);
    return value;
  } catch (const NativeInstallWireError&) {
    throw;
  } catch (const std::exception&) {
    Fail("invalidCommand");
  }
}

std::string EncodeNativeInstallWireCommandV1(
    const NativeInstallWireCommandV1& value) {
  ValidateCommand(value);
  JsonValue::Object object;
  object.emplace("operation", JsonValue(value.operation));
  object.emplace("protocolVersion", JsonValue(value.protocol_version));
  object.emplace("transactionId", JsonValue(value.transaction_id));
  object.emplace("readyToken", JsonValue(value.ready_token));
  object.emplace("journalSha256", JsonValue(value.journal_sha256));
  object.emplace("helperEndpointIdentitySha256",
                 JsonValue(value.helper_endpoint_identity_sha256));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

NativeInstallTransactionStatusV1 ParseNativeInstallTransactionStatusV1(
    const std::string& canonical_json) {
  try {
    JsonValue owner;
    const auto& object = ParseCanonicalObject(canonical_json, &owner);
    RequireExactKeys(object, {"protocolVersion", "transactionId", "state",
                              "resultCode", "journalSha256"});
    NativeInstallTransactionStatusV1 value{
        At(object, "protocolVersion").integer(),
        At(object, "transactionId").string(),
        At(object, "state").string(),
        At(object, "resultCode").string(),
        At(object, "journalSha256").string(),
    };
    ValidateStatus(value);
    return value;
  } catch (const NativeInstallWireError&) {
    throw;
  } catch (const std::exception&) {
    Fail("invalidTransactionStatus");
  }
}

std::string EncodeNativeInstallTransactionStatusV1(
    const NativeInstallTransactionStatusV1& value) {
  ValidateStatus(value);
  JsonValue::Object object;
  object.emplace("protocolVersion", JsonValue(value.protocol_version));
  object.emplace("transactionId", JsonValue(value.transaction_id));
  object.emplace("state", JsonValue(value.state));
  object.emplace("resultCode", JsonValue(value.result_code));
  object.emplace("journalSha256", JsonValue(value.journal_sha256));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

NativeInstallRecoveryResultV1 ParseNativeInstallRecoveryResultV1(
    const std::string& canonical_json) {
  try {
    JsonValue owner;
    const auto& object = ParseCanonicalObject(canonical_json, &owner);
    RequireExactKeys(object,
                     {"protocolVersion", "transactionId", "resultCode",
                      "verifiedOutcome", "journalSha256"});
    NativeInstallRecoveryResultV1 value{
        At(object, "protocolVersion").integer(),
        At(object, "transactionId").string(),
        At(object, "resultCode").string(),
        At(object, "verifiedOutcome").string(),
        At(object, "journalSha256").string(),
    };
    ValidateRecovery(value);
    return value;
  } catch (const NativeInstallWireError&) {
    throw;
  } catch (const std::exception&) {
    Fail("invalidRecoveryResult");
  }
}

std::string EncodeNativeInstallRecoveryResultV1(
    const NativeInstallRecoveryResultV1& value) {
  ValidateRecovery(value);
  JsonValue::Object object;
  object.emplace("protocolVersion", JsonValue(value.protocol_version));
  object.emplace("transactionId", JsonValue(value.transaction_id));
  object.emplace("resultCode", JsonValue(value.result_code));
  object.emplace("verifiedOutcome", JsonValue(value.verified_outcome));
  object.emplace("journalSha256", JsonValue(value.journal_sha256));
  return EncodeCanonicalJson(JsonValue(std::move(object)));
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
