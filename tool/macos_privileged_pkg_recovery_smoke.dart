import "dart:async";
import "dart:convert";
import "dart:ffi";
import "dart:io";

import "package:args/args.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:path/path.dart" as path;

import "native_runtime_smoke_server.dart" as smoke_server;

const _targetPath = "/Applications/Desktop Updater SMAppService PKG E2E.app";
const _bundleIdentifier = "net.monolib.updater";
const _receiptIdentifier = "net.monolib.updater.pkg";
const _ownerMarkerName = "desktop_updater_smoke_owner.txt";
const _ownerMarkerText = "desktop_updater macOS production smoke";
const _teamIdentifier = "UPK4SC93AN";
const _executableName = "MacOSRuntimeCompile";
const _serviceIdentifier = "net.monolib.updater.helper";
const _baselineVersion = "2.7.0";
const _baselineBuild = "270";
const _artifactKind = "pkgInstaller";
const _launchMode = "privilegedInstallerTool";
const _minimumUpdaterVersion = "2.7.0";
const _managerStartedEvent = "managerStarted";
const _transactionRetryAttempts = 10;
const _transactionRetryDelay = Duration(milliseconds: 500);
const _replaySafeTransactionOperations = {
  "--query-transaction",
  "--recover-transaction",
};
const _readyMarker = "/private/var/tmp/net.monolib.updater.pkg-recovery.ready";
const _releaseMarker =
    "/private/var/tmp/net.monolib.updater.pkg-recovery.release";
const _evidencePath = "reports/macos-privileged-updater/recovery.json";

final _commitPattern = RegExp(r"^[0-9a-f]{40}$");
final _sha256Pattern = RegExp(r"^[0-9a-f]{64}$");
final _uuidPattern = RegExp(
  r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
  r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
);

typedef _ProcPIDInfoNative = Int32 Function(
  Int32,
  Int32,
  Uint64,
  Pointer<Void>,
  Int32,
);
typedef _ProcPIDInfoDart = int Function(
  int,
  int,
  int,
  Pointer<Void>,
  int,
);
typedef _ProcPIDPathNative = Int32 Function(
  Int32,
  Pointer<Void>,
  Uint32,
);
typedef _ProcPIDPathDart = int Function(
  int,
  Pointer<Void>,
  int,
);
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _SysctlNative = Int32 Function(
  Pointer<Int32>,
  Uint32,
  Pointer<Void>,
  Pointer<UintPtr>,
  Pointer<Void>,
  UintPtr,
);
typedef _SysctlDart = int Function(
  Pointer<Int32>,
  int,
  Pointer<Void>,
  Pointer<UintPtr>,
  Pointer<Void>,
  int,
);

final _ProcPIDInfoDart _procPIDInfo = DynamicLibrary.process()
    .lookupFunction<_ProcPIDInfoNative, _ProcPIDInfoDart>("proc_pidinfo");
final _ProcPIDPathDart _procPIDPath = DynamicLibrary.process()
    .lookupFunction<_ProcPIDPathNative, _ProcPIDPathDart>("proc_pidpath");
final _MallocDart _malloc = DynamicLibrary.process()
    .lookupFunction<_MallocNative, _MallocDart>("malloc");
final _FreeDart _free =
    DynamicLibrary.process().lookupFunction<_FreeNative, _FreeDart>("free");
final _SysctlDart _sysctl = DynamicLibrary.process()
    .lookupFunction<_SysctlNative, _SysctlDart>("sysctl");

Future<void> main(List<String> arguments) async {
  try {
    if (!Platform.isMacOS) throw const _RecoveryFailure("macos-host-required");
    await _RecoverySmoke(_RecoveryRequest.parse(arguments)).run();
  } on FormatException {
    stderr.writeln("macOS privileged PKG recovery smoke: invalid-arguments");
    exitCode = 64;
  } on _RecoveryFailure catch (error) {
    stderr.writeln(
      "macOS privileged PKG recovery smoke: ${error.failureClass}",
    );
    exitCode = 1;
  } on Object {
    stderr.writeln("macOS privileged PKG recovery smoke: unexpected-failure");
    exitCode = 1;
  }
}

final class _RecoveryRequest {
  const _RecoveryRequest({
    required this.app,
    required this.pkg,
    required this.receiptIdentifier,
    required this.expectedVersion,
    required this.expectedBuild,
    required this.gitCommit,
    required this.artifactSHA256,
    required this.notarizationSubmissionId,
    required this.evidence,
    required this.smokeRoot,
  });

  factory _RecoveryRequest.parse(List<String> arguments) {
    final parser = ArgParser()
      ..addOption("app", mandatory: true)
      ..addOption("pkg", mandatory: true)
      ..addOption("receipt-id", mandatory: true)
      ..addOption("expected-version", mandatory: true)
      ..addOption("expected-build", mandatory: true)
      ..addOption("git-commit", mandatory: true)
      ..addOption("artifact-sha256", mandatory: true)
      ..addOption("notarization-submission-id", mandatory: true)
      ..addOption("evidence", mandatory: true)
      ..addOption("smoke-root", mandatory: true);
    final values = parser.parse(arguments);
    final commit = values.option("git-commit")!;
    final hash = values.option("artifact-sha256")!;
    final submission = values.option("notarization-submission-id")!;
    final expectedBuild = values.option("expected-build")!;
    if (!_commitPattern.hasMatch(commit) ||
        !_sha256Pattern.hasMatch(hash) ||
        !_uuidPattern.hasMatch(submission) ||
        !RegExp(r"^[0-9]+$").hasMatch(expectedBuild)) {
      throw const FormatException("invalid identity");
    }
    return _RecoveryRequest(
      app: Directory(values.option("app")!),
      pkg: File(values.option("pkg")!),
      receiptIdentifier: values.option("receipt-id")!,
      expectedVersion: values.option("expected-version")!,
      expectedBuild: expectedBuild,
      gitCommit: commit,
      artifactSHA256: hash,
      notarizationSubmissionId: submission,
      evidence: File(values.option("evidence")!),
      smokeRoot: Directory(values.option("smoke-root")!),
    );
  }

  final Directory app;
  final File pkg;
  final String receiptIdentifier;
  final String expectedVersion;
  final String expectedBuild;
  final String gitCommit;
  final String artifactSHA256;
  final String notarizationSubmissionId;
  final File evidence;
  final Directory smokeRoot;
}

final class _RecoverySmoke {
  const _RecoverySmoke(this.request);

  final _RecoveryRequest request;

  Future<void> run() async {
    await _validatePreconditions();
    final initialJournals = await _providerTransactions();
    if (initialJournals.isNotEmpty) {
      throw const _RecoveryFailure("provider-journal-already-present");
    }
    final server = await _SmokeServer.open(
      artifact: request.pkg,
      version: request.expectedVersion,
      build: int.parse(request.expectedBuild),
    );
    try {
      final runtime = await _runInstall(server);
      if (runtime.exitCode != 0 ||
          !runtime.output.contains("installAndRelaunch scheduled")) {
        throw const _RecoveryFailure("runtime-handoff-failed");
      }
    } finally {
      await server.close();
    }

    await _waitForReadyMarker(const Duration(seconds: 90));
    final transactionID = await _waitForSingleNewTransaction(
      initialJournals,
      const Duration(seconds: 30),
    );
    final query = await _transactionEvent("--query-transaction", transactionID);
    if (query.event != "query" ||
        query.state != "commitAccepted" ||
        query.resultCode != "recoveryRequired") {
      throw const _RecoveryFailure("manager-started-query-invalid");
    }
    // The fixed preinstall ready marker proves that the commitAccepted query is
    // the managerStarted phase rather than an earlier commit boundary.
    if (_managerStartedEvent != "managerStarted") {
      throw const _RecoveryFailure("manager-started-event-invalid");
    }

    final manager = await _waitForUniqueInstaller(
      transactionID,
      const Duration(seconds: 30),
    );
    final stage = await _snapshotOwnedStage();
    final metadata = await _readBundleMetadata(request.app);
    final helperExecutable = path.join(
      request.app.path,
      "Contents",
      "Helpers",
      "DesktopUpdaterInstallHelper",
    );
    final helperPID = await _launchDaemonPID(metadata.serviceIdentifier);
    if (helperPID == null || helperPID == manager.pid) {
      throw const _RecoveryFailure("launch-daemon-pid-invalid");
    }
    final helperIdentity = await _processIdentity(
      helperPID,
      helperExecutable,
    );
    if (helperIdentity == null ||
        !await _sameLaunchDaemonIdentity(
          metadata.serviceIdentifier,
          helperIdentity,
          helperExecutable,
        )) {
      throw const _RecoveryFailure("launch-daemon-identity-invalid");
    }
    final crash = await _transactionEvent(
      "--terminate-helper-for-recovery-smoke",
      transactionID,
    );
    if (crash.event != "helperCrashScheduled" ||
        crash.state != "commitAccepted" ||
        crash.resultCode != "recoveryRequired") {
      throw const _RecoveryFailure("launch-daemon-crash-request-invalid");
    }
    await _waitForIdentityExit(helperIdentity, const Duration(seconds: 15));

    final recovery = await _transactionEvent(
      "--recover-transaction",
      transactionID,
    );
    if (recovery.event != "recovery" ||
        recovery.state != "prepared" ||
        recovery.resultCode != "recoveryRequired") {
      throw const _RecoveryFailure("live-manager-recovery-invalid");
    }
    final replacementHelper = await _waitForLaunchDaemonReplacement(
      metadata.serviceIdentifier,
      helperIdentity,
      helperExecutable,
      const Duration(seconds: 15),
    );
    if (replacementHelper.pid == manager.pid) {
      throw const _RecoveryFailure("replacement-helper-pid-invalid");
    }
    final managerRetained = await _sameLiveManager(manager, transactionID);
    final retainedStage = await _sameOwnedStage(stage);
    if (!managerRetained || !retainedStage) {
      throw const _RecoveryFailure("live-manager-mutated-owned-state");
    }

    await _createReleaseMarker(manager.pid);
    await _waitForIdentityExit(manager, const Duration(minutes: 3));
    final terminal = await _waitForCompletedRecovery(
      transactionID,
      const Duration(minutes: 2),
    );
    if (terminal.state != "completed" || terminal.resultCode != "succeeded") {
      throw const _RecoveryFailure("terminal-recovery-invalid");
    }

    final terminalTarget = await _inspectTarget(
      expectedVersion: request.expectedVersion,
      expectedBuild: request.expectedBuild,
    );
    final stageRemoved = !await request.smokeRoot
        .subdirectory("staging")
        .list(followLinks: false)
        .any((_) => true);
    final remainingTransactions = await _providerTransactions();
    final lock = File(
      path.join(
        path.dirname(_targetPath),
        ".${path.basename(_targetPath)}.desktop-updater-lock",
      ),
    );
    if (!stageRemoved ||
        remainingTransactions.isNotEmpty ||
        await FileSystemEntity.type(lock.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const _RecoveryFailure("completed-owned-state-retained");
    }
    final repeat =
        await _transactionEvent("--query-transaction", transactionID);
    if (repeat.event != "query" ||
        repeat.state != "completed" ||
        repeat.resultCode != "succeeded") {
      throw const _RecoveryFailure("completed-query-not-idempotent");
    }
    await _requireMarkersAbsent();

    final evidence = <String, Object?>{
      "schemaVersion": 1,
      "status": "verified locally",
      "gitCommit": request.gitCommit,
      "artifactSHA256": request.artifactSHA256,
      "notarizationSubmissionId": request.notarizationSubmissionId,
      "bundleIdentifier": _bundleIdentifier,
      "receiptIdentifier": _receiptIdentifier,
      "teamIdentifier": _teamIdentifier,
      "artifactKind": _artifactKind,
      "launchMode": _launchMode,
      "minimumUpdaterVersion": _minimumUpdaterVersion,
      "version": terminalTarget.version,
      "build": terminalTarget.build,
      "receiptVersion": terminalTarget.receiptVersion,
      "crashPoint": "installer-active-after-managerStarted",
      "managerObservedLive": true,
      "stageRetainedWhileManagerLive": retainedStage,
      "concurrentMutationObserved": false,
      "finalState": "completed",
      "verifiedOutcome": "newTarget",
      "fixedInstallerAuthority": true,
      "stageRemovedAfterCompletion": stageRemoved,
      "rootOwnershipVerified": true,
      "signaturesVerified": true,
      "launchDaemonActive": terminalTarget.launchDaemonPID != null,
    };
    _validateEvidence(evidence);
    await _writeEvidence(evidence);
    stdout.writeln(
      jsonEncode({"status": "verified locally", "finalState": "completed"}),
    );
  }

  Future<void> _validatePreconditions() async {
    if (request.app.path != _targetPath ||
        request.receiptIdentifier != _receiptIdentifier ||
        request.expectedVersion != "2.7.1" ||
        request.expectedBuild != "271" ||
        path.normalize(request.evidence.path) != _evidencePath ||
        !path.isAbsolute(request.pkg.path) ||
        !path.isAbsolute(request.smokeRoot.path) ||
        path.dirname(path.normalize(request.smokeRoot.path)) !=
            "/private/tmp" ||
        !path.basename(request.smokeRoot.path).startsWith(
              "desktop-updater-pkg-recovery-",
            )) {
      throw const _RecoveryFailure("fixed-smoke-authority-mismatch");
    }
    final currentCommit = (await _runChecked(
      "/usr/bin/git",
      ["rev-parse", "HEAD"],
      "git-head-unavailable",
    ))
        .trim();
    if (currentCommit != request.gitCommit) {
      throw const _RecoveryFailure("git-head-mismatch");
    }
    await _requireDirectory(request.app.path);
    if (await request.app.resolveSymbolicLinks() != _targetPath) {
      throw const _RecoveryFailure("target-path-mismatch");
    }
    await _requireRegularFile(request.pkg.path);
    if (await _sha256(request.pkg) != request.artifactSHA256) {
      throw const _RecoveryFailure("artifact-hash-mismatch");
    }
    await _verifyPackage(request.pkg);
    await _inspectTarget(
      expectedVersion: _baselineVersion,
      expectedBuild: _baselineBuild,
    );
    if (await FileSystemEntity.type(
          request.smokeRoot.path,
          followLinks: false,
        ) ==
        FileSystemEntityType.notFound) {
      await request.smokeRoot.create();
    }
    await _requireDirectory(request.smokeRoot.path);
    if (await request.smokeRoot.resolveSymbolicLinks() !=
        path.normalize(request.smokeRoot.path)) {
      throw const _RecoveryFailure("smoke-root-symlinked");
    }
    if (await request.smokeRoot.list(followLinks: false).any((_) => true)) {
      throw const _RecoveryFailure("smoke-root-not-empty");
    }
    await _requireMarkersAbsent();
    final lock = File(
      path.join(
        path.dirname(_targetPath),
        ".${path.basename(_targetPath)}.desktop-updater-lock",
      ),
    );
    if (await FileSystemEntity.type(lock.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const _RecoveryFailure("target-lock-already-present");
    }
  }

  Future<_RuntimeResult> _runInstall(_SmokeServer server) async {
    final metadata = await _readBundleMetadata(request.app);
    final executable = path.join(
      request.app.path,
      "Contents",
      "MacOS",
      metadata.executable,
    );
    try {
      final result = await Process.run(
        executable,
        [
          "--smoke",
          "--app-archive-url",
          server.archiveURL.toString(),
          "--public-key-base64",
          server.publicKeyBase64,
          "--package-id",
          _bundleIdentifier,
          "--smoke-root",
          request.smokeRoot.path,
          "--diagnostics-log",
          path.join(request.smokeRoot.path, "helper.jsonl"),
          "--expected-team-identifier",
          _teamIdentifier,
        ],
        environment: const {"DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH": "1"},
        includeParentEnvironment: true,
      ).timeout(const Duration(minutes: 3));
      return _RuntimeResult(
        exitCode: result.exitCode,
        output: "${result.stdout}\n${result.stderr}",
      );
    } on ProcessException {
      throw const _RecoveryFailure("runtime-launch-failed");
    }
  }

  Future<_TransactionEvent> _transactionEvent(
    String operation,
    String transactionID,
  ) async {
    final operationIsReplaySafe = _replaySafeTransactionOperations.contains(
      operation,
    );
    for (var attempt = 0; attempt < _transactionRetryAttempts; attempt += 1) {
      final metadata = await _readBundleMetadata(request.app);
      final result = await Process.run(
        path.join(
          request.app.path,
          "Contents",
          "MacOS",
          metadata.executable,
        ),
        ["--smoke", operation, transactionID],
      ).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0) {
        throw const _RecoveryFailure("transaction-query-failed");
      }
      _TransactionEvent? event;
      for (final line in "${result.stdout}\n${result.stderr}".split("\n")) {
        try {
          final value = jsonDecode(line.trim());
          if (value is Map<String, Object?> &&
              value.keys.toSet().difference(
                const {"event", "state", "resultCode"},
              ).isEmpty &&
              value.keys.length == 3 &&
              value["event"] is String &&
              value["state"] is String &&
              value["resultCode"] is String) {
            event = _TransactionEvent(
              event: value["event"]! as String,
              state: value["state"]! as String,
              resultCode: value["resultCode"]! as String,
            );
          }
        } on FormatException {
          // Ignore unrelated runtime output.
        }
      }
      if (event == null) {
        throw const _RecoveryFailure("typed-transaction-event-missing");
      }
      final endpointUnavailable =
          event.state == "unknown" && event.resultCode == "endpointUnavailable";
      if (!endpointUnavailable) return event;
      if (!operationIsReplaySafe || attempt + 1 >= _transactionRetryAttempts) {
        throw const _RecoveryFailure("transaction-query-failed");
      }
      await Future<void>.delayed(_transactionRetryDelay);
    }
    throw const _RecoveryFailure("transaction-query-failed");
  }

  Future<Set<String>> _providerTransactions() async {
    final targetName = path.basename(_targetPath);
    final pattern = RegExp(
      "^\\.${RegExp.escape(targetName)}\\.desktop-updater-"
      "([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
      r"[89ab][0-9a-f]{3}-[0-9a-f]{12})\.provider\.json$",
    );
    final transactions = <String>{};
    await for (final entry in Directory("/Applications").list(
      followLinks: false,
    )) {
      final match = pattern.firstMatch(path.basename(entry.path));
      if (match == null) continue;
      if (await FileSystemEntity.type(entry.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const _RecoveryFailure("provider-journal-node-invalid");
      }
      transactions.add(match.group(1)!);
    }
    return transactions;
  }

  Future<String> _waitForSingleNewTransaction(
    Set<String> initial,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final current = await _providerTransactions();
      final added = current.difference(initial);
      if (added.length == 1 && current.length == initial.length + 1) {
        return added.single;
      }
      if (added.length > 1) {
        throw const _RecoveryFailure("provider-journal-ambiguous");
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const _RecoveryFailure("provider-journal-not-created");
  }

  Future<_ProcessStartIdentity> _waitForUniqueInstaller(
    String transactionID,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final matches = await _installerProcesses(transactionID);
      if (matches.length == 1) return matches.single;
      if (matches.length > 1) {
        throw const _RecoveryFailure("installer-manager-ambiguous");
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const _RecoveryFailure("installer-manager-not-found");
  }

  Future<List<_ProcessStartIdentity>> _installerProcesses(
    String transactionID,
  ) async {
    final result = await _runChecked(
      "/bin/ps",
      ["-ww", "-axo", "pid=,command="],
      "process-inspection-failed",
    );
    final matches = <_ProcessStartIdentity>[];
    final linePattern = RegExp(r"^\s*([0-9]+)\s+(.+)$");
    for (final line in result.split("\n")) {
      final parsed = linePattern.firstMatch(line);
      if (parsed == null) continue;
      final command = parsed.group(2)!;
      if (_fixedInstallerArguments(command, transactionID)) {
        final pid = int.parse(parsed.group(1)!);
        final startIdentity = _processStartIdentity(pid);
        if (startIdentity != null) {
          matches.add(
            _ProcessStartIdentity(pid: pid, startIdentity: startIdentity),
          );
        }
      }
    }
    return matches;
  }

  bool _fixedInstallerArguments(String command, String transactionID) {
    return _hasFixedInstallerArguments(command, transactionID);
  }

  Future<bool> _sameLiveManager(
    _ProcessStartIdentity expected,
    String transactionID,
  ) async {
    final matches = await _installerProcesses(transactionID);
    return matches.length == 1 &&
        matches.single.pid == expected.pid &&
        matches.single.startIdentity == expected.startIdentity;
  }

  Future<_StageSnapshot> _snapshotOwnedStage() async {
    final staging = request.smokeRoot.subdirectory("staging");
    await _requireDirectory(staging.path);
    final entries = await staging.list(followLinks: false).toList();
    if (entries.length != 1 ||
        await FileSystemEntity.type(entries.single.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !path.basename(entries.single.path).startsWith(
              "desktop_updater_stage_",
            )) {
      throw const _RecoveryFailure("owned-stage-invalid");
    }
    final stage = Directory(entries.single.path);
    final installer = File(path.join(stage.path, "installer.pkg"));
    await _requireRegularFile(installer.path);
    return _StageSnapshot(
      path: stage.path,
      nodeIdentity: await _nodeIdentity(stage.path),
      installerSHA256: await _sha256(installer),
    );
  }

  Future<bool> _sameOwnedStage(_StageSnapshot expected) async {
    if (await FileSystemEntity.type(expected.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    final installer = File(path.join(expected.path, "installer.pkg"));
    return await _nodeIdentity(expected.path) == expected.nodeIdentity &&
        await FileSystemEntity.type(installer.path, followLinks: false) ==
            FileSystemEntityType.file &&
        await _sha256(installer) == expected.installerSHA256;
  }

  Future<int?> _launchDaemonPID(String serviceIdentifier) async {
    final result = await Process.run(
      "/bin/launchctl",
      ["print", "system/$serviceIdentifier"],
    );
    if (result.exitCode != 0) return null;
    final match = RegExp(r"^\s*pid = ([1-9][0-9]*)\s*$", multiLine: true)
        .firstMatch("${result.stdout}");
    return match == null ? null : int.parse(match.group(1)!);
  }

  Future<_ProcessStartIdentity?> _processIdentity(
    int pid,
    String expectedExecutable,
  ) async {
    if (_processExecutablePath(pid) != expectedExecutable) {
      return null;
    }
    final startIdentity = _processStartIdentity(pid);
    return startIdentity == null
        ? null
        : _ProcessStartIdentity(pid: pid, startIdentity: startIdentity);
  }

  Future<bool> _sameLaunchDaemonIdentity(
    String serviceIdentifier,
    _ProcessStartIdentity expected,
    String expectedExecutable,
  ) async {
    if (await _launchDaemonPID(serviceIdentifier) != expected.pid) return false;
    final current = await _processIdentity(expected.pid, expectedExecutable);
    return current != null && current.startIdentity == expected.startIdentity;
  }

  Future<void> _waitForIdentityExit(
    _ProcessStartIdentity expected,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_processStartIdentity(expected.pid) != expected.startIdentity) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const _RecoveryFailure("process-did-not-exit");
  }

  Future<_ProcessStartIdentity> _waitForLaunchDaemonReplacement(
    String serviceIdentifier,
    _ProcessStartIdentity previous,
    String expectedExecutable,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final pid = await _launchDaemonPID(serviceIdentifier);
      if (pid != null) {
        final current = await _processIdentity(pid, expectedExecutable);
        if (current != null &&
            (current.pid != previous.pid ||
                current.startIdentity != previous.startIdentity)) {
          return current;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const _RecoveryFailure("launch-daemon-not-restarted");
  }

  Future<_TransactionEvent> _waitForCompletedRecovery(
    String transactionID,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final event = await _transactionEvent(
        "--recover-transaction",
        transactionID,
      );
      if (event.state == "completed" && event.resultCode == "succeeded") {
        return event;
      }
      if (event.resultCode != "recoveryRequired") {
        throw const _RecoveryFailure("recovery-entered-unexpected-state");
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const _RecoveryFailure("recovery-did-not-complete");
  }

  Future<void> _createReleaseMarker(int managerPID) async {
    if (await FileSystemEntity.type(_releaseMarker, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const _RecoveryFailure("release-marker-already-present");
    }
    final file = File(_releaseMarker);
    await file.create(exclusive: true);
    final handle = await file.open(mode: FileMode.write);
    try {
      await handle.writeString("$managerPID\n");
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Future<void> _waitForRegularFile(String value, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final type = await FileSystemEntity.type(value, followLinks: false);
      if (type == FileSystemEntityType.file) return;
      if (type != FileSystemEntityType.notFound) {
        throw const _RecoveryFailure("gate-marker-node-invalid");
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const _RecoveryFailure("gate-marker-timeout");
  }

  Future<void> _waitForReadyMarker(Duration timeout) async {
    await _waitForRegularFile(_readyMarker, timeout);
    final authority = await _runChecked(
      "/usr/bin/stat",
      ["-f", "%Su:%Sg:%Lp", _readyMarker],
      "ready-marker-authority-unavailable",
    );
    if (authority.trim() != "root:wheel:600") {
      throw const _RecoveryFailure("ready-marker-authority-invalid");
    }
  }

  Future<void> _requireMarkersAbsent() async {
    for (final marker in [_readyMarker, _releaseMarker]) {
      if (await FileSystemEntity.type(marker, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const _RecoveryFailure("stale-gate-marker");
      }
    }
  }

  Future<_InstalledTarget> _inspectTarget({
    required String expectedVersion,
    required String expectedBuild,
  }) async {
    final metadata = await _readBundleMetadata(request.app);
    if (metadata.bundleIdentifier != _bundleIdentifier ||
        metadata.version != expectedVersion ||
        metadata.build != expectedBuild) {
      throw const _RecoveryFailure("target-version-mismatch");
    }
    final marker = File(
      path.join(
        request.app.path,
        "Contents",
        "Resources",
        _ownerMarkerName,
      ),
    );
    await _requireRegularFile(marker.path);
    final ownerLines = await marker.readAsLines();
    if (!ownerLines.contains(_ownerMarkerText) ||
        !ownerLines.contains("packageId=$_bundleIdentifier")) {
      throw const _RecoveryFailure("target-owner-marker-mismatch");
    }
    final executable = File(
      path.join(request.app.path, "Contents", "MacOS", metadata.executable),
    );
    final helper = File(
      path.join(
        request.app.path,
        "Contents",
        "Helpers",
        "DesktopUpdaterInstallHelper",
      ),
    );
    final daemon = File(
      path.join(
        request.app.path,
        "Contents",
        "Library",
        "LaunchDaemons",
        "${metadata.serviceIdentifier}.plist",
      ),
    );
    for (final file in [executable, helper, daemon]) {
      await _requireRegularFile(file.path);
    }
    if (await _plistValue(daemon, "Label") != metadata.serviceIdentifier ||
        await _plistValue(daemon, "BundleProgram") !=
            "Contents/Helpers/DesktopUpdaterInstallHelper" ||
        await _plistHasKey(daemon, "Program") ||
        await _plistHasKey(daemon, "ProgramArguments")) {
      throw const _RecoveryFailure("launch-daemon-metadata-invalid");
    }
    for (final target in [request.app.path, executable.path, helper.path]) {
      await _verifyCodeSignature(target, deep: target == request.app.path);
    }
    await _runChecked(
      "/usr/sbin/spctl",
      ["--assess", "--type", "execute", "--verbose=2", request.app.path],
      "app-gatekeeper-rejected",
    );
    await _runChecked(
      "/usr/bin/xcrun",
      ["stapler", "validate", request.app.path],
      "app-staple-invalid",
    );
    for (final target in [
      request.app.path,
      executable.path,
      helper.path,
      daemon.path,
    ]) {
      final ownership = await _runChecked(
        "/usr/bin/stat",
        ["-f", "%Su:%Sg", target],
        "ownership-inspection-failed",
      );
      if (ownership.trim() != "root:wheel") {
        throw const _RecoveryFailure("root-ownership-mismatch");
      }
    }
    final receiptVersion = await _receiptVersion();
    if (receiptVersion != expectedVersion) {
      throw const _RecoveryFailure("receipt-version-mismatch");
    }
    return _InstalledTarget(
      version: metadata.version,
      build: metadata.build,
      receiptVersion: receiptVersion,
      launchDaemonPID: await _launchDaemonPID(metadata.serviceIdentifier),
    );
  }

  Future<_BundleMetadata> _readBundleMetadata(Directory app) async {
    final plist = File(path.join(app.path, "Contents", "Info.plist"));
    await _requireRegularFile(plist.path);
    final metadata = _BundleMetadata(
      bundleIdentifier: await _plistValue(plist, "CFBundleIdentifier"),
      version: await _plistValue(plist, "CFBundleShortVersionString"),
      build: await _plistValue(plist, "CFBundleVersion"),
      executable: await _plistValue(plist, "CFBundleExecutable"),
      serviceIdentifier: await _plistValue(
        plist,
        "DesktopUpdaterInstallHelperServiceID",
      ),
    );
    if (metadata.executable != _executableName ||
        metadata.serviceIdentifier != _serviceIdentifier) {
      throw const _RecoveryFailure("bundle-authority-mismatch");
    }
    return metadata;
  }

  Future<void> _verifyPackage(File pkg) async {
    await _runChecked(
      "/usr/sbin/pkgutil",
      ["--check-signature", pkg.path],
      "package-signature-invalid",
    );
    await _runChecked(
      "/usr/sbin/spctl",
      ["--assess", "--type", "install", "--verbose=2", pkg.path],
      "package-gatekeeper-rejected",
    );
    await _runChecked(
      "/usr/bin/xcrun",
      ["stapler", "validate", pkg.path],
      "package-staple-invalid",
    );
  }

  Future<void> _verifyCodeSignature(String target, {required bool deep}) async {
    await _runChecked(
      "/usr/bin/codesign",
      ["--verify", if (deep) "--deep", "--strict", "--verbose=2", target],
      "strict-signature-invalid",
    );
    final details = await _runChecked(
      "/usr/bin/codesign",
      ["-dv", "--verbose=4", target],
      "signature-details-unavailable",
    );
    if (!RegExp(
          "^TeamIdentifier=${RegExp.escape(_teamIdentifier)}\$",
          multiLine: true,
        ).hasMatch(details) ||
        !RegExp(r"^CodeDirectory .*flags=.*\(runtime\)", multiLine: true)
            .hasMatch(details)) {
      throw const _RecoveryFailure("team-or-runtime-mismatch");
    }
  }

  Future<String> _receiptVersion() async {
    final output = await _runChecked(
      "/usr/sbin/pkgutil",
      ["--pkg-info", _receiptIdentifier],
      "receipt-missing",
    );
    final packageID = RegExp(r"^package-id: (\S+)\s*$", multiLine: true)
        .firstMatch(output)
        ?.group(1);
    final version = RegExp(r"^version: (\S+)\s*$", multiLine: true)
        .firstMatch(output)
        ?.group(1);
    if (packageID != _receiptIdentifier || version == null) {
      throw const _RecoveryFailure("receipt-identity-mismatch");
    }
    return version;
  }

  void _validateEvidence(Map<String, Object?> evidence) {
    const fields = {
      "schemaVersion",
      "status",
      "gitCommit",
      "artifactSHA256",
      "notarizationSubmissionId",
      "bundleIdentifier",
      "receiptIdentifier",
      "teamIdentifier",
      "artifactKind",
      "launchMode",
      "minimumUpdaterVersion",
      "version",
      "build",
      "receiptVersion",
      "crashPoint",
      "managerObservedLive",
      "stageRetainedWhileManagerLive",
      "concurrentMutationObserved",
      "finalState",
      "verifiedOutcome",
      "fixedInstallerAuthority",
      "stageRemovedAfterCompletion",
      "rootOwnershipVerified",
      "signaturesVerified",
      "launchDaemonActive",
    };
    if (evidence.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(evidence.keys.toSet()).isNotEmpty ||
        evidence["schemaVersion"] != 1 ||
        evidence["status"] != "verified locally" ||
        evidence["bundleIdentifier"] != _bundleIdentifier ||
        evidence["receiptIdentifier"] != _receiptIdentifier ||
        evidence["teamIdentifier"] != _teamIdentifier ||
        evidence["artifactKind"] != _artifactKind ||
        evidence["launchMode"] != _launchMode ||
        evidence["minimumUpdaterVersion"] != _minimumUpdaterVersion ||
        evidence["managerObservedLive"] != true ||
        evidence["stageRetainedWhileManagerLive"] != true ||
        evidence["concurrentMutationObserved"] != false ||
        evidence["finalState"] != "completed" ||
        evidence["verifiedOutcome"] != "newTarget" ||
        evidence["stageRemovedAfterCompletion"] != true ||
        evidence["rootOwnershipVerified"] != true ||
        evidence["signaturesVerified"] != true ||
        evidence["launchDaemonActive"] != true) {
      throw const _RecoveryFailure("evidence-schema-invalid");
    }
    final encoded = jsonEncode(evidence);
    if (encoded.contains("/private/") ||
        encoded.contains("/Users/") ||
        encoded.contains("BEGIN ") ||
        encoded.contains("commandLine") ||
        encoded.contains("managerPID") ||
        encoded.contains("managerStartIdentity") ||
        encoded.contains("stagePath") ||
        encoded.contains("helperLog")) {
      throw const _RecoveryFailure("evidence-not-sanitized");
    }
  }

  Future<void> _writeEvidence(Map<String, Object?> evidence) async {
    final parent = request.evidence.parent;
    await parent.create(recursive: true);
    await _requireDirectory(parent.path);
    final resolvedWorkspace = await Directory.current.resolveSymbolicLinks();
    final expectedParent = path.join(
      resolvedWorkspace,
      "reports",
      "macos-privileged-updater",
    );
    if (await parent.resolveSymbolicLinks() != expectedParent) {
      throw const _RecoveryFailure("evidence-parent-symlinked");
    }
    if (await FileSystemEntity.type(
          request.evidence.path,
          followLinks: false,
        ) ==
        FileSystemEntityType.link) {
      throw const _RecoveryFailure("evidence-output-symlink");
    }
    final temporary = File("${request.evidence.path}.tmp");
    if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const _RecoveryFailure("evidence-temporary-exists");
    }
    await temporary.writeAsString(
      "${const JsonEncoder.withIndent("  ").convert(evidence)}\n",
      flush: true,
    );
    await temporary.rename(request.evidence.path);
  }
}

extension on Directory {
  Directory subdirectory(String name) =>
      Directory("${this.path}${Platform.pathSeparator}$name");
}

Future<String> _plistValue(File plist, String key) async {
  final result = await _runChecked(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", plist.path],
    "plist-value-invalid",
  );
  final value = result.trim();
  if (value.isEmpty || value.contains("\n")) {
    throw const _RecoveryFailure("plist-value-invalid");
  }
  return value;
}

Future<bool> _plistHasKey(File plist, String key) async {
  final result = await Process.run(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", plist.path],
  );
  return result.exitCode == 0;
}

Future<String> _runChecked(
  String executable,
  List<String> arguments,
  String failureClass,
) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) throw _RecoveryFailure(failureClass);
  return "${result.stdout}\n${result.stderr}";
}

Future<void> _requireDirectory(String value) async {
  if (await FileSystemEntity.type(value, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const _RecoveryFailure("required-directory-invalid");
  }
}

Future<void> _requireRegularFile(String value) async {
  if (await FileSystemEntity.type(value, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const _RecoveryFailure("required-file-invalid");
  }
}

Future<String> _sha256(File file) async =>
    crypto.sha256.convert(await file.readAsBytes()).toString();

Future<String> _nodeIdentity(String value) async {
  final identity = (await _runChecked(
    "/usr/bin/stat",
    ["-f", "%d:%i", value],
    "node-identity-unavailable",
  ))
      .trim();
  if (!RegExp(r"^[0-9]+:[0-9]+$").hasMatch(identity)) {
    throw const _RecoveryFailure("node-identity-invalid");
  }
  return identity;
}

String? _processStartIdentity(int pid) {
  const procPIDTBSDInfo = 3;
  const procBSDInfoSize = 136;
  const startSecondsOffset = 120;
  const startMicrosecondsOffset = 128;
  if (pid <= 0) return null;
  final buffer = _malloc(procBSDInfoSize);
  if (buffer.address == 0) return null;
  try {
    final read = _procPIDInfo(
      pid,
      procPIDTBSDInfo,
      0,
      buffer,
      procBSDInfoSize,
    );
    if (read == procBSDInfoSize) {
      final bytes = buffer.cast<Uint8>();
      final seconds = (bytes + startSecondsOffset).cast<Uint64>().value;
      final microseconds =
          (bytes + startMicrosecondsOffset).cast<Uint64>().value;
      return "macos:$seconds:$microseconds";
    }
  } finally {
    _free(buffer);
  }
  return _kernProcessStartIdentity(pid);
}

String? _kernProcessStartIdentity(int pid) {
  const ctlKern = 1;
  const kernProc = 14;
  const kernProcPID = 1;
  const timevalSize = 16;
  if (pid <= 0) return null;
  final mib = _malloc(4 * sizeOf<Int32>()).cast<Int32>();
  final outputSize = _malloc(sizeOf<UintPtr>()).cast<UintPtr>();
  if (mib.address == 0 || outputSize.address == 0) {
    if (mib.address != 0) _free(mib.cast<Void>());
    if (outputSize.address != 0) _free(outputSize.cast<Void>());
    return null;
  }
  Pointer<Void> output = nullptr;
  try {
    mib[0] = ctlKern;
    mib[1] = kernProc;
    mib[2] = kernProcPID;
    mib[3] = pid;
    outputSize.value = 0;
    if (_sysctl(mib, 4, nullptr, outputSize, nullptr, 0) != 0 ||
        outputSize.value < timevalSize) {
      return null;
    }
    output = _malloc(outputSize.value);
    if (output.address == 0 ||
        _sysctl(mib, 4, output, outputSize, nullptr, 0) != 0 ||
        outputSize.value < timevalSize) {
      return null;
    }
    final bytes = output.cast<Uint8>();
    final seconds = bytes.cast<Uint64>().value;
    final microseconds = (bytes + sizeOf<Uint64>()).cast<Int32>().value;
    if (seconds <= 0 || microseconds < 0 || microseconds >= 1000000) {
      return null;
    }
    return "macos:$seconds:$microseconds";
  } finally {
    if (output.address != 0) _free(output);
    _free(outputSize.cast<Void>());
    _free(mib.cast<Void>());
  }
}

String? _processExecutablePath(int pid) {
  const bufferSize = 4096;
  if (pid <= 0) return null;
  final buffer = _malloc(bufferSize);
  if (buffer.address == 0) return null;
  try {
    final read = _procPIDPath(pid, buffer, bufferSize);
    if (read <= 0 || read > bufferSize) return null;
    final bytes = buffer.cast<Uint8>().asTypedList(read);
    final terminator = bytes.indexOf(0);
    final value = utf8.decode(
      terminator < 0 ? bytes : bytes.sublist(0, terminator),
      allowMalformed: false,
    );
    return path.isAbsolute(value) ? value : null;
  } on FormatException {
    return null;
  } finally {
    _free(buffer);
  }
}

String? macOSProcessStartIdentityForTesting(int pid) =>
    _processStartIdentity(pid);

String? macOSKernProcessStartIdentityForTesting(int pid) =>
    _kernProcessStartIdentity(pid);

bool macOSFixedInstallerArgumentsForTesting(
  String command,
  String transactionID,
) =>
    _hasFixedInstallerArguments(command, transactionID);

String? macOSProcessExecutablePathForTesting(int pid) =>
    _processExecutablePath(pid);

bool _hasFixedInstallerArguments(String command, String transactionID) {
  final pattern = RegExp(
    r"^/usr/sbin/installer -pkg "
    r"/Library/PrivilegedHelperTools/\.desktop-updater-stages-"
    r"[0-9a-f]{64}/desktop-updater-stage-"
    "${RegExp.escape(transactionID)}"
    r"/installer\.pkg -target /$",
  );
  return pattern.hasMatch(command);
}

final class _SmokeServer {
  const _SmokeServer({
    required this.server,
    required this.root,
    required this.archiveURL,
    required this.publicKeyBase64,
  });

  static Future<_SmokeServer> open({
    required File artifact,
    required String version,
    required int build,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final root = await Directory.systemTemp.createTemp("macos_pkg_recovery_");
    final base = Uri.parse("http://127.0.0.1:${server.port}");
    final bytes = await artifact.readAsBytes();
    final descriptor = await smoke_server.signedDescriptor(
      platform: "macos",
      artifactKind: _artifactKind,
      packageId: _bundleIdentifier,
      appName: path.basename(_targetPath),
      version: version,
      buildNumber: build,
      artifactURL: base.resolve("/artifact.pkg"),
      artifactBytes: bytes,
      allowUnsignedArtifact: false,
      publisherThumbprint: null,
    );
    final install = descriptor["install"] as Map<String, dynamic>;
    final pkg = install["macosPkg"] as Map<String, dynamic>;
    if (descriptor["minimumUpdaterVersion"] != _minimumUpdaterVersion ||
        pkg["launchMode"] != _launchMode) {
      await server.close(force: true);
      await root.delete(recursive: true);
      throw const _RecoveryFailure("release-authority-invalid");
    }
    final index = await smoke_server.signedIndex(
      appName: path.basename(_targetPath),
      version: version,
      buildNumber: build,
      platform: "macos",
      releaseURL: base.resolve("/release.json"),
    );
    final indexFile = File(path.join(root.path, "app-archive.json"));
    final descriptorFile = File(path.join(root.path, "release.json"));
    await indexFile.writeAsString(jsonEncode(index));
    await descriptorFile.writeAsString(jsonEncode(descriptor));
    final publicKey = await smoke_server.smokeKeyPair().then(
          (pair) => pair.extractPublicKey(),
        );
    server.listen((request) {
      smoke_server.serveRequest(
        request,
        files: {
          "/app-archive.json": indexFile,
          "/release.json": descriptorFile,
          "/artifact.pkg": artifact,
        },
        shutdownToken: "unused",
        onShutdown: () {},
      );
    });
    return _SmokeServer(
      server: server,
      root: root,
      archiveURL: base.resolve("/app-archive.json"),
      publicKeyBase64: base64Encode(publicKey.bytes),
    );
  }

  final HttpServer server;
  final Directory root;
  final Uri archiveURL;
  final String publicKeyBase64;

  Future<void> close() async {
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _ProcessStartIdentity {
  const _ProcessStartIdentity({required this.pid, required this.startIdentity});

  final int pid;
  final String startIdentity;
}

final class _StageSnapshot {
  const _StageSnapshot({
    required this.path,
    required this.nodeIdentity,
    required this.installerSHA256,
  });

  final String path;
  final String nodeIdentity;
  final String installerSHA256;
}

final class _TransactionEvent {
  const _TransactionEvent({
    required this.event,
    required this.state,
    required this.resultCode,
  });

  final String event;
  final String state;
  final String resultCode;
}

final class _BundleMetadata {
  const _BundleMetadata({
    required this.bundleIdentifier,
    required this.version,
    required this.build,
    required this.executable,
    required this.serviceIdentifier,
  });

  final String bundleIdentifier;
  final String version;
  final String build;
  final String executable;
  final String serviceIdentifier;
}

final class _InstalledTarget {
  const _InstalledTarget({
    required this.version,
    required this.build,
    required this.receiptVersion,
    required this.launchDaemonPID,
  });

  final String version;
  final String build;
  final String receiptVersion;
  final int? launchDaemonPID;
}

final class _RuntimeResult {
  const _RuntimeResult({required this.exitCode, required this.output});

  final int exitCode;
  final String output;
}

final class _RecoveryFailure implements Exception {
  const _RecoveryFailure(this.failureClass);

  final String failureClass;
}
