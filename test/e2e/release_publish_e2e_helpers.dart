import "dart:io";

import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:path/path.dart" as path;

import "../fixtures/release_publish_project.dart";
import "../fixtures/update_server.dart";

class ReleasePublishE2eFixture {
  const ReleasePublishE2eFixture({
    required this.projectRoot,
    required this.webRoot,
    required this.server,
    required this.platform,
  });

  final Directory projectRoot;
  final Directory webRoot;
  final UpdateServer server;
  final String platform;

  File get manifestFile {
    return File(
      path.join(
        projectRoot.path,
        "dist",
        "desktop_updater",
        ".desktop_updater_publish.json",
      ),
    );
  }

  Directory get distRoot {
    return Directory(path.join(projectRoot.path, "dist", "desktop_updater"));
  }

  Future<void> delete() async {
    await server.close();
    await projectRoot.delete(recursive: true);
  }
}

Future<ReleasePublishE2eFixture> createReleasePublishE2eFixture({
  String providerConfig = "",
  Uri? baseUrl,
}) async {
  final projectRoot =
      await Directory.systemTemp.createTemp("release_publish_e2e_");
  final webRoot = Directory(path.join(projectRoot.path, "web"));
  await webRoot.create();
  final server = await UpdateServer.bind(webRoot);

  await writeReleasePublishFixtureProject(
    root: projectRoot,
    config: """
updates:
  baseUrl: ${baseUrl ?? server.uri}
$providerConfig
""",
  );

  return ReleasePublishE2eFixture(
    projectRoot: projectRoot,
    webRoot: webRoot,
    server: server,
    platform: releasePublishFixturePlatform,
  );
}

Future<void> startDockerComposeServices(List<String> services) async {
  final args = [
    "compose",
    "-f",
    path.join("test", "e2e", "docker", "docker-compose.release-publish.yml"),
    "up",
    "-d",
    "--force-recreate",
    ...services,
  ];
  final result = await Process.run("docker", args);
  if (result.exitCode != 0) {
    throw ProcessException(
      "docker",
      args,
      "${result.stdout}\n${result.stderr}",
      result.exitCode,
    );
  }
}

Future<bool> executableExists(String executable) async {
  final result = await Process.run(
    Platform.isWindows ? "where" : "which",
    [executable],
  );
  return result.exitCode == 0;
}

Future<bool> dockerDaemonAvailable() async {
  if (!await executableExists("docker")) {
    return false;
  }
  final result = await Process.run("docker", ["info"]);
  return result.exitCode == 0;
}

Future<void> chownSftpUploadVolume() async {
  final result = await Process.run(
    "docker",
    ["exec", "docker-sftp-1", "chown", "-R", "1001:100", "/home/deploy/upload"],
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      "docker",
      const [
        "exec",
        "docker-sftp-1",
        "chown",
        "-R",
        "1001:100",
        "/home/deploy/upload",
      ],
      "${result.stdout}\n${result.stderr}",
      result.exitCode,
    );
  }
}

Future<void> configureMinioBucket({
  required String bucket,
  required String endpoint,
  required String accessKey,
  required String secretKey,
}) async {
  final environment = {
    ...Platform.environment,
    "AWS_ACCESS_KEY_ID": accessKey,
    "AWS_SECRET_ACCESS_KEY": secretKey,
    "AWS_DEFAULT_REGION": "us-east-1",
  };
  final headResult = await Process.run(
    "aws",
    [
      "s3api",
      "head-bucket",
      "--bucket",
      bucket,
      "--endpoint-url",
      endpoint,
    ],
    environment: environment,
  );
  if (headResult.exitCode != 0) {
    await _runAws(
      [
        "s3api",
        "create-bucket",
        "--bucket",
        bucket,
        "--endpoint-url",
        endpoint,
      ],
      environment,
    );
  }

  final tempDir = await Directory.systemTemp.createTemp("minio_policy_");
  try {
    final policy = File("${tempDir.path}/policy.json");
    await policy.writeAsString("""
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::$bucket/*"]
    }
  ]
}
""");
    await _runAws(
      [
        "s3api",
        "put-bucket-policy",
        "--bucket",
        bucket,
        "--policy",
        "file://${policy.path}",
        "--endpoint-url",
        endpoint,
      ],
      environment,
    );
  } finally {
    await tempDir.delete(recursive: true);
  }
}

Future<void> _runAws(
  List<String> args,
  Map<String, String> environment,
) async {
  final result = await Process.run("aws", args, environment: environment);
  if (result.exitCode != 0) {
    throw ProcessException(
      "aws",
      args,
      "${result.stdout}\n${result.stderr}",
      result.exitCode,
    );
  }
}

Future<void> waitForPort(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      await socket.close();
      return;
    } on Object catch (error) {
      lastError = error;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  throw StateError("Timed out waiting for localhost:$port. $lastError");
}

Future<void> waitForTcpPrefix(int port, String prefix) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      final line = await socket
          .cast<List<int>>()
          .expand((bytes) => bytes)
          .take(prefix.length)
          .toList()
          .timeout(const Duration(seconds: 1));
      final text = String.fromCharCodes(line);
      if (text == prefix) {
        await socket.close();
        return;
      }
      lastError = "Expected $prefix from localhost:$port, got $text";
    } on Object catch (error) {
      lastError = error;
    } finally {
      socket?.destroy();
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError(
    "Timed out waiting for $prefix on localhost:$port. $lastError",
  );
}

bool get releasePublishE2eEnabled {
  return Platform.environment["DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E"] == "1";
}

Future<StringBuffer> publishFixture(ReleasePublishE2eFixture fixture) async {
  final output = StringBuffer();
  final exitCode = await runReleaseCommand(
    ["publish", "--platform", fixture.platform, "--skip-build-for-test"],
    projectRoot: fixture.projectRoot,
    output: output,
  );
  if (exitCode != 0) {
    throw StateError("release publish failed:\n$output");
  }
  return output;
}

Future<StringBuffer> validateFixture(ReleasePublishE2eFixture fixture) async {
  final output = StringBuffer();
  final exitCode = await runReleaseCommand(
    [
      "validate",
      "--manifest",
      fixture.manifestFile.path,
      "--from-version",
      "2.0.0+200",
    ],
    projectRoot: fixture.projectRoot,
    output: output,
  );
  if (exitCode != 0) {
    throw StateError("release validate failed:\n$output");
  }
  return output;
}

Future<void> copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = path.relative(entity.path, from: source.path);
    final targetPath = path.join(destination.path, relative);
    if (entity is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entity is File) {
      await File(targetPath).parent.create(recursive: true);
      await entity.copy(targetPath);
    }
  }
}
