import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("native helpers expose only exact sealed strategy providers", () {
    final mac = requiredFile(
      "macos/install_helper/Sources/DesktopUpdaterInstallHelper/InstallStrategy.swift",
    );
    final windows = requiredFile(
      "windows/native/src/helper/install_strategy.cpp",
    );
    final linux = requiredFile(
      "linux/native/src/helper/install_strategy.cc",
    );
    final linuxHeader = requiredFile(
      "linux/native/src/helper/install_strategy.h",
    );
    final macHelperTest = requiredFile(
      "macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/InstallStrategyTests.swift",
    );
    final macBoundaryTest = requiredFile(
      "macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallStrategyTests.swift",
    );
    final windowsTest = requiredFile(
      "windows/native/test/helper/windows_install_strategy_test.cpp",
    );
    final linuxTest = requiredFile(
      "linux/native/test/helper/linux_install_strategy_test.cc",
    );
    final windowsCmake = requiredFile("windows/native/CMakeLists.txt");
    final linuxCmake = requiredFile("linux/native/CMakeLists.txt");
    final all = [mac, windows, linux, linuxHeader].join("\n");

    for (final capability in const {
      "directoryReplace": "platformDirectory",
      "singleFileReplace": "platformFile",
      "verifiedInstallerHandoff": "windowsInno",
      "systemPackageTransaction": "apt",
      "externalManagedRefresh": "flatpak",
    }.entries) {
      expect(all, contains(capability.key));
      expect(all, contains(capability.value));
    }
    expect(all, contains("macosInstaller"));
    expect(all, contains("dnf"));
    expect(all, contains("snap"));
    expect(all, contains("broker_authenticated"));
    expect(all, contains("caller_arguments"));
    expect(all, isNot(contains("callerCommand")));
    expect(macHelperTest, contains("InstallStrategyTests"));
    expect(macBoundaryTest, contains("MacInstallStrategyTests"));
    expect(windowsTest, contains("WindowsInstallStrategy"));
    expect(linuxTest, contains("LinuxInstallStrategy"));
    expect(windowsCmake, contains("windows_install_strategy"));
    expect(linuxCmake, contains("linux_install_strategy"));
  });

  test("bounded provider implementations reject command and mount escape", () {
    final linux = [
      requiredFile("linux/native/src/helper/single_file_replace.cc"),
      requiredFile("linux/native/src/helper/system_package_transaction.cc"),
      requiredFile("linux/native/src/helper/external_managed_refresh.cc"),
    ].join("\n");
    expect(linux, contains("LinuxFileTransaction"));
    expect(linux, contains("/usr/bin/apt-get"));
    expect(linux, contains("/usr/bin/dnf"));
    expect(linux, contains("/usr/bin/flatpak"));
    expect(linux, contains("/usr/bin/snap"));
    expect(linux, contains("dangerous_sideload"));
    expect(linux, contains("direct_revision_mutation"));
    expect(linux, isNot(contains("/bin/sh")));
    expect(linux, isNot(contains("system(")));
    expect(linux, isNot(contains("popen(")));
    expect(linux, isNot(contains("--dangerous")));
  });

  test("strategy work does not add Linux artifact production", () {
    expect(Directory("lib/src/release_cli/linux").existsSync(), isFalse);
    final releaseDescriptor = requiredFile(
      "lib/src/core/release_descriptor.dart",
    );
    for (final futureKind in const [
      "appImage",
      "debPackage",
      "rpmPackage",
      "flatpakBundle",
      "snapPackage",
    ]) {
      expect(releaseDescriptor, isNot(contains('\"$futureKind\"')));
    }
    final repositoryFiles = Directory(".")
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((file) => file.path.toLowerCase())
        .where(
          (path) =>
              path.contains("appimage_packager") ||
              path.contains("deb_packager") ||
              path.contains("rpm_packager") ||
              path.contains("flatpak_repository_publisher") ||
              path.contains("snap_store_publisher"),
        )
        .toList();
    expect(repositoryFiles, isEmpty);
    final workflow = requiredFile(".github/workflows/desktop-updater-ci.yml");
    expect(workflow, isNot(contains("SNAPCRAFT_STORE_CREDENTIALS")));
    expect(workflow, isNot(contains("FLATPAK_GPG_PRIVATE_KEY")));
  });

  test("approved follow-on mapping remains documented and future-only", () {
    final design = requiredFile(
      "docs/design-docs/2026-07-11-cross-platform-privileged-install-helper-design.md",
    );
    final followOnPlan = requiredFile(
      "docs/exec-plans/active/2026-07-11-linux-distribution-artifacts-plan.md",
    );
    for (final mapping in const [
      "AppImage to `singleFileReplace`",
      "deb/rpm to `systemPackageTransaction`",
      "Flatpak self-hosted or Flathub remotes to `externalManagedRefresh`",
      "Snap public or Brand Stores to `externalManagedRefresh`",
    ]) {
      expect(design, contains(mapping));
    }
    expect(followOnPlan, contains("`.AppImage`"));
    expect(followOnPlan, contains("`debPackage`"));
    expect(followOnPlan, contains("`rpmPackage`"));
    expect(followOnPlan, contains("`flatpakBundle`"));
    expect(followOnPlan, contains("`snapPackage`"));
    expect(design, contains("Production Snap"));
    expect(design, contains("sideload remains prohibited"));
  });
}

String requiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}
