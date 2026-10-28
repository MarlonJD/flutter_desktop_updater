import "dart:convert";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/native_install_helper/canonical_json.dart";

/// Validates strict source JSON against the sealed helper policy contract.
ValidatedHelperPolicy validateHelperPolicyJson(
  String source, {
  required String expectedApplicationPackageId,
  required int minimumAcceptedPolicyVersion,
}) {
  final decoded = decodeStrictNativeInstallHelperJson(source);
  if (decoded is! Map<String, dynamic>) {
    throw const HelperPolicyValidationFailure("invalidType:policy");
  }
  return validateHelperPolicy(
    decoded,
    expectedApplicationPackageId: expectedApplicationPackageId,
    minimumAcceptedPolicyVersion: minimumAcceptedPolicyVersion,
  );
}

/// Validates policy authority and computes its canonical digest.
ValidatedHelperPolicy validateHelperPolicy(
  Map<String, dynamic> policy, {
  required String expectedApplicationPackageId,
  required int minimumAcceptedPolicyVersion,
}) {
  _requireExactKeys(
    policy,
    required: _policyFields,
  );
  final policyVersion = _requireInteger(
    policy["policyVersion"],
    "policyVersion",
    minimum: 1,
  );
  if (policyVersion < minimumAcceptedPolicyVersion) {
    throw const HelperPolicyValidationFailure("policyRollback");
  }
  _requireIdentifier(policy["policyId"], "policyId");
  final applicationPackageId = _requireIdentifier(
    policy["applicationPackageId"],
    "applicationPackageId",
  );
  if (applicationPackageId != expectedApplicationPackageId) {
    throw const HelperPolicyValidationFailure("applicationPackageIdMismatch");
  }
  _requireIdentifier(policy["helperServiceId"], "helperServiceId");
  _validateSigner(
    _requireMap(policy["allowedApplicationSigner"], "allowedApplicationSigner"),
    "allowedApplicationSigner",
  );
  _validateSigner(
    _requireMap(policy["allowedHelperSigner"], "allowedHelperSigner"),
    "allowedHelperSigner",
  );

  final targetClasses = _requireStringList(
    policy["allowedTargetClasses"],
    "allowedTargetClasses",
    allowEmpty: false,
  );
  if (targetClasses.any((value) => !_targetClasses.contains(value))) {
    throw const HelperPolicyValidationFailure("unknownTargetClass");
  }
  if (targetClasses.toSet().length != targetClasses.length) {
    throw const HelperPolicyValidationFailure("duplicateTargetClass");
  }

  final installRoots = _requireStringList(
    policy["allowedInstallRoots"],
    "allowedInstallRoots",
    allowEmpty: true,
  );
  final rootSet = <String>{};
  for (final root in installRoots) {
    _validateInstallRoot(root);
    if (!rootSet.add(root)) {
      throw const HelperPolicyValidationFailure("duplicateInstallRoot");
    }
  }

  _validateReleaseRootPublicKeys(policy["releaseRootPublicKeys"]);
  final strategies = _validateStrategies(policy["allowedStrategies"]);
  _requireInteger(
    policy["minimumHelperProtocolVersion"],
    "minimumHelperProtocolVersion",
    minimum: 1,
  );

  final portable = installRoots.isEmpty;
  if (portable &&
      (targetClasses.any((value) => value != "sameUserWritable") ||
          strategies.any(
            (entry) =>
                entry.strategy != "directoryReplace" &&
                entry.strategy != "singleFileReplace",
          ))) {
    throw const HelperPolicyValidationFailure(
      "portablePolicyRequestsElevation",
    );
  }

  final canonicalJson = canonicalNativeInstallHelperJson(policy);
  return ValidatedHelperPolicy(
    canonicalJson: canonicalJson,
    canonicalSha256:
        crypto.sha256.convert(utf8.encode(canonicalJson)).toString(),
  );
}

void _validateSigner(Map<String, dynamic> signer, String field) {
  _requireExactKeys(
    signer,
    path: field,
    required: const <String>{"kind", "value"},
  );
  final kind = _requireString(signer["kind"], "$field.kind");
  if (!_signerKinds.contains(kind)) {
    throw const HelperPolicyValidationFailure("invalidSigner");
  }
  final value = _requireString(signer["value"], "$field.value");
  if (value.contains("*") || value.contains("?")) {
    throw const HelperPolicyValidationFailure("wildcardSigner");
  }
  if (kind == "sha256" && !_sha256Pattern.hasMatch(value)) {
    throw const HelperPolicyValidationFailure("invalidSigner");
  }
}

void _validateInstallRoot(String root) {
  if (root == "/" || RegExp(r"^[A-Za-z]:[\\/]?$").hasMatch(root)) {
    throw const HelperPolicyValidationFailure("rootFilesystemAuthorization");
  }
  final absolute =
      root.startsWith("/") || RegExp(r"^[A-Za-z]:[\\/]").hasMatch(root);
  if (!absolute) {
    throw const HelperPolicyValidationFailure("relativeInstallRoot");
  }
  final segments = root.split(RegExp(r"[\\/]"));
  if (segments.any((segment) => segment == "." || segment == "..") ||
      root.contains("*") ||
      root.contains("?")) {
    throw const HelperPolicyValidationFailure("invalidInstallRoot");
  }
}

void _validateReleaseRootPublicKeys(Object? value) {
  if (value is! List || value.isEmpty) {
    throw const HelperPolicyValidationFailure("emptyReleaseRootPublicKeys");
  }
  final keyIds = <String>{};
  for (final entry in value) {
    final key = _requireMap(entry, "releaseRootPublicKeys");
    _requireExactKeys(
      key,
      path: "releaseRootPublicKeys",
      required: const <String>{"keyId", "algorithm", "publicKeyBase64"},
    );
    final keyId = _requireString(key["keyId"], "releaseRootPublicKeys.keyId");
    if (!_keyIdPattern.hasMatch(keyId)) {
      throw const HelperPolicyValidationFailure("invalidReleaseKeyId");
    }
    if (!keyIds.add(keyId)) {
      throw const HelperPolicyValidationFailure("duplicateReleaseKeyId");
    }
    if (key["algorithm"] != "ed25519") {
      throw const HelperPolicyValidationFailure("invalidReleaseKeyAlgorithm");
    }
    final rawEncoded = key["publicKeyBase64"];
    if (rawEncoded is! String) {
      throw const HelperPolicyValidationFailure(
        "invalidType:releaseRootPublicKeys.publicKeyBase64",
      );
    }
    if (rawEncoded.isEmpty) {
      throw const HelperPolicyValidationFailure("emptyReleaseRootPublicKey");
    }
    final encoded = rawEncoded;
    try {
      if (base64Decode(encoded).length != 32) {
        throw const FormatException();
      }
    } on FormatException {
      throw const HelperPolicyValidationFailure("emptyReleaseRootPublicKey");
    }
  }
}

List<_ValidatedAllowedStrategy> _validateStrategies(Object? value) {
  if (value is! List || value.isEmpty) {
    throw const HelperPolicyValidationFailure("emptyAllowedStrategies");
  }
  final result = <_ValidatedAllowedStrategy>[];
  final seen = <String>{};
  for (final entry in value) {
    final strategy = _requireMap(entry, "allowedStrategies");
    _requireExactKeys(
      strategy,
      path: "allowedStrategies",
      required: const <String>{"strategy", "provider"},
    );
    final strategyName =
        _requireString(strategy["strategy"], "allowedStrategies.strategy");
    if (!_strategyProviders.containsKey(strategyName)) {
      throw const HelperPolicyValidationFailure("unknownStrategy");
    }
    final provider =
        _requireString(strategy["provider"], "allowedStrategies.provider");
    if (!_strategyProviders[strategyName]!.contains(provider)) {
      throw const HelperPolicyValidationFailure("strategyProviderMismatch");
    }
    if (!seen.add("$strategyName\u0000$provider")) {
      throw const HelperPolicyValidationFailure("duplicateAllowedStrategy");
    }
    result.add(
      _ValidatedAllowedStrategy(strategy: strategyName, provider: provider),
    );
  }
  return result;
}

void _requireExactKeys(
  Map<String, dynamic> value, {
  required Set<String> required,
  String path = "",
}) {
  for (final key in required) {
    if (!value.containsKey(key)) {
      throw HelperPolicyValidationFailure(
        "missingField:${_field(path, key)}",
      );
    }
  }
  for (final key in value.keys) {
    if (!required.contains(key)) {
      throw HelperPolicyValidationFailure(
        "unknownField:${_field(path, key)}",
      );
    }
  }
}

String _field(String prefix, String key) =>
    prefix.isEmpty ? key : "$prefix.$key";

Map<String, dynamic> _requireMap(Object? value, String field) {
  if (value is! Map<String, dynamic>) {
    throw HelperPolicyValidationFailure("invalidType:$field");
  }
  return value;
}

String _requireString(Object? value, String field) {
  if (value is! String) {
    throw HelperPolicyValidationFailure("invalidType:$field");
  }
  if (value.trim().isEmpty) {
    throw HelperPolicyValidationFailure("invalidString:$field");
  }
  return value;
}

String _requireIdentifier(Object? value, String field) {
  final identifier = _requireString(value, field);
  if (!_identifierPattern.hasMatch(identifier)) {
    throw HelperPolicyValidationFailure("invalidIdentifier:$field");
  }
  return identifier;
}

int _requireInteger(
  Object? value,
  String field, {
  required int minimum,
}) {
  if (value is! int || value < minimum) {
    throw HelperPolicyValidationFailure("invalidInteger:$field");
  }
  return value;
}

List<String> _requireStringList(
  Object? value,
  String field, {
  required bool allowEmpty,
}) {
  if (value is! List || (!allowEmpty && value.isEmpty)) {
    throw HelperPolicyValidationFailure("invalidArray:$field");
  }
  final result = <String>[];
  for (final entry in value) {
    result.add(_requireString(entry, field));
  }
  return result;
}

const _policyFields = <String>{
  "policyVersion",
  "policyId",
  "applicationPackageId",
  "helperServiceId",
  "allowedApplicationSigner",
  "allowedHelperSigner",
  "allowedTargetClasses",
  "allowedInstallRoots",
  "releaseRootPublicKeys",
  "allowedStrategies",
  "minimumHelperProtocolVersion",
};

const _targetClasses = <String>{
  "sameUserWritable",
  "applicationBundle",
  "applicationDirectory",
  "singleExecutable",
  "protectedApplication",
  "systemPackage",
  "externalManaged",
};

const _signerKinds = <String>{
  "appleDesignatedRequirement",
  "authenticodePublisher",
  "sha256",
};

const _strategyProviders = <String, Set<String>>{
  "directoryReplace": <String>{"platformDirectory"},
  "singleFileReplace": <String>{"platformFile"},
  "verifiedInstallerHandoff": <String>{"macosInstaller", "windowsInno"},
  "systemPackageTransaction": <String>{"apt", "dnf"},
  "externalManagedRefresh": <String>{"flatpak", "snap"},
};

final _identifierPattern = RegExp(
  r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{1,126}[A-Za-z0-9])?$",
);
final _sha256Pattern = RegExp(r"^[0-9a-f]{64}$");
final _keyIdPattern = RegExp(r"^[A-Za-z0-9._-]{1,128}$");

/// Canonical build inputs produced only after policy validation.
final class ValidatedHelperPolicy {
  /// Creates a validated JSON and digest pair.
  const ValidatedHelperPolicy({
    required this.canonicalJson,
    required this.canonicalSha256,
  });

  /// Canonical JSON, excluding any final newline.
  final String canonicalJson;

  /// SHA-256 of the canonical UTF-8 JSON bytes.
  final String canonicalSha256;
}

final class _ValidatedAllowedStrategy {
  const _ValidatedAllowedStrategy({
    required this.strategy,
    required this.provider,
  });

  final String strategy;
  final String provider;
}

/// A stable failure code for a rejected policy.
final class HelperPolicyValidationFailure implements Exception {
  /// Creates a failure with its validation code.
  const HelperPolicyValidationFailure(this.code);

  /// The machine-readable validation failure.
  final String code;

  @override
  String toString() => code;
}
