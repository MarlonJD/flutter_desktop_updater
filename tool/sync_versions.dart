import "dart:io";

import "package:pub_semver/pub_semver.dart";

/// Canonical package version and the formats derived for native ecosystems.
final class NativeSdkVersions {
  const NativeSdkVersions({
    required this.canonical,
    required this.cmake,
    required this.nuget,
  });

  /// Full Dart package and CLI version from the root pubspec.
  final String canonical;

  /// Numeric CMake project version without prerelease or build metadata.
  final String cmake;

  /// NuGet-compatible SemVer 2 version.
  final String nuget;
}

/// One generated version surface that differs from its expected contents.
final class VersionFileChange {
  const VersionFileChange({
    required this.path,
    required this.expected,
  });

  /// Repository-relative path to update.
  final String path;

  /// Complete expected file contents.
  final String expected;
}

/// Computes every checked version surface without changing release authority.
Future<(NativeSdkVersions, List<VersionFileChange>)> planVersionSync({
  Directory? projectRoot,
}) async {
  final root = projectRoot ?? Directory.current;
  final versions = await _readCanonicalVersion(root);
  final expected = <String, String>{};

  expected["lib/src/package_version.dart"] = _dartVersionSource(versions);
  expected["macos/desktop_updater/Sources/DesktopUpdaterKit/"
      "DesktopUpdaterVersion.swift"] = _swiftVersionSource(versions);
  expected["windows/native/include/desktop_updater_version.h"] =
      await _nativeHeader(
    root,
    "windows/native/include/desktop_updater_version.h",
    versions,
  );
  expected["linux/native/include/desktop_updater_version.h"] =
      await _nativeHeader(
    root,
    "linux/native/include/desktop_updater_version.h",
    versions,
  );
  expected["windows/native/CMakeLists.txt"] = await _cmakeProject(
    root,
    "windows/native/CMakeLists.txt",
    versions,
  );
  expected["linux/native/CMakeLists.txt"] = await _cmakeProject(
    root,
    "linux/native/CMakeLists.txt",
    versions,
  );
  expected["example/native/windows-cmake/CMakeLists.txt"] =
      await _cmakeConsumer(
    root,
    "example/native/windows-cmake/CMakeLists.txt",
    versions,
  );
  expected["example/native/linux-cmake/CMakeLists.txt"] = await _cmakeConsumer(
    root,
    "example/native/linux-cmake/CMakeLists.txt",
    versions,
  );
  expected["windows/native/dotnet/DesktopUpdater.Native/"
      "DesktopUpdater.Native.csproj"] = await _nugetProject(root, versions);
  expected["linux/native/cmake/desktop_updater_native.pc.in"] =
      await _pkgConfig(root, versions);

  final changes = <VersionFileChange>[];
  for (final entry in expected.entries) {
    final file = File(_join(root.path, entry.key));
    final current = await file.exists() ? await file.readAsString() : null;
    if (current == null || !versionSourcesMatch(current, entry.value)) {
      changes.add(VersionFileChange(path: entry.key, expected: entry.value));
    }
  }
  return (versions, List<VersionFileChange>.unmodifiable(changes));
}

/// Compares generated source while treating Git's LF and CRLF checkouts as
/// equivalent.
bool versionSourcesMatch(String current, String expected) {
  String normalize(String source) => source.replaceAll("\r\n", "\n");
  return normalize(current) == normalize(expected);
}

/// Synchronizes generated native version surfaces from root `pubspec.yaml`.
Future<List<String>> syncNativeSdkVersions({Directory? projectRoot}) async {
  final root = projectRoot ?? Directory.current;
  final (_, changes) = await planVersionSync(projectRoot: root);
  for (final change in changes) {
    final file = File(_join(root.path, change.path));
    await file.parent.create(recursive: true);
    await file.writeAsString(change.expected);
  }
  return List<String>.unmodifiable(changes.map((change) => change.path));
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    throw const FormatException("sync_versions.dart does not accept options.");
  }
  final (versions, _) = await planVersionSync();
  final updated = await syncNativeSdkVersions();
  stdout.writeln("Canonical package version: ${versions.canonical}");
  if (updated.isEmpty) {
    stdout.writeln("Native SDK versions already synchronized.");
    return;
  }
  for (final path in updated) {
    stdout.writeln("Updated $path");
  }
}

Future<NativeSdkVersions> _readCanonicalVersion(Directory root) async {
  final pubspec = File(_join(root.path, "pubspec.yaml"));
  final source = await pubspec.readAsString();
  final matches = RegExp(
    r"^version:\s*([^\s#]+)\s*(?:#.*)?$",
    multiLine: true,
  ).allMatches(source).toList();
  if (matches.length != 1) {
    throw const FormatException(
      "Root pubspec.yaml must declare exactly one version.",
    );
  }
  final canonical = matches.single.group(1)!;
  final parsed = Version.parse(canonical);
  final cmake = "${parsed.major}.${parsed.minor}.${parsed.patch}";
  return NativeSdkVersions(
    canonical: canonical,
    cmake: cmake,
    nuget: parsed.toString(),
  );
}

String _dartVersionSource(NativeSdkVersions versions) {
  return """
/// Version of the `desktop_updater` package used in runtime policy checks and
/// diagnostics reports.
const String desktopUpdaterPackageVersion = "${versions.canonical}";
""";
}

String _swiftVersionSource(NativeSdkVersions versions) {
  return """
/// Canonical version of the Flutter-free DesktopUpdaterKit helper package.
public enum DesktopUpdaterVersion {
    public static let string = "${versions.canonical}"
}
""";
}

Future<String> _nativeHeader(
  Directory root,
  String relativePath,
  NativeSdkVersions versions,
) async {
  final source = await File(_join(root.path, relativePath)).readAsString();
  final versionLine =
      '#define DESKTOP_UPDATER_NATIVE_VERSION_STRING "${versions.canonical}"';
  final versionPattern = RegExp(
    r'^#define DESKTOP_UPDATER_NATIVE_VERSION_STRING ".*"$',
    multiLine: true,
  );
  if (versionPattern.hasMatch(source)) {
    return source.replaceFirst(versionPattern, versionLine);
  }
  final apiPattern = RegExp(
    r"^#define DESKTOP_UPDATER_NATIVE_(?:ABI|API)_VERSION\s+\d+u$",
    multiLine: true,
  );
  if (!apiPattern.hasMatch(source)) {
    throw FormatException("Native version anchor is missing in $relativePath.");
  }
  return source.replaceFirstMapped(
    apiPattern,
    (match) => "${match.group(0)}\n$versionLine",
  );
}

Future<String> _cmakeProject(
  Directory root,
  String relativePath,
  NativeSdkVersions versions,
) async {
  final source = await File(_join(root.path, relativePath)).readAsString();
  final pattern = RegExp(
    r"project\(desktop_updater_native(?: VERSION [^ )]+)? "
    r"(LANGUAGES (?:C )?CXX)\)",
  );
  if (!pattern.hasMatch(source)) {
    throw FormatException(
      "CMake project declaration is missing in $relativePath.",
    );
  }
  return source.replaceFirstMapped(
    pattern,
    (match) => "project(desktop_updater_native VERSION ${versions.cmake} "
        "${match.group(1)})",
  );
}

Future<String> _nugetProject(
  Directory root,
  NativeSdkVersions versions,
) async {
  const relativePath = "windows/native/dotnet/DesktopUpdater.Native/"
      "DesktopUpdater.Native.csproj";
  final source = (await File(_join(root.path, relativePath)).readAsString())
      .replaceAll("\r\n", "\n")
      .replaceAll("\r", "\n");
  final versionLine = "    <Version>${versions.nuget}</Version>";
  final pattern = RegExp(
    r"^[ \t]*<Version>[^\r\n]*</Version>$",
    multiLine: true,
  );
  if (pattern.hasMatch(source)) {
    return source.replaceFirst(pattern, versionLine);
  }
  const anchor = "    <PackageId>DesktopUpdater.Native</PackageId>";
  if (!source.contains(anchor)) {
    throw const FormatException("NuGet PackageId anchor is missing.");
  }
  return source.replaceFirst(anchor, "$anchor\n$versionLine");
}

Future<String> _cmakeConsumer(
  Directory root,
  String relativePath,
  NativeSdkVersions versions,
) async {
  final source = await File(_join(root.path, relativePath)).readAsString();
  final pattern = RegExp(
    r"find_package\(desktop_updater_native(?: [^)]*)?\)",
  );
  if (!pattern.hasMatch(source)) {
    throw FormatException(
      "CMake consumer package lookup is missing in $relativePath.",
    );
  }
  return source.replaceFirst(
    pattern,
    "find_package(desktop_updater_native ${versions.cmake} EXACT CONFIG REQUIRED)",
  );
}

Future<String> _pkgConfig(
  Directory root,
  NativeSdkVersions versions,
) async {
  const relativePath = "linux/native/cmake/desktop_updater_native.pc.in";
  final source = await File(_join(root.path, relativePath)).readAsString();
  final pattern = RegExp(r"^Version:.*$", multiLine: true);
  if (!pattern.hasMatch(source)) {
    throw const FormatException("pkg-config Version field is missing.");
  }
  return source.replaceFirst(pattern, "Version: ${versions.canonical}");
}

String _join(String root, String relativePath) {
  final separator = Platform.pathSeparator;
  return "$root$separator${relativePath.replaceAll("/", separator)}";
}
