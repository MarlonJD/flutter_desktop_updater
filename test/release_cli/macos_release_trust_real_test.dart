import "dart:io";

import "package:desktop_updater/src/release_cli/macos/macos_release_trust.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("secretless ad hoc app is real Mach-O and codesign-verifiable",
      () async {
    if (!Platform.isMacOS) return;

    final root = await Directory.systemTemp.createTemp("macos_adhoc_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = Directory(path.join(root.path, "AdHocFixture.app"));
    final source = File(path.join(root.path, "main.c"));
    final executable = File(
      path.join(app.path, "Contents", "MacOS", "AdHocFixture"),
    );
    await executable.parent.create(recursive: true);
    await source.writeAsString("int main(void) { return 0; }\n");
    await File(path.join(app.path, "Contents", "Info.plist")).writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.adhoc.fixture</string>
<key>CFBundleExecutable</key><string>AdHocFixture</string>
</dict></plist>
''');

    await _run("/usr/bin/clang", ["-o", executable.path, source.path]);
    await _run("/usr/bin/codesign", [
      "--force",
      "--options",
      "runtime",
      "--sign",
      "-",
      app.path,
    ]);
    final inventory = await MacOSReleaseTrust().preflight(
      app: app,
      expectedApplicationIdentifier: "com.example.adhoc.fixture",
    );
    expect(inventory.applicationTarget.kind, MacOSCodeTargetKind.application);
    await _run("/usr/bin/codesign", [
      "--verify",
      "--deep",
      "--strict",
      app.path,
    ]);
  });
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }
}
