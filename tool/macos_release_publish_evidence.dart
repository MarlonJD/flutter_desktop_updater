import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/release_cli/macos/macos_release_trust.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:path/path.dart" as path;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption("artifact")
    ..addOption("metadata")
    ..addOption("git-commit")
    ..addOption("expected-application-id")
    ..addOption("evidence");
  try {
    final parsed = parser.parse(arguments);
    final artifact = File(_required(parsed, "artifact"));
    final metadata = jsonDecode(
      await File(_required(parsed, "metadata")).readAsString(),
    );
    if (metadata is! Map<String, dynamic>) {
      throw const FormatException("publish smoke metadata must be an object");
    }
    final expectedCommit = _required(parsed, "git-commit");
    final expectedApplicationId =
        parsed.option("expected-application-id")?.trim() ??
            (metadata["applicationIdentifier"] as String?);
    if (expectedApplicationId == null || expectedApplicationId.isEmpty) {
      throw const FormatException(
          "publish smoke metadata has no application id");
    }
    final evidence = File(_required(parsed, "evidence"));
    final metadataCommit = metadata["gitCommit"];
    if (metadataCommit != expectedCommit ||
        !RegExp(r"^[0-9a-f]{40}$").hasMatch(expectedCommit)) {
      throw const FormatException("publish evidence is not bound to HEAD");
    }
    final appBundleName = metadata["appBundleName"];
    final preStapleSha256 = metadata["preStapleSha256"];
    final preStapleLength = metadata["preStapleLength"];
    final notaryIds = metadata["notarizationSubmissionIds"];
    if (appBundleName is! String ||
        !appBundleName.endsWith(".app") ||
        path.basename(appBundleName) != appBundleName ||
        preStapleSha256 is! String ||
        !RegExp(r"^[0-9a-f]{64}$").hasMatch(preStapleSha256) ||
        preStapleLength is! int ||
        preStapleLength < 0 ||
        notaryIds is! List ||
        notaryIds.isEmpty ||
        notaryIds.any((value) => value is! String || value.trim().isEmpty)) {
      throw const FormatException("publish smoke metadata is incomplete");
    }
    if (!Platform.isMacOS) {
      throw const FormatException("macOS artifact evidence requires macOS");
    }

    final artifactSha256 = await sha256File(artifact);
    final artifactLength = await artifact.length();
    final trust = MacOSReleaseTrust();
    final temporary = await Directory.systemTemp.createTemp(
      "desktop_updater_release_publish_evidence_",
    );
    try {
      await trust.auditFinalArtifact(
        artifact: artifact,
        kind: "zip",
        appBundleName: appBundleName,
        expectedApplicationIdentifier: expectedApplicationId,
      );
      await _runChecked("/usr/bin/ditto", [
        "-x",
        "-k",
        "--sequesterRsrc",
        artifact.path,
        temporary.path,
      ]);
      final app = Directory(path.join(temporary.path, appBundleName));
      final inventory = await trust.preflight(
        app: app,
        expectedApplicationIdentifier: expectedApplicationId,
      );
      final appRoot = path.normalize(await app.resolveSymbolicLinks());
      await trust.verifyApp(inventory: inventory);

      final targetEvidence = <Map<String, Object?>>[];
      final teamIds = <String>{};
      var absenceOfGetTaskAllow = true;
      var noEntitlementPropagation = true;
      for (final target in inventory.targets) {
        final details = await _runChecked("/usr/bin/codesign", [
          "-dvvv",
          target.path,
        ]);
        final detailText = "${details.stdout}\n${details.stderr}";
        final identifier = _requiredLine(detailText, "Identifier");
        final teamId = _requiredLine(detailText, "TeamIdentifier");
        final flags = _requiredLine(detailText, "flags");
        final requirement = await _readRequirement(target.path);
        final entitlements = await _readEntitlements(target.path);
        final relative = path.relative(target.path, from: appRoot);
        final targetName = relative == "." ? appBundleName : relative;
        teamIds.add(teamId);
        final hasGetTaskAllow = entitlements.contains(
          "com.apple.security.get-task-allow",
        );
        absenceOfGetTaskAllow &= !hasGetTaskAllow;
        if (!target.allowsEntitlements && entitlements != "{}") {
          noEntitlementPropagation = false;
        }
        targetEvidence.add({
          "path": targetName,
          "kind": target.kind.name,
          "identifier": identifier,
          "teamId": teamId,
          "designatedRequirement": requirement,
          "runtimeFlags": flags,
          "entitlementsSha256":
              crypto.sha256.convert(utf8.encode(entitlements)).toString(),
          "hasGetTaskAllow": hasGetTaskAllow,
        });
      }
      if (teamIds.length != 1 || teamIds.single.isEmpty) {
        throw StateError("macOS targets do not share one Team ID");
      }
      if (!absenceOfGetTaskAllow || !noEntitlementPropagation) {
        throw StateError("macOS entitlement trust checks failed");
      }

      await _writeEvidence(
        evidence,
        {
          "schemaVersion": 1,
          "status": "verified locally",
          "headSha": expectedCommit,
          "artifactSHA256": artifactSha256,
          "artifactLength": artifactLength,
          "preStapleSHA256": preStapleSha256,
          "preStapleLength": preStapleLength,
          "notarizationSubmissionIds": List<String>.from(notaryIds),
          "inventory": targetEvidence,
          "equalTeamIds": true,
          "teamId": teamIds.single,
          "absenceOfGetTaskAllow": true,
          "noEntitlementPropagation": true,
          "strictSignatures": true,
          "stapleValid": true,
          "gatekeeperExecuteAccepted": true,
          "finalArtifactAudited": true,
        },
      );
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  } on Object {
    // A failure report is deliberately minimal and never includes command
    // output, absolute paths, credentials, or process diagnostics.
    final evidenceIndex = arguments.indexOf("--evidence");
    final evidencePath =
        evidenceIndex >= 0 && evidenceIndex + 1 < arguments.length
            ? arguments[evidenceIndex + 1]
            : null;
    if (evidencePath != null && evidencePath.trim().isNotEmpty) {
      await _writeEvidence(
        File(evidencePath),
        const {
          "schemaVersion": 1,
          "status": "candidate-only",
          "failureClass": "macos-release-publish-evidence-failed",
        },
      );
    }
    exitCode = 1;
  }
}

String _required(ArgResults parsed, String name) {
  final value = parsed.option(name)?.trim();
  if (value == null || value.isEmpty) {
    throw FormatException("--$name is required");
  }
  return value;
}

Future<ProcessResult> _runChecked(
    String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError("macOS trust command failed");
  }
  return result;
}

String _requiredLine(String output, String key) {
  final pattern = key == "flags"
      ? RegExp(r"\bflags=([^\r\n]+)")
      : RegExp("(?:^|\\n)${RegExp.escape(key)}=([^\\r\\n]+)");
  final value = pattern.firstMatch(output)?.group(1)?.trim();
  if (value == null || value.isEmpty) throw StateError("missing trust field");
  return value;
}

Future<String> _readRequirement(String target) async {
  final result = await _runChecked("/usr/bin/codesign", [
    "-d",
    "-r-",
    target,
  ]);
  final output = "${result.stdout}\n${result.stderr}";
  final requirement = RegExp(r"(?:^|\n)designated => ([^\r\n]+)")
      .firstMatch(output)
      ?.group(1)
      ?.trim();
  if (requirement == null || requirement.isEmpty) {
    throw StateError("missing designated requirement");
  }
  return requirement;
}

Future<String> _readEntitlements(String target) async {
  final result = await _runChecked("/usr/bin/codesign", [
    "-d",
    "--entitlements",
    ":-",
    target,
  ]);
  final output = "${result.stderr}\n${result.stdout}";
  final start = output.indexOf("<?xml");
  final plistStart = start < 0 ? output.indexOf("<plist") : start;
  if (plistStart < 0) {
    if (output.trim().isEmpty ||
        RegExp(r"(?:^|\n)Executable=").hasMatch(output)) {
      return "{}";
    }
    throw StateError("macOS entitlements could not be parsed");
  }
  final end = output.indexOf("</plist>", plistStart);
  if (end < 0) throw StateError("macOS entitlements are incomplete");
  return output.substring(plistStart, end + "</plist>".length).trim();
}

Future<void> _writeEvidence(File file, Map<String, Object?> value) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(
    "${const JsonEncoder.withIndent("  ").convert(value)}\n",
    flush: true,
  );
}
