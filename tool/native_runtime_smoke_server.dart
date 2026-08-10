import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";

import "package:args/args.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:path/path.dart" as path;

const publicKeyId = "native-runtime-smoke-stable";
const maximumArtifactBytes = 512 * 1024 * 1024;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption("artifact", mandatory: true)
    ..addOption("artifact-kind", mandatory: true)
    ..addOption("platform", mandatory: true)
    ..addOption("package-id", defaultsTo: "com.example.native-runtime-smoke")
    ..addOption("app-name", defaultsTo: "NativeRuntimeSmoke")
    ..addOption("version", defaultsTo: "2.7.1")
    ..addOption("build-number", defaultsTo: "271")
    ..addOption("port", defaultsTo: "43892")
    ..addOption("ready-file")
    ..addOption("publisher-thumbprint")
    ..addFlag("allow-unsigned-artifact", negatable: false);
  final options = parser.parse(arguments);
  final artifact = File(options.option("artifact")!);
  if (!await artifact.exists()) {
    throw FileSystemException(
      "Native runtime smoke artifact is missing.",
      artifact.path,
    );
  }
  final artifactLength = await artifact.length();
  if (artifactLength <= 0 || artifactLength > maximumArtifactBytes) {
    throw StateError("Native runtime smoke artifact exceeds its byte bound.");
  }
  final port = int.parse(options.option("port")!);
  if (port <= 0 || port > 65535) {
    throw const FormatException("--port must be between 1 and 65535.");
  }
  final buildNumber = int.parse(options.option("build-number")!);
  final platform = options.option("platform")!;
  final artifactKind = options.option("artifact-kind")!;
  final packageId = options.option("package-id")!;
  final appName = options.option("app-name")!;
  final version = options.option("version")!;
  final extension = path.extension(artifact.path);
  final artifactName = "artifact${extension.isEmpty ? ".bin" : extension}";
  final root = await Directory.systemTemp.createTemp("native_runtime_smoke_");
  final servedArtifact = File(path.join(root.path, artifactName));
  await artifact.copy(servedArtifact.path);

  HttpServer? server;
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  try {
    final stopped = Completer<void>();
    final shutdownToken = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final base = Uri.parse("http://127.0.0.1:$port");
    final artifactBytes = await servedArtifact.readAsBytes();
    final descriptorJson = await signedDescriptor(
      platform: platform,
      artifactKind: artifactKind,
      packageId: packageId,
      appName: appName,
      version: version,
      buildNumber: buildNumber,
      artifactURL: base.resolve("/$artifactName"),
      artifactBytes: artifactBytes,
      allowUnsignedArtifact: options.flag("allow-unsigned-artifact"),
      publisherThumbprint: options.option("publisher-thumbprint"),
    );
    final descriptorFile = File(path.join(root.path, "release.json"));
    await descriptorFile.writeAsString(jsonEncode(descriptorJson));
    final indexFile = File(path.join(root.path, "app-archive.json"));
    final indexJson = await signedIndex(
      appName: appName,
      version: version,
      buildNumber: buildNumber,
      platform: platform,
      releaseURL: base.resolve("/release.json"),
    );
    await indexFile.writeAsString(jsonEncode(indexJson));
    final publicKey =
        await smokeKeyPair().then((pair) => pair.extractPublicKey());
    final ready = {
      "appArchiveUrl": base.resolve("/app-archive.json").toString(),
      "publicKeyId": publicKeyId,
      "publicKeyBase64": base64Encode(publicKey.bytes),
      "publicKeyHex": publicKey.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, "0"))
          .join(),
      "servingRoot": root.path,
      "shutdownToken": shutdownToken,
    };
    final readyPath = options.option("ready-file");
    if (readyPath != null) {
      await File(readyPath).writeAsString(jsonEncode(ready));
    }

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    stdout.writeln(jsonEncode(ready));
    void stop(ProcessSignal _) {
      if (!stopped.isCompleted) stopped.complete();
    }

    subscriptions.add(ProcessSignal.sigint.watch().listen(stop));
    if (!Platform.isWindows) {
      subscriptions.add(ProcessSignal.sigterm.watch().listen(stop));
    }
    server.listen(
      (request) => serveRequest(
        request,
        files: {
          "/app-archive.json": indexFile,
          "/release.json": descriptorFile,
          "/$artifactName": servedArtifact,
        },
        shutdownToken: shutdownToken,
        onShutdown: () {
          if (!stopped.isCompleted) stopped.complete();
        },
      ),
    );
    await stopped.future;
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await server?.close(force: true);
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }
}

Future<Map<String, dynamic>> signedIndex({
  required String appName,
  required String version,
  required int buildNumber,
  required String platform,
  required Uri releaseURL,
}) async {
  final json = <String, dynamic>{
    "schemaVersion": 3,
    "appName": appName,
    "items": [
      {
        "version": version,
        "buildNumber": buildNumber,
        "platform": platform,
        "channel": "stable",
        "mandatory": false,
        "release": releaseURL.toString(),
      },
    ],
    "signature": {
      "algorithm": "ed25519",
      "publicKeyId": publicKeyId,
      "value": "",
    },
  };
  final index = ReleaseIndex.fromJson(json);
  final signature = await Ed25519().sign(
    index.canonicalSignatureBytes(),
    keyPair: await smokeKeyPair(),
  );
  (json["signature"] as Map<String, dynamic>)["value"] =
      base64Encode(signature.bytes);
  return json;
}

Future<Map<String, dynamic>> signedDescriptor({
  required String platform,
  required String artifactKind,
  required String packageId,
  required String appName,
  required String version,
  required int buildNumber,
  required Uri artifactURL,
  required List<int> artifactBytes,
  required bool allowUnsignedArtifact,
  required String? publisherThumbprint,
  String? minimumUpdaterVersion,
}) async {
  final json = <String, dynamic>{
    "schemaVersion": 3,
    "packageId": packageId,
    "appName": appName,
    "version": version,
    "buildNumber": buildNumber,
    "platform": platform,
    "channel": "stable",
    "artifact": {
      "kind": artifactKind,
      "url": artifactURL.toString(),
      "sha256": crypto.sha256.convert(artifactBytes).toString(),
      "length": artifactBytes.length,
    },
    "install": installMetadata(
      platform: platform,
      artifactKind: artifactKind,
      packageId: packageId,
      appName: appName,
      allowUnsignedArtifact: allowUnsignedArtifact,
      publisherThumbprint: publisherThumbprint,
    ),
    "signature": {
      "algorithm": "ed25519",
      "publicKeyId": publicKeyId,
      "value": "",
    },
    "minimumUpdaterVersion": minimumUpdaterVersion ??
        (artifactKind == "pkgInstaller" ? "2.7.0" : "2.0.0"),
    "minimumOS": {platform: minimumOS(platform)},
    "generatedAt": DateTime.now().toUtc().toIso8601String(),
  };
  final descriptor = ReleaseDescriptor.fromJson(json)..validate();
  final signature = await Ed25519().sign(
    descriptor.canonicalSignatureBytes(),
    keyPair: await smokeKeyPair(),
  );
  (json["signature"] as Map<String, dynamic>)["value"] =
      base64Encode(signature.bytes);
  return json;
}

Map<String, dynamic> installMetadata({
  required String platform,
  required String artifactKind,
  required String packageId,
  required String appName,
  required bool allowUnsignedArtifact,
  required String? publisherThumbprint,
}) {
  switch (artifactKind) {
    case "zip":
      return {
        "strategy": platform == "macos"
            ? "wholeBundleReplace"
            : "wholeDirectoryReplace",
      };
    case "dmg":
      if (platform != "macos") throw StateError("DMG smoke requires macOS.");
      return {
        "strategy": "wholeBundleReplace",
        "macosDmg": {
          "appBundleName": appName,
          "verifyPrimarySignature": !allowUnsignedArtifact,
        },
      };
    case "pkgInstaller":
      if (platform != "macos") throw StateError("PKG smoke requires macOS.");
      return {
        "strategy": "pkgInstaller",
        "macosPkg": {
          "launchMode": "privilegedInstallerTool",
          "expectedPackageIds": ["$packageId.pkg"],
          "relaunchAfterInstall": false,
        },
      };
    case "innoInstaller":
      if (platform != "windows" || publisherThumbprint == null) {
        throw StateError("Signed Inno smoke requires a publisher thumbprint.");
      }
      return {
        "strategy": "innoInstaller",
        "inno": {
          "silentArgs": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
          "inheritInstallDirectory": true,
          "logFileName": "native_runtime_inno_smoke.log",
          "relaunchAfterInstall": true,
          "requiresElevation": "auto",
          "authenticode": {
            "required": true,
            "sha256Thumbprints": [publisherThumbprint],
          },
        },
      };
    default:
      throw StateError(
        "Unsupported native runtime smoke artifact: $artifactKind",
      );
  }
}

String minimumOS(String platform) => switch (platform) {
      "macos" => "13.0",
      "windows" => "10.0.19045",
      "linux" => "glibc-2.35",
      _ => throw StateError("Unsupported native runtime smoke platform."),
    };

Future<SimpleKeyPair> smokeKeyPair() {
  return Ed25519().newKeyPairFromSeed(
    List<int>.generate(32, (index) => 255 - index),
  );
}

Future<void> serveRequest(
  HttpRequest request, {
  required Map<String, File> files,
  required String shutdownToken,
  required void Function() onShutdown,
}) async {
  try {
    if (request.uri.path == "/shutdown") {
      if (request.method != "POST" ||
          request.uri.queryParameters["token"] != shutdownToken) {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      request.response.write("stopping");
      onShutdown();
      return;
    }
    if (request.method != "GET" && request.method != "HEAD") {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }
    if (request.uri.path == "/health") {
      request.response.headers.contentType = ContentType.text;
      if (request.method == "GET") request.response.write("ok");
      return;
    }
    final file = files[request.uri.path];
    if (file == null || !await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    final length = await file.length();
    var start = 0;
    var endExclusive = length;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r"^bytes=(\d+)-(\d*)$").firstMatch(range);
      if (match == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return;
      }
      start = int.parse(match.group(1)!);
      endExclusive =
          match.group(2)!.isEmpty ? length : int.parse(match.group(2)!) + 1;
      if (start < 0 ||
          start >= length ||
          endExclusive <= start ||
          endExclusive > length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return;
      }
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        "bytes $start-${endExclusive - 1}/$length",
      );
    }
    request.response.headers.set(HttpHeaders.acceptRangesHeader, "bytes");
    request.response.contentLength = endExclusive - start;
    if (request.method == "GET") {
      await request.response.addStream(file.openRead(start, endExclusive));
    }
  } finally {
    await request.response.close();
  }
}
