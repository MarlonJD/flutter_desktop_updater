import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:flutter_test/flutter_test.dart";

void main() {
  test("privileged macOS smoke is repository-owned and two-phase", () {
    final host = File(
      "example/macos/Runner/AppDelegate.swift",
    ).readAsStringSync();
    final smoke = File(
      "tool/macos_install_helper_smoke.dart",
    ).readAsStringSync();
    final workflow = File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsStringSync();
    final policy = File(
      "example/macos/Runner/DesktopUpdaterHelperPolicy.json",
    ).readAsStringSync();
    final project = File(
      "example/macos/Runner.xcodeproj/project.pbxproj",
    ).readAsStringSync();
    final infoPlist = File(
      "example/macos/Runner/Info.plist",
    ).readAsStringSync();
    final helperClient = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();

    expect(host, contains("--desktop-updater-smappservice-smoke"));
    expect(host, contains("MacInstallHelper.smAppServiceSmokeHost()"));
    expect(host, isNot(contains("MacInstallHelper()")));
    expect(host, contains("targetParentWritable"));
    expect(helperClient, contains("@_spi(DesktopUpdaterSmoke)"));
    expect(helperClient, contains("privilegeRequired: { _ in true }"));
    expect(
      helperClient,
      contains("forcePrivilegedPersistentOperations: true"),
    );
    expect(host, contains("SMAppService.daemon"));
    expect(host, contains('case "register"'));
    expect(host, contains("case .notRegistered, .notFound:"));
    expect(host, isNot(contains("synchronizeFile")));
    expect(host, contains("prepareInstall"));
    expect(host, contains("commitAfterExit"));
    expect(host, contains("recoverPendingInstall"));
    expect(host, contains("queryTransaction"));
    expect(host, contains("Darwin.exit"));

    expect(smoke, contains("DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_STAGED_APP"));
    expect(
      smoke,
      contains("/Applications/DesktopUpdaterSMAppServiceSmoke"),
    );
    expect(smoke, contains("path.dirname(app.path)"));
    expect(smoke, isNot(contains("DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_HOST")));
    expect(smoke, contains('phase: "prepareOnly"'));
    expect(smoke, contains('phase: "commit"'));
    expect(smoke, contains('phase: "recover"'));
    expect(smoke, contains('phase: "query"'));
    expect(smoke, contains("--exit-gate"));
    expect(smoke, contains("launchctl"));
    expect(smoke, contains("rolledBack"));
    expect(smoke, contains("commitAccepted"));
    expect(smoke, contains("authenticatedXPC"));
    expect(smoke, contains("_bundleOwnership"));
    expect(smoke, contains('"targetOwnership": targetOwnership'));
    expect(smoke, contains('"servicePIDAfterUpdate": servicePIDAfterUpdate'));
    expect(smoke, contains("servicePIDAfterUpdate == servicePIDAfterRecovery"));
    expect(smoke, contains('targetOwnership != "0:0"'));
    expect(
      smoke,
      contains(
        "_endpointIdentity(completedQueryEvidence) != stagedEndpointIdentity",
      ),
    );
    expect(smoke, contains('evidence["targetParentWritable"] != false'));
    expect(smoke, contains("recoverableSwapExecuted"));
    expect(smoke, isNot(contains("_smokeSentinelName")));
    expect(smoke, contains("native-runtime-smoke-stable"));
    expect(policy, contains('"keyId":"native-runtime-smoke-stable"'));
    expect(
      policy,
      contains('"/Applications/DesktopUpdaterSMAppServiceSmoke"'),
    );
    expect(
      policy,
      contains(
        '"publicKeyBase64":"uvxxvq06xeS2PpyCFu5xo0quxlci7tvKcotOmzzM45Y="',
      ),
    );
    final canonicalPolicy =
        policy.endsWith("\n") ? policy.substring(0, policy.length - 1) : policy;
    final policySHA256 =
        crypto.sha256.convert(utf8.encode(canonicalPolicy)).toString();
    expect(project, contains(policySHA256));
    expect(infoPlist, contains("DesktopUpdaterInstallPolicyID"));
    expect(infoPlist, contains("DesktopUpdaterInstallHelperServiceID"));
    expect(infoPlist, contains("DesktopUpdaterInstallHelperRequirement"));
    expect(
      infoPlist,
      contains("DesktopUpdaterInstallHelperLaunchDaemonPlistName"),
    );
    expect(infoPlist, isNot(contains("SMPrivilegedExecutables")));
    expect(infoPlist, contains("net.monolib.updater.helper"));

    expect(workflow, isNot(contains("DESKTOP_UPDATER_SMJOBBLESS")));
    expect(workflow, isNot(contains("SMJobBless")));
    expect(
      workflow,
      contains("DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_STAGED_APP"),
    );
  });
}
