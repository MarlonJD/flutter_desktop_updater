import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("macOS DMG and PKG docs cover artifact boundaries and smoke commands",
      () {
    final doc =
        File("docs/macos-dmg-pkg-installer-updates.md").readAsStringSync();

    expect(doc, contains("artifact.kind: dmg"));
    expect(doc, contains("artifact.kind: pkgInstaller"));
    expect(doc, contains("install.strategy: pkgInstaller"));
    expect(doc, contains("silent privileged install is not promised"));
    expect(
      doc,
      contains("dart run tool/macos_production_smoke.dart doctor"),
    );
    expect(
      doc,
      contains("dart run tool/macos_production_smoke.dart pkg-install-verify"),
    );
    expect(doc, contains("separate opt-in QA gate"));
    expect(doc, contains("hdiutil attach -readonly -nobrowse"));
    expect(doc, contains("pkgutil --check-signature"));
  });

  test(
      "README links to detailed macOS DMG and PKG docs without bloating quick start",
      () {
    final readme = File("README.md").readAsStringSync();

    expect(readme, contains("docs/macos-dmg-pkg-installer-updates.md"));
    expect(
      readme.split("docs/macos-dmg-pkg-installer-updates.md"),
      hasLength(2),
    );
  });

  test("publishing docs include concise macOS DMG and PKG config examples", () {
    final doc = File("docs/publishing.md").readAsStringSync();

    expect(doc, contains("macos.artifact.kind: dmg"));
    expect(doc, contains("macos.artifact.kind: pkg"));
    expect(doc, contains("packageIdentifier"));
    expect(doc, contains("docs/macos-dmg-pkg-installer-updates.md"));
  });
}
