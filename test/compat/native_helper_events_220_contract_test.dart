import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("native helper event names are stable across platform sources", () {
    final fixture = jsonDecode(
      File("fixtures/compat/native-contract/helper-events.json")
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final events = (fixture["events"] as List<dynamic>).cast<String>();
    final legacyFixture = jsonDecode(
      File("fixtures/compat/native-helper-events.json").readAsStringSync(),
    ) as Map<String, dynamic>;
    final legacyEvents =
        (legacyFixture["events"] as List<dynamic>).cast<String>();
    final sources = [
      File(
        "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
      ),
      File("windows/desktop_updater_plugin.cpp"),
      File("linux/desktop_updater_plugin.cc"),
    ].map((file) => file.readAsStringSync()).join("\n");

    expect(fixture["schemaVersion"], 1);
    expect(events, legacyEvents);
    for (final event in events) {
      expect(sources, contains(event), reason: event);
    }
  });
}
