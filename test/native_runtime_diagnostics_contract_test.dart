import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("native runtimes consume exact redaction and helper event fixtures", () {
    final diagnostics = fixture("diagnostics-redaction-cases.json");
    final helperEvents = fixture("helper-events.json");
    final swift = readDirectory(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime",
    );
    final common = readDirectory("native_runtime/cpp");

    expect(diagnostics["schemaVersion"], 1);
    expect(helperEvents["schemaVersion"], 1);
    expect(swift, contains("diagnostics-redaction-cases.json"));
    expect(swift, contains("helper-events.json"));
    expect(common, contains("diagnostics-redaction-cases.json"));
    expect(common, contains("helper-events.json"));
    expect(swift, contains("redactedLogLine"));
    expect(common, contains("RedactedDiagnosticLogLine"));
  });

  test("native reports are bounded and helper recovery stays explicit", () {
    final swift = readDirectory(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime",
    );
    final common = readDirectory("native_runtime/cpp");
    final windowsCMake = readFile("windows/native/CMakeLists.txt");
    final linuxCMake = readFile("linux/native/CMakeLists.txt");

    expect(swift, contains("maximumEntries = 80"));
    expect(common, contains("kMaximumDiagnosticEntries = 80"));
    expect(swift, contains("HelperRecoverySummary"));
    expect(common, contains("HelperRecoverySummary"));
    expect(swift, contains("Flutter lifecycle diagnostics remain Dart-owned"));
    expect(common, contains("Flutter lifecycle diagnostics remain Dart-owned"));
    expect(windowsCMake, contains("diagnostics_fixture_tests.cc"));
    expect(linuxCMake, contains("diagnostics_fixture_tests.cc"));
  });

  test("every canonical helper event remains emitted by native helpers", () {
    final events = (fixture("helper-events.json")["events"] as List<dynamic>)
        .cast<String>();
    final helpers = [
      readFile(
        "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
      ),
      readFile("windows/native/src/desktop_updater_native.cpp"),
      readFile("linux/native/src/desktop_updater_native.cc"),
    ];

    for (final helper in helpers) {
      for (final event in events) {
        expect(helper, contains(event), reason: event);
      }
    }
  });
}

Map<String, dynamic> fixture(String name) {
  return jsonDecode(
    readFile("fixtures/compat/native-contract/$name"),
  ) as Map<String, dynamic>;
}

String readFile(String path) {
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
