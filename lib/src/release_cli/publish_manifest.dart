import "dart:convert";
import "dart:io";

class PublishManifest {
  const PublishManifest({
    required this.schemaVersion,
    required this.baseUrl,
    required this.localRoot,
    required this.appArchive,
    required this.release,
    required this.artifact,
  });

  factory PublishManifest.fromJson(Map<String, dynamic> json) {
    return PublishManifest(
      schemaVersion: json["schemaVersion"] as int? ?? 0,
      baseUrl: Uri.parse(json["baseUrl"] as String? ?? ""),
      localRoot: json["localRoot"] as String? ?? "",
      appArchive: PublishManifestFile.fromJson(
        json["appArchive"] as Map<String, dynamic>? ?? const {},
      ),
      release: PublishManifestRelease.fromJson(
        json["release"] as Map<String, dynamic>? ?? const {},
      ),
      artifact: PublishManifestArtifact.fromJson(
        json["artifact"] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  final int schemaVersion;
  final Uri baseUrl;
  final String localRoot;
  final PublishManifestFile appArchive;
  final PublishManifestRelease release;
  final PublishManifestArtifact artifact;

  static Future<PublishManifest> readFrom(File file) async {
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return PublishManifest.fromJson(json);
  }

  Future<void> writeTo(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      "${const JsonEncoder.withIndent("  ").convert(toJson())}\n",
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "schemaVersion": schemaVersion,
      "baseUrl": baseUrl.toString(),
      "localRoot": localRoot,
      "appArchive": appArchive.toJson(),
      "release": release.toJson(),
      "artifact": artifact.toJson(),
    };
  }
}

class PublishManifestFile {
  const PublishManifestFile({
    required this.path,
    required this.url,
  });

  factory PublishManifestFile.fromJson(Map<String, dynamic> json) {
    return PublishManifestFile(
      path: json["path"] as String? ?? "",
      url: Uri.parse(json["url"] as String? ?? ""),
    );
  }

  final String path;
  final Uri url;

  Map<String, dynamic> toJson() {
    return {
      "path": path,
      "url": url.toString(),
    };
  }
}

class PublishManifestRelease extends PublishManifestFile {
  const PublishManifestRelease({
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.channel,
    required super.path,
    required super.url,
  });

  factory PublishManifestRelease.fromJson(Map<String, dynamic> json) {
    return PublishManifestRelease(
      version: json["version"] as String? ?? "",
      buildNumber: json["buildNumber"] as int?,
      platform: json["platform"] as String? ?? "",
      channel: json["channel"] as String? ?? "stable",
      path: json["path"] as String? ?? "",
      url: Uri.parse(json["url"] as String? ?? ""),
    );
  }

  final String version;
  final int? buildNumber;
  final String platform;
  final String channel;

  @override
  Map<String, dynamic> toJson() {
    return {
      "version": version,
      if (buildNumber != null) "buildNumber": buildNumber,
      "platform": platform,
      "channel": channel,
      ...super.toJson(),
    };
  }
}

class PublishManifestArtifact extends PublishManifestFile {
  const PublishManifestArtifact({
    required super.path,
    required super.url,
    required this.sha256,
    required this.length,
  });

  factory PublishManifestArtifact.fromJson(Map<String, dynamic> json) {
    return PublishManifestArtifact(
      path: json["path"] as String? ?? "",
      url: Uri.parse(json["url"] as String? ?? ""),
      sha256: json["sha256"] as String? ?? "",
      length: json["length"] as int? ?? 0,
    );
  }

  final String sha256;
  final int length;

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      "sha256": sha256,
      "length": length,
    };
  }
}
