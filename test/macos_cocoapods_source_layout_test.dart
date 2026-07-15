import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "support/contract_source.dart";

const _typecheck =
    r'xcrun swiftc -typecheck -target x86_64-apple-macosx10.14 -swift-version 5 -module-cache-path "$RUNNER_TEMP/desktop-updater-swift-module-cache" -F "$FLUTTER_ROOT/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64" macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterVersion.swift macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift';

const _podSources = <String>[
  "desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterVersion.swift",
  "desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift",
  "desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
  "desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift",
  "desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
];

void main() {
  test("podspec rejects mutations, extra sources, and commented floors", () {
    final valid = _podFixture();
    final bad = <String>[
      "$valid\ns.source_files.replace(['Runtime/*.swift'])",
      "$valid\ns.source_files += ['Runtime/*.swift']",
      "$valid\ns.source_files << 'Runtime/Extra.swift'",
      valid.replaceFirst(
        "\n]",
        "\n  , File.join(\n    'desktop_updater', 'Sources', "
            "'DesktopUpdaterKit', 'Runtime', '*.swift'\n  )\n]",
      ),
      valid.replaceFirst(
        "s.platform = :osx, '10.14'",
        "# s.platform = :osx, '10.14'\ns.platform = :osx, '10.15'",
      ),
      valid.replaceFirst("]\n", "].push('Runtime/Extra.swift')\n"),
      valid.replaceFirst("]\n", "] + ['Runtime/Extra.swift']\n"),
      valid.replaceFirst(
        "]\n",
        "]\n  .push('Runtime/Extra.swift')\n",
      ),
    ];
    for (final fixture in bad) {
      expect(_podErrors(fixture), isNotEmpty);
    }
  });

  test("CocoaPods fallback uses the exact five-file macOS 10.14 set", () {
    expect(
      _podErrors(File("macos/desktop_updater.podspec").readAsStringSync()),
      isEmpty,
    );
  });

  test("CocoaPods invokes helper tooling outside the exact source allowlist",
      () {
    final podspec = File("macos/desktop_updater.podspec").readAsStringSync();
    expect(_podErrors(podspec), isEmpty);
    expect(podspec, contains("install_helper/embed_install_helper.sh"));
    expect(podspec, contains("preserve_paths"));
    expect(podspec, isNot(contains("EmbeddedHelperLocator.swift")));
  });

  test("CocoaPods smoke host imports the plugin module SPI", () {
    final host = File(
      "example/macos/Runner/AppDelegate.swift",
    ).readAsStringSync();

    expect(
      host,
      contains("@_spi(DesktopUpdaterSmoke) import desktop_updater"),
    );
  });

  test("CI gates are structurally bound to the macOS jobs", () {
    final valid = File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsStringSync();
    final bad = <String>[
      valid.replaceFirst("  macos-native:", "  decoy:"),
      valid.replaceFirst(
        _step(
          "Run DesktopUpdaterKit SwiftPM tests",
          "swift test --package-path .",
        ),
        "",
      ),
      valid.replaceFirst(
        "        if: matrix.integration == 'swiftpm'\n",
        "",
      ),
      valid.replaceFirst(
        _step(
          "Enable CocoaPods fallback integration",
          "flutter config --no-enable-swift-package-manager",
          condition: "matrix.integration == 'cocoapods'",
        ),
        "",
      ),
      valid.replaceFirst(
        _step(
          "Build macOS example",
          "flutter build macos --debug",
          directory: "example",
        ),
        _step("Build macOS example", "flutter build macos --debug"),
      ),
      valid.replaceFirst(
        "        if: matrix.integration == 'cocoapods'\n"
            "        working-directory: example\n"
            "        run: flutter clean",
        "        working-directory: example\n        run: flutter clean",
      ),
    ];
    for (final fixture in bad) {
      expect(_workflowErrors(fixture), isNotEmpty);
    }
  });

  test("CI ignores gate text outside steps and rejects extra step fields", () {
    final valid = File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsStringSync();
    final typecheck = _step(
      "Typecheck macOS 10.14 CocoaPods fallback source set",
      _typecheck,
    );
    final blockScalarDecoy = valid.replaceFirst(typecheck, "").replaceFirst(
          "  macos-native:\n"
              "    name: macOS Native Consumer\n"
              "    runs-on: macos-15\n",
          "  macos-native:\n"
              "    name: |\n"
              "$typecheck"
              "    runs-on: macos-15\n",
        );
    final extraField = valid.replaceFirst(
      "        run: swift test --package-path .\n",
      "        run: swift test --package-path .\n"
          "        continue-on-error: true\n",
    );

    expect(_workflowErrors(valid), isEmpty);
    expect(_workflowErrors(blockScalarDecoy), isNotEmpty);
    expect(_workflowErrors(extraField), isNotEmpty);
  });

  test("CI typechecks and builds both macOS integration modes", () {
    expect(
      _workflowErrors(
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync(),
      ),
      isEmpty,
    );
  });

  test("launch contract ignores decoy tokens in strings and comments", () {
    const bad = r'''
private func moveMacOSAppToApplications() {
  if #available(macOS 10.15, *) {
    let decoy = "NSWorkspace.OpenConfiguration() NSWorkspace.shared.openApplication completeCopiedAppLaunch(error: error, result: result)"
  } else {
    NSWorkspace.shared.launchApplication(destinationURL.path)
    FlutterError(code: "LaunchFailed", message: "Unable to launch the copied app.", details: destinationURL.path)
  }
}
private func completeCopiedAppLaunch() {
  // FlutterError(code: "LaunchFailed", message: "Unable to launch the copied app.", details: error.localizedDescription)
}
''';
    expect(_launchErrors(bad), isNotEmpty);
  });

  test("launch contract rejects workspace APIs in the opposite branch", () {
    final plugin = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    final legacyInModern = plugin.replaceFirst(
      "            if #available(macOS 10.15, *) {\n",
      "            if #available(macOS 10.15, *) {\n"
          "                NSWorkspace.shared.launchApplication(destinationURL.path)\n",
    );
    final modernInLegacy = plugin.replaceFirst(
      "            } else {\n"
          "                let launched = NSWorkspace.shared.launchApplication(",
      "            } else {\n"
          "                let decoy = NSWorkspace.OpenConfiguration()\n"
          "                NSWorkspace.shared.openApplication(at: destinationURL, configuration: decoy)\n"
          "                let launched = NSWorkspace.shared.launchApplication(",
    );

    expect(_launchErrors(legacyInModern), isNotEmpty);
    expect(_launchErrors(modernInLegacy), isNotEmpty);
  });

  test("launch contract tolerates unrelated availability checks", () {
    final plugin = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    expect(
      _launchErrors("${_unrelatedAvailability()}\n$plugin"),
      isEmpty,
    );
  });

  test("CocoaPods helper source set owns its provenance dependencies", () {
    final podspec = File("macos/desktop_updater.podspec").readAsStringSync();
    final requestSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift",
    ).readAsStringSync();

    expect(podspec, isNot(contains("'Runtime'")));
    expect(requestSource, contains("public struct StageProvenanceEntry"));
    expect(requestSource, contains("public struct StageProvenanceState"));
    expect(requestSource, contains("public enum StageProvenance"));
    expect(requestSource, contains("import CommonCrypto"));
    expect(requestSource, isNot(contains("import CryptoKit")));
  });

  test("shared helper sources remain Flutter-free", () {
    final helperSources = Directory(
      "macos/desktop_updater/Sources/DesktopUpdaterKit",
    )
        .listSync()
        .whereType<File>()
        .map((file) => file.readAsStringSync())
        .join("\n");
    final pluginSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();

    expect(helperSources, isNot(contains("FlutterMacOS")));
    expect(helperSources, isNot(contains("FlutterMethodChannel")));
    expect(pluginSource, contains("#if canImport(DesktopUpdaterKit)"));
    expect(pluginSource, contains("import DesktopUpdaterKit"));
  });
}

List<String> _podErrors(String source) {
  final errors = <String>[];
  final code = maskNonCode(source, ruby: true);
  final references = RegExp(r"\bs\.source_files\b").allMatches(code).toList();
  if (references.length != 1) return <String>["source_files is mutated"];
  var cursor = skipWhitespace(code, references.single.end);
  if (cursor >= code.length || code[cursor] != "=") {
    return <String>["source_files is not directly assigned"];
  }
  cursor = skipWhitespace(code, cursor + 1);
  final close = cursor < code.length && code[cursor] == "["
      ? matchingClose(code, cursor, "[", "]")
      : null;
  if (close == null) return <String>["source_files is not one array"];
  final entries = splitTopLevelText(
    source.substring(cursor + 1, close),
  ).map(_fileJoin).toList();
  if (!_same(entries, _podSources)) errors.add("wrong source allowlist");
  final lineEnd = code.indexOf("\n", close + 1);
  final tail = code.substring(close + 1, lineEnd < 0 ? code.length : lineEnd);
  if (tail.trim().isNotEmpty) {
    errors.add("source_files RHS continues after array");
  }
  if (lineEnd >= 0) {
    final nextToken = RegExp(r"\S").firstMatch(code.substring(lineEnd + 1));
    if (nextToken != null && ".&+-*/%|^".contains(nextToken.group(0)!)) {
      errors.add("source_files RHS continues on the next line");
    }
  }

  final active = _stripRubyComments(source);
  final platforms = RegExp(r"^\s*s\.platform\s*=.*$", multiLine: true)
      .allMatches(active)
      .map((match) => match.group(0)!.trim())
      .toList();
  final swift = RegExp(r"^\s*s\.swift_version\s*=.*$", multiLine: true)
      .allMatches(active)
      .map((match) => match.group(0)!.trim())
      .toList();
  if (platforms.length != 1 ||
      platforms.single != "s.platform = :osx, '10.14'") {
    errors.add("wrong platform floor");
  }
  if (swift.length != 1 || swift.single != "s.swift_version = '5.0'") {
    errors.add("wrong Swift version");
  }
  return errors;
}

List<String> _workflowErrors(String source) {
  final errors = <String>[];
  final native = _job(source, "macos-native");
  final flutter = _job(source, "macos-flutter");
  if (native == null) {
    errors.add("missing macos-native job");
  } else {
    _expectSteps(errors, native, <String>[
      _step("Typecheck macOS 10.14 CocoaPods fallback source set", _typecheck),
      _step(
        "Run DesktopUpdaterKit SwiftPM tests",
        "swift test --package-path .",
      ),
      _step(
        "Run external SwiftPM consumer",
        "swift run --package-path example/native/macos",
      ),
    ]);
  }
  if (flutter == null) {
    errors.add("missing macos-flutter job");
  } else {
    if (!RegExp(r"^ {8}integration: \[swiftpm, cocoapods\]$", multiLine: true)
        .hasMatch(flutter)) {
      errors.add("wrong integration matrix");
    }
    _expectSteps(errors, flutter, <String>[
      _step(
        "Enable SwiftPM integration",
        "flutter config --enable-swift-package-manager",
        condition: "matrix.integration == 'swiftpm'",
      ),
      _step(
        "Enable CocoaPods fallback integration",
        "flutter config --no-enable-swift-package-manager",
        condition: "matrix.integration == 'cocoapods'",
      ),
      _step(
        "Clean CocoaPods fallback build",
        "flutter clean",
        condition: "matrix.integration == 'cocoapods'",
        directory: "example",
      ),
      _step(
        "Build macOS example",
        "flutter build macos --debug",
        directory: "example",
      ),
      _step(
        "Run macOS integration tests",
        "flutter test integration_test -d macos",
        directory: "example",
      ),
    ]);
  }
  return errors;
}

String? _job(String source, String id) {
  final lines = source.split("\n");
  final jobs = lines.indexWhere((line) => line == "jobs:");
  if (jobs < 0) return null;
  final starts = <int>[];
  for (var index = jobs + 1; index < lines.length; index++) {
    if (RegExp(r"^\S").hasMatch(lines[index])) break;
    if (lines[index] == "  $id:") starts.add(index);
  }
  if (starts.length != 1) return null;
  var end = lines.length;
  for (var index = starts.single + 1; index < lines.length; index++) {
    if (RegExp(r"^ {0,2}\S").hasMatch(lines[index])) {
      end = index;
      break;
    }
  }
  return lines.sublist(starts.single, end).join("\n");
}

void _expectSteps(List<String> errors, String job, List<String> expected) {
  final actual = _namedStepBlocks(job);
  if (actual == null) {
    errors.add("missing steps sequence");
    return;
  }
  for (final step in expected) {
    if (actual.where((block) => block == step).length != 1) {
      errors.add("missing or changed step");
    }
  }
}

List<String>? _namedStepBlocks(String job) {
  final lines = job.split("\n");
  final sequences = <int>[
    for (var index = 0; index < lines.length; index++)
      if (lines[index] == "    steps:") index,
  ];
  if (sequences.length != 1) return null;
  var end = lines.length;
  for (var index = sequences.single + 1; index < lines.length; index++) {
    if (RegExp(r"^ {0,4}\S").hasMatch(lines[index])) {
      end = index;
      break;
    }
  }
  final starts = <int>[
    for (var index = sequences.single + 1; index < end; index++)
      if (RegExp(r"^ {6}- ").hasMatch(lines[index])) index,
  ];
  final blocks = <String>[];
  for (var index = 0; index < starts.length; index++) {
    if (!RegExp(r"^ {6}- name: [^|>]+$").hasMatch(lines[starts[index]])) {
      continue;
    }
    final blockEnd = index + 1 < starts.length ? starts[index + 1] : end;
    blocks.add(
      "${lines.sublist(starts[index], blockEnd).join("\n").trimRight()}\n",
    );
  }
  return blocks;
}

List<String> _launchErrors(String source) {
  final errors = <String>[];
  final move = _function(source, "moveMacOSAppToApplications");
  final completion = _function(source, "completeCopiedAppLaunch");
  if (move == null || completion == null) {
    return <String>["launch functions missing"];
  }
  final branches = _launchBranches(move);
  if (branches == null) return <String>["launch availability branch missing"];
  final modern = branches.$1.code.replaceAll(RegExp(r"\s+"), "");
  final legacy = branches.$2.code.replaceAll(RegExp(r"\s+"), "");
  if (!modern.contains(
    "letconfiguration=NSWorkspace.OpenConfiguration()NSWorkspace.shared.openApplication(at:destinationURL,configuration:configuration){_,errorinself.completeCopiedAppLaunch(error:error,result:result)",
  )) {
    errors.add("wrong modern launch path");
  }
  if (modern.contains("NSWorkspace.shared.launchApplication(")) {
    errors.add("legacy launch API appears in modern branch");
  }
  if (!legacy.contains(
    "letlaunched=NSWorkspace.shared.launchApplication(destinationURL.path)",
  )) {
    errors.add("wrong legacy launch path");
  }
  if (legacy.contains("NSWorkspace.OpenConfiguration(") ||
      legacy.contains("NSWorkspace.shared.openApplication(")) {
    errors.add("modern launch API appears in fallback branch");
  }
  final modernError = _flutterError(completion);
  final legacyError = _flutterError(branches.$2);
  if (modernError == null ||
      legacyError == null ||
      modernError.$1 != "LaunchFailed" ||
      modernError.$2 != "Unable to launch the copied app." ||
      modernError.$1 != legacyError.$1 ||
      modernError.$2 != legacyError.$2 ||
      modernError.$3 != legacyError.$3) {
    errors.add("launch error parity changed");
  }
  return errors;
}

(SourceSlice, SourceSlice)? _launchBranches(SourceSlice function) {
  final matches =
      RegExp(r"if\s+#available\s*\(\s*macOS\s+10\.15\s*,\s*\*\s*\)\s*\{")
          .allMatches(function.code);
  final candidates = <(SourceSlice, SourceSlice)>[];
  for (final match in matches) {
    final open = function.code.indexOf("{", match.start);
    final modernClose = matchingClose(function.code, open, "{", "}");
    if (modernClose == null) continue;
    var cursor = skipWhitespace(function.code, modernClose + 1);
    if (!function.code.startsWith("else", cursor)) continue;
    cursor = skipWhitespace(function.code, cursor + 4);
    final legacyClose = matchingClose(function.code, cursor, "{", "}");
    if (legacyClose == null) continue;
    final pair = (
      function.sub(open + 1, modernClose),
      function.sub(cursor + 1, legacyClose),
    );
    if ("${pair.$1.code}${pair.$2.code}".contains("NSWorkspace")) {
      candidates.add(pair);
    }
  }
  return candidates.length == 1 ? candidates.single : null;
}

SourceSlice? _function(String source, String name) {
  final code = maskNonCode(source);
  final matches = RegExp("\\bfunc\\s+${RegExp.escape(name)}\\s*\\(")
      .allMatches(code)
      .toList();
  if (matches.length != 1) return null;
  final open = code.indexOf("{", matches.single.end);
  final close = matchingClose(code, open, "{", "}");
  return close == null
      ? null
      : SourceSlice(
          source.substring(open + 1, close),
          code.substring(open + 1, close),
        );
}

(String, String, String)? _flutterError(SourceSlice slice) {
  final calls = RegExp(r"\bFlutterError\s*\(").allMatches(slice.code).toList();
  if (calls.length != 1) return null;
  final open = slice.code.indexOf("(", calls.single.start);
  final close = matchingClose(slice.code, open, "(", ")");
  if (close == null) return null;
  final body =
      slice.source.substring(open + 1, close).replaceAll(RegExp(r"\s+"), " ");
  final match = RegExp(
    r'^\s*code: "([^"]+)", message: "([^"]+)", details: ([A-Za-z_][A-Za-z0-9_.]*)\s*$',
  ).firstMatch(body);
  if (match == null) return null;
  return (match.group(1)!, match.group(2)!, "member-access");
}

String _stripRubyComments(String source) => source.split("\n").map((line) {
      String? quote;
      for (var i = 0; i < line.length; i++) {
        final c = line[i];
        if (quote == null && (c == "'" || c == '"')) {
          quote = c;
        } else if (quote != null &&
            c == quote &&
            (i == 0 || line[i - 1] != r"\")) {
          quote = null;
        } else if (quote == null && c == "#") {
          return line.substring(0, i);
        }
      }
      return line;
    }).join("\n");

String? _fileJoin(String value) {
  final match =
      RegExp(r"^File\.join\s*\((.*)\)$", dotAll: true).firstMatch(value);
  if (match == null) return null;
  final pieces = splitTopLevelText(match.group(1)!);
  if (pieces.any((piece) => !RegExp(r"^'[^']+'$").hasMatch(piece))) return null;
  return pieces.map((piece) => piece.substring(1, piece.length - 1)).join("/");
}

bool _same(List<String?> left, List<String> right) =>
    left.length == right.length &&
    List.generate(left.length, (i) => left[i] == right[i])
        .every((same) => same);

String _podFixture() => """
s.source_files = [
${_podSources.map((path) => "  File.join('${path.split("/").join("', '")}')").join(",\n")}
]
s.platform = :osx, '10.14'
s.swift_version = '5.0'
""";

String _step(String name, String run, {String? condition, String? directory}) =>
    "      - name: $name\n${condition == null ? "" : "        if: $condition\n"}${directory == null ? "" : "        working-directory: $directory\n"}        run: $run\n";

String _unrelatedAvailability() =>
    "private func unrelated() { if #available(macOS 10.15, *) { modern() } else { legacy() } }";
