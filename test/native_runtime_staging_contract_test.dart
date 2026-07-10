import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("miniz is pinned and archive limits are runtime-only", () {
    final thirdParty = readRequiredFile("third_party/README.md");
    final stager = readDirectory("native_runtime/cpp");
    final windows = readRequiredFile("windows/native/CMakeLists.txt");
    final linux = readRequiredFile("linux/native/CMakeLists.txt");

    expect(
      thirdParty,
      contains(
        "f0446d863f9c19926ad9483c523fdc42e42b8d4a6a431d27e09d49c79a140d9a",
      ),
    );
    expect(File("third_party/miniz/LICENSE").existsSync(), isTrue);
    expect(stager, contains("maximum_archive_entries"));
    expect(stager, contains("maximum_uncompressed_bytes"));
    expect(stager, contains("maximum_single_entry_bytes"));
    expect(stager, contains("Unsafe archive path"));
    expect(stager, contains("symbolic link"));
    expect(stager, contains("duplicate file/directory conflict"));
    expect(windows, contains("miniz.c"));
    expect(linux, contains("miniz.c"));
  });

  test("macOS stager keeps ZIP DMG and PKG trust gates explicit", () {
    final source = readRequiredFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/"
      "ArtifactStager.swift",
    );

    expect(source, contains("/usr/bin/ditto"));
    expect(source, contains("hdiutil"));
    expect(source, contains("-readonly"));
    expect(source, contains("codesign"));
    expect(source, contains("spctl"));
    expect(source, contains("stapler"));
    expect(source, contains("pkgutil"));
    expect(source, contains("expectedPackageIds"));
    expect(source, contains("expectedTeamIdentifier"));
    expect(source, contains(".desktop_updater_release_manifest.json"));
    expect(source, contains("MacInstallHelper"));
  });

  test("Windows and Linux stagers bind package identity before helper handoff",
      () {
    final windows = readDirectory("windows/native/src/runtime");
    final linux = readDirectory("linux/native/src/runtime");

    expect(windows, contains("WinVerifyTrust"));
    expect(windows, contains("CERT_SHA256_HASH_PROP_ID"));
    expect(windows, contains("sha256Thumbprints"));
    expect(windows, contains("innoInstaller"));
    expect(windows, contains("expected_package_id"));
    expect(windows, contains(".desktop_updater_release_manifest.json"));
    expect(
      windows,
      contains("desktop_updater_schedule_install_and_relaunch_v1"),
    );
    expect(windows, contains("StageZipArchive"));
    expect(linux, contains("executable_relative_path"));
    expect(linux, contains("expected_package_id"));
    expect(linux, contains(".desktop_updater_release_manifest.json"));
    expect(linux, contains("ValidateLinuxInstallHandoff"));
    expect(linux, contains("HandoffLinuxInstall"));
    expect(linux, contains("StageZipArchive"));
    expect(linux, isNot(contains('install_root = "/usr/bin"')));
  });
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}

String readDirectory(String path) {
  final directory = Directory(path);
  expect(directory.existsSync(), isTrue, reason: "$path must exist");
  if (!directory.existsSync()) return "";
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.readAsStringSync())
      .join("\n");
}
