// Cross-host evidence for signed archive transfer. The seed below is a public
// synthetic fixture, never an application signing credential.
import "dart:convert";
import "dart:io";
import "dart:isolate";

import "package:crypto/crypto.dart" as crypto;
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_manager.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_profile.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_publisher.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:path/path.dart" as path;

final _base = Uri.parse("https://updates.example.invalid/archive-interop/");
const _profileId = "0123456789abcdef0123456789abcdef";
const _platforms = {"macos", "windows", "linux"};

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String _sha(List<int> bytes) => crypto.sha256.convert(bytes).toString();

Future<void> _writeJson(File file, Object value) async {
  await file.parent.create(recursive: true);
  await file
      .writeAsString("${const JsonEncoder.withIndent("  ").convert(value)}\n");
}

Future<ReleaseIndex> _readIndex(File file) async => ReleaseIndex.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );

Object? _reverseKeys(Object? value) => value is Map<String, dynamic>
    ? {
        for (final key in value.keys.toList().reversed)
          key: _reverseKeys(value[key]),
      }
    : value is List
        ? value.map(_reverseKeys).toList()
        : value;

Future<void> main(List<String> args) async {
  if (args.length < 3 || !{"produce", "consume"}.contains(args[0])) {
    throw ArgumentError(
      "Usage: release_archive_interop.dart produce|consume output label [inputs] [expected-fixtures]",
    );
  }
  _require(_platforms.contains(Platform.operatingSystem), "Unsupported host");
  final output = Directory(path.absolute(args[1]));
  _require(
    !await output.exists(),
    "Refusing to overwrite evidence: ${output.path}",
  );
  await output.create(recursive: true);
  final root = await Directory.systemTemp.createTemp("archive-interop-");
  try {
    final fixture = await _Fixture.create(root);
    final uri = (await Isolate.resolvePackageUri(
      Uri.parse("package:desktop_updater/desktop_updater.dart"),
    ))!;
    final pubspec = await File(
      path.join(File.fromUri(uri).parent.parent.path, "pubspec.yaml"),
    ).readAsString();
    final version = RegExp(r"^version:\s*(\S+)", multiLine: true)
        .firstMatch(pubspec)!
        .group(1)!;
    final provenance = <String, Object?>{
      "label": args[2],
      "packageVersion": version,
      "host": Platform.operatingSystem,
      "dartVersion": Platform.version,
      "keyStore": fixture.store.description,
      "scope":
          "Real profile resolution, ZIP packaging, Ed25519 signing, and manual-publication validation with synthetic application files. Hosted HTTP is simulated; no native install, upload, or production credential use.",
    };
    if (args[0] == "produce") {
      final project = Directory(path.join(root.path, "producer 中文"));
      await fixture.prepareProject(project);
      final archive = File(path.join(project.path, "dist", "app-archive.json"));
      final snapshots = <Map<String, Object?>>[];
      for (var build = 1; build <= 3; build++) {
        await fixture.publish(
          project,
          build: build,
          existing: build > 1 ? archive.path : null,
        );
        final index = await _readIndex(archive);
        _require(
          await fixture.verifier.verify(index),
          "Producer signature failed",
        );
        _require(index.items.length == build, "Producer lost history");
        final bytes = await archive.readAsBytes();
        final name = "build-$build.json";
        await File(path.join(output.path, name)).writeAsBytes(bytes);
        snapshots.add({
          "file": name,
          "rawSha256": _sha(bytes),
          "canonicalSha256": _sha(index.canonicalSignatureBytes()),
          "items": build,
        });
      }
      final descriptors = <Map<String, Object?>>[];
      for (var build = 1; build <= 3; build++) {
        final file = File(
          path.join(
            project.path,
            "dist",
            "releases",
            "stable",
            "1.0.0",
            "build-$build",
            Platform.operatingSystem,
            "release.json",
          ),
        );
        final bytes = await file.readAsBytes();
        final name = "release-$build.json";
        await File(path.join(output.path, name)).writeAsBytes(bytes);
        descriptors.add({"file": name, "rawSha256": _sha(bytes)});
      }
      await _writeJson(
        File(path.join(output.path, "profile.json")),
        fixture.profile.toJson(),
      );
      await _writeJson(
        File(path.join(output.path, "fixture.json")),
        {...provenance, "snapshots": snapshots, "descriptors": descriptors},
      );
      stdout.writeln("Produced ${args[2]} with desktop_updater $version");
    } else {
      _require(
        args.length == 5,
        "Consume requires inputs and expected fixture count",
      );
      final manifests = await Directory(args[3])
          .list(recursive: true, followLinks: false)
          .where((e) => e is File && path.basename(e.path) == "fixture.json")
          .cast<File>()
          .toList();
      _require(
        manifests.length == int.parse(args[4]),
        "Expected ${args[4]} producer fixtures, found ${manifests.length}",
      );
      manifests.sort((a, b) => a.path.compareTo(b.path));
      final cases = <Map<String, Object?>>[];
      for (final manifest in manifests) {
        final metadata =
            jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
        final producer = metadata["label"] as String;
        final profile = await readReleaseKeyProfile(
          File(path.join(manifest.parent.path, "profile.json")),
        );
        _require(
          jsonEncode(profile.toJson()) == jsonEncode(fixture.profile.toJson()),
          "Public profiles differ across hosts",
        );
        for (final entry in metadata["snapshots"] as List) {
          final snapshot = Map<String, dynamic>.from(entry as Map);
          final bytes = await File(
            path.join(manifest.parent.path, snapshot["file"] as String),
          ).readAsBytes();
          _require(
            _sha(bytes) == snapshot["rawSha256"],
            "Artifact transfer changed $producer bytes",
          );
          final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          final encodings = <String, List<int>>{
            "raw": bytes,
            "CRLF": utf8.encode(
              "${const JsonEncoder.withIndent("  ").convert(json).replaceAll("\n", "\r\n")}\r\n",
            ),
            "reversed object keys": utf8.encode(jsonEncode(_reverseKeys(json))),
            "UTF-8 BOM": [0xef, 0xbb, 0xbf, ...bytes],
          };
          for (final encoding in encodings.entries) {
            final index = ReleaseIndex.fromJson(
              jsonDecode(utf8.decode(encoding.value)) as Map<String, dynamic>,
            );
            _require(
              _sha(index.canonicalSignatureBytes()) ==
                  snapshot["canonicalSha256"],
              "Canonical bytes differ for $producer/${encoding.key}",
            );
            _require(
              await fixture.verifier.verify(index),
              "Cross-host signature rejected: $producer/${encoding.key}",
            );
            cases.add({
              "producer": producer,
              "case": "verify transferred archive",
              "snapshot": snapshot["file"],
              "encoding": encoding.key,
            });
          }
        }
        for (final entry in metadata["descriptors"] as List) {
          final descriptor = Map<String, dynamic>.from(entry as Map);
          final bytes = await File(
            path.join(manifest.parent.path, descriptor["file"] as String),
          ).readAsBytes();
          _require(
            _sha(bytes) == descriptor["rawSha256"],
            "Descriptor transfer changed bytes",
          );
          final parsed = ReleaseDescriptor.fromJson(
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
          );
          _require(
            await Ed25519ReleaseSignatureVerifier(fixture.profile.publicKeys)
                .verify(parsed),
            "Cross-host descriptor signature rejected",
          );
          cases.add({
            "producer": producer,
            "case": "verify transferred descriptor",
            "descriptor": descriptor["file"],
          });
        }
        final original =
            await File(path.join(manifest.parent.path, "build-3.json"))
                .readAsBytes();
        final history = ReleaseIndex.fromJson(
          jsonDecode(utf8.decode(original)) as Map<String, dynamic>,
        );
        for (final mode in [
          "absent-native",
          "absent-forward-CRLF",
          "hosted-native",
        ]) {
          final project = Directory(
            path.join(root.path, "consumer 中文", "case-${cases.length}"),
          );
          await fixture.prepareProject(project);
          final archive =
              File(path.join(project.path, "dist", "app-archive.json"));
          await archive.parent.create();
          final bytes = mode == "absent-forward-CRLF"
              ? utf8.encode(utf8.decode(original).replaceAll("\n", "\r\n"))
              : original;
          await archive.writeAsBytes(bytes);
          final relative = mode == "absent-forward-CRLF"
              ? "dist/app-archive.json"
              : path.join("dist", "app-archive.json");
          await fixture.publish(
            project,
            build: 4,
            existing: relative,
            hosted: mode == "hosted-native" ? bytes : null,
          );
          final updated = await _readIndex(archive);
          _require(
            await fixture.verifier.verify(updated),
            "Extended archive has invalid signature",
          );
          _require(updated.items.length == 4, "Extended archive lost history");
          for (final item in history.items) {
            _require(
              updated.items.any(
                (candidate) =>
                    jsonEncode(candidate.toJson()) == jsonEncode(item.toJson()),
              ),
              "An original item changed during extension",
            );
          }
          cases.add({
            "producer": producer,
            "case": "extend transferred history",
            "mode": mode,
            "items": updated.items.length,
          });
        }
        for (final mutation in ["appName", "item order"]) {
          final project =
              Directory(path.join(root.path, "negative-${cases.length}"));
          await fixture.prepareProject(project);
          final archive =
              File(path.join(project.path, "dist", "app-archive.json"));
          final changed =
              jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
          if (mutation == "appName") {
            changed["appName"] = "Changed after signing";
          } else {
            changed["items"] = (changed["items"] as List).reversed.toList();
          }
          await _writeJson(archive, changed);
          final before = _sha(await archive.readAsBytes());
          Object? rejection;
          try {
            await fixture.publish(project, build: 4, existing: archive.path);
          } on Object catch (error) {
            rejection = error;
          }
          _require(
            rejection is FormatException &&
                rejection.toString().contains("signature"),
            "Tampering did not fail signature preflight",
          );
          _require(
            _sha(await archive.readAsBytes()) == before,
            "Rejected archive was changed",
          );
          _require(
            (await archive.parent.list().toList()).length == 1,
            "Rejected input created release output",
          );
          cases.add({
            "producer": producer,
            "case": "tampering rejected before output mutation",
            "mutation": mutation,
          });
        }
      }
      await _writeJson(File(path.join(output.path, "results.json")), {
        ...provenance,
        "status": "passed",
        "producerFixtures": manifests.length,
        "cases": cases,
      });
      stdout.writeln(
        "Verified ${cases.length} cases using desktop_updater $version on ${Platform.operatingSystem}",
      );
    }
  } finally {
    await root.delete(recursive: true);
  }
}

class _Fixture {
  _Fixture(this.root, this.profile, this.store, this.signing);
  final Directory root;
  final ReleaseKeyProfile profile;
  final ReleaseKeySecretStore store;
  final ReleaseSigningOptions signing;
  Ed25519ReleaseIndexSignatureVerifier get verifier =>
      Ed25519ReleaseIndexSignatureVerifier(profile.publicKeys);

  static Future<_Fixture> create(Directory root) async {
    final seed = List<int>.generate(32, (i) => i);
    final pair = await Ed25519().newKeyPairFromSeed(seed);
    final public = (await pair.extractPublicKey()).bytes;
    final keyId = releaseKeyIdForPublicKey(public);
    final profile = ReleaseKeyProfile(
      profileId: _profileId,
      feedUrl: _base.resolve("app-archive.json").toString(),
      activeKeyId: keyId,
      pendingKeyId: null,
      publicKeys: {keyId: base64Encode(public)},
    );
    final keyRoot = Directory(path.join(root.path, "fixture-keys"));
    final store = Platform.isWindows
        ? WindowsDpapiReleaseKeyStore(rootDirectory: keyRoot)
        : LocalFileReleaseKeyStore(rootDirectory: keyRoot);
    await store.write(profileId: _profileId, keyId: keyId, seed: seed);
    await writeReleaseKeyProfile(
      File(path.join(root.path, "desktop_updater.keys.json")),
      profile,
    );
    final manager = ReleaseKeyManager(
      projectRoot: root,
      feedUrl: _base.resolve("app-archive.json"),
      store: store,
    );
    final loaded = await manager.readProfile();
    final resolvedSeed = await manager.seedForActive(loaded);
    return _Fixture(
      root,
      profile,
      store,
      ReleaseSigningOptions(
        publicKeyId: loaded.activeKeyId,
        privateKeyBase64: base64Encode(resolvedSeed),
        trustedReleasePublicKeys: loaded.publicKeys,
      ),
    );
  }

  Future<void> prepareProject(Directory project) async {
    await project.create(recursive: true);
    await File(path.join(project.path, "desktop_updater.yaml"))
        .writeAsString("updates:\n  baseUrl: $_base\n  output: dist\n");
    final input =
        Directory(path.join(project.path, "input 中文", "flutter_client.app"));
    await input.create(recursive: true);
    await File(path.join(input.path, "fixture.txt")).writeAsString(
      "Synthetic package input; not a runnable native application.\n",
    );
  }

  Future<void> publish(
    Directory project, {
    required int build,
    String? existing,
    List<int>? hosted,
  }) async {
    final client = MockClient((request) async {
      _require(
        request.url == _base.resolve("app-archive.json"),
        "Unexpected network target ${request.url}",
      );
      return hosted == null
          ? http.Response("", 404)
          : http.Response.bytes(hosted, 200);
    });
    final log = StringBuffer();
    try {
      await ReleasePublisher(httpClient: client).publish(
        projectRoot: project,
        platform: Platform.operatingSystem,
        overrides: ReleasePublishOverrides(
          projectType: "manual",
          artifactRoot:
              path.join(project.path, "input 中文", "flutter_client.app"),
          appName: Platform.isMacOS ? "flutter_client.app" : "flutter_client",
          packageId: "com.example.archiveinterop",
          version: "1.0.0",
          buildNumber: build,
          initializeFeed: hosted == null,
          existingAppArchive: existing,
        ),
        signing: signing,
        output: log,
      );
    } on Object {
      if (log.isNotEmpty) stderr.writeln(log);
      rethrow;
    } finally {
      client.close();
    }
  }
}
