// Read-only diagnostics. Run from the application's project directory with:
// dart --packages=.dart_tool/package_config.json diagnose_archive.dart \
//   dist/desktop_updater/app-archive.json desktop_updater.keys.json
import "dart:convert";
import "dart:io";
import "dart:isolate";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:path/path.dart" as path;

String sha(List<int> bytes) => crypto.sha256.convert(bytes).toString();

Future<String?> packageVersion(String name, String entryPoint) async {
  final uri =
      await Isolate.resolvePackageUri(Uri.parse("package:$name/$entryPoint"));
  if (uri == null || uri.scheme != "file") return null;
  final pubspec =
      File(path.join(File.fromUri(uri).parent.parent.path, "pubspec.yaml"));
  if (!await pubspec.exists()) return null;
  return RegExp(r"^version:\s*([^\r\n]+)", multiLine: true)
      .firstMatch(await pubspec.readAsString())
      ?.group(1)
      ?.trim();
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      "Usage: diagnose_archive.dart <app-archive.json> <public desktop_updater.keys.json>",
    );
    exitCode = 64;
    return;
  }
  try {
    final archiveFile = File(args[0]);
    final archiveBytes = await archiveFile.readAsBytes();
    final profileFile = File(args[1]);
    final profileBytes = await profileFile.readAsBytes();
    final profile =
        jsonDecode(utf8.decode(profileBytes)) as Map<String, dynamic>;
    final keys = Map<String, String>.from(profile["publicKeys"] as Map);
    final index = ReleaseIndex.fromJson(
      jsonDecode(utf8.decode(archiveBytes)) as Map<String, dynamic>,
    );
    final indexVerifier = Ed25519ReleaseIndexSignatureVerifier(keys);
    final descriptorVerifier = Ed25519ReleaseSignatureVerifier(keys);
    final localRoot = await archiveFile.parent.resolveSymbolicLinks();
    final feed = Uri.parse(profile["feedUrl"] as String);
    final base = feed.resolve(".");
    final descriptors = <Map<String, Object?>>[];
    for (final item in index.items) {
      final release = item.release;
      final result = <String, Object?>{
        "version": item.version,
        "buildNumber": item.buildNumber,
        "platform": item.platform,
        "channel": item.channel,
      };
      descriptors.add(result);
      if (release.scheme != base.scheme ||
          release.host != base.host ||
          release.port != base.port ||
          !release.path.startsWith(base.path)) {
        result["status"] = "release URL is outside the profile feed directory";
        continue;
      }
      final relative = Uri.parse(release.path.substring(base.path.length));
      final segments = relative.pathSegments;
      if (segments.isEmpty ||
          segments.any(
            (s) =>
                s.isEmpty ||
                s == "." ||
                s == ".." ||
                s.contains("/") ||
                s.contains("\\"),
          )) {
        result["status"] = "release URL does not map to a safe local path";
        continue;
      }
      final file = File(path.joinAll([localRoot, ...segments]));
      if (!await file.exists()) {
        result["status"] = "local release.json missing";
        continue;
      }
      if (!path.isWithin(localRoot, await file.resolveSymbolicLinks())) {
        result["status"] =
            "local release.json resolves outside archive directory";
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        final descriptor = ReleaseDescriptor.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
        result.addAll({
          "status": "read",
          "rawSha256": sha(bytes),
          "signatureKeyId": descriptor.signature?.publicKeyId,
          "signatureValidWithThisProfile":
              await descriptorVerifier.verify(descriptor),
          "signatureEqualsArchiveSignature": descriptor.signature != null &&
              index.signature != null &&
              descriptor.signature!.value == index.signature!.value,
        });
      } on Object catch (error) {
        result["status"] = "parse or verification failed";
        result["errorType"] = error.runtimeType.toString();
      }
    }
    final report = {
      "tool": "issue84-read-only-archive-diagnostics-v1",
      "operatingSystem": Platform.operatingSystem,
      "dartVersion": Platform.version,
      "desktopUpdaterVersion":
          await packageVersion("desktop_updater", "desktop_updater.dart"),
      "cryptographyPlusVersion":
          await packageVersion("cryptography_plus", "cryptography_plus.dart"),
      "publicProfile": {
        "rawSha256": sha(profileBytes),
        "activeKeyId": profile["activeKeyId"],
        "publicKeyFingerprints": {
          for (final entry in keys.entries)
            entry.key: sha(base64Decode(entry.value)),
        },
      },
      "archive": {
        "rawSha256": sha(archiveBytes),
        "canonicalSha256": sha(index.canonicalSignatureBytes()),
        "appName": index.appName,
        "itemCount": index.items.length,
        "signatureKeyId": index.signature?.publicKeyId,
        "signatureSha256": index.signature == null
            ? null
            : sha(base64Decode(index.signature!.value)),
        "signatureValidWithThisProfile": await indexVerifier.verify(index),
      },
      "localReleaseDescriptors": descriptors,
      "archiveUnchanged":
          sha(archiveBytes) == sha(await archiveFile.readAsBytes()),
      "publicProfileUnchanged":
          sha(profileBytes) == sha(await profileFile.readAsBytes()),
      "scope":
          "Reads only the specified archive/public profile, contained release.json files, and resolved package versions. No network, signing, keychain, private-key reads, or writes.",
    };
    stdout.writeln(const JsonEncoder.withIndent("  ").convert(report));
  } on Object catch (error) {
    stderr.writeln(
      "Read-only diagnostics failed (${error.runtimeType}). Check the file arguments and package configuration.",
    );
    exitCode = 1;
  }
}
