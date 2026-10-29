import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:desktop_updater/src/release_cli/macos/xcode_project_edit.dart";
import "package:path/path.dart" as path;

/// The managed phase resolves the installed Dart package on every build.
const managedHelperScript = r'''set -eu
cd "${PROJECT_DIR}/.."
"${FLUTTER_ROOT}/bin/dart" run desktop_updater:release helper-embed
''';

const _phaseName = "Embed Desktop Updater Install Helper";
const _plistInput = r"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)";

/// Prepares, but does not apply, a scoped Runner project repair.
/// Returns null for a policy-only project without Runner.xcodeproj.
Future<XcodeProjectEdit?> prepareHelperXcodeSetup(Directory projectRoot) async {
  final macos = path.join(projectRoot.path, "macos");
  final project = path.join(macos, "Runner.xcodeproj");
  final file = File(path.join(project, "project.pbxproj"));
  for (final directory in [macos, project]) {
    final type = await FileSystemEntity.type(directory, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        "Xcode setup requires regular directories.",
        directory,
      );
    }
  }
  if (!Platform.isMacOS) {
    throw const FormatException(
      "Automatic Xcode setup requires macOS. Use --no-configure-xcode to generate only the policy files on this host.",
    );
  }
  final edit = await XcodeProjectEdit.read(file);
  final objects = edit.objects;
  Map<String, dynamic> object(Object? id, String isa) {
    final value = objects[id];
    if (value is! Map<String, dynamic> || value["isa"] != isa) {
      throw FormatException("Invalid $isa reference in Runner.xcodeproj: $id");
    }
    return value;
  }

  final targets = objects.entries.where(
    (entry) =>
        entry.value is Map &&
        (entry.value as Map)["isa"] == "PBXNativeTarget" &&
        (entry.value as Map)["name"] == "Runner" &&
        (entry.value as Map)["productType"] ==
            "com.apple.product-type.application",
  );
  if (targets.length != 1) {
    throw const FormatException(
      "Automatic helper setup requires exactly one Runner application target.",
    );
  }
  final targetId = targets.single.key;
  final target = object(targetId, "PBXNativeTarget");
  final phases = (target["buildPhases"] as List).cast<String>();
  if (phases.toSet().length != phases.length) {
    throw const FormatException(
      "Runner contains duplicate build-phase references.",
    );
  }
  final scripts = phases
      .where(
        (id) =>
            objects[id] is Map &&
            (objects[id] as Map)["isa"] == "PBXShellScriptBuildPhase",
      )
      .toList();
  final flutterPhases = scripts
      .where(
        (id) => RegExp(r'''macos_assemble\.sh["']?\s+embed(?:\s|$)''')
            .hasMatch((objects[id] as Map)["shellScript"] as String? ?? ""),
      )
      .toList();
  if (flutterPhases.length != 1) {
    throw const FormatException(
      "Cannot uniquely identify Runner's macos_assemble.sh embed phase. No project changes were written.",
    );
  }
  final helperPhases = scripts.where((id) {
    final phase = objects[id] as Map;
    final script = phase["shellScript"] as String? ?? "";
    return script.contains("embed_install_helper.sh") ||
        script.contains("desktop_updater:release helper-embed") ||
        phase["name"] == _phaseName;
  }).toList();
  if (helperPhases.length > 1) {
    throw const FormatException(
      "Runner has multiple helper build phases. Keep one before running helper-policy.",
    );
  }
  final existing = helperPhases.isNotEmpty;
  late String helperId;
  if (existing) {
    helperId = helperPhases.single;
    final script = object(helperId, "PBXShellScriptBuildPhase")["shellScript"]
            as String? ??
        "";
    if (helperId == flutterPhases.single ||
        (script.trim().isNotEmpty &&
            !script.contains("embed_install_helper.sh") &&
            !script.contains("desktop_updater:release helper-embed"))) {
      throw const FormatException(
        "Runner's helper phase has an unrecognized custom script. Configure it manually or rename it before automatic setup.",
      );
    }
  } else {
    var index = 0;
    do {
      helperId = sha256
          .convert(utf8.encode("desktop_updater.helper.$targetId.${index++}"))
          .toString()
          .substring(0, 24)
          .toUpperCase();
    } while (objects.containsKey(helperId));
  }

  final configurations = object(
    target["buildConfigurationList"],
    "XCConfigurationList",
  )["buildConfigurations"] as List;
  if (configurations.isEmpty) {
    throw const FormatException("Runner has no build configurations.");
  }
  // A shared phase/configuration cannot be changed without affecting other targets.
  for (final entry in objects.entries) {
    if (entry.key == targetId || entry.value is! Map) continue;
    final other = entry.value as Map;
    if (![
      "PBXNativeTarget",
      "PBXAggregateTarget",
      "PBXLegacyTarget",
      "PBXProject",
    ].contains(other["isa"])) {
      continue;
    }
    final otherConfigurations = object(
      other["buildConfigurationList"],
      "XCConfigurationList",
    )["buildConfigurations"] as List;
    if ((other["buildPhases"] as List? ?? []).contains(helperId) ||
        otherConfigurations.any(configurations.contains)) {
      throw const FormatException(
        "Runner shares helper settings with another target; configure this project manually.",
      );
    }
  }
  for (final configId in configurations) {
    final config = object(configId, "XCBuildConfiguration");
    if (config["buildSettings"] is! Map) {
      throw const FormatException(
        "Runner configuration is missing buildSettings.",
      );
    }
    edit.set(
      [
        "objects",
        configId as String,
        "buildSettings",
        "ENABLE_USER_SCRIPT_SANDBOXING",
      ],
      "NO",
    );
  }

  if (!existing) {
    edit.set([
      "objects",
      helperId,
    ], {
      "isa": "PBXShellScriptBuildPhase",
      "name": _phaseName,
      "alwaysOutOfDate": "1",
      "buildActionMask": "2147483647",
      "files": <String>[],
      "inputPaths": [_plistInput],
      "outputPaths": <String>[],
      "runOnlyForDeploymentPostprocessing": "0",
      "shellPath": "/bin/sh",
      "shellScript": managedHelperScript,
    });
  } else {
    final helper = object(helperId, "PBXShellScriptBuildPhase");
    final inputs = (helper["inputPaths"] as List? ?? []).cast<String>();
    edit
      ..set([
        "objects",
        helperId,
        "inputPaths",
      ], [
        ...inputs,
        if (!inputs.contains(_plistInput)) _plistInput,
      ])
      ..set(["objects", helperId, "alwaysOutOfDate"], "1")
      ..set(["objects", helperId, "runOnlyForDeploymentPostprocessing"], "0");
    if ((helper["shellScript"] as String? ?? "").trim().isEmpty) {
      edit
        ..set(["objects", helperId, "shellPath"], "/bin/sh")
        ..set(["objects", helperId, "shellScript"], managedHelperScript);
    }
  }
  if (!existing ||
      phases.indexOf(helperId) < phases.indexOf(flutterPhases.single)) {
    final ordered = phases.where((id) => id != helperId).toList();
    ordered.insert(ordered.indexOf(flutterPhases.single) + 1, helperId);
    edit.set(["objects", targetId, "buildPhases"], ordered);
  }
  await edit.validate();
  return edit;
}
