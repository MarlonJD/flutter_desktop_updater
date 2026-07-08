import "package:desktop_updater/src/macos_install_location.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("classifies common macOS install locations", () {
    expect(
      classifyMacOSInstallLocation("/Applications/Example.app"),
      MacOSInstallLocationKind.installed,
    );
    expect(
      classifyMacOSInstallLocation("/Volumes/Example/Example.app"),
      MacOSInstallLocationKind.diskImage,
    );
    expect(
      classifyMacOSInstallLocation("/Users/me/Downloads/Example.app"),
      MacOSInstallLocationKind.downloads,
    );
    expect(
      classifyMacOSInstallLocation("/Users/me/Desktop/Example.app"),
      MacOSInstallLocationKind.other,
    );
  });

  test("move prompt is offered only for movable locations", () {
    expect(
      const MacOSInstallLocationStatus(
        kind: MacOSInstallLocationKind.diskImage,
        bundlePath: "/Volumes/Example/Example.app",
        targetPath: "/Applications/Example.app",
      ).shouldOfferMovePrompt,
      isTrue,
    );
    expect(
      const MacOSInstallLocationStatus(
        kind: MacOSInstallLocationKind.installed,
        bundlePath: "/Applications/Example.app",
        targetPath: "/Applications/Example.app",
      ).shouldOfferMovePrompt,
      isFalse,
    );
  });
}
