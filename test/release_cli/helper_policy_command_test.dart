import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:desktop_updater/src/native_install_helper/canonical_json.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_profile.dart";
import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  late Directory root;
  late Directory runner;
  late File source;
  late File sealed;
  late File digest;
  late StringBuffer output;

  Future<int> run([List<String> options = const []]) {
    output = StringBuffer();
    return runReleaseCommand(
      ["helper-policy", ...options],
      projectRoot: root,
      output: output,
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp("helper policy consumer ");
    runner = Directory(path.join(root.path, "macos", "Runner"));
    await Directory(path.join(runner.path, "Configs")).create(recursive: true);
    await File(path.join(runner.path, "Configs", "AppInfo.xcconfig"))
        .writeAsString("PRODUCT_BUNDLE_IDENTIFIER = com.example.consumer\n");
    await File(path.join(root.path, "desktop_updater.yaml")).writeAsString(
      "updates:\n  baseUrl: https://updates.example.com/stable/\n",
    );
    await defaultReleaseKeyProfileFile(root).writeAsString(jsonEncode(
      ReleaseKeyProfile(
        profileId: "0123456789abcdef0123456789abcdef",
        feedUrl: "https://updates.example.com/stable/app-archive.json",
        activeKeyId: "consumer-key",
        pendingKeyId: null,
        publicKeys: {"consumer-key": base64Encode(List.filled(32, 7))},
      ).toJson(),
    ));
    source =
        File(path.join(runner.path, "DesktopUpdaterHelperPolicy.source.json"));
    sealed = File(path.join(runner.path, "DesktopUpdaterHelperPolicy.json"));
    digest = File(path.join(runner.path, "DesktopUpdaterHelperPolicy.sha256"));
  });

  tearDown(() => root.delete(recursive: true));

  test(
      "creates app-owned policy and digest from literal app ID and public profile",
      () async {
    expect(await run(["--team-id", "ABC1234567"]), 0, reason: "$output");
    final policy = jsonDecode(await sealed.readAsString()) as Map;
    expect(policy["applicationPackageId"], "com.example.consumer");
    expect(policy["helperServiceId"], "com.example.consumer.helper");
    expect(policy["allowedApplicationSigner"]["value"],
        'identifier "com.example.consumer" and anchor apple generic and certificate leaf[subject.OU] = "ABC1234567"');
    expect(policy["allowedHelperSigner"]["value"],
        'identifier "com.example.consumer.helper" and anchor apple generic and certificate leaf[subject.OU] = "ABC1234567"');
    expect(policy["allowedTargetClasses"], ["applicationBundle"]);
    expect(policy["allowedInstallRoots"], ["/Applications"]);
    expect(policy["releaseRootPublicKeys"][0]["keyId"], "consumer-key");
    final canonical = canonicalNativeInstallHelperJson(policy);
    expect(await sealed.readAsString(), "$canonical\n");
    expect((await digest.readAsString()).trim(),
        sha256.convert(utf8.encode(canonical)).toString());
    expect(jsonDecode(await source.readAsString()), policy);
  });

  test("rerun preserves customized source exactly and regenerates only outputs",
      () async {
    expect(await run(["--team-id", "ABC1234567"]), 0);
    final policy = jsonDecode(await source.readAsString()) as Map;
    policy["allowedInstallRoots"] = ["/Applications/Company Apps"];
    final edited = '${const JsonEncoder.withIndent("    ").convert(policy)}\n';
    await source.writeAsString(edited);
    await defaultReleaseKeyProfileFile(root).delete();
    expect(await run(), 0, reason: "$output");
    expect(await source.readAsString(), edited);
    expect(jsonDecode(await sealed.readAsString())["allowedInstallRoots"],
        ["/Applications/Company Apps"]);
    final pair = [await sealed.readAsString(), await digest.readAsString()];
    expect(await run(), 0);
    expect([await sealed.readAsString(), await digest.readAsString()], pair);
  });

  test("adopts existing customized policy instead of inventing a replacement",
      () async {
    expect(await run(["--team-id", "ABC1234567"]), 0);
    final existing = await sealed.readAsString();
    await source.delete();
    await defaultReleaseKeyProfileFile(root).delete();
    expect(await run(), 0, reason: "$output");
    expect(await source.readAsString(), existing);
  });

  test("rejects feed mismatch before writing any policy files", () async {
    final profile = defaultReleaseKeyProfileFile(root);
    await profile.writeAsString((await profile.readAsString()).replaceAll(
      "https://updates.example.com/stable/",
      "https://different.example.com/",
    ));
    expect(await run(["--team-id", "ABC1234567"]), isNonZero);
    expect(output.toString(), contains("feed does not match"));
    expect(await source.exists(), isFalse);
    expect(await sealed.exists(), isFalse);
    expect(await digest.exists(), isFalse);
  });

  test("missing public profile explains key setup without creating keys",
      () async {
    await defaultReleaseKeyProfileFile(root).delete();
    expect(await run(["--team-id", "ABC1234567"]), isNonZero);
    expect(output.toString(), contains("release keygen"));
    expect(await defaultReleaseKeyProfileFile(root).exists(), isFalse);
    expect(await source.exists(), isFalse);
  });

  for (final team in [null, "bad", 'ABC1234567" or true']) {
    test("requires a concrete Team ID: $team", () async {
      expect(await run(team == null ? [] : ["--team-id", team]), isNonZero);
      expect(output.toString(), contains("--team-id"));
      expect(await source.exists(), isFalse);
    });
  }

  test("unresolved bundle ID requires explicit override", () async {
    await File(path.join(runner.path, "Configs", "AppInfo.xcconfig"))
        .writeAsString(r"PRODUCT_BUNDLE_IDENTIFIER = $(APP_ID)");
    expect(await run(["--team-id", "ABC1234567"]), isNonZero);
    expect(output.toString(), contains("--package-id"));
    expect(await source.exists(), isFalse);
    expect(
        await run([
          "--team-id",
          "ABC1234567",
          "--package-id",
          "com.example.explicit"
        ]),
        0);
    expect(jsonDecode(await sealed.readAsString())["applicationPackageId"],
        "com.example.explicit");
  });

  test("invalid source leaves the previously pinned pair unchanged", () async {
    expect(await run(["--team-id", "ABC1234567"]), 0);
    final before = [await sealed.readAsString(), await digest.readAsString()];
    await source.writeAsString('{"policyVersion":1,"policyVersion":2}');
    expect(await run(), isNonZero);
    expect(output.toString(), contains("duplicateKey:policyVersion"));
    expect([await sealed.readAsString(), await digest.readAsString()], before);
  });

  test("mismatched source app ID cannot generate a policy for another app",
      () async {
    expect(await run(["--team-id", "ABC1234567"]), 0);
    expect(await run(["--package-id", "com.example.wrong"]), isNonZero);
    expect(output.toString(), contains("applicationPackageIdMismatch"));
  });

  test("custom helper ID stays distinct from the app identity", () async {
    expect(
        await run([
          "--team-id",
          "ABC1234567",
          "--helper-service-id",
          "com.example.consumer"
        ]),
        isNonZero);
    expect(await source.exists(), isFalse);
    expect(
        await run([
          "--team-id",
          "ABC1234567",
          "--helper-service-id",
          "com.example.customHelper"
        ]),
        0);
    final policy = jsonDecode(await sealed.readAsString());
    expect(policy["helperServiceId"], "com.example.customHelper");
    expect(policy["allowedHelperSigner"]["value"],
        contains('identifier "com.example.customHelper"'));
    expect(policy["allowedApplicationSigner"]["value"],
        contains('identifier "com.example.consumer"'));
  });

  test("initialization flags cannot replace existing policy authority",
      () async {
    expect(await run(["--team-id", "ABC1234567"]), 0);
    final before = await source.readAsString();
    expect(
        await run([
          "--team-id",
          "OTHER12345",
          "--helper-service-id",
          "com.other.helper"
        ]),
        0);
    expect(await source.readAsString(), before);
    expect(
        output.toString(), contains("Initialization options do not replace"));
  });

  test("rejects output symlink before creating source or touching its target",
      () async {
    final outside = File(path.join(root.path, "unrelated.json"));
    await outside.writeAsString("keep me");
    await Link(sealed.path).create(outside.path);
    expect(await run(["--team-id", "ABC1234567"]), isNonZero);
    expect(output.toString(), contains("regular file"));
    expect(await outside.readAsString(), "keep me");
    expect(await source.exists(), isFalse);
  }, skip: Platform.isWindows);
}
