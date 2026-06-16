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
    return File(
      path.join(outputDirectory.path, ".desktop_updater_publish.json"),
    );
  }

  File get appArchiveFile {
    return File(path.join(outputDirectory.path, appArchiveRelativePath));
  }

  File get releaseFile {
    return File(path.join(outputDirectory.path, releaseRelativePath));
  }

  File get artifactFile {
    return File(path.join(outputDirectory.path, artifactRelativePath));
  }

  Directory get releaseDirectory => releaseFile.parent;

  static PublishLayout create({
    required Directory outputDirectory,
    required Uri baseUrl,
    required String version,
    required String platform,
    required String appName,
  }) {
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    final artifactName = "${_artifactNameStem(appName)}-$version-$platform.zip";
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
