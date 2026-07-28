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
    required String platform,
    required String appName,
    String artifactExtension = ".zip",
    String artifactSuffix = "",
    String? artifactFileName,
  }) {
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    final artifactName = artifactFileName ??
        "${_artifactNameStem(appName)}-$version-$platform$artifactSuffix$artifactExtension";
    final releaseRelativePath = path.posix.join(
      "releases",
      version,
      platform,
      "release.json",
    );
    final artifactRelativePath = path.posix.join(
      "releases",
      version,
      platform,
      artifactName,
    );

    return PublishLayout(
      outputDirectory: outputDirectory,
      appArchiveRelativePath: "app-archive.json",
      releaseRelativePath: releaseRelativePath,
      artifactRelativePath: artifactRelativePath,
      appArchiveUrl: normalizedBaseUrl.resolve("app-archive.json"),
      releaseUrl: normalizedBaseUrl.resolve(releaseRelativePath),
      artifactUrl: normalizedBaseUrl.resolve(artifactRelativePath),
    );
  }
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
