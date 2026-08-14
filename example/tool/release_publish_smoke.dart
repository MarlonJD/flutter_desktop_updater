import "dart:async";
import "dart:convert";
import "dart:io";

Future<void> main(List<String> args) async {
  final platform = _argValue(args, "--platform") ?? _hostPlatform();
  final notarize = args.contains("--notarize");
  if (platform == null) {
    stderr.writeln("Unsupported host platform.");
    _usage();
    exit(64);
  }
  if (platform != _hostPlatform()) {
    stderr.writeln(
      "Release publish smoke must run on its target host platform. "
      "Requested $platform on ${_hostPlatform()}.",
    );
    exit(64);
  }
  if (notarize && platform != "macos") {
    stderr.writeln("--notarize is only supported for --platform macos.");
    exit(64);
  }
  if (notarize &&
      Platform.environment["DESKTOP_UPDATER_RUN_NOTARIZED_PUBLISH_E2E"] !=
          "1") {
    stdout.writeln(
      "Skipping notarized release publish smoke. Set "
      "DESKTOP_UPDATER_RUN_NOTARIZED_PUBLISH_E2E=1 to run it.",
    );
    return;
  }

  final projectRoot = Directory.current;
  final packageRoot = projectRoot.parent;
  final tempRoot = await Directory.systemTemp.createTemp(
    "desktop_updater_release_publish_smoke_",
  );
  final webRoot = Directory(_join(tempRoot.path, "web"));
  await webRoot.create(recursive: true);
  final profileFile = File(_join(tempRoot.path, "desktop_updater.keys.json"));
  final secretDataRoot = Directory(_join(tempRoot.path, "release-key-store"));
  final smokeEnvironment = {
    ...Platform.environment,
    if (Platform.isWindows)
      "LOCALAPPDATA": secretDataRoot.path
    else
      "XDG_DATA_HOME": secretDataRoot.path,
  };

  final server = await _StaticServer.bind(webRoot);
  stdout.writeln("Release publish smoke server: ${server.baseUrl}");
  try {
    final configFile = File(_join(tempRoot.path, "desktop_updater.yaml"));
    await configFile.writeAsString(
      _publishConfig(
        baseUrl: server.baseUrl,
        outputRoot: _joinAll([tempRoot.path, "dist", "desktop_updater"]),
        copyCommand: _copyCommand(packageRoot, webRoot),
        notarize: notarize,
      ),
    );

    await _runChecked(
      "dart",
      [
        "run",
        "desktop_updater:release",
        "keygen",
        "--config",
        configFile.path,
        "--key-profile",
        profileFile.path,
      ],
      workingDirectory: projectRoot.path,
      environment: smokeEnvironment,
    );

    final publishArgs = [
      "run",
      "desktop_updater:release",
      "publish",
      "--platform",
      platform,
      "--key-profile",
      profileFile.path,
      "--initialize-feed",
      "--config",
      configFile.path,
      "--version",
      _argValue(args, "--version") ?? "9.9.9",
      "--build-number",
      _argValue(args, "--build-number") ?? "999",
      if (notarize) "--notarize",
    ];
    final result = await _runChecked(
      "dart",
      publishArgs,
      workingDirectory: projectRoot.path,
      environment: smokeEnvironment,
    );
    final output = "${result.stdout}${result.stderr}";
    if (!output.contains("Hosted artifact SHA-256: OK") ||
        !output.contains("OK: Published and validated.")) {
      stderr.writeln(output);
      throw StateError(
        "release publish smoke did not reach hosted validation success.",
      );
    }
    final evidenceRoot =
        Platform.environment["DESKTOP_UPDATER_RELEASE_PUBLISH_EVIDENCE_ROOT"];
    if (evidenceRoot != null && evidenceRoot.trim().isNotEmpty) {
      await _writeEvidenceSnapshot(
        evidenceRoot: Directory(evidenceRoot),
        output: output,
        appBundleName:
            _argValue(args, "--app-bundle-name") ?? "Egas Manager.app",
      );
    }
  } finally {
    await server.close();
    if (Platform.environment["DESKTOP_UPDATER_KEEP_RELEASE_PUBLISH_SMOKE"] ==
        "1") {
      stdout.writeln("Keeping release publish smoke files: ${tempRoot.path}");
    } else {
      await tempRoot.delete(recursive: true);
    }
  }
}

String _publishConfig({
  required Uri baseUrl,
  required String outputRoot,
  required String copyCommand,
  required bool notarize,
}) {
  return """
updates:
  baseUrl: ${_yamlSingleQuoted(baseUrl.toString())}
  output: ${_yamlSingleQuoted(outputRoot)}

customCommand:
  command: ${_yamlSingleQuoted(copyCommand)}
${notarize ? _macOSNotarizationConfig() : ""}
""";
}

String _macOSNotarizationConfig() {
  return """
macos:
  notarize: true
  staple: true
  gatekeeperAssess: true
""";
}

String _copyCommand(Directory packageRoot, Directory webRoot) {
  final script = File(
    _joinAll([
      packageRoot.path,
      "test",
      "e2e",
      "fixtures",
      "upload_commands",
      "copy_updates.dart",
    ]),
  );
  return 'dart "${script.path}" unused "${webRoot.path}"';
}

Future<void> _writeEvidenceSnapshot({
  required Directory evidenceRoot,
  required String output,
  required String appBundleName,
}) async {
  final artifactMatch = RegExp(
    r"(?:^|\n)Artifact:\s*(\S+)",
    multiLine: true,
  ).firstMatch(output);
  final artifactUrl = artifactMatch == null
      ? null
      : Uri.tryParse(artifactMatch.group(1)!);
  if (artifactUrl == null || artifactUrl.pathSegments.isEmpty) {
    throw StateError("publish smoke did not expose an artifact URL");
  }
  final releaseMatch = RegExp(
    r"(?:^|\n)Release:\s*(\S+)",
    multiLine: true,
  ).firstMatch(output);
  final releaseUrl = releaseMatch == null
      ? null
      : Uri.tryParse(releaseMatch.group(1)!);
  if (releaseUrl == null) {
    throw StateError("publish smoke did not expose a release URL");
  }

  final client = HttpClient();
  try {
    final bytes = await _downloadBytes(client, artifactUrl);
    final releaseBytes = await _downloadBytes(client, releaseUrl);
    final release = jsonDecode(utf8.decode(releaseBytes));
    if (release is! Map<String, dynamic>) {
      throw StateError("hosted release descriptor is not an object");
    }
    final releaseAppName = release["appName"];
    final releasePackageId = release["packageId"];
    if (releaseAppName is! String || releasePackageId is! String) {
      throw StateError("hosted release descriptor identity is incomplete");
    }
    final resolvedAppBundleName = releaseAppName.trim().isEmpty
        ? appBundleName
        : releaseAppName.endsWith(".app")
        ? releaseAppName
        : "$releaseAppName.app";
    await evidenceRoot.create(recursive: true);
    final artifact = File(pathJoin(evidenceRoot.path, "hosted-artifact.zip"));
    await artifact.writeAsBytes(bytes, flush: true);
    final preStapleMatch = RegExp(
      r"pre-staple notarization archive SHA-256:\s*([0-9a-f]{64})\s*\(length=(\d+)\)",
    ).firstMatch(output);
    final notaryIds = RegExp(r"macOS app notarization: Accepted \(([^)]+)\)")
        .allMatches(output)
        .map((match) => match.group(1)!)
        .toList();
    await File(pathJoin(evidenceRoot.path, "publish-smoke.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({"artifactPath": artifact.path, "artifactUrl": artifactUrl.toString(), "appBundleName": resolvedAppBundleName, "applicationIdentifier": releasePackageId, "gitCommit": Platform.environment["GITHUB_SHA"], "notarizationSubmissionIds": notaryIds, "preStapleSha256": preStapleMatch?.group(1), "preStapleLength": preStapleMatch == null ? null : int.parse(preStapleMatch.group(2)!)})}\n",
    );
  } finally {
    client.close(force: true);
  }
}

Future<List<int>> _downloadBytes(HttpClient client, Uri url) async {
  final request = await client.getUrl(url);
  final response = await request.close();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException(
      "hosted release download failed with HTTP ${response.statusCode}",
      uri: url,
    );
  }
  final bytes = <int>[];
  await for (final chunk in response) {
    bytes.addAll(chunk);
  }
  return bytes;
}

Future<ProcessResult> _runChecked(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  Map<String, String>? environment,
}) async {
  stdout.writeln("\$ $executable ${arguments.join(" ")}");
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }
  return result;
}

class _StaticServer {
  const _StaticServer(this._server, this._root);

  final HttpServer _server;
  final Directory _root;

  Uri get baseUrl => Uri.parse("http://127.0.0.1:${_server.port}/");

  static Future<_StaticServer> bind(Directory root) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final staticServer = _StaticServer(server, root);
    server.listen(staticServer._handle);
    return staticServer;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final relative = request.uri.pathSegments
        .map(Uri.decodeComponent)
        .where((segment) => segment.isNotEmpty)
        .join(Platform.pathSeparator);
    if (relative.contains("..")) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final file = File(_join(_root.path, relative));
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    request.response.headers.contentLength = await file.length();
    await request.response.addStream(file.openRead());
    await request.response.close();
  }
}

String? _hostPlatform() {
  if (Platform.isMacOS) {
    return "macos";
  }
  if (Platform.isWindows) {
    return "windows";
  }
  if (Platform.isLinux) {
    return "linux";
  }
  return null;
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}

String _yamlSingleQuoted(String value) {
  return "'${value.replaceAll("'", "''")}'";
}

String _join(String left, String right) {
  if (left.endsWith(Platform.pathSeparator)) {
    return "$left$right";
  }
  return "$left${Platform.pathSeparator}$right";
}

String _joinAll(List<String> parts) {
  return parts.reduce(_join);
}

void _usage() {
  stderr.writeln(
    "Usage: dart run tool/release_publish_smoke.dart "
    "[--platform <host-platform>] [--notarize]\n"
    "\n"
    "Runs the user-facing `dart run desktop_updater:release publish` flow, "
    "uploads the generated release to a local static server with a custom "
    "command, and requires hosted validation to pass.\n"
    "\n"
    "For --notarize, set DESKTOP_UPDATER_RUN_NOTARIZED_PUBLISH_E2E=1, "
    "DESKTOP_UPDATER_MACOS_DEVELOPER_ID_APPLICATION, "
    "and DESKTOP_UPDATER_MACOS_NOTARY_PROFILE. An optional "
    "DESKTOP_UPDATER_MACOS_KEYCHAIN enables explicit keychain binding; when "
    "omitted, notarytool uses the default keychain search list. Use "
    "--app-bundle-name and "
    "DESKTOP_UPDATER_RELEASE_PUBLISH_EVIDENCE_ROOT for bound evidence.",
  );
}

String pathJoin(String left, String right) {
  if (left.endsWith(Platform.pathSeparator)) return "$left$right";
  return "$left${Platform.pathSeparator}$right";
}
