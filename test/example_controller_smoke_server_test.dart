import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";

import "../example/tool/updater_smoke.dart" as smoke;

void main() {
  test("signed local smoke feed issues a library-owned verified stage",
      () async {
    final root = await Directory.systemTemp.createTemp("controller_smoke_");
    addTearDown(() => root.delete(recursive: true));
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(
          "desktop_updater_smoke.txt",
          utf8.encode("installed"),
        ),
      );
    final artifact = File("${root.path}/update.zip");
    await artifact.writeAsBytes(ZipEncoder().encode(archive));
    final server = await smoke.ControllerSmokeUpdateServer.start(
      artifact: artifact,
      platform: "linux",
      packageId: "com.example.desktop_updater",
      appName: "desktop_updater smoke",
    );
    addTearDown(server.close);

    final client = UpdateClient(
      appArchiveUrl: server.appArchiveUrl,
      currentVersion: DesktopVersionInfo.parse("2.0.1+201"),
      expectedPackageId: "com.example.desktop_updater",
      trustedReleasePublicKeys: <String, String>{
        server.publicKeyId: server.publicKeyBase64,
      },
      platform: "linux",
      stagingParent: root,
    );
    final checkResult = await client.checkForUpdate();
    expect(checkResult, isNotNull);

    final stage = await client.downloadVerifyAndStage(
      checkResult: checkResult!,
    );
    expect(stage.descriptor.packageId, "com.example.desktop_updater");
    expect(
      await File("${stage.stagingPath}/desktop_updater_smoke.txt")
          .readAsString(),
      "installed",
    );
    expect(stage.stageProvenanceSha256, matches(RegExp(r"^[0-9a-f]{64}$")));
  });
}
