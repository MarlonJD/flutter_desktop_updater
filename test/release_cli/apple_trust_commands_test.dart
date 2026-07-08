import "dart:io";

import "package:desktop_updater/src/release_cli/macos/apple_trust_commands.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("wraps Apple trust commands with expected arguments", () async {
    final commands = <List<String>>[];
    final trust = AppleTrustCommands(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments]);
        return ProcessResult(0, 0, "", "");
      },
    );

    await trust.codesignApp(
      app: Directory("/tmp/Example.app"),
      identity: "Developer ID Application: Example Corp (TEAMID1234)",
    );
    await trust.codesignArtifact(
      artifact: File("/tmp/Example.dmg"),
      identity: "Developer ID Application: Example Corp (TEAMID1234)",
    );
    await trust.verifyApp(Directory("/tmp/Example.app"));
    await trust.assessExecute(Directory("/tmp/Example.app"));
    await trust.assessInstall(File("/tmp/Example.pkg"));
    await trust.assessDmg(File("/tmp/Example.dmg"));
    await trust.staple(File("/tmp/Example.dmg"));
    await trust.validateStaple(File("/tmp/Example.pkg"));
    await trust.checkPkgSignature(File("/tmp/Example.pkg"));
    await trust.submitForNotarization(
      archive: File("/tmp/Example-notary.zip"),
      notaryProfile: "desktop-updater-notary",
      keychain: "/Users/me/Library/Keychains/login.keychain-db",
    );

    expect(commands, [
      [
        "/usr/bin/codesign",
        "--force",
        "--options",
        "runtime",
        "--timestamp",
        "--sign",
        "Developer ID Application: Example Corp (TEAMID1234)",
        "/tmp/Example.app",
      ],
      [
        "/usr/bin/codesign",
        "--force",
        "--timestamp",
        "--sign",
        "Developer ID Application: Example Corp (TEAMID1234)",
        "/tmp/Example.dmg",
      ],
      [
        "/usr/bin/codesign",
        "--verify",
        "--deep",
        "--strict",
        "--verbose=2",
        "/tmp/Example.app",
      ],
      ["/usr/bin/codesign", "-dvvv", "/tmp/Example.app"],
      [
        "/usr/sbin/spctl",
        "--assess",
        "--type",
        "execute",
        "--verbose=2",
        "/tmp/Example.app",
      ],
      [
        "/usr/sbin/spctl",
        "--assess",
        "--type",
        "install",
        "--verbose=2",
        "/tmp/Example.pkg",
      ],
      [
        "/usr/sbin/spctl",
        "--assess",
        "--type",
        "open",
        "--context",
        "context:primary-signature",
        "--verbose=2",
        "/tmp/Example.dmg",
      ],
      ["/usr/bin/xcrun", "stapler", "staple", "/tmp/Example.dmg"],
      ["/usr/bin/xcrun", "stapler", "validate", "/tmp/Example.pkg"],
      ["/usr/sbin/pkgutil", "--check-signature", "/tmp/Example.pkg"],
      [
        "/usr/bin/xcrun",
        "notarytool",
        "submit",
        "/tmp/Example-notary.zip",
        "--keychain-profile",
        "desktop-updater-notary",
        "--keychain",
        "/Users/me/Library/Keychains/login.keychain-db",
        "--wait",
      ],
    ]);
  });
}
