import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/safe_zip_extractor.dart";
import "package:desktop_updater/src/json/strict_json.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:path/path.dart" as path;

const int _maxPlistBytes = 4 * 1024 * 1024;
const int _maxPolicyBytes = 256 * 1024;
const int _maxEmbeddedPlistBytes = 8 * 1024 * 1024;
const int _maxInventoryEntries = 200000;
const int _maxPlistNodes = 100000;
const int _maxPlistDepth = 128;

/// Optional stable filesystem identity reader used by inventory tests.
typedef MacOSFileIdentityReader = Future<String?> Function(String path);

/// The kind of code object that is signed as one macOS code-signing target.
enum MacOSCodeTargetKind {
  application,
  appExtension,
  xpc,
  systemExtension,
  framework,
  bundle,
  executable,
  installHelper,
}

/// One deduplicated code-signing target discovered from bundle topology.
class MacOSCodeTarget {
  const MacOSCodeTarget({
    required this.path,
    required this.kind,
    this.identifier,
    this.bundleIdentifier,
  });

  final String path;
  final MacOSCodeTargetKind kind;
  final String? identifier;
  final String? bundleIdentifier;

  bool get allowsEntitlements =>
      kind == MacOSCodeTargetKind.application ||
      kind == MacOSCodeTargetKind.appExtension ||
      kind == MacOSCodeTargetKind.xpc ||
      kind == MacOSCodeTargetKind.systemExtension;
}

/// The sealed helper policy embedded in a packaged install helper.
class MacOSSealedHelperPolicy {
  const MacOSSealedHelperPolicy({
    required this.policyId,
    required this.applicationPackageId,
    required this.helperServiceId,
    required this.applicationRequirement,
    required this.helperRequirement,
    required this.policyBytes,
    required this.policySha256,
  });

  final String policyId;
  final String applicationPackageId;
  final String helperServiceId;
  final String applicationRequirement;
  final String helperRequirement;
  final List<int> policyBytes;
  final String policySha256;
}

/// Read-only macOS release inventory produced before any signing mutation.
class MacOSReleaseInventory {
  const MacOSReleaseInventory({
    required this.app,
    required this.applicationIdentifier,
    required this.targets,
    this.sealedPolicy,
  });

  final Directory app;
  final String applicationIdentifier;
  final List<MacOSCodeTarget> targets;
  final MacOSSealedHelperPolicy? sealedPolicy;

  MacOSCodeTarget get applicationTarget => targets.firstWhere(
    (target) => target.kind == MacOSCodeTargetKind.application,
  );
}

/// Typed result of a `notarytool --output-format json` submission.
class MacOSNotarySubmission {
  const MacOSNotarySubmission({required this.id, required this.status});

  final String id;
  final String status;
}

/// macOS release trust pipeline used by the release publisher.
///
/// The first phase only inspects files and metadata. Signing and all other
/// mutations are separate methods so callers cannot accidentally sign before
/// inventory, topology, and sealed-policy checks have completed.
class MacOSReleaseTrust {
  MacOSReleaseTrust({
    this.runProcess = defaultProcessRunner,
    this.readFileIdentity,
  });

  final ProcessRunner runProcess;
  final MacOSFileIdentityReader? readFileIdentity;

  /// Builds a bounded, symlink-safe code inventory without invoking codesign.
  Future<MacOSReleaseInventory> preflight({
    required Directory app,
    String? expectedApplicationIdentifier,
  }) async {
    await _requireRealDirectory(app, "macOS application");
    if (await FileSystemEntity.type(app.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        "macOS application must not be a symbolic link.",
        app.path,
      );
    }
    final appPath = path.normalize(await app.resolveSymbolicLinks());
    await _rejectSymlinkAncestors(appPath, includeSelf: true);

    final appInfoFile = File(path.join(appPath, "Contents", "Info.plist"));
    await _rejectSymlinkAncestors(appInfoFile.path, includeSelf: true);
    final appInfo = await _readRequiredPlist(appInfoFile, runProcess);
    final applicationIdentifier = _requiredSafeString(
      appInfo,
      "CFBundleIdentifier",
      appInfoFile.path,
    );
    if (expectedApplicationIdentifier != null &&
        applicationIdentifier != expectedApplicationIdentifier) {
      throw StateError(
        "macOS application identifier does not match release metadata.",
      );
    }
    final executableName = _requiredExecutableName(appInfo, appInfoFile.path);
    final mainExecutable = File(
      path.join(appPath, "Contents", "MacOS", executableName),
    );
    await _rejectSymlinkAncestors(mainExecutable.path, includeSelf: true);
    await _requireRegularFile(mainExecutable, "macOS application executable");
    if (!await _isMachO(mainExecutable)) {
      throw FileSystemException(
        "macOS application executable is not Mach-O code.",
        mainExecutable.path,
      );
    }

    final bundles = <String, _BundleInfo>{};
    bundles[appPath] = _BundleInfo(
      path: appPath,
      kind: MacOSCodeTargetKind.application,
      info: appInfo,
      principalExecutable: mainExecutable.path,
    );
    var entries = 0;
    await for (final entity in Directory(
      appPath,
    ).list(recursive: true, followLinks: false)) {
      entries += 1;
      if (entries > _maxInventoryEntries) {
        throw StateError(
          "macOS application contains too many filesystem entries.",
        );
      }
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        await _validateContainedSymlink(entity as Link, appPath);
        continue;
      }
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.file) {
        throw FileSystemException(
          "macOS application contains an unsupported filesystem node.",
          entity.path,
        );
      }
      if (type == FileSystemEntityType.directory) {
        final bundleKind = _bundleKindFor(entity.path, appPath);
        if (bundleKind == null || entity.path == appPath) continue;
        final infoResult = await _readBundleInfo(
          entity.path,
          bundleKind,
          runProcess,
          containingRoot: appPath,
        );
        final info = infoResult?.value;
        final infoFile = infoResult?.file;
        if (info == null || infoFile == null) {
          throw FileSystemException(
            "macOS code bundle has malformed or missing Info.plist.",
            entity.path,
          );
        }
        final principal = await _principalExecutable(
          entity.path,
          bundleKind,
          info,
          infoFile.path,
        );
        if (bundleKind != MacOSCodeTargetKind.bundle && principal == null) {
          throw FileSystemException(
            "macOS code bundle has no valid CFBundleExecutable.",
            entity.path,
          );
        }
        bundles[path.normalize(path.absolute(entity.path))] = _BundleInfo(
          path: path.normalize(path.absolute(entity.path)),
          kind: bundleKind,
          info: info,
          principalExecutable: principal,
        );
      }
    }

    final targets = <String, MacOSCodeTarget>{};
    final identities = <String, String>{};
    final principalPaths = bundles.values
        .map((bundle) => bundle.principalExecutable)
        .whereType<String>()
        .map(path.normalize)
        .toSet();
    final principalIdentities = <String>{};
    for (final principalPath in principalPaths) {
      final identity = await _stableFileIdentity(principalPath);
      if (identity != null) principalIdentities.add(identity);
    }
    Future<void> addTarget(MacOSCodeTarget target) async {
      final normalized = path.normalize(path.absolute(target.path));
      final previous = targets[normalized];
      if (previous != null) {
        if (previous.kind != target.kind ||
            previous.identifier != target.identifier) {
          throw StateError(
            "macOS inventory contains a duplicate target: $normalized",
          );
        }
        return;
      }
      final identity = await _stableFileIdentity(normalized);
      if (identity != null) {
        final previousPath = identities[identity];
        if (previousPath != null && previousPath != normalized) {
          final previousTarget = targets[previousPath]!;
          if (previousTarget.kind != target.kind ||
              previousTarget.identifier != target.identifier) {
            throw StateError(
              "macOS inventory contains a duplicate file identity: $normalized",
            );
          }
          return;
        }
      }
      targets[normalized] = MacOSCodeTarget(
        path: normalized,
        kind: target.kind,
        identifier: target.identifier,
        bundleIdentifier: target.bundleIdentifier,
      );
      if (identity != null) identities[identity] = normalized;
    }

    for (final bundle in bundles.values) {
      await _rejectSymlinkAncestors(bundle.path, includeSelf: true);
      final identifier = _requiredSafeString(
        bundle.info,
        "CFBundleIdentifier",
        bundle.path,
      );
      await addTarget(
        MacOSCodeTarget(
          path: bundle.path,
          kind: bundle.kind,
          identifier: identifier,
          bundleIdentifier: applicationIdentifier,
        ),
      );
    }

    await for (final entity in Directory(
      appPath,
    ).list(recursive: true, followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file) continue;
      final file = File(entity.path);
      await _rejectSymlinkAncestors(file.path, includeSelf: true);
      final isMachO = await _isMachO(file);
      if (!isMachO) {
        if (_isAllowedCodeLocation(
              path.normalize(path.absolute(file.path)),
              appPath,
            ) &&
            await _isExecutable(file)) {
          throw FileSystemException(
            "macOS application contains executable bytes that are not Mach-O.",
            file.path,
          );
        }
        continue;
      }
      await _rejectSymlinkAncestors(file.path, includeSelf: true);
      final normalized = path.normalize(path.absolute(file.path));
      if (principalPaths.contains(normalized)) continue;
      final fileIdentity = await _stableFileIdentity(normalized);
      if (fileIdentity != null && principalIdentities.contains(fileIdentity)) {
        continue;
      }
      if (!_isAllowedCodeLocation(normalized, appPath)) {
        throw FileSystemException(
          "Unexpected executable code outside a standard macOS code location.",
          file.path,
        );
      }
      final kind = normalized.endsWith("DesktopUpdaterInstallHelper")
          ? MacOSCodeTargetKind.installHelper
          : MacOSCodeTargetKind.executable;
      await addTarget(
        MacOSCodeTarget(
          path: normalized,
          kind: kind,
          bundleIdentifier: applicationIdentifier,
        ),
      );
    }

    final helper = File(
      path.join(appPath, "Contents", "Helpers", "DesktopUpdaterInstallHelper"),
    );
    MacOSSealedHelperPolicy? sealedPolicy;
    if (await FileSystemEntity.type(helper.path, followLinks: false) ==
        FileSystemEntityType.file) {
      if (!await _isMachO(helper)) {
        throw FileSystemException(
          "Packaged macOS install helper is not Mach-O code.",
          helper.path,
        );
      }
      await addTarget(
        MacOSCodeTarget(
          path: helper.path,
          kind: MacOSCodeTargetKind.installHelper,
          identifier: null,
          bundleIdentifier: applicationIdentifier,
        ),
      );
      sealedPolicy = await _readSealedPolicy(
        appPath: appPath,
        appInfo: appInfo,
        helper: helper,
      );
    }

    if (!targets.containsKey(appPath)) {
      throw StateError("macOS application inventory omitted the outer app.");
    }
    final ordered = targets.values.toList()
      ..sort((a, b) {
        final depth = path
            .split(b.path)
            .length
            .compareTo(path.split(a.path).length);
        if (depth != 0) return depth;
        if (a.kind == MacOSCodeTargetKind.application &&
            b.kind != MacOSCodeTargetKind.application) {
          return 1;
        }
        if (b.kind == MacOSCodeTargetKind.application &&
            a.kind != MacOSCodeTargetKind.application) {
          return -1;
        }
        return a.path.compareTo(b.path);
      });
    return MacOSReleaseInventory(
      app: Directory(appPath),
      applicationIdentifier: applicationIdentifier,
      targets: List.unmodifiable(ordered),
      sealedPolicy: sealedPolicy,
    );
  }

  /// Extracts each target's own entitlements, then signs and verifies targets.
  Future<void> signAndVerify({
    required MacOSReleaseInventory inventory,
    required String identity,
  }) async {
    final entitlements = <String, _EntitlementSnapshot>{};
    try {
      for (final target in inventory.targets) {
        final snapshot = await _readEntitlements(target);
        _validateEntitlementSnapshot(target, snapshot);
        if (snapshot.xmlBytes != null) {
          final file = File(
            path.join(
              Directory.systemTemp.path,
              "desktop_updater_entitlements_${DateTime.now().microsecondsSinceEpoch}_${entitlements.length}.plist",
            ),
          );
          await file.writeAsBytes(snapshot.xmlBytes!, flush: true);
          entitlements[target.path] = snapshot.copyWith(file: file);
        } else {
          entitlements[target.path] = snapshot;
        }
      }

      final policy = inventory.sealedPolicy;
      _teamIDs.clear();
      for (final target in inventory.targets) {
        final requirement = _requirementFor(target, policy);
        final explicitIdentifier = _identifierFor(target, policy);
        final args = <String>[
          "--force",
          "--options",
          "runtime",
          if (identity != "-") "--timestamp",
          if (explicitIdentifier != null && explicitIdentifier.isNotEmpty) ...[
            "--identifier",
            explicitIdentifier,
          ],
          if (requirement != null) "-r=designated => $requirement",
          if (entitlements[target.path]?.file != null) ...[
            "--entitlements",
            entitlements[target.path]!.file!.path,
          ],
          "--sign",
          identity,
          target.path,
        ];
        await _runChecked("/usr/bin/codesign", args);
        await _verifyTarget(
          target,
          requirement: requirement,
          expectedIdentifier: explicitIdentifier,
        );
      }

      for (final target in inventory.targets) {
        final before = entitlements[target.path];
        if (before == null) continue;
        final after = await _readEntitlements(target);
        if (!_semanticEqual(before.value, after.value)) {
          throw StateError(
            "macOS target entitlements changed during signing: ${target.path}",
          );
        }
      }
      await _assertEqualTeamIDs();
      await _runChecked("/usr/bin/codesign", [
        "--verify",
        "--deep",
        "--strict",
        "--verbose=2",
        inventory.app.path,
      ]);
    } finally {
      for (final snapshot in entitlements.values) {
        if (snapshot.file != null && await snapshot.file!.exists()) {
          await snapshot.file!.delete();
        }
      }
    }
  }

  Future<void> verifyApp({required MacOSReleaseInventory inventory}) async {
    for (final target in inventory.targets) {
      final snapshot = await _readEntitlements(target);
      _validateEntitlementSnapshot(target, snapshot);
    }
    _teamIDs.clear();
    for (final target in inventory.targets) {
      await _verifyTarget(
        target,
        requirement: _requirementFor(target, inventory.sealedPolicy),
        expectedIdentifier: _identifierFor(target, inventory.sealedPolicy),
      );
    }
    await _assertEqualTeamIDs();
    await _runChecked("/usr/bin/codesign", [
      "--verify",
      "--deep",
      "--strict",
      "--verbose=2",
      inventory.app.path,
    ]);
  }

  Future<MacOSNotarySubmission> submit({
    required File archive,
    required String profile,
    String? keychain,
  }) async {
    final result = await _runChecked("/usr/bin/xcrun", [
      "notarytool",
      "submit",
      archive.path,
      "--keychain-profile",
      profile,
      if (keychain != null && keychain.trim().isNotEmpty) ...[
        "--keychain",
        keychain,
      ],
      "--wait",
      "--output-format",
      "json",
    ]);
    return parseNotarySubmission(result.stdout.toString());
  }

  static MacOSNotarySubmission parseNotarySubmission(String response) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(response);
    } on FormatException catch (error) {
      throw StateError(
        "Unable to parse macOS notarization response: ${error.message}",
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw StateError("Unable to parse macOS notarization response.");
    }
    final id = decoded["id"];
    final status = decoded["status"];
    if (id is! String || id.trim().isEmpty || status is! String) {
      throw StateError(
        "macOS notarization response must contain a submission ID and status.",
      );
    }
    if (status != "Accepted") {
      throw StateError(
        "macOS notarization failed: $status for submission $id.",
      );
    }
    return MacOSNotarySubmission(id: id.trim(), status: status);
  }

  Future<void> stapleAndAssess({
    required FileSystemEntity artifact,
    required bool gatekeeperExecute,
    required bool gatekeeperInstall,
  }) async {
    await _runChecked("/usr/bin/xcrun", ["stapler", "staple", artifact.path]);
    await _runChecked("/usr/bin/xcrun", ["stapler", "validate", artifact.path]);
    if (gatekeeperExecute) {
      await _runChecked("/usr/sbin/spctl", [
        "--assess",
        "--type",
        "execute",
        "--verbose=2",
        artifact.path,
      ]);
    }
    if (gatekeeperInstall) {
      await _runChecked("/usr/sbin/spctl", [
        "--assess",
        "--type",
        "install",
        "--verbose=2",
        artifact.path,
      ]);
    }
  }

  /// Audits the exact distributable after packaging and before metadata sign.
  Future<void> auditFinalArtifact({
    required File artifact,
    required String kind,
    required String appBundleName,
    required String expectedApplicationIdentifier,
  }) async {
    _validateAppBundleName(appBundleName);
    final temp = await Directory.systemTemp.createTemp(
      "desktop_updater_final_audit_",
    );
    String? mountPoint;
    String? detachTarget;
    var auditSucceeded = false;
    try {
      Directory? extractedApp;
      if (kind == "zip") {
        await const SafeZipExtractor().preflight(
          artifact,
          rejectSymlinks: false,
        );
        await _runChecked("/usr/bin/ditto", [
          "-x",
          "-k",
          "--sequesterRsrc",
          artifact.path,
          temp.path,
        ]);
        extractedApp = Directory(path.join(temp.path, appBundleName));
      } else if (kind == "dmg") {
        final mounted = await _attachDmg(artifact);
        mountPoint = mounted.mountPoint;
        detachTarget = mounted.detachTarget;
        await _runChecked("/usr/bin/xcrun", [
          "stapler",
          "validate",
          artifact.path,
        ]);
        await _runChecked("/usr/sbin/spctl", [
          "--assess",
          "--type",
          "open",
          "--context",
          "context:primary-signature",
          "--verbose=2",
          artifact.path,
        ]);
        extractedApp = Directory(path.join(mountPoint, appBundleName));
      } else if (kind == "pkgInstaller") {
        await _runChecked("/usr/bin/xcrun", [
          "stapler",
          "validate",
          artifact.path,
        ]);
        await _runChecked("/usr/sbin/pkgutil", [
          "--check-signature",
          artifact.path,
        ]);
        await _runChecked("/usr/sbin/spctl", [
          "--assess",
          "--type",
          "install",
          "--verbose=2",
          artifact.path,
        ]);
        final expanded = Directory(path.join(temp.path, "expanded"));
        await _runChecked("/usr/sbin/pkgutil", [
          "--expand-full",
          artifact.path,
          expanded.path,
        ]);
        await _validateExtractedTree(expanded);
        extractedApp = await _findExpandedPayloadApp(expanded, appBundleName);
      }
      if (extractedApp == null ||
          await FileSystemEntity.type(extractedApp.path, followLinks: false) !=
              FileSystemEntityType.directory) {
        throw StateError("Final macOS distributable does not contain its app.");
      }
      final inventory = await preflight(
        app: extractedApp,
        expectedApplicationIdentifier: expectedApplicationIdentifier,
      );
      await verifyApp(inventory: inventory);
      await _runChecked("/usr/bin/xcrun", [
        "stapler",
        "validate",
        extractedApp.path,
      ]);
      await _runChecked("/usr/sbin/spctl", [
        "--assess",
        "--type",
        "execute",
        "--verbose=2",
        extractedApp.path,
      ]);
      auditSucceeded = true;
    } finally {
      if (mountPoint != null) {
        try {
          await _runChecked("/usr/bin/hdiutil", [
            "detach",
            detachTarget ?? mountPoint,
          ]);
        } on Object {
          if (auditSucceeded) rethrow;
        }
      }
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  Future<_MountedDmg> _attachDmg(File artifact) async {
    final result = await _runChecked("/usr/bin/hdiutil", [
      "attach",
      "-readonly",
      "-nobrowse",
      "-plist",
      artifact.path,
    ]);
    try {
      final record = _findMountRecord(
        _PlistXmlParser(result.stdout.toString()).parse(),
      );
      if (record != null) return record;
      final fallback = _mountPoint(result.stdout.toString());
      return _MountedDmg(mountPoint: fallback, detachTarget: fallback);
    } on Object {
      await _bestEffortDetachDmg(artifact);
      rethrow;
    }
  }

  Future<void> _bestEffortDetachDmg(File artifact) async {
    try {
      final result = await _runChecked("/usr/bin/hdiutil", ["info", "-plist"]);
      final value = _PlistXmlParser(result.stdout.toString()).parse();
      if (value is! Map) return;
      final images = value["images"];
      if (images is! List) return;
      final expected = path.normalize(path.absolute(artifact.path));
      for (final image in images) {
        if (image is! Map || image["image-path"] is! String) continue;
        final imagePath = path.normalize(
          path.absolute(image["image-path"]! as String),
        );
        if (imagePath != expected) continue;
        final record = _findMountRecord(image);
        if (record == null) return;
        await _runChecked("/usr/bin/hdiutil", ["detach", record.detachTarget]);
        return;
      }
    } on Object {
      // Preserve the attach/parse failure that required best-effort cleanup.
    }
  }

  Future<String?> _stableFileIdentity(String value) async {
    final injected = readFileIdentity;
    if (injected != null) return injected(value);
    final result = await runProcess("/usr/bin/stat", ["-f", "%d:%i", value]);
    if (result.exitCode != 0) return null;
    final identity = result.stdout.toString().trim();
    return RegExp(r"^\d+:\d+$").hasMatch(identity) ? identity : null;
  }

  String? _requirementFor(
    MacOSCodeTarget target,
    MacOSSealedHelperPolicy? policy,
  ) {
    if (policy == null) return null;
    if (target.kind == MacOSCodeTargetKind.installHelper) {
      return policy.helperRequirement;
    }
    if (target.kind == MacOSCodeTargetKind.application) {
      return policy.applicationRequirement;
    }
    return null;
  }

  String? _identifierFor(
    MacOSCodeTarget target,
    MacOSSealedHelperPolicy? policy,
  ) {
    if (policy == null) return target.identifier;
    if (target.kind == MacOSCodeTargetKind.installHelper) {
      return policy.helperServiceId;
    }
    if (target.kind == MacOSCodeTargetKind.application) {
      return policy.applicationPackageId;
    }
    return target.identifier;
  }

  void _validateEntitlementSnapshot(
    MacOSCodeTarget target,
    _EntitlementSnapshot snapshot,
  ) {
    if (snapshot.hasGetTaskAllow) {
      throw StateError(
        "macOS target contains forbidden com.apple.security.get-task-allow: ${target.path}",
      );
    }
    if (!target.allowsEntitlements && snapshot.value.isNotEmpty) {
      throw StateError(
        "Entitlements are not permitted on this macOS code target: ${target.path}",
      );
    }
  }

  Future<void> _assertEqualTeamIDs() async {
    final teams = _teamIDs.values
        .where((team) => team.trim().isNotEmpty)
        .toSet();
    if (_teamIDs.isEmpty ||
        teams.length != 1 ||
        _teamIDs.values.any((team) => team.trim().isEmpty)) {
      throw StateError(
        "macOS signed targets must have one equal nonempty Team ID.",
      );
    }
  }

  Future<void> _verifyTarget(
    MacOSCodeTarget target, {
    required String? requirement,
    required String? expectedIdentifier,
  }) async {
    await _runChecked("/usr/bin/codesign", [
      "--verify",
      "--strict",
      "--verbose=2",
      target.path,
    ]);
    if (requirement != null) {
      await _runChecked("/usr/bin/codesign", [
        "--verify",
        "--strict",
        "-R=$requirement",
        target.path,
      ]);
    }
    final details = await _runChecked("/usr/bin/codesign", [
      "-dvvv",
      target.path,
    ]);
    final detailText = "${details.stdout}\n${details.stderr}";
    final team = RegExp(r"(?:^|\n)TeamIdentifier=([^\r\n]+)")
        .firstMatch(detailText)
        ?.group(1)
        ?.trim();
    if (team == null || team.isEmpty) {
      throw StateError("macOS target has no nonempty Team ID: ${target.path}");
    }
    if (!RegExp(r"\bflags=.*\bruntime\b").hasMatch(detailText)) {
      throw StateError(
        "macOS target is not signed with the hardened runtime: ${target.path}",
      );
    }
    _teamIDs[target.path] = team;
    final identifier = RegExp(r"(?:^|\n)Identifier=([^\r\n]+)")
        .firstMatch(detailText)
        ?.group(1)
        ?.trim();
    if (identifier == null || identifier.isEmpty) {
      throw StateError("macOS target has no identifier: ${target.path}");
    }
    if (expectedIdentifier != null && identifier != expectedIdentifier) {
      throw StateError("macOS target identifier mismatch: ${target.path}");
    }
    if (requirement != null) {
      final requirementResult = await _runChecked("/usr/bin/codesign", [
        "-d",
        "-r-",
        target.path,
      ]);
      final designated = RegExp(r"(?:^|\n)designated => ([^\r\n]+)")
          .firstMatch(
            "${requirementResult.stdout}\n${requirementResult.stderr}",
          )
          ?.group(1)
          ?.trim();
      if (designated == null ||
          _normalizeDesignatedRequirement(designated) !=
              _normalizeDesignatedRequirement(requirement)) {
        throw StateError(
          "macOS target designated requirement does not match sealed policy: ${target.path}",
        );
      }
    }
  }

  final Map<String, String> _teamIDs = <String, String>{};

  Future<_EntitlementSnapshot> _readEntitlements(MacOSCodeTarget target) async {
    final result = await runProcess("/usr/bin/codesign", [
      "-d",
      "--entitlements",
      ":-",
      target.path,
    ]);
    if (result.exitCode != 0) {
      throw StateError("Unable to extract macOS entitlements: ${target.path}");
    }
    final output = "${result.stderr}\n${result.stdout}";
    final start = output.indexOf("<?xml");
    final plistStart = start >= 0 ? start : output.indexOf("<plist");
    if (plistStart < 0) {
      final trimmed = output.trim();
      if (trimmed.isEmpty || RegExp(r"(?:^|\n)Executable=").hasMatch(output)) {
        return const _EntitlementSnapshot(value: <String, Object?>{});
      }
      throw StateError("Unable to parse macOS entitlements: ${target.path}");
    }
    final plistEnd = output.indexOf("</plist>", plistStart);
    if (plistEnd < 0) {
      throw StateError("Unable to parse macOS entitlements: ${target.path}");
    }
    final xml = output.substring(plistStart, plistEnd + "</plist>".length);
    final value = await _parsePlistBytes(
      Uint8List.fromList(utf8.encode(xml)),
      runProcess,
      source: target.path,
    );
    if (value is! Map<String, Object?>) {
      throw StateError(
        "macOS entitlements are not a dictionary: ${target.path}",
      );
    }
    return _EntitlementSnapshot(
      value: value,
      xmlBytes: Uint8List.fromList(utf8.encode(xml)),
    );
  }

  Future<MacOSSealedHelperPolicy> _readSealedPolicy({
    required String appPath,
    required Map<String, Object?> appInfo,
    required File helper,
  }) async {
    final architecturesResult = await _runChecked("/usr/bin/lipo", [
      "-archs",
      helper.path,
    ]);
    final architectures = architecturesResult.stdout
        .toString()
        .trim()
        .split(RegExp(r"\s+"))
        .where((value) => value.isNotEmpty)
        .toList();
    if (architectures.isEmpty) {
      throw StateError("Packaged macOS helper has no Mach-O architecture.");
    }
    final embedded = <_EmbeddedPlist>[];
    for (final architecture in architectures) {
      final result = await _runChecked("/usr/bin/otool", [
        "-arch",
        architecture,
        "-v",
        "-s",
        "__TEXT",
        "__info_plist",
        helper.path,
      ]);
      embedded.add(
        _extractEmbeddedPlist(result.stdout.toString(), helper.path),
      );
    }
    for (final metadata in embedded.skip(1)) {
      if (!const ListEquality<int>().equals(
        metadata.plistBytes,
        embedded.first.plistBytes,
      )) {
        throw StateError(
          "Packaged helper architectures have different metadata.",
        );
      }
    }
    final helperInfo = await _parsePlistBytes(
      Uint8List.fromList(embedded.first.plistBytes),
      runProcess,
      source: helper.path,
    );
    if (helperInfo is! Map<String, Object?>) {
      throw StateError("Packaged helper embedded Info.plist is invalid.");
    }
    final data = helperInfo["DesktopUpdaterSealedPolicy"];
    final digest = helperInfo["DesktopUpdaterSealedPolicySHA256"];
    if (data is! List || digest is! String || digest.trim().isEmpty) {
      throw StateError("Packaged helper sealed policy is incomplete.");
    }
    final policyBytes = <int>[];
    for (final item in data) {
      if (item is! int || item < 0 || item > 255) {
        throw StateError("Packaged helper sealed policy data is invalid.");
      }
      policyBytes.add(item);
    }
    if (policyBytes.length > _maxPolicyBytes ||
        crypto.sha256.convert(policyBytes).toString() != digest) {
      throw StateError("Packaged helper sealed policy digest mismatch.");
    }
    final decoded = parseStrictJson(utf8.decode(policyBytes));
    if (decoded is! Map<String, Object?>) {
      throw StateError("Packaged helper sealed policy is not a dictionary.");
    }
    final required = {
      "policyVersion",
      "policyId",
      "applicationPackageId",
      "helperServiceId",
      "allowedApplicationSigner",
      "allowedHelperSigner",
      "allowedTargetClasses",
      "allowedInstallRoots",
      "releaseRootPublicKeys",
      "allowedStrategies",
      "minimumHelperProtocolVersion",
    };
    final decodedKeys = decoded.keys.toSet();
    if (decodedKeys.length != required.length ||
        !decodedKeys.containsAll(required)) {
      throw StateError("Packaged helper sealed policy has unexpected fields.");
    }
    if (decoded["policyVersion"] is! int ||
        (decoded["policyVersion"]! as int) < 1 ||
        decoded["minimumHelperProtocolVersion"] is! int ||
        (decoded["minimumHelperProtocolVersion"]! as int) < 1 ||
        !_validPolicyStringList(
          decoded["allowedTargetClasses"],
          nonempty: true,
          allowed: const {
            "sameUserWritable",
            "applicationBundle",
            "applicationDirectory",
            "singleExecutable",
            "protectedApplication",
            "systemPackage",
            "externalManaged",
          },
        ) ||
        !_validPolicyStringList(
          decoded["allowedInstallRoots"],
          absolutePaths: true,
          maximumLength: 4096,
        ) ||
        !_validPolicyStrategies(decoded["allowedStrategies"]) ||
        !_validPolicyReleaseKeys(decoded["releaseRootPublicKeys"])) {
      throw StateError("Packaged helper sealed policy fields are invalid.");
    }
    final canonicalPolicy = utf8.encode(jsonEncode(_sortedValue(decoded)));
    if (!const ListEquality<int>().equals(policyBytes, canonicalPolicy)) {
      throw StateError("Packaged helper sealed policy is not canonical JSON.");
    }
    final applicationSigner = _signerValue(decoded["allowedApplicationSigner"]);
    final helperSigner = _signerValue(decoded["allowedHelperSigner"]);
    final applicationPackageId = _safeIdentifier(
      decoded["applicationPackageId"],
    );
    final helperServiceId = _safeIdentifier(decoded["helperServiceId"]);
    final policyId = _safeIdentifier(decoded["policyId"]);
    if (applicationSigner == null || helperSigner == null) {
      throw StateError("Packaged helper policy signer is invalid.");
    }
    final applicationRequirement = applicationSigner.value;
    final helperRequirement = helperSigner.value;
    if (applicationSigner.kind != "appleDesignatedRequirement" ||
        helperSigner.kind != "appleDesignatedRequirement") {
      throw StateError(
        "Packaged helper policy requires Apple designated requirements.",
      );
    }
    if (helperInfo["CFBundleIdentifier"] != helperServiceId ||
        appInfo["CFBundleIdentifier"] != applicationPackageId ||
        appInfo["DesktopUpdaterInstallPolicyID"] != policyId ||
        appInfo["DesktopUpdaterInstallHelperServiceID"] != helperServiceId ||
        appInfo["DesktopUpdaterInstallHelperRequirement"] !=
            helperRequirement ||
        appInfo["DesktopUpdaterInstallHelperLaunchDaemonPlistName"] !=
            "$helperServiceId.plist") {
      throw StateError(
        "Packaged helper policy does not match bundle metadata.",
      );
    }
    final daemon = File(
      path.join(
        appPath,
        "Contents",
        "Library",
        "LaunchDaemons",
        "$helperServiceId.plist",
      ),
    );
    final daemonInfo = await _readRequiredPlist(daemon, runProcess);
    final services = daemonInfo["MachServices"];
    if (daemonInfo["Label"] != helperServiceId ||
        daemonInfo["BundleProgram"] !=
            "Contents/Helpers/DesktopUpdaterInstallHelper" ||
        daemonInfo["Program"] != null ||
        daemonInfo["ProgramArguments"] != null ||
        services is! Map<String, Object?> ||
        services.length != 1 ||
        services[helperServiceId] != true) {
      throw StateError("Packaged helper LaunchDaemon metadata is invalid.");
    }
    return MacOSSealedHelperPolicy(
      policyId: policyId,
      applicationPackageId: applicationPackageId,
      helperServiceId: helperServiceId,
      applicationRequirement: applicationRequirement,
      helperRequirement: helperRequirement,
      policyBytes: policyBytes,
      policySha256: digest,
    );
  }

  Future<ProcessResult> _runChecked(
    String executable,
    List<String> arguments,
  ) async {
    final result = await runProcess(executable, arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        "Command failed with exit ${result.exitCode}.",
        result.exitCode,
      );
    }
    return result;
  }
}

class _BundleInfoResult {
  const _BundleInfoResult({required this.file, required this.value});

  final File file;
  final Map<String, Object?> value;
}

class _BundleInfo {
  const _BundleInfo({
    required this.path,
    required this.kind,
    required this.info,
    required this.principalExecutable,
  });

  final String path;
  final MacOSCodeTargetKind kind;
  final Map<String, Object?> info;
  final String? principalExecutable;
}

class _EmbeddedPlist {
  const _EmbeddedPlist({required this.plistBytes});

  final List<int> plistBytes;
}

class _MountedDmg {
  const _MountedDmg({required this.mountPoint, required this.detachTarget});

  final String mountPoint;
  final String detachTarget;
}

_MountedDmg? _findMountRecord(Object? value) {
  if (value is Map) {
    final mountPoint = value["mount-point"];
    if (mountPoint is String && mountPoint.startsWith("/Volumes/")) {
      final device = value["dev-entry"];
      return _MountedDmg(
        mountPoint: mountPoint,
        detachTarget: device is String && device.isNotEmpty
            ? device
            : mountPoint,
      );
    }
    for (final child in value.values) {
      final record = _findMountRecord(child);
      if (record != null) return record;
    }
  } else if (value is List) {
    for (final child in value) {
      final record = _findMountRecord(child);
      if (record != null) return record;
    }
  }
  return null;
}

_EmbeddedPlist _extractEmbeddedPlist(String output, String source) {
  if (output.length > _maxEmbeddedPlistBytes * 4) {
    throw StateError("Packaged helper embedded metadata is too large.");
  }
  final rawStart = _plistStart(output);
  if (rawStart >= 0) {
    final rawText = output.substring(rawStart);
    return _embeddedPlistFromText(rawText, source);
  }

  final bytes = <int>[];
  for (final line in output.split("\n")) {
    final tokens = line.trim().split(RegExp(r"\s+"));
    if (tokens.length < 2 ||
        !RegExp(r"^[0-9a-fA-F]{8,16}$").hasMatch(tokens.first)) {
      continue;
    }
    for (final token in tokens.skip(1)) {
      if (!RegExp(r"^[0-9a-fA-F]{2}$").hasMatch(token)) break;
      bytes.add(int.parse(token, radix: 16));
      if (bytes.length > _maxEmbeddedPlistBytes) {
        throw StateError("Packaged helper embedded metadata is too large.");
      }
    }
  }
  if (bytes.isEmpty) {
    throw StateError(
      "Packaged helper architecture lacks embedded Info.plist: $source",
    );
  }
  try {
    final text = utf8.decode(bytes);
    return _embeddedPlistFromText(text, source);
  } on FormatException {
    throw StateError(
      "Packaged helper embedded Info.plist is not valid UTF-8: $source",
    );
  }
}

_EmbeddedPlist _embeddedPlistFromText(String text, String source) {
  final start = _plistStart(text);
  final end = text.indexOf("</plist>", start < 0 ? 0 : start);
  if (start < 0 || end < 0) {
    throw StateError(
      "Packaged helper architecture lacks embedded Info.plist: $source",
    );
  }
  final plistText = text.substring(start, end + "</plist>".length);
  final plistBytes = utf8.encode(plistText);
  if (plistBytes.length > _maxEmbeddedPlistBytes) {
    throw StateError("Packaged helper embedded metadata is too large.");
  }
  return _EmbeddedPlist(plistBytes: List.unmodifiable(plistBytes));
}

int _plistStart(String value) {
  final xml = value.indexOf("<?xml");
  final plist = value.indexOf("<plist");
  if (xml < 0) return plist;
  if (plist < 0) return xml;
  return xml < plist ? xml : plist;
}

class _EntitlementSnapshot {
  const _EntitlementSnapshot({required this.value, this.xmlBytes, this.file});

  final Map<String, Object?> value;
  final List<int>? xmlBytes;
  final File? file;

  bool get hasGetTaskAllow =>
      value.containsKey("com.apple.security.get-task-allow");

  _EntitlementSnapshot copyWith({File? file}) =>
      _EntitlementSnapshot(value: value, xmlBytes: xmlBytes, file: file);
}

class _Signer {
  const _Signer(this.kind, this.value);

  final String kind;
  final String value;
}

bool _validPolicyStringList(
  Object? value, {
  bool nonempty = false,
  bool absolutePaths = false,
  Set<String>? allowed,
  int? maximumLength,
}) {
  if (value is! List || (nonempty && value.isEmpty)) return false;
  final values = <String>[];
  for (final item in value) {
    if (item is! String ||
        item.isEmpty ||
        (maximumLength != null && item.length > maximumLength) ||
        (allowed != null && !allowed.contains(item)) ||
        (absolutePaths &&
            (!path.isAbsolute(item) ||
                path.normalize(item) != item ||
                item == "/"))) {
      return false;
    }
    values.add(item);
  }
  return values.toSet().length == values.length;
}

bool _validPolicyReleaseKeys(Object? value) {
  if (value is! List || value.isEmpty) return false;
  final ids = <String>{};
  for (final item in value) {
    if (item is! Map<String, Object?> ||
        item.keys.toSet().length != 3 ||
        item.keys.toSet().difference({
          "keyId",
          "algorithm",
          "publicKeyBase64",
        }).isNotEmpty ||
        item["keyId"] is! String ||
        !RegExp(r"^[A-Za-z0-9._-]{1,128}$")
            .hasMatch(item["keyId"]! as String) ||
        !ids.add(item["keyId"]! as String) ||
        item["algorithm"] != "ed25519" ||
        item["publicKeyBase64"] is! String) {
      return false;
    }
    try {
      final bytes = base64Decode(item["publicKeyBase64"]! as String);
      if (bytes.length != 32 ||
          base64Encode(bytes) != item["publicKeyBase64"]! as String) {
        return false;
      }
    } on FormatException {
      return false;
    }
  }
  return true;
}

bool _validPolicyStrategies(Object? value) {
  if (value is! List || value.isEmpty) return false;
  final pairs = <String>{};
  for (final item in value) {
    if (item is! Map<String, Object?> ||
        item.keys.toSet().length != 2 ||
        item.keys.toSet().difference({"strategy", "provider"}).isNotEmpty ||
        item["strategy"] is! String ||
        item["provider"] is! String) {
      return false;
    }
    final strategy = item["strategy"]! as String;
    final provider = item["provider"]! as String;
    final validProvider = switch (strategy) {
      "directoryReplace" => provider == "platformDirectory",
      "singleFileReplace" => provider == "platformFile",
      "verifiedInstallerHandoff" =>
        provider == "macosInstaller" || provider == "windowsInno",
      "systemPackageTransaction" => provider == "apt" || provider == "dnf",
      "externalManagedRefresh" => provider == "flatpak" || provider == "snap",
      _ => false,
    };
    if (!validProvider || !pairs.add("$strategy\u0000$provider")) return false;
  }
  return true;
}

_Signer? _signerValue(Object? value) {
  if (value is! Map<String, Object?> ||
      value.length != 2 ||
      value["kind"] is! String ||
      value["value"] is! String ||
      (value["value"]! as String).trim().isEmpty ||
      (value["value"]! as String).length > 2048 ||
      (value["value"]! as String).contains("*") ||
      (value["value"]! as String).contains("?")) {
    return null;
  }
  return _Signer(value["kind"]! as String, value["value"]! as String);
}

String _safeIdentifier(Object? value) {
  if (value is! String ||
      !RegExp(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{1,126}[A-Za-z0-9])?$")
          .hasMatch(value)) {
    throw StateError("Invalid sealed helper identifier.");
  }
  return value;
}

String _normalizeDesignatedRequirement(String value) {
  var normalized = value;
  normalized = normalized.replaceAllMapped(
    RegExp(r'identifier "([A-Za-z0-9][A-Za-z0-9._-]{0,126})"'),
    (match) => "identifier ${match.group(1)}",
  );
  normalized = normalized.replaceAllMapped(
    RegExp(r'(certificate leaf\[subject\.OU\] = )"([A-Z0-9]{1,64})"'),
    (match) => "${match.group(1)}${match.group(2)}",
  );
  return normalized;
}

String _requiredSafeString(
  Map<String, Object?> map,
  String key,
  String source,
) {
  final value = _optionalSafeString(map, key);
  if (value == null || value.isEmpty) {
    throw FormatException("$source is missing a nonblank $key.");
  }
  return value;
}

String? _optionalSafeString(Map<String, Object?> map, String key) {
  final value = map[key];
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

String _requiredExecutableName(Map<String, Object?> info, String source) {
  final executable = _requiredSafeString(info, "CFBundleExecutable", source);
  if (executable == "." ||
      executable == ".." ||
      executable.contains("/") ||
      executable.contains("\\")) {
    throw FormatException("$source contains an unsafe CFBundleExecutable.");
  }
  return executable;
}

MacOSCodeTargetKind? _bundleKindFor(String entityPath, String appPath) {
  final lower = path.basename(entityPath).toLowerCase();
  if (!lower.endsWith(".app") &&
      !lower.endsWith(".appex") &&
      !lower.endsWith(".xpc") &&
      !lower.endsWith(".systemextension") &&
      !lower.endsWith(".framework") &&
      !lower.endsWith(".bundle")) {
    return null;
  }
  if (path.normalize(path.absolute(entityPath)) == appPath) {
    return MacOSCodeTargetKind.application;
  }
  if (lower.endsWith(".appex")) return MacOSCodeTargetKind.appExtension;
  if (lower.endsWith(".xpc")) return MacOSCodeTargetKind.xpc;
  if (lower.endsWith(".systemextension")) {
    return MacOSCodeTargetKind.systemExtension;
  }
  if (lower.endsWith(".framework")) return MacOSCodeTargetKind.framework;
  if (lower.endsWith(".bundle")) return MacOSCodeTargetKind.bundle;
  return MacOSCodeTargetKind.application;
}

File _bundleInfoFile(String bundlePath, MacOSCodeTargetKind kind) {
  final contents = path.join(bundlePath, "Contents", "Info.plist");
  if (kind == MacOSCodeTargetKind.framework ||
      kind == MacOSCodeTargetKind.bundle) {
    return File(path.join(bundlePath, "Resources", "Info.plist"));
  }
  return File(contents);
}

Future<_BundleInfoResult?> _readBundleInfo(
  String bundlePath,
  MacOSCodeTargetKind kind,
  ProcessRunner runProcess, {
  required String containingRoot,
}) async {
  final candidates = <File>[
    if (kind == MacOSCodeTargetKind.framework ||
        kind == MacOSCodeTargetKind.bundle)
      File(path.join(bundlePath, "Resources", "Info.plist")),
    if (kind == MacOSCodeTargetKind.bundle)
      File(path.join(bundlePath, "Contents", "Info.plist")),
    if (kind == MacOSCodeTargetKind.framework)
      File(
        path.join(bundlePath, "Versions", "Current", "Resources", "Info.plist"),
      ),
    _bundleInfoFile(bundlePath, kind),
    if (kind == MacOSCodeTargetKind.framework ||
        kind == MacOSCodeTargetKind.bundle)
      File(path.join(bundlePath, "Info.plist")),
  ];
  final seen = <String>{};
  for (final file in candidates) {
    if (!seen.add(path.normalize(path.absolute(file.path)))) continue;
    final value = await _readOptionalPlist(
      file,
      runProcess,
      symlinkRoot: containingRoot,
    );
    if (value != null) {
      return _BundleInfoResult(file: file, value: value);
    }
  }
  return null;
}

Future<String?> _principalExecutable(
  String bundlePath,
  MacOSCodeTargetKind kind,
  Map<String, Object?> info,
  String source,
) async {
  final executableName = _optionalSafeString(info, "CFBundleExecutable");
  if (executableName == null) return null;
  if (executableName == "." ||
      executableName == ".." ||
      executableName.contains("/") ||
      executableName.contains("\\")) {
    throw FormatException("$source contains an unsafe CFBundleExecutable.");
  }
  final candidates = <String>[];
  if (kind == MacOSCodeTargetKind.framework) {
    candidates.add(path.join(bundlePath, executableName));
    candidates.add(
      path.join(bundlePath, "Versions", "Current", executableName),
    );
  } else {
    candidates.add(path.join(bundlePath, "Contents", "MacOS", executableName));
  }
  for (final candidate in candidates) {
    final resolved = await _resolveContainedPath(candidate, bundlePath);
    if (resolved == null) continue;
    if (await FileSystemEntity.type(resolved, followLinks: false) ==
            FileSystemEntityType.file &&
        await _isMachO(File(resolved))) {
      return path.normalize(path.absolute(resolved));
    }
  }
  return null;
}

Future<String?> _resolveContainedPath(String value, String root) async {
  String resolved;
  try {
    resolved = await File(value).resolveSymbolicLinks();
  } on FileSystemException {
    return null;
  }
  final canonical = path.normalize(path.absolute(resolved));
  final canonicalRoot = path.normalize(
    await Directory(root).resolveSymbolicLinks(),
  );
  if (canonical != canonicalRoot && !path.isWithin(canonicalRoot, canonical)) {
    throw FileSystemException(
      "Bundle metadata or executable symlink escapes its bundle.",
      value,
    );
  }
  return canonical;
}

Future<void> _requireRealDirectory(Directory directory, String label) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException(
      "$label must be a real directory.",
      directory.path,
    );
  }
}

Future<void> _requireRegularFile(File file, String label) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw FileSystemException(
      "$label is missing or is not a regular file.",
      file.path,
    );
  }
}

Future<void> _rejectSymlinkAncestors(
  String value, {
  required bool includeSelf,
}) async {
  final normalized = path.normalize(path.absolute(value));
  final parts = path.split(normalized);
  final limit = includeSelf ? parts.length : parts.length - 1;
  var current = parts.first == path.separator ? path.separator : parts.first;
  for (
    var index = parts.first == path.separator ? 1 : 1;
    index < limit;
    index++
  ) {
    current = current == path.separator
        ? path.join(current, parts[index])
        : path.join(current, parts[index]);
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        "Signing target has a symbolic-link ancestor.",
        value,
      );
    }
  }
}

Future<void> _validateContainedSymlink(Link link, String root) async {
  String resolved;
  try {
    resolved = path.normalize(await link.resolveSymbolicLinks());
  } on FileSystemException {
    throw FileSystemException(
      "macOS application contains a dangling symlink.",
      link.path,
    );
  }
  final canonicalRoot = path.normalize(
    await Directory(root).resolveSymbolicLinks(),
  );
  if (resolved != canonicalRoot && !path.isWithin(canonicalRoot, resolved)) {
    throw FileSystemException(
      "macOS application symlink escapes its bundle.",
      link.path,
    );
  }
}

bool _isAllowedCodeLocation(String filePath, String appPath) {
  final relative = path.relative(filePath, from: appPath);
  final parts = path.split(relative);
  final codeRoots = {
    "MacOS",
    "Frameworks",
    "PlugIns",
    "XPCServices",
    "Helpers",
    "LoginItems",
    "SystemExtensions",
  };
  for (var index = 0; index < parts.length; index++) {
    if (parts[index] == "Contents" &&
        index + 1 < parts.length &&
        codeRoots.contains(parts[index + 1]))
      return true;
    if (parts[index] == "Contents" &&
        index + 2 < parts.length &&
        parts[index + 1] == "Library" &&
        {"LoginItems", "SystemExtensions"}.contains(parts[index + 2])) {
      return true;
    }
  }
  return false;
}

Future<bool> _isExecutable(File file) async {
  final mode = (await file.stat()).mode;
  return mode & 0x49 != 0;
}

Future<bool> _isMachO(File file) async {
  final handle = await file.open();
  try {
    final bytes = await handle.read(4);
    if (bytes.length != 4) return false;
    final value = bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3];
    return const {
      0xfeedface,
      0xcefaedfe,
      0xfeedfacf,
      0xcffaedfe,
      0xcafebabe,
      0xbebafeca,
    }.contains(value);
  } finally {
    await handle.close();
  }
}

Future<Map<String, Object?>> _readRequiredPlist(
  File file,
  ProcessRunner runProcess,
) async {
  final value = await _readOptionalPlist(file, runProcess);
  if (value == null) {
    throw FileSystemException(
      "Required macOS Info.plist is missing or invalid.",
      file.path,
    );
  }
  return value;
}

Future<Map<String, Object?>?> _readOptionalPlist(
  File file,
  ProcessRunner runProcess, {
  String? symlinkRoot,
}) async {
  final source = symlinkRoot == null
      ? file
      : File(await _resolveContainedPath(file.path, symlinkRoot) ?? file.path);
  if (await FileSystemEntity.type(source.path, followLinks: false) !=
      FileSystemEntityType.file)
    return null;
  final bytes = await source.readAsBytes();
  if (bytes.length > _maxPlistBytes) {
    throw FileSystemException(
      "macOS plist exceeds the bounded size limit.",
      source.path,
    );
  }
  final value = await _parsePlistBytes(bytes, runProcess, source: source.path);
  return value is Map<String, Object?> ? value : null;
}

Future<Object?> _parsePlistBytes(
  List<int> bytes,
  ProcessRunner runProcess, {
  required String source,
}) async {
  if (bytes.length > _maxPlistBytes) {
    throw StateError("Unable to parse macOS plist: $source");
  }
  final text = _tryUtf8(bytes);
  if (text != null && text.contains("<plist")) {
    return _PlistXmlParser(text).parse();
  }
  final converted = await runProcess("/usr/bin/plutil", [
    "-convert",
    "json",
    "-o",
    "-",
    source,
  ]);
  if (converted.exitCode != 0) {
    throw StateError("Unable to parse macOS plist: $source");
  }
  final convertedText = converted.stdout.toString();
  if (convertedText.length > _maxPlistBytes) {
    throw StateError("Unable to parse macOS plist: $source");
  }
  try {
    final value = jsonDecode(convertedText);
    _validateBoundedPlistValue(value);
    return value;
  } on FormatException {
    throw StateError("Unable to parse macOS plist: $source");
  }
}

void _validateBoundedPlistValue(
  Object? value, {
  int depth = 0,
  _PlistBudget? budget,
}) {
  final activeBudget = budget ?? _PlistBudget();
  if (depth > _maxPlistDepth || ++activeBudget.nodes > _maxPlistNodes) {
    throw const FormatException("plist exceeds the bounded parse limit");
  }
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException("plist dictionary key is invalid");
      }
      _validateBoundedPlistValue(
        entry.value,
        depth: depth + 1,
        budget: activeBudget,
      );
    }
  } else if (value is List) {
    for (final item in value) {
      _validateBoundedPlistValue(item, depth: depth + 1, budget: activeBudget);
    }
  }
}

final class _PlistBudget {
  int nodes = 0;
}

String? _tryUtf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

bool _semanticEqual(Map<String, Object?> left, Map<String, Object?> right) {
  return jsonEncode(_sortedValue(left)) == jsonEncode(_sortedValue(right));
}

Object? _sortedValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _sortedValue(value[key]),
    };
  }
  if (value is List) return value.map(_sortedValue).toList(growable: false);
  return value;
}

String _mountPoint(String output) {
  for (final line in output.split("\n").reversed) {
    final match = RegExp(r"(/Volumes/.*)$").firstMatch(line.trim());
    if (match != null) return match.group(1)!;
  }
  throw StateError("hdiutil output did not contain a mount point.");
}

void _validateAppBundleName(String value) {
  if (value.isEmpty ||
      path.basename(value) != value ||
      path.normalize(value) != value ||
      !value.endsWith(".app")) {
    throw FormatException("Unsafe macOS application bundle name: $value");
  }
}

Future<Directory> _findExpandedPayloadApp(
  Directory expanded,
  String appBundleName,
) async {
  await for (final entity in expanded.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is Directory && path.basename(entity.path) == appBundleName) {
      return entity;
    }
  }
  throw StateError("Expanded PKG payload does not contain $appBundleName.");
}

Future<void> _validateExtractedTree(Directory root) async {
  if (await FileSystemEntity.type(root.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw FileSystemException("Expanded macOS artifact is not a directory.");
  }
  final canonicalRoot = path.normalize(
    await Directory(root.path).resolveSymbolicLinks(),
  );
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await _validateContainedSymlink(Link(entity.path), canonicalRoot);
    } else if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.file) {
      throw FileSystemException(
        "Expanded macOS artifact contains an unsupported filesystem node.",
        entity.path,
      );
    }
  }
}

/// Small plist XML reader for bounded Info.plist and entitlement dictionaries.
class _PlistXmlParser {
  _PlistXmlParser(this.source);

  final String source;
  var _offset = 0;
  var _nodes = 0;

  Object? parse() {
    final root = _nextOpeningTag("plist");
    if (root == null || root.selfClosing) {
      throw const FormatException("plist root is missing");
    }
    final value = _readValue(0);
    final closing = _nextTag();
    if (closing == null || !closing.closing || closing.name != "plist") {
      throw const FormatException("plist root is not closed");
    }
    if (source.substring(_offset).trim().isNotEmpty) {
      throw const FormatException("plist contains trailing data");
    }
    return value;
  }

  Object? _readValue(int depth) {
    if (depth > _maxPlistDepth || ++_nodes > _maxPlistNodes) {
      throw const FormatException("plist exceeds the bounded parse limit");
    }
    final tag = _nextTag();
    if (tag == null || tag.closing)
      throw const FormatException("plist value is missing");
    if (tag.selfClosing) {
      if (tag.name == "true") return true;
      if (tag.name == "false") return false;
      return null;
    }
    switch (tag.name) {
      case "dict":
        final map = <String, Object?>{};
        while (true) {
          final next = _nextTag();
          if (next == null)
            throw const FormatException("unterminated plist dict");
          if (next.closing && next.name == "dict") return map;
          if (next.name != "key" || next.closing || next.selfClosing) {
            throw const FormatException("plist dict key is invalid");
          }
          final key = _readTextUntil("key");
          if (map.containsKey(key)) {
            throw const FormatException("plist dict contains duplicate keys");
          }
          map[key] = _readValue(depth + 1);
        }
      case "array":
        final values = <Object?>[];
        while (true) {
          final next = _peekTag();
          if (next != null && next.closing && next.name == "array") {
            _nextTag();
            return values;
          }
          values.add(_readValue(depth + 1));
        }
      case "string":
      case "data":
      case "integer":
      case "real":
      case "date":
        final text = _readTextUntil(tag.name);
        if (tag.name == "data") {
          try {
            return base64Decode(text.replaceAll(RegExp(r"\s+"), ""));
          } on FormatException {
            throw const FormatException("plist data is invalid");
          }
        }
        if (tag.name == "integer") return int.parse(text);
        if (tag.name == "real") return double.parse(text);
        return text;
      default:
        throw FormatException("unsupported plist value ${tag.name}");
    }
  }

  String _readTextUntil(String name) {
    final end = source.indexOf("</$name", _offset);
    if (end < 0) throw FormatException("unterminated plist $name");
    final text = _decodeXml(source.substring(_offset, end)).trim();
    final close = source.indexOf(">", end);
    if (close < 0) throw const FormatException("plist closing tag is invalid");
    _offset = close + 1;
    return text;
  }

  _PlistTag? _nextOpeningTag(String name) {
    while (true) {
      final tag = _nextTag();
      if (tag == null) return null;
      if (!tag.closing && tag.name == name) return tag;
    }
  }

  _PlistTag? _peekTag() {
    final saved = _offset;
    final tag = _nextTag();
    _offset = saved;
    return tag;
  }

  _PlistTag? _nextTag() {
    final start = source.indexOf("<", _offset);
    if (start < 0) return null;
    final end = source.indexOf(">", start + 1);
    if (end < 0) return null;
    _offset = end + 1;
    var body = source.substring(start + 1, end).trim();
    if (body.startsWith("?")) return _nextTag();
    if (body.startsWith("!")) return _nextTag();
    final closing = body.startsWith("/");
    if (closing) body = body.substring(1).trim();
    final selfClosing = body.endsWith("/");
    if (selfClosing) body = body.substring(0, body.length - 1).trim();
    final name = body.split(RegExp(r"\s+")).first;
    return _PlistTag(name: name, closing: closing, selfClosing: selfClosing);
  }
}

class _PlistTag {
  const _PlistTag({
    required this.name,
    required this.closing,
    required this.selfClosing,
  });

  final String name;
  final bool closing;
  final bool selfClosing;
}

String _decodeXml(String value) => value
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&amp;", "&");

class ListEquality<T> {
  const ListEquality();

  bool equals(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i += 1) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}
