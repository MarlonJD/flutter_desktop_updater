#include "native_install_request.h"

#include <algorithm>
#include <cstddef>
#include <initializer_list>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <utility>

#include "json_value.h"

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

using Object = JsonValue::Object;

[[noreturn]] void Fail(const std::string& code) {
  throw NativeInstallProtocolError(code);
}

std::size_t Utf8ScalarCount(const std::string& value) {
  std::size_t count = 0;
  for (std::size_t index = 0; index < value.size();) {
    const unsigned char first = static_cast<unsigned char>(value[index]);
    std::size_t width = 0;
    std::uint32_t scalar = 0;
    if (first <= 0x7f) {
      width = 1;
      scalar = first;
    } else if (first >= 0xc2 && first <= 0xdf) {
      width = 2;
      scalar = first & 0x1f;
    } else if (first >= 0xe0 && first <= 0xef) {
      width = 3;
      scalar = first & 0x0f;
    } else if (first >= 0xf0 && first <= 0xf4) {
      width = 4;
      scalar = first & 0x07;
    } else {
      Fail("invalidJson");
    }
    if (index + width > value.size()) Fail("invalidJson");
    for (std::size_t offset = 1; offset < width; ++offset) {
      const unsigned char continuation =
          static_cast<unsigned char>(value[index + offset]);
      if ((continuation & 0xc0) != 0x80) Fail("invalidJson");
      scalar = (scalar << 6) | (continuation & 0x3f);
    }
    if ((width == 2 && scalar < 0x80) ||
        (width == 3 && scalar < 0x800) ||
        (width == 4 && scalar < 0x10000) ||
        (scalar >= 0xd800 && scalar <= 0xdfff) || scalar > 0x10ffff) {
      Fail("invalidJson");
    }
    index += width;
    ++count;
  }
  return count;
}

std::string Field(const std::string& path, const std::string& key) {
  return path.empty() ? key : path + "." + key;
}

const Object& RequireObject(const JsonValue* value,
                            const std::string& field) {
  if (value == nullptr || value->type() != JsonValue::Type::kObject) {
    Fail("invalidType:" + field);
  }
  return value->object();
}

void RequireExactKeys(const Object& object,
                      std::initializer_list<const char*> required,
                      std::initializer_list<const char*> optional = {},
                      const std::string& path = "") {
  std::set<std::string> allowed;
  for (const char* key : required) {
    allowed.insert(key);
    if (object.find(key) == object.end()) {
      Fail("missingField:" + Field(path, key));
    }
  }
  for (const char* key : optional) allowed.insert(key);
  for (const auto& entry : object) {
    if (allowed.find(entry.first) == allowed.end()) {
      Fail("unknownField:" + Field(path, entry.first));
    }
  }
}

const JsonValue* Find(const Object& object, const char* key) {
  const auto found = object.find(key);
  return found == object.end() ? nullptr : &found->second;
}

std::string RequireString(const JsonValue* value, const std::string& field) {
  if (value == nullptr || value->type() != JsonValue::Type::kString) {
    Fail("invalidType:" + field);
  }
  return value->string();
}

std::string RequireBoundedString(const JsonValue* value,
                                 const std::string& field,
                                 std::size_t maximum) {
  const std::string result = RequireString(value, field);
  const std::size_t length = Utf8ScalarCount(result);
  if (length == 0 || length > maximum ||
      std::all_of(result.begin(), result.end(), [](unsigned char byte) {
        return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n';
      })) {
    Fail("invalidString:" + field);
  }
  return result;
}

std::int64_t RequireInteger(const JsonValue* value,
                            const std::string& field,
                            std::int64_t minimum,
                            std::int64_t maximum =
                                std::numeric_limits<std::int64_t>::max()) {
  if (value == nullptr || value->type() != JsonValue::Type::kInteger) {
    Fail("invalidInteger:" + field);
  }
  const std::int64_t result = value->integer();
  if (result < minimum || result > maximum) {
    Fail("invalidInteger:" + field);
  }
  return result;
}

bool IsAsciiAlphaNumeric(unsigned char byte) {
  return (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
         (byte >= '0' && byte <= '9');
}

bool IsLowerHex(const std::string& value, std::size_t length) {
  return value.size() == length &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return (byte >= '0' && byte <= '9') ||
                  (byte >= 'a' && byte <= 'f');
         });
}

bool IsLowercaseUuid(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-') {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const unsigned char byte = static_cast<unsigned char>(value[index]);
    if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool IsDottedIdentifier(const std::string& value) {
  if (value.size() < 3 || value.size() > 128) return false;
  const auto valid_edge = [](unsigned char byte) {
    return (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9');
  };
  if (!valid_edge(static_cast<unsigned char>(value.front())) ||
      !valid_edge(static_cast<unsigned char>(value.back()))) {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](unsigned char byte) {
    return (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') ||
           byte == '.' || byte == '_' || byte == '-';
  });
}

bool IsReadyToken(const std::string& value) {
  return value.size() == 43 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return IsAsciiAlphaNumeric(byte) || byte == '-' || byte == '_';
         });
}

std::string RequireSha256(const JsonValue* value,
                          const std::string& field,
                          const std::string& failure = "") {
  const std::string result = RequireString(value, field);
  if (!IsLowerHex(result, 64)) {
    Fail(failure.empty() ? "invalidSha256:" + field : failure);
  }
  return result;
}

std::string RequireDottedIdentifier(const JsonValue* value,
                                    const std::string& field,
                                    const std::string& failure) {
  const std::string result = RequireString(value, field);
  if (!IsDottedIdentifier(result)) Fail(failure);
  return result;
}

std::string RequireEnumeration(const JsonValue* value,
                               const std::string& field,
                               const std::set<std::string>& allowed,
                               const std::string& failure) {
  const std::string result = RequireString(value, field);
  if (allowed.find(result) == allowed.end()) Fail(failure);
  return result;
}

std::string RequireSafeSiblingName(const JsonValue* value) {
  const std::string result = RequireString(value, "target.targetNameHint");
  const std::size_t length = Utf8ScalarCount(result);
  if (length == 0 || length > 255 || result == "." || result == ".." ||
      result.find('/') != std::string::npos ||
      result.find('\\') != std::string::npos ||
      result.find(':') != std::string::npos) {
    Fail("invalidTargetNameHint");
  }
  return result;
}

std::string RequireSafeRelativePath(const JsonValue* value) {
  const std::string result =
      RequireString(value, "target.executableRelativePath");
  const std::size_t length = Utf8ScalarCount(result);
  if (length == 0 || length > 1024 || result.front() == '/' ||
      result.find('\\') != std::string::npos ||
      (result.size() >= 2 &&
       ((result[0] >= 'A' && result[0] <= 'Z') ||
        (result[0] >= 'a' && result[0] <= 'z')) &&
       result[1] == ':')) {
    Fail("invalidExecutableRelativePath");
  }
  std::size_t start = 0;
  while (start <= result.size()) {
    const std::size_t end = result.find('/', start);
    const std::string component = result.substr(
        start, end == std::string::npos ? std::string::npos : end - start);
    if (component.empty() || component == "." || component == "..") {
      Fail("invalidExecutableRelativePath");
    }
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return result;
}

NativeInstallVersionIdentityV1 ParseVersionIdentity(
    const JsonValue* value,
    const std::string& field) {
  const Object& object = RequireObject(value, field);
  RequireExactKeys(object, {"version", "buildNumber",
                            "packageIdentitySha256"}, {}, field);
  NativeInstallVersionIdentityV1 result;
  result.version =
      RequireBoundedString(Find(object, "version"), field + ".version", 128);
  result.build_number = RequireInteger(Find(object, "buildNumber"),
                                       field + ".buildNumber", 0);
  result.package_identity_sha256 = RequireSha256(
      Find(object, "packageIdentitySha256"),
      field + ".packageIdentitySha256");
  return result;
}

NativeInstallTargetV1 ParseTarget(const JsonValue* value,
                                  const std::string& strategy) {
  const Object& object = RequireObject(value, "target");
  RequireExactKeys(object,
                   {"class", "pathHint", "targetNameHint",
                    "executableRelativePath", "identityProofSha256"},
                   {}, "target");
  static const std::set<std::string> classes = {
      "sameUserWritable", "applicationBundle", "applicationDirectory",
      "singleExecutable", "protectedApplication", "systemPackage",
      "externalManaged"};
  static const std::map<std::string, std::set<std::string>> strategy_classes = {
      {"directoryReplace",
       {"sameUserWritable", "applicationBundle", "applicationDirectory",
        "protectedApplication"}},
      {"singleFileReplace", {"singleExecutable"}},
      {"verifiedInstallerHandoff",
       {"applicationBundle", "applicationDirectory",
        "protectedApplication"}},
      {"systemPackageTransaction", {"systemPackage"}},
      {"externalManagedRefresh", {"externalManaged"}},
  };
  NativeInstallTargetV1 result;
  result.target_class = RequireEnumeration(
      Find(object, "class"), "target.class", classes, "unknownTargetClass");
  const auto allowed = strategy_classes.find(strategy);
  if (allowed == strategy_classes.end() ||
      allowed->second.find(result.target_class) == allowed->second.end()) {
    Fail("strategyTargetMismatch");
  }
  result.path_hint = RequireBoundedString(Find(object, "pathHint"),
                                          "target.pathHint", 4096);
  result.target_name_hint =
      RequireSafeSiblingName(Find(object, "targetNameHint"));
  result.executable_relative_path =
      RequireSafeRelativePath(Find(object, "executableRelativePath"));
  result.identity_proof_sha256 = RequireSha256(
      Find(object, "identityProofSha256"), "target.identityProofSha256");
  return result;
}

NativeInstallStageV1 ParseStage(const JsonValue* value) {
  const Object& object = RequireObject(value, "stage");
  RequireExactKeys(object,
                   {"pathHint", "ownershipNonce", "provenanceSha256",
                    "artifactSha256", "artifactLength"},
                   {}, "stage");
  NativeInstallStageV1 result;
  result.path_hint = RequireBoundedString(Find(object, "pathHint"),
                                          "stage.pathHint", 4096);
  result.ownership_nonce = RequireSha256(
      Find(object, "ownershipNonce"), "stage.ownershipNonce",
      "invalidStageOwnershipNonce");
  result.provenance_sha256 = RequireSha256(
      Find(object, "provenanceSha256"), "stage.provenanceSha256");
  result.artifact_sha256 = RequireSha256(
      Find(object, "artifactSha256"), "stage.artifactSha256");
  result.artifact_length = RequireInteger(
      Find(object, "artifactLength"), "stage.artifactLength", 1);
  return result;
}

NativeInstallSignedDescriptorV1 ParseSignedDescriptor(
    const JsonValue* value) {
  const Object& object = RequireObject(value, "signedDescriptor");
  RequireExactKeys(object,
                   {"canonicalSha256", "signatureAlgorithm", "keyId",
                    "signatureBase64"},
                   {}, "signedDescriptor");
  NativeInstallSignedDescriptorV1 result;
  result.canonical_sha256 = RequireSha256(
      Find(object, "canonicalSha256"), "signedDescriptor.canonicalSha256");
  result.signature_algorithm = RequireString(
      Find(object, "signatureAlgorithm"),
      "signedDescriptor.signatureAlgorithm");
  if (result.signature_algorithm != "ed25519") {
    Fail("unsupportedDescriptorSignatureAlgorithm");
  }
  result.key_id = RequireString(Find(object, "keyId"),
                                "signedDescriptor.keyId");
  if (result.key_id.empty() || result.key_id.size() > 128 ||
      !std::all_of(result.key_id.begin(), result.key_id.end(),
                   [](unsigned char byte) {
                     return IsAsciiAlphaNumeric(byte) || byte == '.' ||
                            byte == '_' || byte == '-';
                   })) {
    Fail("invalidDescriptorKeyId");
  }
  result.signature_base64 = RequireString(
      Find(object, "signatureBase64"), "signedDescriptor.signatureBase64");
  if (result.signature_base64.size() != 88 ||
      result.signature_base64.substr(86) != "==" ||
      !std::all_of(result.signature_base64.begin(),
                   result.signature_base64.begin() + 86,
                   [](unsigned char byte) {
                     return IsAsciiAlphaNumeric(byte) || byte == '+' ||
                            byte == '/';
                   })) {
    Fail("invalidDescriptorSignature");
  }
  return result;
}

NativeInstallCallerV1 ParseCaller(const JsonValue* value,
                                  const std::string& package_id) {
  const Object& object = RequireObject(value, "caller");
  RequireExactKeys(object,
                   {"processId", "processStartIdentity", "executableSha256",
                    "packageId", "signerIdentity"},
                   {}, "caller");
  NativeInstallCallerV1 result;
  result.process_id = RequireInteger(Find(object, "processId"),
                                     "caller.processId", 1, 4294967295LL);
  result.process_start_identity = RequireBoundedString(
      Find(object, "processStartIdentity"), "caller.processStartIdentity",
      256);
  result.executable_sha256 = RequireSha256(
      Find(object, "executableSha256"), "caller.executableSha256");
  result.package_id = RequireDottedIdentifier(
      Find(object, "packageId"), "caller.packageId", "invalidCallerPackageId");
  if (result.package_id != package_id) Fail("callerPackageIdMismatch");
  result.signer_identity = RequireBoundedString(
      Find(object, "signerIdentity"), "caller.signerIdentity", 512);
  return result;
}

NativeInstallDiagnosticsDestinationV1 ParseDiagnostics(
    const JsonValue* value) {
  NativeInstallDiagnosticsDestinationV1 result;
  if (value == nullptr) return result;
  const Object& object = RequireObject(value, "diagnosticsDestination");
  RequireExactKeys(object, {"kind"}, {"stream"},
                   "diagnosticsDestination");
  static const std::set<std::string> kinds = {"platformLog",
                                               "inheritedStream"};
  result.present = true;
  result.kind = RequireEnumeration(Find(object, "kind"),
                                   "diagnosticsDestination.kind", kinds,
                                   "invalidDiagnosticsDestination");
  const JsonValue* stream = Find(object, "stream");
  if (result.kind == "inheritedStream") {
    if (stream == nullptr ||
        RequireString(stream, "diagnosticsDestination.stream") != "stderr") {
      Fail("invalidDiagnosticsDestination");
    }
    result.stream = "stderr";
  } else if (stream != nullptr) {
    Fail("invalidDiagnosticsDestination");
  }
  return result;
}

}  // namespace

NativeInstallProtocolError::NativeInstallProtocolError(std::string code)
    : std::runtime_error(code), code_(std::move(code)) {}

NativeInstallTransactionRequestV1 ParseNativeInstallTransactionRequestV1(
    const std::string& canonical_json) {
  try {
    (void)Utf8ScalarCount(canonical_json);
    const JsonValue value = ParseJson(canonical_json);
    if (EncodeCanonicalJson(value) != canonical_json) {
      Fail("nonCanonicalJson");
    }
    const Object& object = RequireObject(&value, "request");
    RequireExactKeys(
        object,
        {"schemaVersion", "protocolVersion", "transactionId", "policyId",
         "packageId", "strategy", "provider", "target", "currentIdentity",
         "desiredIdentity", "stage", "signedDescriptor", "caller",
         "requestNonce"},
        {"diagnosticsDestination"});

    NativeInstallTransactionRequestV1 result;
    result.schema_version = RequireInteger(Find(object, "schemaVersion"),
                                           "schemaVersion",
                                           std::numeric_limits<std::int64_t>::min());
    if (result.schema_version != 1) Fail("unsupportedSchemaVersion");
    result.protocol_version = RequireInteger(
        Find(object, "protocolVersion"), "protocolVersion",
        std::numeric_limits<std::int64_t>::min());
    if (result.protocol_version != 1) Fail("unsupportedProtocolVersion");

    result.transaction_id =
        RequireString(Find(object, "transactionId"), "transactionId");
    if (!IsLowercaseUuid(result.transaction_id)) Fail("invalidTransactionId");
    result.policy_id = RequireDottedIdentifier(
        Find(object, "policyId"), "policyId", "invalidPolicyId");
    result.package_id = RequireDottedIdentifier(
        Find(object, "packageId"), "packageId", "invalidPackageId");

    static const std::map<std::string, std::set<std::string>>
        strategy_providers = {
            {"directoryReplace", {"platformDirectory"}},
            {"singleFileReplace", {"platformFile"}},
            {"verifiedInstallerHandoff", {"macosInstaller", "windowsInno"}},
            {"systemPackageTransaction", {"apt", "dnf"}},
            {"externalManagedRefresh", {"flatpak", "snap"}},
        };
    static const std::set<std::string> strategies = {
        "directoryReplace", "singleFileReplace", "verifiedInstallerHandoff",
        "systemPackageTransaction", "externalManagedRefresh"};
    static const std::set<std::string> providers = {
        "platformDirectory", "platformFile", "macosInstaller", "windowsInno",
        "apt", "dnf", "flatpak", "snap"};
    result.strategy = RequireEnumeration(Find(object, "strategy"), "strategy",
                                         strategies, "unknownStrategy");
    result.provider = RequireEnumeration(Find(object, "provider"), "provider",
                                         providers, "unknownProvider");
    if (strategy_providers.at(result.strategy).find(result.provider) ==
        strategy_providers.at(result.strategy).end()) {
      Fail("strategyProviderMismatch");
    }

    result.target = ParseTarget(Find(object, "target"), result.strategy);
    result.current_identity =
        ParseVersionIdentity(Find(object, "currentIdentity"),
                             "currentIdentity");
    result.desired_identity =
        ParseVersionIdentity(Find(object, "desiredIdentity"),
                             "desiredIdentity");
    result.stage = ParseStage(Find(object, "stage"));
    result.signed_descriptor =
        ParseSignedDescriptor(Find(object, "signedDescriptor"));
    result.caller = ParseCaller(Find(object, "caller"), result.package_id);
    result.request_nonce =
        RequireString(Find(object, "requestNonce"), "requestNonce");
    if (!IsReadyToken(result.request_nonce)) Fail("invalidRequestNonce");
    result.diagnostics_destination =
        ParseDiagnostics(Find(object, "diagnosticsDestination"));
    return result;
  } catch (const NativeInstallProtocolError&) {
    throw;
  } catch (const JsonError& error) {
    const std::string message = error.what();
    const std::string prefix = "Duplicate JSON object key: ";
    if (message.rfind(prefix, 0) == 0) {
      std::string key = message.substr(prefix.size());
      if (!key.empty() && key.back() == '.') key.pop_back();
      Fail("duplicateKey:" + key);
    }
    Fail("invalidJson");
  }
}

std::string EncodeCanonicalNativeInstallTransactionRequestV1(
    const NativeInstallTransactionRequestV1& request) {
  JsonValue::Object target;
  target.emplace("class", JsonValue(request.target.target_class));
  target.emplace("pathHint", JsonValue(request.target.path_hint));
  target.emplace("targetNameHint",
                 JsonValue(request.target.target_name_hint));
  target.emplace("executableRelativePath",
                 JsonValue(request.target.executable_relative_path));
  target.emplace("identityProofSha256",
                 JsonValue(request.target.identity_proof_sha256));

  const auto encode_identity = [](const NativeInstallVersionIdentityV1& value) {
    JsonValue::Object identity;
    identity.emplace("version", JsonValue(value.version));
    identity.emplace("buildNumber", JsonValue(value.build_number));
    identity.emplace("packageIdentitySha256",
                     JsonValue(value.package_identity_sha256));
    return JsonValue(std::move(identity));
  };

  JsonValue::Object stage;
  stage.emplace("pathHint", JsonValue(request.stage.path_hint));
  stage.emplace("ownershipNonce", JsonValue(request.stage.ownership_nonce));
  stage.emplace("provenanceSha256",
                JsonValue(request.stage.provenance_sha256));
  stage.emplace("artifactSha256", JsonValue(request.stage.artifact_sha256));
  stage.emplace("artifactLength", JsonValue(request.stage.artifact_length));

  JsonValue::Object descriptor;
  descriptor.emplace("canonicalSha256",
                     JsonValue(request.signed_descriptor.canonical_sha256));
  descriptor.emplace("signatureAlgorithm",
                     JsonValue(request.signed_descriptor.signature_algorithm));
  descriptor.emplace("keyId", JsonValue(request.signed_descriptor.key_id));
  descriptor.emplace("signatureBase64",
                     JsonValue(request.signed_descriptor.signature_base64));

  JsonValue::Object caller;
  caller.emplace("processId", JsonValue(request.caller.process_id));
  caller.emplace("processStartIdentity",
                 JsonValue(request.caller.process_start_identity));
  caller.emplace("executableSha256",
                 JsonValue(request.caller.executable_sha256));
  caller.emplace("packageId", JsonValue(request.caller.package_id));
  caller.emplace("signerIdentity",
                 JsonValue(request.caller.signer_identity));

  JsonValue::Object root;
  root.emplace("schemaVersion", JsonValue(request.schema_version));
  root.emplace("protocolVersion", JsonValue(request.protocol_version));
  root.emplace("transactionId", JsonValue(request.transaction_id));
  root.emplace("policyId", JsonValue(request.policy_id));
  root.emplace("packageId", JsonValue(request.package_id));
  root.emplace("strategy", JsonValue(request.strategy));
  root.emplace("provider", JsonValue(request.provider));
  root.emplace("target", JsonValue(std::move(target)));
  root.emplace("currentIdentity", encode_identity(request.current_identity));
  root.emplace("desiredIdentity", encode_identity(request.desired_identity));
  root.emplace("stage", JsonValue(std::move(stage)));
  root.emplace("signedDescriptor", JsonValue(std::move(descriptor)));
  root.emplace("caller", JsonValue(std::move(caller)));
  root.emplace("requestNonce", JsonValue(request.request_nonce));
  if (request.diagnostics_destination.present) {
    JsonValue::Object diagnostics;
    diagnostics.emplace("kind",
                        JsonValue(request.diagnostics_destination.kind));
    if (!request.diagnostics_destination.stream.empty()) {
      diagnostics.emplace("stream",
                          JsonValue(request.diagnostics_destination.stream));
    }
    root.emplace("diagnosticsDestination",
                 JsonValue(std::move(diagnostics)));
  }
  const std::string canonical =
      EncodeCanonicalJson(JsonValue(std::move(root)));
  (void)ParseNativeInstallTransactionRequestV1(canonical);
  return canonical;
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
