import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Linux helper uses bash when the generated script uses bash features",
      () {
    final source = File("linux/desktop_updater_plugin.cc").readAsStringSync();

    expect(
      source,
      contains('execl("/bin/bash", "bash", script_path.c_str(), nullptr);'),
    );
    expect(source, contains("#!/bin/bash"));
    expect(source, contains("set -euo pipefail"));
    expect(source, contains("removed=("));
  });

  test("native helpers append diagnostics only when an explicit path is passed",
      () {
    final macosSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    final linuxSource =
        File("linux/desktop_updater_plugin.cc").readAsStringSync();
    final windowsSource =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();

    expect(macosSource, contains("diagnosticsLogPath"));
    expect(macosSource, contains("DIAGNOSTICS_LOG="));
    expect(macosSource, contains("log_event \"helper scheduled\""));
    expect(macosSource, contains(r'[ -n "$DIAGNOSTICS_LOG" ] || return 0'));

    expect(linuxSource, contains("diagnosticsLogPath"));
    expect(linuxSource, contains("diagnostics_log="));
    expect(linuxSource, contains(r'log_event \"helper scheduled\"'));
    expect(linuxSource, contains(r'[ -n \"$diagnostics_log\" ] || return 0'));

    expect(windowsSource, contains("diagnosticsLogPath"));
    expect(windowsSource, contains(r"$diagnosticsLog = "));
    expect(
      windowsSource,
      contains("Write-DiagnosticsEvent 'helper scheduled'"),
    );
    expect(
      windowsSource,
      contains(
        r"if ([string]::IsNullOrWhiteSpace($diagnosticsLog)) { return }",
      ),
    );
  });

  test("native helpers include failure events for support diagnostics", () {
    final macosSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    final linuxSource =
        File("linux/desktop_updater_plugin.cc").readAsStringSync();
    final windowsSource =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();

    for (final source in <String>[macosSource, linuxSource, windowsSource]) {
      expect(source, contains("backup failure"));
      expect(source, contains("move failure"));
      expect(source, contains("cleanup failure"));
      expect(source, contains("rollback failure"));
    }
  });

  test("Linux native test header exposes diagnostics log path scheduling", () {
    final source =
        File("linux/desktop_updater_plugin_private.h").readAsStringSync();

    expect(source, contains("diagnostics_log_path"));
  });

  test("Linux helper prunes target before whole directory overlay", () {
    final source = File("linux/desktop_updater_plugin.cc").readAsStringSync();
    const pruneSnippet =
        r'find \"$target\" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +';
    const copySnippet = r'cp -a \"$staging/.\" \"$target/\"';

    final pruneIndex = source.indexOf(pruneSnippet);
    final copyIndex = source.indexOf(copySnippet);

    expect(pruneIndex, isNonNegative);
    expect(copyIndex, isNonNegative);
    expect(pruneIndex, lessThan(copyIndex));
  });

  test("Windows helper prunes target before whole directory overlay", () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();
    const pruneSnippet = r"Get-ChildItem -LiteralPath $target -Force";
    const copySnippet =
        r"Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force";

    final pruneIndex = source.indexOf(pruneSnippet);
    final removeIndex =
        source.indexOf(r"Remove-Item -LiteralPath $_.FullName -Recurse -Force");
    final copyIndex = source.indexOf(copySnippet);

    expect(pruneIndex, isNonNegative);
    expect(
      source,
      contains(r"Remove-Item -LiteralPath $_.FullName -Recurse -Force"),
    );
    expect(removeIndex, isNonNegative);
    expect(copyIndex, isNonNegative);
    expect(pruneIndex, lessThan(copyIndex));
  });

  test("Windows helper updates uninstall DisplayVersion after overlay", () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();
    const copySnippet =
        r"Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force";
    const registrySnippet = r"Update-UninstallDisplayVersion -Version";

    final copyIndex = source.indexOf(copySnippet);
    final registryIndex = source.indexOf(registrySnippet);
    final relaunchIndex = source.indexOf(r"Start-Process -FilePath $exe");

    expect(source, contains(r".desktop_updater_release_manifest.json"));
    expect(source, contains("DisplayVersion"));
    expect(copyIndex, isNonNegative);
    expect(registryIndex, isNonNegative);
    expect(relaunchIndex, isNonNegative);
    expect(copyIndex, lessThan(registryIndex));
    expect(registryIndex, lessThan(relaunchIndex));
  });
}
