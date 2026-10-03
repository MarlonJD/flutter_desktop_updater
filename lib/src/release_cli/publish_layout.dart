import "dart:io";

import "package:path/path.dart" as path;

class PublishLayout {
  const PublishLayout({
    required this.outputDirectory,
    required this.appArchiveRelativePath,
    required this.releaseRelativePath,
    required this.artifactRelativePath,
    required this.appArchiveUrl,
    required this.releaseUrl,
    required this.artifactUrl,
  });

  final Directory outputDirectory;
  final String appArchiveRelativePath;
  final String releaseRelativePath;
  final String artifactRelativePath;
  final Uri appArchiveUrl;
  final Uri releaseUrl;
  final Uri artifactUrl;

  File get manifestFile {
    return _localFile(".desktop_updater_publish.json");
  }

  File get appArchiveFile {
    return _localFile(appArchiveRelativePath);
  }

  File get releaseFile {
    return _localFile(releaseRelativePath);
  }

  File get artifactFile {
    return _localFile(artifactRelativePath);
  }

  Directory get releaseDirectory => releaseFile.parent;

  File _localFile(String relativePath) {
    return File(
      path.joinAll([
        outputDirectory.path,
        ...path.posix.split(relativePath),
      ]),
    );
  }

  static PublishLayout create({
    required Directory outputDirectory,
    required Uri baseUrl,
    required String version,
    required int? buildNumber,
    required String platform,
    required String channel,
    required String appName,
    String artifactExtension = ".zip",
    String artifactSuffix = "",
    String? artifactFileName,
  }) {
    final safeChannel = _requireIdentitySegment(channel, "channel");
    final safeVersion = _requireIdentitySegment(version, "version");
    final safePlatform = _requireIdentitySegment(platform, "platform");
    if (buildNumber != null && buildNumber < 0) {
      throw const FormatException(
        "Release build number must be zero or greater when provided.",
      );
    }
    final buildSegment =
        buildNumber == null ? "no-build" : "build-$buildNumber";
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    final artifactName = _requireArtifactFileName(
      artifactFileName ??
          "${_artifactNameStem(appName)}-$safeVersion-$safePlatform"
              "$artifactSuffix$artifactExtension",
    );
    final releaseSegments = [
      "releases",
      safeChannel,
      safeVersion,
      buildSegment,
      safePlatform,
    ];
    final releaseRelativePath = path.posix.joinAll([
      ...releaseSegments,
      "release.json",
    ]);
    final artifactRelativePath = path.posix.joinAll([
      ...releaseSegments,
      artifactName,
    ]);

    return PublishLayout(
      outputDirectory: outputDirectory,
      appArchiveRelativePath: "app-archive.json",
      releaseRelativePath: releaseRelativePath,
      artifactRelativePath: artifactRelativePath,
      appArchiveUrl: normalizedBaseUrl.resolve("app-archive.json"),
      releaseUrl: _resolvePathSegments(
        normalizedBaseUrl,
        [...releaseSegments, "release.json"],
      ),
      artifactUrl: _resolvePathSegments(
        normalizedBaseUrl,
        [...releaseSegments, artifactName],
      ),
    );
  }
}

final _identitySegmentPattern = RegExp(
  r"^[A-Za-z0-9](?:[A-Za-z0-9.+_-]*[A-Za-z0-9_+-])?$",
);

String _requireIdentitySegment(String value, String name) {
  if (!_identitySegmentPattern.hasMatch(value) ||
      value == "." ||
      value == "..") {
    throw FormatException(
      "Release $name must be one URL-safe path segment containing only "
      "letters, numbers, dots, plus signs, underscores, and hyphens.",
    );
  }
  return value;
}

String _requireArtifactFileName(String value) {
  if (value.isEmpty ||
      value == "." ||
      value == ".." ||
      value.endsWith(".") ||
      value.endsWith(" ") ||
      value.contains("%") ||
      value.codeUnits.any((unit) => unit < 0x20) ||
      RegExp(r'[<>:"/\\|?*]').hasMatch(value)) {
    throw const FormatException(
      "Release artifact name must be a single safe file name.",
    );
  }
  return value;
}

Uri _resolvePathSegments(Uri baseUrl, List<String> segments) {
  return baseUrl.resolve(segments.map(Uri.encodeComponent).join("/"));
}

Uri _normalizeBaseUrl(Uri baseUrl) {
  final text = baseUrl.toString();
  return Uri.parse(text.endsWith("/") ? text : "$text/");
}

String _artifactNameStem(String appName) {
  var stem = appName;
  if (stem.endsWith(".app")) {
    stem = stem.substring(0, stem.length - ".app".length);
  }
  if (stem.endsWith(".exe")) {
    stem = stem.substring(0, stem.length - ".exe".length);
  }
  return stem;
}
