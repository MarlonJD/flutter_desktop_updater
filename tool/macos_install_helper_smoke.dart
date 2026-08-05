import "dart:async";
import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:desktop_updater/src/release_cli/sign_command.dart";
import "package:path/path.dart" as path;

const _smokePublicKeyId = "native-runtime-smoke-stable";
const _hostCommand = "--desktop-updater-smappservice-smoke";
const _hostPhases = <String>{
  "register",
  "prepareOnly",
  "commit",
  "recover",
  "query",
};
const _appEnvironment = "DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_APP";
const _stagedAppEnvironment = "DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_STAGED_APP";
const _protectedSmokeRoot = "/Applications";

Future<void> main(List<String> arguments) async {
  try {
    if (!Platform.isMacOS) {
      throw StateError("macOS install-helper smoke requires a macOS host");
    }
    final mode = _option(arguments, "--mode");
    switch (mode) {
      case "unprivileged":
        await _runUnprivileged();
      case "privileged":
        await _runPrivileged();
      default:
        throw const UsageException(
          "Usage: dart run tool/macos_install_helper_smoke.dart "
          "--mode <unprivileged|privileged>",
        );
    }
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = error is UsageException ? 64 : 1;
  }
}

Future<void> _runUnprivileged() async {
  final root = _repositoryRoot();
  await _runChecked(
    "swift",
    [
      "test",
      "--package-path",
      "macos/install_helper",
      "--filter",
      "MacFileTransactionTests.testUnprivilegedSmoke",
    ],
    workingDirectory: root.path,
  );
  await _runChecked(
    "swift",
    [
      "test",
      "--package-path",
      "macos/install_helper",
      "--filter",
      "HelperVersionTests.testBuiltHelperExecutableParsesCanonicalRequest",
    ],
    workingDirectory: root.path,
  );
  stdout.writeln(
    jsonEncode({
      "schemaVersion": 1,
      "mode": "unprivileged",
      "canonicalProtocolParsed": true,
      "recoverableSwapExecuted": true,
    }),
  );
}

Future<void> _runPrivileged() async {
  final app = await _requiredApp(_appEnvironment);
  final stagedSource = await _requiredApp(_stagedAppEnvironment);
  final appMetadata = await _bundleMetadata(app);
  final stagedMetadata = await _bundleMetadata(stagedSource);
  _validateSmokeApplications(
    app: app,
    stagedApp: stagedSource,
    appMetadata: appMetadata,
    stagedMetadata: stagedMetadata,
  );
  final targetOwnership = await _bundleOwnership(app, appMetadata);
  if (targetOwnership != "0:0") {
    throw StateError(
      "SMAppService smoke target must be root:wheel before mutation; "
      "found $targetOwnership",
    );
  }
  final stagedSourceOwnership = await _bundleOwnership(
    stagedSource,
    stagedMetadata,
  );
  if (stagedSourceOwnership == targetOwnership) {
    throw StateError(
      "SMAppService smoke stage must exercise ownership normalization",
    );
  }
  final stagedEndpointIdentity = await _sha256File(
    File(
      path.join(
        stagedSource.path,
        "Contents",
        "Helpers",
        "DesktopUpdaterInstallHelper",
      ),
    ),
  );

  final serviceIdentifier = await _plistString(
    app,
    "DesktopUpdaterInstallHelperServiceID",
  );
  if (!_dottedIdentifier.hasMatch(serviceIdentifier)) {
    throw StateError("signed app has an invalid SMAppService daemon identity");
  }
  final host = File(
    path.join(app.path, "Contents", "MacOS", appMetadata.executable),
  );
  if (!await host.exists()) {
    throw StateError("repository smoke host executable does not exist");
  }

  await _verifyPackagedDaemon(
    app: app,
    serviceIdentifier: serviceIdentifier,
  );
  final registrationEvidence = await _runHost(host, phase: "register");
  if (registrationEvidence["schemaVersion"] != 1 ||
      registrationEvidence["mode"] != "privileged" ||
      registrationEvidence["phase"] != "register" ||
      registrationEvidence["targetParentWritable"] != false) {
    throw StateError(
      "SMAppService host returned invalid registration evidence",
    );
  }
  final serviceStatus = registrationEvidence["serviceStatus"];
  if (serviceStatus != "enabled") {
    throw StateError(
      serviceStatus == "requiresApproval"
          ? "SMAppService daemon requires admin approval in System Settings "
              "> General > Login Items & Extensions"
          : "SMAppService daemon is not enabled: $serviceStatus",
    );
  }
  final stage = await _createSignedStage(
    stagedSource: stagedSource,
    metadata: stagedMetadata,
  );
  var stageCanBeRemoved = false;
  try {
    final prepareEvidence = await _runHost(
      host,
      phase: "prepareOnly",
      arguments: [
        "--stage-root",
        stage.root.path,
        "--staged-app",
        stage.stagedApp.path,
      ],
    );
    _expectHostEvidence(prepareEvidence, phase: "prepareOnly");
    final recoveryTransactionID = _transactionID(prepareEvidence);
    final endpointIdentity = _endpointIdentity(prepareEvidence);

    final servicePIDBeforeCrash = await _servicePID(serviceIdentifier);
    if (servicePIDBeforeCrash == null) {
      throw StateError("privileged daemon is not running after prepareInstall");
    }
    await _killPrivilegedDaemon(serviceIdentifier);
    await _waitForServicePIDChange(
      serviceIdentifier,
      previousPID: servicePIDBeforeCrash,
    );

    final recoveryEvidence = await _runHost(
      host,
      phase: "recover",
      arguments: ["--transaction-id", recoveryTransactionID],
    );
    _expectHostEvidence(recoveryEvidence, phase: "recover");
    if (recoveryEvidence["transactionState"] != "rolledBack" ||
        recoveryEvidence["resultCode"] != "succeeded" ||
        recoveryEvidence["verifiedOutcome"] != "oldTarget" ||
        recoveryEvidence["recoveredSwap"] != true ||
        _endpointIdentity(recoveryEvidence) != endpointIdentity) {
      throw StateError("privileged recovery did not verify the old target");
    }
    final servicePIDAfterRecovery = await _servicePID(serviceIdentifier);
    if (servicePIDAfterRecovery == null ||
        servicePIDAfterRecovery == servicePIDBeforeCrash) {
      throw StateError("privileged daemon did not restart for recovery");
    }
    await _expectInstalledVersion(app, appMetadata);
    await _expectBundleOwnership(app, appMetadata, targetOwnership);

    final gate = File(path.join(stage.parent.path, "commit-exit-gate"));
    final commit = await _startGatedCommit(
      host,
      stage: stage,
      gate: gate,
    );
    final commitEvidence = commit.evidence;
    _expectHostEvidence(commitEvidence, phase: "commit");
    if (commitEvidence["commitAccepted"] != true ||
        commitEvidence["transactionState"] != "commitAccepted" ||
        _endpointIdentity(commitEvidence) != endpointIdentity) {
      await commit.abort();
      throw StateError("privileged commit was not accepted over XPC");
    }
    final commitTransactionID = _transactionID(commitEvidence);

    final activeQueryEvidence = await _runHost(
      host,
      phase: "query",
      arguments: ["--transaction-id", commitTransactionID],
    );
    _expectHostEvidence(activeQueryEvidence, phase: "query");
    if (activeQueryEvidence["transactionState"] != "prepared" ||
        activeQueryEvidence["resultCode"] != "recoveryRequired" ||
        _endpointIdentity(activeQueryEvidence) != endpointIdentity) {
      await commit.abort();
      throw StateError(
        "active transaction query did not use authenticated privileged state",
      );
    }

    await commit.release();
    await _waitForInstalledUpdate(app, stagedMetadata);
    await _expectBundleOwnership(app, stagedMetadata, targetOwnership);
    final completedQueryEvidence = await _runHost(
      File(
        path.join(app.path, "Contents", "MacOS", stagedMetadata.executable),
      ),
      phase: "query",
      arguments: ["--transaction-id", commitTransactionID],
    );
    _expectHostEvidence(completedQueryEvidence, phase: "query");
    if (completedQueryEvidence["transactionState"] != "completed" ||
        completedQueryEvidence["resultCode"] != "succeeded" ||
        _endpointIdentity(completedQueryEvidence) != stagedEndpointIdentity) {
      throw StateError("completed privileged transaction was not queryable");
    }
    final servicePIDAfterUpdate = await _servicePID(serviceIdentifier);
    if (servicePIDAfterUpdate == null ||
        servicePIDAfterUpdate == servicePIDAfterRecovery) {
      throw StateError(
        "privileged daemon did not restart from the installed update",
      );
    }
    await _launchctlPrint(serviceIdentifier);
    stageCanBeRemoved = true;

    stdout.writeln(
      jsonEncode({
        "schemaVersion": 1,
        "mode": "privileged",
        "serviceIdentifier": serviceIdentifier,
        "privilegedDaemonExecuted": true,
        "authenticatedXPC": true,
        "helperEndpointIdentitySha256": endpointIdentity,
        "updatedHelperEndpointIdentitySha256": stagedEndpointIdentity,
        "targetOwnership": targetOwnership,
        "stagedSourceOwnership": stagedSourceOwnership,
        "servicePIDBeforeCrash": servicePIDBeforeCrash,
        "servicePIDAfterRecovery": servicePIDAfterRecovery,
        "servicePIDAfterUpdate": servicePIDAfterUpdate,
        "recoveryTransactionId": recoveryTransactionID,
        "commitTransactionId": commitTransactionID,
        "recoveryState": "rolledBack",
        "commitState": "completed",
        "recoverableSwapExecuted": true,
      }),
    );
  } finally {
    if (stageCanBeRemoved && await stage.parent.exists()) {
      await stage.parent.delete(recursive: true);
    } else if (await stage.parent.exists()) {
      stderr.writeln(
        "preserved failed SMAppService smoke stage: ${stage.parent.path}",
      );
    }
  }
}

Future<_StagedSmokeUpdate> _createSignedStage({
  required Directory stagedSource,
  required _BundleMetadata metadata,
}) async {
  final parent = await Directory.systemTemp.createTemp(
    "desktop_updater_smappservice_smoke_",
  );
  final root = await createOwnedStagingDirectory(parent: parent);
  final stagedApp =
      Directory(path.join(root.path, path.basename(stagedSource.path)));
  await _runChecked(
    "/usr/bin/ditto",
    [stagedSource.path, stagedApp.path],
  );
  final artifact = File(
    path.join(root.path, ".desktop_updater_artifact.zip"),
  );
  await _runChecked(
    "/usr/bin/ditto",
    [
      "-c",
      "-k",
      "--sequesterRsrc",
      "--keepParent",
      stagedSource.path,
      artifact.path,
    ],
  );
  final artifactSHA256 = await crypto.sha256.bind(artifact.openRead()).first;
  final descriptor = File(
    path.join(root.path, ".desktop_updater_release_manifest.json"),
  );
  await descriptor.writeAsString(
    "${const JsonEncoder.withIndent("  ").convert({
          "schemaVersion": 3,
          "packageId": metadata.packageID,
          "appName": path.basename(stagedSource.path),
          "version": metadata.version,
          "buildNumber": metadata.buildNumber,
          "platform": "macos",
          "channel": "stable",
          "artifact": {
            "kind": "zip",
            "url": Uri(
              scheme: "https",
              host: "smoke.invalid",
              pathSegments: ["desktop-updater-smappservice.zip"],
            ).toString(),
            "sha256": artifactSHA256.toString(),
            "length": await artifact.length(),
          },
          "install": {"strategy": "wholeBundleReplace"},
          "minimumUpdaterVersion": "2.0.0",
          "minimumOS": {"macos": "13.0"},
          "generatedAt": DateTime.now().toUtc().toIso8601String(),
        })}\n",
    flush: true,
  );
  await ReleaseDescriptorSigner().sign(
    releaseFile: descriptor,
    publicKeyId: _smokePublicKeyId,
    privateKeyBase64: base64Encode(
      List<int>.generate(32, (index) => 255 - index),
    ),
  );
  final descriptorJSON = jsonDecode(await descriptor.readAsString());
  final nonce = path.basename(root.path).substring(
        desktopUpdaterStagingPrefix.length,
      );
  await writeStagedUpdateProvenance(
    stageRoot: root,
    nonce: nonce,
    packageId: metadata.packageID,
    descriptorSha256: canonicalJsonSha256(descriptorJSON),
    artifactSha256: artifactSHA256.toString(),
  );
  return _StagedSmokeUpdate(parent: parent, root: root, stagedApp: stagedApp);
}

Future<_GatedHostProcess> _startGatedCommit(
  File host, {
  required _StagedSmokeUpdate stage,
  required File gate,
}) async {
  if (await gate.exists()) {
    await gate.delete();
  }
  final process = await Process.start(host.path, [
    _hostCommand,
    "commit",
    "--stage-root",
    stage.root.path,
    "--staged-app",
    stage.stagedApp.path,
    "--exit-gate",
    gate.path,
  ]);
  final evidenceCompleter = Completer<Map<String, Object?>>();
  final stderrBuffer = StringBuffer();
  final stdoutSubscription = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    stdout.writeln(line);
    if (!evidenceCompleter.isCompleted && line.trimLeft().startsWith("{")) {
      try {
        evidenceCompleter.complete(_lastJsonObject(line));
      } on Object {
        // Flutter may emit unrelated structured diagnostics before the host.
      }
    }
  });
  final stderrSubscription =
      process.stderr.transform(utf8.decoder).listen((chunk) {
    stderrBuffer.write(chunk);
    stderr.write(chunk);
  });
  try {
    final evidence = await evidenceCompleter.future.timeout(
      const Duration(seconds: 90),
    );
    return _GatedHostProcess(
      process: process,
      gate: gate,
      evidence: evidence,
      stderrBuffer: stderrBuffer,
      stdoutSubscription: stdoutSubscription,
      stderrSubscription: stderrSubscription,
    );
  } on Object {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
    rethrow;
  }
}

Future<Map<String, Object?>> _runHost(
  File host, {
  required String phase,
  List<String> arguments = const [],
}) async {
  if (!_hostPhases.contains(phase)) {
    throw ArgumentError.value(phase, "phase", "unsupported host phase");
  }
  final result =
      await _runChecked(host.path, [_hostCommand, phase, ...arguments]);
  return _lastJsonObject(result.stdout as String);
}

void _expectHostEvidence(
  Map<String, Object?> evidence, {
  required String phase,
}) {
  if (evidence["schemaVersion"] != 1 ||
      evidence["mode"] != "privileged" ||
      evidence["phase"] != phase ||
      evidence["authenticatedXPC"] != true ||
      evidence["targetParentWritable"] != false ||
      !_transactionIDPattern
          .hasMatch(evidence["transactionId"] as String? ?? "") ||
      !_sha256Pattern.hasMatch(
        evidence["helperEndpointIdentitySha256"] as String? ?? "",
      )) {
    throw StateError("privileged host returned invalid $phase evidence");
  }
}

String _transactionID(Map<String, Object?> evidence) =>
    evidence["transactionId"]! as String;

String _endpointIdentity(Map<String, Object?> evidence) =>
    evidence["helperEndpointIdentitySha256"]! as String;

Future<void> _verifyPackagedDaemon({
  required Directory app,
  required String serviceIdentifier,
}) async {
  final oneShot = File(
    path.join(
      app.path,
      "Contents",
      "Helpers",
      "DesktopUpdaterInstallHelper",
    ),
  );
  final plistName = await _plistString(
    app,
    "DesktopUpdaterInstallHelperLaunchDaemonPlistName",
  );
  if (plistName != "$serviceIdentifier.plist") {
    throw StateError("signed app has an invalid LaunchDaemon plist name");
  }
  final launchDaemon = File(
    path.join(
      app.path,
      "Contents",
      "Library",
      "LaunchDaemons",
      plistName,
    ),
  );
  if (!await oneShot.exists() || !await launchDaemon.exists()) {
    throw StateError("signed app is missing its bundled privileged daemon");
  }
  if (await oneShot.length() == 0) {
    throw StateError("bundled privileged daemon executable is empty");
  }
  if (await _plistFileString(launchDaemon, "Label") != serviceIdentifier ||
      await _plistFileString(launchDaemon, "BundleProgram") !=
          "Contents/Helpers/DesktopUpdaterInstallHelper") {
    throw StateError("bundled LaunchDaemon metadata is invalid");
  }
  await _expectMissingPlistKey(launchDaemon, "Program");
  await _expectMissingPlistKey(launchDaemon, "ProgramArguments");
  for (final target in [app.path, oneShot.path]) {
    await _runChecked(
      "/usr/bin/codesign",
      ["--verify", "--strict", "--verbose=2", target],
    );
  }
}

Future<Directory> _requiredApp(String environmentName) async {
  final value = _requiredEnvironment(environmentName);
  if (await FileSystemEntity.type(value, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError(
      "SMAppService smoke $environmentName app is not a real directory",
    );
  }
  return Directory(await Directory(value).resolveSymbolicLinks());
}

void _validateSmokeApplications({
  required Directory app,
  required Directory stagedApp,
  required _BundleMetadata appMetadata,
  required _BundleMetadata stagedMetadata,
}) {
  if (path.dirname(app.path) != _protectedSmokeRoot ||
      path.basename(app.path) != "Desktop Updater Smoke.app") {
    throw StateError(
      "SMAppService smoke target must be installed directly under "
      "$_protectedSmokeRoot as Desktop Updater Smoke.app",
    );
  }
  if (path.basename(app.path) != path.basename(stagedApp.path) ||
      appMetadata.packageID != stagedMetadata.packageID ||
      appMetadata.executable != stagedMetadata.executable) {
    throw StateError("installed and staged smoke apps do not share identity");
  }
  if (appMetadata.version == stagedMetadata.version &&
      appMetadata.buildNumber == stagedMetadata.buildNumber) {
    throw StateError("staged smoke app must be a distinct update");
  }
}

Future<_BundleMetadata> _bundleMetadata(Directory app) async {
  final buildText = await _plistString(app, "CFBundleVersion");
  final build = int.tryParse(buildText);
  if (build == null || build < 0) {
    throw StateError("app has an invalid CFBundleVersion");
  }
  final executable = await _plistString(app, "CFBundleExecutable");
  if (!_simpleComponent.hasMatch(executable) || executable.contains("\u0000")) {
    throw StateError("app has an invalid CFBundleExecutable");
  }
  return _BundleMetadata(
    packageID: await _plistString(app, "CFBundleIdentifier"),
    executable: executable,
    version: await _plistString(app, "CFBundleShortVersionString"),
    buildNumber: build,
  );
}

Future<String> _plistString(Directory app, String key) async {
  final info = File(path.join(app.path, "Contents", "Info.plist"));
  if (!await info.exists()) {
    throw StateError("app is missing Contents/Info.plist");
  }
  final result = await Process.run(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", info.path],
  );
  if (result.exitCode != 0) {
    throw StateError("app Info.plist is missing $key");
  }
  final value = (result.stdout as String).trim();
  if (value.isEmpty) {
    throw StateError("app Info.plist has an empty $key");
  }
  return value;
}

Future<String> _plistFileString(File plist, String key) async {
  final result = await Process.run(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", plist.path],
  );
  final value = (result.stdout as String).trim();
  if (result.exitCode != 0 || value.isEmpty) {
    throw StateError("${plist.path} is missing $key");
  }
  return value;
}

Future<String> _bundleOwnership(
  Directory app,
  _BundleMetadata metadata,
) async {
  final paths = [
    app.path,
    path.join(app.path, "Contents", "MacOS", metadata.executable),
    path.join(
      app.path,
      "Contents",
      "Helpers",
      "DesktopUpdaterInstallHelper",
    ),
  ];
  final ownership = await _pathOwnership(paths.first);
  for (final entry in paths.skip(1)) {
    final candidate = await _pathOwnership(entry);
    if (candidate != ownership) {
      throw StateError(
        "app bundle ownership is inconsistent: $entry is $candidate, "
        "expected $ownership",
      );
    }
  }
  return ownership;
}

Future<String> _pathOwnership(String target) async {
  final result = await Process.run("/usr/bin/stat", ["-f", "%u:%g", target]);
  final ownership = (result.stdout as String).trim();
  if (result.exitCode != 0 || !RegExp(r"^\d+:\d+$").hasMatch(ownership)) {
    throw StateError("could not inspect ownership for $target");
  }
  return ownership;
}

Future<String> _sha256File(File target) async {
  if (!await target.exists()) {
    throw StateError("could not inspect helper identity for ${target.path}");
  }
  return (await crypto.sha256.bind(target.openRead()).first).toString();
}

Future<void> _expectBundleOwnership(
  Directory app,
  _BundleMetadata metadata,
  String expected,
) async {
  final actual = await _bundleOwnership(app, metadata);
  if (actual != expected) {
    throw StateError(
      "privileged update changed target ownership from $expected to $actual",
    );
  }
}

Future<void> _expectMissingPlistKey(File plist, String key) async {
  final result = await Process.run(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", plist.path],
  );
  if (result.exitCode == 0) {
    throw StateError("${plist.path} must not contain $key");
  }
}

Future<void> _expectInstalledVersion(
  Directory app,
  _BundleMetadata expected,
) async {
  final actual = await _bundleMetadata(app);
  if (!actual.matches(expected)) {
    throw StateError("recovery changed the installed target");
  }
}

Future<void> _waitForInstalledUpdate(
  Directory app,
  _BundleMetadata expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final metadata = await _bundleMetadata(app);
      if (metadata.matches(expected)) {
        await _runChecked(
          "/usr/bin/codesign",
          ["--verify", "--deep", "--strict", "--verbose=2", app.path],
        );
        return;
      }
    } on FileSystemException {
      // The target is briefly absent between the durable rename steps.
    } on StateError {
      // Info.plist can be briefly unavailable while the swap is completing.
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException("timed out waiting for privileged target mutation");
}

Future<void> _killPrivilegedDaemon(String serviceIdentifier) async {
  final command = "/bin/launchctl kill SIGKILL system/$serviceIdentifier";
  final script = 'do shell script "$command" with administrator privileges';
  await _runChecked("/usr/bin/osascript", ["-e", script]);
}

Future<void> _waitForServicePIDChange(
  String serviceIdentifier, {
  required int previousPID,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final pid = await _servicePID(serviceIdentifier);
    if (pid == null || pid != previousPID) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException("privileged daemon did not terminate after SIGKILL");
}

Future<int?> _servicePID(String serviceIdentifier) async {
  final result = await Process.run(
    "/bin/launchctl",
    ["print", "system/$serviceIdentifier"],
  );
  if (result.exitCode != 0) {
    return null;
  }
  final match = RegExp(r"^\s*pid = (\d+)\s*$", multiLine: true).firstMatch(
    result.stdout as String,
  );
  return match == null ? null : int.parse(match.group(1)!);
}

Future<void> _launchctlPrint(String serviceIdentifier) {
  return _runChecked(
    "/bin/launchctl",
    ["print", "system/$serviceIdentifier"],
  ).then((_) {});
}

String _requiredEnvironment(String name) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError("missing required environment variable $name");
  }
  return value;
}

String? _option(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) {
    return null;
  }
  return arguments[index + 1];
}

Directory _repositoryRoot() {
  var candidate = File.fromUri(Platform.script).parent.parent;
  while (candidate.parent.path != candidate.path) {
    if (File("${candidate.path}/pubspec.yaml").existsSync() &&
        Directory("${candidate.path}/macos/install_helper").existsSync()) {
      return candidate;
    }
    candidate = candidate.parent;
  }
  throw StateError("could not locate repository root");
}

Future<ProcessResult> _runChecked(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if ((result.stdout as String).isNotEmpty) {
    stdout.write(result.stdout);
  }
  if ((result.stderr as String).isNotEmpty) {
    stderr.write(result.stderr);
  }
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "command exited with ${result.exitCode}",
      result.exitCode,
    );
  }
  return result;
}

Map<String, Object?> _lastJsonObject(String output) {
  for (final line in output.split("\n").reversed) {
    final candidate = line.trim();
    if (!candidate.startsWith("{")) {
      continue;
    }
    final value = jsonDecode(candidate);
    if (value is Map<String, Object?>) {
      return value;
    }
  }
  throw const FormatException("host did not emit JSON smoke evidence");
}

final _dottedIdentifier = RegExp(
  r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
  r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$",
);
final _simpleComponent = RegExp(r"^[^/\\]+$");
final _sha256Pattern = RegExp(r"^[0-9a-f]{64}$");
final _transactionIDPattern = RegExp(
  r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
);

final class _BundleMetadata {
  const _BundleMetadata({
    required this.packageID,
    required this.executable,
    required this.version,
    required this.buildNumber,
  });

  final String packageID;
  final String executable;
  final String version;
  final int buildNumber;

  bool matches(_BundleMetadata other) =>
      packageID == other.packageID &&
      executable == other.executable &&
      version == other.version &&
      buildNumber == other.buildNumber;
}

final class _StagedSmokeUpdate {
  const _StagedSmokeUpdate({
    required this.parent,
    required this.root,
    required this.stagedApp,
  });

  final Directory parent;
  final Directory root;
  final Directory stagedApp;
}

final class _GatedHostProcess {
  const _GatedHostProcess({
    required this.process,
    required this.gate,
    required this.evidence,
    required this.stderrBuffer,
    required this.stdoutSubscription,
    required this.stderrSubscription,
  });

  final Process process;
  final File gate;
  final Map<String, Object?> evidence;
  final StringBuffer stderrBuffer;
  final StreamSubscription<String> stdoutSubscription;
  final StreamSubscription<String> stderrSubscription;

  Future<void> release() async {
    await gate.writeAsString("release\n", flush: true);
    final code = await process.exitCode.timeout(const Duration(seconds: 90));
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
    if (code != 0) {
      throw ProcessException(
        process.toString(),
        const [],
        "gated host exited with $code: $stderrBuffer",
        code,
      );
    }
  }

  Future<void> abort() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
  }
}

final class UsageException implements Exception {
  const UsageException(this.message);

  final String message;

  @override
  String toString() => message;
}
