import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Swift and C++ runtimes consume the canonical contract fixtures", () {
    final swiftTests = readDirectory(
      "macos/desktop_updater/Tests/DesktopUpdaterKitTests",
    );
    final cppTests = readRequiredFile(
      "native_runtime/cpp/contract_fixture_tests.cc",
    );

    for (final fixture in <String>[
      "selection-cases.json",
      "canonical-signature-cases.json",
      "descriptorBindingCases",
      "release-windows-inno.json",
      "release-linux-zip.json",
    ]) {
      expect("$swiftTests\n$cppTests", contains(fixture));
    }
    expect(swiftTests, contains("ArtifactVerifier.verifyDescriptorSignature"));
    expect(cppTests, contains("VerifyDescriptorSignature"));
  });

  test("Monocypher is pinned and isolated to runtime targets", () {
    final thirdParty = readRequiredFile("third_party/README.md");
    final windows = readRequiredFile("windows/native/CMakeLists.txt");
    final linux = readRequiredFile("linux/native/CMakeLists.txt");
    final flutterWindows = readRequiredFile("windows/CMakeLists.txt");
    final flutterLinux = readRequiredFile("linux/CMakeLists.txt");

    expect(
      thirdParty,
      contains(
        "40904ada5c7ee4f7741733e38b69a30a4b0561cbffba5ffe7c2dce16136d54025",
      ),
    );
    expect(File("third_party/monocypher/LICENCE.md").existsSync(), isTrue);
    expect(
      File(
        "third_party/monocypher/src/optional/monocypher-ed25519.c",
      ).existsSync(),
      isTrue,
    );
    for (final cmake in <String>[windows, linux]) {
      expect(cmake, contains("if(DESKTOP_UPDATER_NATIVE_RUNTIME)"));
      expect(cmake, contains("monocypher-ed25519.c"));
      expect(cmake, contains("desktop_updater_runtime_contract_test"));
    }
    expect(
        flutterWindows, isNot(contains("DESKTOP_UPDATER_NATIVE_RUNTIME=ON")));
    expect(flutterLinux, isNot(contains("DESKTOP_UPDATER_NATIVE_RUNTIME=ON")));
  });

  test("target-host CTest enables runtime conformance with zero-test guards",
      () {
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );

    expect(
      workflow,
      contains("-DDESKTOP_UPDATER_NATIVE_RUNTIME=ON"),
    );
    expect(workflow, contains("No tests were found"));
    expect(workflow, contains("Linux native CTest registered zero tests"));
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
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.readAsStringSync())
      .join("\n");
}
