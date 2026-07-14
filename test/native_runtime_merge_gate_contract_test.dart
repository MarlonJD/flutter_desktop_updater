import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("generated fixtures cover adversarial Dart-native normalization", () {
    final selection =
        _json("fixtures/compat/native-contract/selection-cases.json");
    final validation = _json(
      "fixtures/compat/native-contract/descriptor-validation-cases.json",
    );
    final signatures = _json(
      "fixtures/compat/native-contract/canonical-signature-cases.json",
    );

    expect(
      _caseNames(selection, "parityCases"),
      containsAll(<String>{
        "rollout identity trims surrounding whitespace",
        "whitespace-only rollout identity is absent",
        "minimum OS keys and values are trimmed",
        "hyphen is valid inside prerelease identifier",
        "first numeric build metadata component is the build number",
        "ISO offset and UTC deadline represent the same instant",
        "same-second fractional deadline remains warning",
      }),
    );
    expect(
      _caseNames(selection, "indexValidationCases"),
      containsAll(<String>{
        "missing index channel defaults to stable",
        "present blank index channel is rejected",
      }),
    );
    expect(
      _caseNames(validation, "cases"),
      containsAll(<String>{
        "blank package identity",
        "blank version",
        "blank platform",
        "blank channel",
        "unsafe Inno log file name",
        "invalid Inno elevation policy",
        "missing Authenticode thumbprints",
        "invalid delta from version",
        "invalid delta URL",
        "invalid artifact URL",
        "zip artifact rejects pkgInstaller strategy",
        "invalid Inno inherit directory type",
        "invalid Inno relaunch type",
        "invalid Inno log file name type",
        "invalid Inno elevation type",
        "invalid Authenticode required type",
        "invalid DMG signature flag type",
        "invalid PKG relaunch type",
        "Inno silent args reject null entry",
        "Inno silent args reject object entry",
        "Inno silent args reject array entry",
        "Inno silent args reject integer entry",
        "Inno silent args reject boolean entry",
        "PKG package IDs reject object entry",
        "Authenticode thumbprints reject null entry",
      }),
    );
    expect(
      _caseNames(signatures, "normalizationCases"),
      containsAll(<String>{
        "canonicalization applies omitted install defaults",
        "canonicalization ignores unknown descriptor keys",
        "canonicalization normalizes offset timestamp",
        "canonicalization preserves six-digit microseconds",
        "canonicalization normalizes primary identity fields",
      }),
    );
  });

  test("native public result models preserve selected release fidelity", () {
    final windowsHeader =
        File("windows/native/include/desktop_updater_runtime_c.h")
            .readAsStringSync();
    final windowsRuntime =
        File("windows/native/src/runtime/desktop_updater_runtime_c.cpp")
            .readAsStringSync();
    final dotnet = File(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs",
    ).readAsStringSync();
    final linuxHeader = File(
      "linux/native/include/desktop_updater_runtime.h",
    ).readAsStringSync();
    final linuxRuntime = File(
      "linux/native/src/runtime/update_client_linux.cc",
    ).readAsStringSync();

    for (final field in <String>[
      "mandatory",
      "selected_build_number",
      "selected_platform_utf8",
      "selected_channel_utf8",
      "fresh_install_url_utf8",
      "fresh_install_message_utf8",
    ]) {
      expect(windowsHeader, contains(field), reason: field);
      expect(windowsRuntime, contains(field), reason: field);
    }
    for (final field in <String>[
      "Mandatory",
      "SelectedBuildNumber",
      "SelectedPlatform",
      "SelectedChannel",
      "FreshInstallUrl",
      "FreshInstallMessage",
    ]) {
      expect(dotnet, contains(field), reason: field);
    }
    for (final field in <String>[
      "mandatory",
      "selected_build_number",
      "selected_platform",
      "selected_channel",
      "fresh_install_url",
      "fresh_install_message",
    ]) {
      expect(linuxHeader, contains(field), reason: field);
      expect(linuxRuntime, contains(field), reason: field);
    }
  });

  test("Windows repeated-free fixture populates every owned result string", () {
    final source = File(
      "windows/native/test/runtime/runtime_c_api_compile_test.cpp",
    ).readAsStringSync();

    expect(source, contains("OwnedString("));
    for (final field in <String>[
      "selected_platform_utf8",
      "selected_channel_utf8",
      "fresh_install_url_utf8",
      "fresh_install_message_utf8",
    ]) {
      expect(source, contains("result.$field = OwnedString("), reason: field);
      expect(source, contains("result.$field != nullptr"), reason: field);
    }
    expect(
      RegExp(r"desktop_updater_runtime_result_free_v1\(&result\)")
          .allMatches(source),
      hasLength(greaterThanOrEqualTo(2)),
    );
  });

  test("CI names real helper recovery and privileged target-host evidence", () {
    final workflow = File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsStringSync();

    for (final lane in <String>[
      "Run macOS unprivileged crash recovery suite",
      "Run Windows helper trust, pipe, transaction, and crash recovery tests",
      "Run Linux unprivileged helper and crash recovery tests",
      "Run Linux privileged mount namespace rejection test",
      "Run signed bundled SMAppService daemon and XPC recovery smoke",
      "Run Authenticode and interactive UAC helper smoke",
      "Run installed polkit root broker smoke",
    ]) {
      expect(workflow, contains("- name: $lane"), reason: lane);
    }

    expect(
      workflow,
      contains("runs-on: [self-hosted, Windows, X64, desktop-updater-uac]"),
    );
    expect(
      workflow,
      contains("runs-on: [self-hosted, Linux, X64, desktop-updater-polkit]"),
    );
    expect(
      workflow,
      contains("DESKTOP_UPDATER_RUN_ELEVATED_HELPER_E2E == '1'"),
    );
    expect(
      workflow,
      contains("DESKTOP_UPDATER_RUN_POLKIT_HELPER_E2E == '1'"),
    );
    expect(workflow, contains("native-helper-test-counts"));
    expect(workflow, contains("helper-test-counts"));
    expect(workflow, isNot(contains("helper-raw-diagnostics")));
  });

  test("Linux polkit lane seals canonical policy bytes safely", () {
    final workflow = File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsStringSync();
    final smoke = File(
      "tool/linux_install_helper_smoke.sh",
    ).readAsStringSync();

    expect(workflow, contains("jq -cS ."));
    expect(workflow, contains("canonical_policy_sha="));
    expect(workflow, contains("escaped_policy_json="));
    expect(
      workflow,
      contains(
        r"DESKTOP_UPDATER_HELPER_CANONICAL_POLICY_JSON=$escaped_policy_json",
      ),
    );
    expect(smoke, contains("canonicalPolicySha256"));
    expect(smoke, contains("actual_policy_sha"));
  });
}

Map<String, dynamic> _json(String path) {
  return Map<String, dynamic>.from(
    jsonDecode(File(path).readAsStringSync()) as Map,
  );
}

Set<String> _caseNames(Map<String, dynamic> fixture, String key) {
  return ((fixture[key] as List?) ?? const <Object?>[])
      .map((entry) => (entry as Map)["name"]! as String)
      .toSet();
}
