import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "../tool/sync_versions.dart";

void main() {
  test("3.1.0 version sync covers every generated release surface", () async {
    final (versions, changes) = await planVersionSync();

    expect(versions.canonical, "3.1.0");
    expect(changes, isEmpty);
    expect(
      changes.where((change) => change.path.contains("lock")),
      isEmpty,
    );
  });

  test("version sync includes the macOS helper executable surfaces", () {
    final source = File("tool/sync_versions.dart").readAsStringSync();

    expect(source, contains("macos/install_helper/Sources/"));
    expect(source, contains("HelperVersion.swift"));
    expect(source,
        contains("macos/install_helper/Configuration/Helper-Info.plist"));
    expect(source, contains("CFBundleShortVersionString"));
    expect(source, contains("CFBundleVersion"));
  });
}
