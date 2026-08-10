import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:flutter_test/flutter_test.dart";

void main() {
  test("ad hoc macOS builds seal identifier-only helper authority", () {
    final debugPolicyFile = File(
      "example/macos/Runner/DesktopUpdaterHelperPolicy-Debug.json",
    );
    expect(debugPolicyFile.existsSync(), isTrue);
    if (!debugPolicyFile.existsSync()) {
      return;
    }
    final policySource = debugPolicyFile.readAsStringSync();
    final policy = jsonDecode(policySource) as Map<String, dynamic>;
    final applicationSigner =
        policy["allowedApplicationSigner"] as Map<String, dynamic>;
    final helperSigner = policy["allowedHelperSigner"] as Map<String, dynamic>;
    expect(
      applicationSigner["value"],
      "identifier com.example.desktopUpdaterSmoke",
    );
    expect(
      helperSigner["value"],
      "identifier com.example.desktopUpdaterSmoke.helper",
    );
    final canonicalPolicy = policySource.endsWith("\n")
        ? policySource.substring(0, policySource.length - 1)
        : policySource;
    final policySHA256 =
        crypto.sha256.convert(utf8.encode(canonicalPolicy)).toString();
    final project = File(
      "example/macos/Runner.xcodeproj/project.pbxproj",
    ).readAsStringSync();
    final embed = File(
      "macos/install_helper/embed_install_helper.sh",
    ).readAsStringSync();
    expect(project, contains("DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_PATH"));
    expect(project, contains("DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_SHA256"));
    expect(project, contains(policySHA256));
    expect(embed, contains("DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_PATH"));
    expect(embed, contains("DESKTOP_UPDATER_AD_HOC_SEALED_POLICY_SHA256"));
  });

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
    expect(host, contains('"installAuthority": installAuthority'));
    expect(host, contains('"targetPath": targetPath'));
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
    expect(
        host, contains("DesktopUpdaterPlugin.loadVerifiedStageForSmokeHost("));
    expect(host, contains("transactionID: transactionID"));
    expect(host, isNot(contains("MacVerifiedStage(")));
    expect(host, isNot(contains("allowUnsignedUpdates")));
    expect(host, isNot(contains("diagnosticsLogPath")));
    expect(host, contains("commitAfterExit"));
    expect(host, contains("recoverPendingInstall"));
    expect(host, contains("queryTransaction"));
    expect(host, contains("Unmanaged.passRetained(reservation)"));
    expect(host, contains('"reservationPreservedForRecovery"'));
    expect(
      host,
      isNot(
        contains(
          "Privileged prepareOnly reservation was not cancelled.",
        ),
      ),
    );
    expect(host, contains("Darwin.exit"));

    expect(smoke, contains("DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_STAGED_APP"));
    expect(
      smoke,
      contains('const _protectedSmokeRoot = "/Applications";'),
    );
    expect(
      smoke,
      contains("Desktop Updater Smoke.app"),
    );
    expect(smoke, contains("path.dirname(app.path)"));
    expect(smoke, isNot(contains("DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_HOST")));
    expect(smoke, contains('phase: "prepareOnly"'));
    expect(smoke, contains('phase: "commit"'));
    expect(smoke, contains('phase: "recover"'));
    expect(smoke, contains('phase: "query"'));
    expect(smoke, contains("--exit-gate"));
    expect(smoke, contains("--transaction-id"));
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
    expect(smoke, contains('evidence["targetParentWritable"] is! bool'));
    expect(
      smoke,
      contains('evidence["installAuthority"] != _installAuthority'),
    );
    expect(smoke, contains('evidence["targetPath"] != _targetPath'));
    expect(smoke, contains('evidence["privilegedDaemonExecuted"] != true'));
    expect(smoke, contains("recoverableSwapExecuted"));
    expect(smoke, isNot(contains("_smokeSentinelName")));
    expect(smoke, contains("native-runtime-smoke-stable"));
    expect(policy, contains('"keyId":"native-runtime-smoke-stable"'));
    expect(
      policy,
      contains('"allowedInstallRoots":["/Applications"]'),
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
    expect(infoPlist, contains("com.example.desktopUpdaterSmoke.helper"));

    expect(workflow, isNot(contains("DESKTOP_UPDATER_SMJOBBLESS")));
    expect(workflow, isNot(contains("SMJobBless")));
    expect(
      workflow,
      contains("DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_STAGED_APP"),
    );
  });

  test("smoke environment hooks cannot alter normal package behavior", () {
    final currentVersion = File(
      "lib/src/current_version.dart",
    ).readAsStringSync();
    final helper = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();
    final plugin = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    final publicInitializer = helper.substring(
      helper.indexOf("    public init() {"),
      helper.indexOf("    @_spi(DesktopUpdaterSmoke)",
          helper.indexOf("    public init() {")),
    );

    expect(currentVersion, isNot(contains("DESKTOP_UPDATER_CONTROLLER_SMOKE")));
    expect(
      currentVersion,
      isNot(contains("DESKTOP_UPDATER_CONTROLLER_SMOKE_CURRENT_VERSION")),
    );
    expect(publicInitializer, isNot(contains("validatedSmokeTargetURL")));
    expect(publicInitializer, isNot(contains("smokeTargetPath")));
    expect(plugin, contains("smokeRelaunchSuppressionAllowed"));
    expect(plugin, contains("com.example.desktopUpdaterSmoke"));
    expect(plugin, contains("/Applications/Desktop Updater Smoke.app"));
    expect(plugin, contains("DESKTOP_UPDATER_CONTROLLER_SMOKE_TARGET"));
  });
}
