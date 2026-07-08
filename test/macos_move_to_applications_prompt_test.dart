import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:desktop_updater/widget/macos_move_to_applications_prompt.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  testWidgets("shows prompt for disk image launches", (tester) async {
    var moveCalled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MacOSMoveToApplicationsPrompt(
          statusLoader: () async => const MacOSInstallLocationStatus(
            kind: MacOSInstallLocationKind.diskImage,
            bundlePath: "/Volumes/Example/Example.app",
            targetPath: "/Applications/Example.app",
          ),
          mover: ({required replaceExisting}) async {
            moveCalled = true;
          },
          child: const Text("Home"),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text("Move to Applications?"), findsOneWidget);
    await tester.tap(find.text("Move"));
    await tester.pump();
    expect(moveCalled, isTrue);
  });

  testWidgets("does not show prompt for installed apps", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MacOSMoveToApplicationsPrompt(
          statusLoader: () async => const MacOSInstallLocationStatus(
            kind: MacOSInstallLocationKind.installed,
            bundlePath: "/Applications/Example.app",
            targetPath: "/Applications/Example.app",
          ),
          child: const Text("Home"),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text("Home"), findsOneWidget);
    expect(find.text("Move to Applications?"), findsNothing);
  });

  testWidgets("confirms replacement when target already exists",
      (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MacOSMoveToApplicationsPrompt(
          statusLoader: () async => const MacOSInstallLocationStatus(
            kind: MacOSInstallLocationKind.downloads,
            bundlePath: "/Users/me/Downloads/Example.app",
            targetPath: "/Applications/Example.app",
          ),
          mover: ({required replaceExisting}) async {
            calls.add(replaceExisting);
            if (!replaceExisting) {
              throw PlatformException(code: "AlreadyExists");
            }
          },
          child: const Text("Home"),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text("Move"));
    await tester.pumpAndSettle();
    expect(find.text("Replace existing app?"), findsOneWidget);
    await tester.tap(find.text("Replace"));
    await tester.pumpAndSettle();

    expect(calls, [false, true]);
  });

  testWidgets("uses localized prompt copy", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MacOSMoveToApplicationsPrompt(
          localization: const DesktopUpdateLocalization(
            macosMoveToApplicationsTitleText: "Move custom?",
            macosMoveToApplicationsBodyText: "Move body",
            macosMoveToApplicationsMoveText: "Move custom",
            macosMoveToApplicationsSkipText: "Skip custom",
          ),
          statusLoader: () async => const MacOSInstallLocationStatus(
            kind: MacOSInstallLocationKind.diskImage,
            bundlePath: "/Volumes/Example/Example.app",
            targetPath: "/Applications/Example.app",
          ),
          child: const Text("Home"),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text("Move custom?"), findsOneWidget);
    expect(find.text("Move body"), findsOneWidget);
    expect(find.text("Move custom"), findsOneWidget);
    expect(find.text("Skip custom"), findsOneWidget);
  });

  test("default callbacks use public DesktopUpdater facade", () {
    final source = File(
      "lib/widget/macos_move_to_applications_prompt.dart",
    ).readAsStringSync();

    expect(source, contains("DesktopUpdater().checkMacOSInstallLocation"));
    expect(source, contains("DesktopUpdater().moveMacOSAppToApplications"));
  });
}
