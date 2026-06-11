import "dart:convert";

class ReleaseDescriptor {
  const ReleaseDescriptor({
    required this.schemaVersion,
    required this.packageId,
    required this.appName,
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.channel,
    required this.artifact,
    required this.install,
    required this.minimumUpdaterVersion,
    required this.generatedAt,
    this.signature,
  });

  factory ReleaseDescriptor.fromJson(Map<String, dynamic> json) {
    final descriptor = ReleaseDescriptor(
      schemaVersion: json["schemaVersion"] as int? ?? 0,
      packageId: json["packageId"] as String? ?? "",
      appName: json["appName"] as String? ?? "",
      version: json["version"] as String? ?? "",
      buildNumber: json["buildNumber"] as int? ?? 0,
      platform: json["platform"] as String? ?? "",
      channel: json["channel"] as String? ?? "stable",
      artifact: ReleaseArtifact.fromJson(
        json["artifact"] as Map<String, dynamic>? ?? const {},
      ),
      install: ReleaseInstall.fromJson(
        json["install"] as Map<String, dynamic>? ?? const {},
      ),
      signature: json["signature"] == null
          ? null
          : ReleaseSignature.fromJson(
              json["signature"] as Map<String, dynamic>,
            ),
      minimumUpdaterVersion: json["minimumUpdaterVersion"] as String? ?? "",
      generatedAt: DateTime.parse(
        json["generatedAt"] as String? ?? "1970-01-01T00:00:00Z",
      ),
    );
    descriptor.validate();
    return descriptor;
  }

  final int schemaVersion;
  final String packageId;
  final String appName;
  final String version;
  final int buildNumber;
  final String platform;
  final String channel;
  final ReleaseArtifact artifact;
  final ReleaseInstall install;
  final ReleaseSignature? signature;
  final String minimumUpdaterVersion;
  final DateTime generatedAt;

  Map<String, dynamic> toJson() {
    return {
      "schemaVersion": schemaVersion,
      "packageId": packageId,
      "appName": appName,
      "version": version,
      "buildNumber": buildNumber,
      "platform": platform,
      "channel": channel,
      "artifact": artifact.toJson(),
      "install": install.toJson(),
      if (signature != null) "signature": signature!.toJson(),
      "minimumUpdaterVersion": minimumUpdaterVersion,
      "generatedAt": generatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> toCanonicalSignatureJson() {
    final json = toJson();
    final existingSignature = signature;
    if (existingSignature != null) {
      json["signature"] = existingSignature.copyWith(value: "").toJson();
    }
    return sortJsonValue(json) as Map<String, dynamic>;
  }

  List<int> canonicalSignatureBytes() {
    return utf8.encode(jsonEncode(toCanonicalSignatureJson()));
  }

  void validate() {
    if (schemaVersion != 3) {
      throw FormatException(
        "Unsupported release descriptor schema version: $schemaVersion",
      );
    }
    if (packageId.trim().isEmpty) {
      throw const FormatException("release.json packageId is required.");
    }
    if (version.trim().isEmpty) {
      throw const FormatException("release.json version is required.");
    }
    if (platform.trim().isEmpty) {
      throw const FormatException("release.json platform is required.");
    }
    artifact.validate();
    install.validate();
  }
}

class ReleaseArtifact {
  const ReleaseArtifact({
    required this.kind,
    required this.url,
    required this.sha256,
    required this.length,
  });

  factory ReleaseArtifact.fromJson(Map<String, dynamic> json) {
    return ReleaseArtifact(
      kind: json["kind"] as String? ?? "",
      url: Uri.parse(json["url"] as String? ?? ""),
      sha256: json["sha256"] as String? ?? "",
      length: json["length"] as int? ?? -1,
    );
  }

  final String kind;
  final Uri url;
  final String sha256;
  final int length;

  Map<String, dynamic> toJson() {
    return {
      "kind": kind,
      "url": url.toString(),
      "sha256": sha256,
      "length": length,
    };
  }

  void validate() {
    if (kind != "zip") {
      throw FormatException("Unsupported release artifact kind: $kind");
    }
    if (!RegExp(r"^[0-9a-f]{64}$").hasMatch(sha256)) {
      throw const FormatException(
        "release.json artifact.sha256 must be 64 lowercase hex characters.",
      );
    }
    if (length < 0) {
      throw const FormatException("release.json artifact.length is required.");
    }
  }
}

class ReleaseInstall {
  const ReleaseInstall({required this.strategy});

  factory ReleaseInstall.fromJson(Map<String, dynamic> json) {
    return ReleaseInstall(strategy: json["strategy"] as String? ?? "");
  }

  final String strategy;

  Map<String, dynamic> toJson() {
    return {"strategy": strategy};
  }

  void validate() {
    if (strategy.trim().isEmpty) {
      throw const FormatException("release.json install.strategy is required.");
    }
  }
}

class ReleaseSignature {
  const ReleaseSignature({
    required this.algorithm,
    required this.publicKeyId,
    required this.value,
  });

  factory ReleaseSignature.fromJson(Map<String, dynamic> json) {
    return ReleaseSignature(
      algorithm: json["algorithm"] as String? ?? "",
      publicKeyId: json["publicKeyId"] as String? ?? "",
      value: json["value"] as String? ?? "",
    );
  }

  final String algorithm;
  final String publicKeyId;
  final String value;

  Map<String, dynamic> toJson() {
    return {
      "algorithm": algorithm,
      "publicKeyId": publicKeyId,
      "value": value,
    };
  }

  ReleaseSignature copyWith({String? value}) {
    return ReleaseSignature(
      algorithm: algorithm,
      publicKeyId: publicKeyId,
      value: value ?? this.value,
    );
  }
}

Object? sortJsonValue(Object? value) {
  if (value is Map) {
    final sorted = <String, dynamic>{};
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    for (final key in keys) {
      sorted[key] = sortJsonValue(value[key]);
    }
    return sorted;
  }

  if (value is List) {
    return value.map(sortJsonValue).toList(growable: false);
  }

  return value;
}
