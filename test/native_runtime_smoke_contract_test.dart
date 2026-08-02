import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:flutter_test/flutter_test.dart";

import "../tool/native_runtime_smoke_server.dart" as smoke_server;

void main() {
  test("external samples drive the complete packaged runtime flow", () {
    final swiftClient = readFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/UpdateClient.swift",
    );
    final swiftSample = readDirectory("example/native/macos-runtime");
    final linuxHeader = readFile(
      "linux/native/include/desktop_updater_runtime.h",
    );
    final linuxSample = readDirectory("example/native/linux-cmake-runtime");
    final windowsHeader = readFile(
      "windows/native/include/desktop_updater_runtime_c.h",
    );
    final dotnetClient = readFile(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs",
    );
    final windowsSample = readDirectory(
      "example/native/windows-dotnet-runtime",
    );

    for (final source in [swiftClient, swiftSample]) {
      expect(source, contains("checkForUpdate"));
      expect(source, contains("downloadVerifyAndStage"));
      expect(source, contains("installAndRelaunch"));
    }
    for (final source in [linuxHeader, linuxSample]) {
      expect(source, contains("CheckForUpdate"));
      expect(source, contains("DownloadVerifyAndStage"));
      expect(source, contains("InstallAndRelaunch"));
    }
    for (final source in [windowsHeader, dotnetClient, windowsSample]) {
      expect(source.toLowerCase(), contains("check_for_update"));
      expect(source.toLowerCase(), contains("download_verify_and_stage"));
      expect(source.toLowerCase(), contains("install_and_relaunch"));
    }
  });

  test("runtime smoke harness is local, bounded, signed, and disposable", () {
    final server = readFile("tool/native_runtime_smoke_server.dart");
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final linuxSample = readDirectory("example/native/linux-cmake-runtime");

    expect(server, contains("Ed25519"));
    expect(server, contains("native-runtime-smoke-stable"));
    expect(server, contains("127.0.0.1"));
    expect(server, contains("HttpHeaders.rangeHeader"));
    expect(server, contains("maximumArtifactBytes"));
    expect(server, contains("delete(recursive: true)"));

    for (final lane in [
      "macOS native runtime ZIP package and unsigned rejection smoke",
      "macOS native runtime DMG smoke",
      "macOS native runtime PKG approval-required smoke",
      "Run preapproved signed PKG target-host smoke",
      "Windows native runtime ZIP smoke",
      "Windows native runtime Inno smoke",
      "Linux native runtime ZIP smoke",
    ]) {
      expect(workflow, contains(lane), reason: lane);
    }
    expect(workflow, contains("DESKTOP_UPDATER_RUN_SIGNED_NATIVE_RUNTIME_E2E"));
    expect(linuxSample, contains("/usr/bin"));
    expect(linuxSample, contains("must remain unchanged"));
  });

  test("runtime smoke server signs app archive discovery metadata", () async {
    final json = await smoke_server.signedIndex(
      appName: "NativeRuntimeSmoke",
      version: "2.7.1",
      buildNumber: 271,
      platform: "macos",
      releaseURL: Uri.parse("http://127.0.0.1:43892/release.json"),
    );
    final publicKey = await smoke_server
        .smokeKeyPair()
        .then((keyPair) => keyPair.extractPublicKey());
    final index = ReleaseIndex.fromJson(json);

    expect(index.signature?.publicKeyId, smoke_server.publicKeyId);
    expect(
      await Ed25519ReleaseIndexSignatureVerifier({
        smoke_server.publicKeyId: base64Encode(publicKey.bytes),
      }).verify(index),
      isTrue,
    );
  });

  test("runtime smoke consumers use installed package boundaries", () {
    final swiftPackage = readFile(
      "example/native/macos-runtime/Package.swift",
    );
    final dotnetProject = readFile(
      "example/native/windows-dotnet-runtime/DesktopUpdater.RuntimeCompile.csproj",
    );
    final linuxProject = readFile(
      "example/native/linux-cmake-runtime/CMakeLists.txt",
    );
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");

    expect(swiftPackage, contains("DESKTOP_UPDATER_PACKAGE_PATH"));
    expect(dotnetProject, contains("PackageReference"));
    expect(dotnetProject, isNot(contains("ProjectReference")));
    expect(linuxProject, contains("find_package(desktop_updater_native"));
    expect(workflow, contains(r"DesktopUpdater.Native.$"));
    expect(workflow, contains("CMAKE_PREFIX_PATH"));
  });

  test("macOS runtime smokes execute helper-embedded app bundles", () {
    final packager = readFile(
      "example/native/macos-runtime/package_smoke_app.sh",
    );
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final zipStart = workflow.indexOf(
      "- name: macOS native runtime ZIP package and unsigned rejection smoke",
    );
    final zipEnd = workflow.indexOf("\n  macos-flutter:", zipStart);
    final dmgStart = workflow.indexOf(
      "- name: macOS native runtime DMG smoke",
    );
    final dmgEnd = workflow.indexOf(
      "- name: macOS native runtime PKG approval-required smoke",
      dmgStart,
    );
    final pkgStart = dmgEnd;
    final pkgEnd = workflow.indexOf(
      "- name: Clean native runtime macOS smoke roots",
      pkgStart,
    );

    expect(packager, contains("embed_install_helper.sh"));
    expect(packager, contains("Contents/MacOS/MacOSRuntimeCompile"));
    expect(packager, contains("Contents/Helpers/DesktopUpdaterInstallHelper"));
    expect(packager, contains("Contents/Library/LaunchDaemons"));
    expect(packager, contains("DESKTOP_UPDATER_RUNTIME_ALLOWED_INSTALL_ROOT"));
    expect(packager, contains("desktop_updater_smoke_owner.txt"));
    expect(packager, contains("desktop_updater macOS production smoke"));
    expect(packager, contains("DESKTOP_UPDATER_RUNTIME_NOTARY_PROFILE"));
    expect(packager, contains("notarytool submit"));
    expect(packager, contains("stapler staple"));
    expect(packager, contains("spctl --assess --type execute"));
    expect(packager, contains("codesign --verify --deep --strict"));
    expect(packager, contains("pkgutil --expand-full"));
    expect(packager, contains("component.pkg/Payload"));
    expect(
      packager,
      contains("Contents/Helpers/DesktopUpdaterInstallHelper"),
    );

    for (final boundary in [
      zipStart,
      zipEnd,
      dmgStart,
      dmgEnd,
      pkgStart,
      pkgEnd
    ]) {
      expect(boundary, greaterThanOrEqualTo(0));
    }
    final lanes = <String>[
      workflow.substring(zipStart, zipEnd),
      workflow.substring(dmgStart, dmgEnd),
      workflow.substring(pkgStart, pkgEnd),
    ];
    for (final lane in lanes) {
      expect(lane, contains("package_smoke_app.sh"));
      expect(lane, contains("Contents/MacOS/MacOSRuntimeCompile"));
      expect(lane, isNot(contains(r'"$consumer_bin"')));
      expect(lane, isNot(contains("--bundle-path")));
    }
    for (final lane in lanes.skip(1)) {
      expect(
        lane,
        contains(
          "DESKTOP_UPDATER_RUNTIME_NOTARY_PROFILE=\"\$DESKTOP_UPDATER_NOTARY_PROFILE\"",
        ),
      );
    }
  });

  test("ZIP smokes preserve caller-owned staging roots", () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");

    expect(workflow, contains(r"$cleanupComplete = $false"));
    expect(workflow, contains(r"$stagingRoot = Join-Path $smokeRoot"));
    expect(workflow, contains(r"$stagingClean = (Test-Path -LiteralPath"));
    expect(
      workflow,
      contains(r"Get-ChildItem -LiteralPath $stagingRoot -Force"),
    );
    expect(
      workflow,
      contains(
        r"$versionReady -and $stagingClean -and $moveComplete -and $cleanupComplete",
      ),
    );
    expect(workflow, isNot(contains(r"$stagingRemoved")));
    expect(
      RegExp(
        RegExp.escape(r'test -d "$smoke_root/runtime/staging"'),
      ).allMatches(workflow),
      hasLength(2),
    );
    expect(
      RegExp(
        RegExp.escape(
          r'test -z "$(find "$smoke_root/runtime/staging" '
          r'-mindepth 1 -maxdepth 1 -print -quit)"',
        ),
      ).allMatches(workflow),
      hasLength(1),
    );
    expect(
      workflow,
      contains(
        r'test -n "$(find "$smoke_root/runtime/staging" '
        r'-mindepth 1 -maxdepth 1 -print -quit)"',
      ),
    );
    expect(
      workflow,
      isNot(contains(r'test ! -e "$smoke_root/runtime/staging"')),
    );
  });

  test("macOS ZIP smoke rejects unsigned handoff before helper launch", () {
    final sample = readFile(
      "example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift",
    );
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final start = workflow.indexOf(
      "- name: macOS native runtime ZIP package and unsigned rejection smoke",
    );
    final end = workflow.indexOf("\n  macos-flutter:", start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final lane = workflow.substring(start, end);
    expect(sample, contains("--expect-unsigned-handoff-rejection"));
    expect(sample, contains("Expected unsigned install handoff rejection"));
    expect(lane, contains("--expect-unsigned-handoff-rejection"));
    expect(lane, contains("Expected unsigned install handoff rejection"));
    expect(lane, contains(r'test ! -e "$smoke_root/helper-diagnostics.jsonl"'));
    expect(lane, contains('= "2.7.0"'));
    expect(lane, isNot(contains('= "2.7.1"')));
    expect(lane, isNot(contains('"event":"move success"')));
    expect(lane, isNot(contains('"event":"cleanup success"')));
  });

  test("hosted macOS PKG smoke records the required admin approval", () {
    final sample = readFile(
      "example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift",
    );
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final start = workflow.indexOf(
      "- name: macOS native runtime PKG approval-required smoke",
    );
    final end = workflow.indexOf(
      "- name: Clean native runtime macOS smoke roots",
      start,
    );

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final lane = workflow.substring(start, end);
    expect(sample, contains("--expect-helper-approval-required"));
    expect(
        sample, contains("Expected SMAppService admin approval requirement"));
    expect(lane, contains("--expect-helper-approval-required"));
    expect(
      lane,
      isNot(contains("dart run tool/macos_production_smoke.dart pkg-artifact")),
    );
    expect(
      lane,
      contains("DESKTOP_UPDATER_RUNTIME_PKG_OUTPUT=\"\$artifact\""),
    );
    expect(
      lane,
      contains(
        "DESKTOP_UPDATER_RUNTIME_PKG_INSTALLER_IDENTITY="
        "\"\$DESKTOP_UPDATER_DEV_ID_INSTALLER\"",
      ),
    );
    expect(lane, contains("DESKTOP_UPDATER_TEST_VERSION_V2"));
    expect(lane, contains("DESKTOP_UPDATER_TEST_BUILD_V2"));
    expect(lane, contains(r'pkgutil --check-signature "$artifact"'));
    expect(lane, contains(r'spctl --assess --type install "$artifact"'));
    expect(lane, contains(r'xcrun stapler validate "$artifact"'));
    expect(lane, contains("Expected SMAppService admin approval requirement"));
    expect(lane, contains(r'app_path="/Applications/$app_name.app"'));
    expect(
      lane,
      contains(r'DESKTOP_UPDATER_RUNTIME_ALLOWED_INSTALL_ROOT="/Applications"'),
    );
    expect(lane, contains("desktop_updater_smoke_owner.txt"));
    expect(lane, contains("Contents/MacOS/MacOSRuntimeCompile"));
    expect(lane, contains("Contents/Helpers/DesktopUpdaterInstallHelper"));
    expect(lane, contains('= "2.7.0"'));
    expect(lane, contains(r'test -n "$(find "$runtime_root/client/staging"'));
    expect(lane, isNot(contains("--expect-pkg-strategy-rejection")));
    expect(lane, isNot(contains("Expected PKG strategy rejection")));
  });

  test("self-hosted macOS lane proves preapproved PKG install and recovery",
      () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final recoveryStart = workflow.indexOf(
      "- name: Run signed bundled SMAppService daemon and XPC recovery smoke",
    );
    final pkgStart = workflow.indexOf(
      "- name: Run preapproved signed PKG target-host smoke",
      recoveryStart,
    );
    final pkgEnd = workflow.indexOf(
      "- name: Upload macOS SMAppService target-host evidence",
      pkgStart,
    );

    expect(recoveryStart, greaterThanOrEqualTo(0));
    expect(pkgStart, greaterThan(recoveryStart));
    expect(pkgEnd, greaterThan(pkgStart));
    final recovery = workflow.substring(recoveryStart, pkgStart);
    final pkg = workflow.substring(pkgStart, pkgEnd);
    expect(recovery,
        contains("macos_install_helper_smoke.dart --mode privileged"));
    expect(recovery, contains("macos-smappservice-recovery.jsonl"));
    expect(pkg, contains("DESKTOP_UPDATER_SMAPPSERVICE_PKG_SMOKE_APP"));
    expect(pkg, contains("DESKTOP_UPDATER_SMAPPSERVICE_PKG_SMOKE_ARTIFACT"));
    expect(pkg, contains("DESKTOP_UPDATER_SMAPPSERVICE_PKG_RECEIPT_ID"));
    expect(pkg, contains("native_runtime_smoke_server.dart"));
    expect(pkg, contains("--artifact-kind pkgInstaller"));
    expect(pkg, contains(r'test "$executable" = MacOSRuntimeCompile'));
    expect(pkg, contains(r'"$app/Contents/MacOS/$executable"'));
    expect(pkg, contains("--expected-team-identifier"));
    expect(pkg, contains("pkgutil --pkg-info-plist"));
    expect(pkg, contains(r'post_info="$app/Contents/Info.plist"'));
    expect(pkg, contains("post_package_id="));
    expect(pkg, contains("post_executable="));
    expect(pkg, contains("post_service_id="));
    expect(pkg, contains(r'test "$post_package_id" = "$package_id"'));
    expect(pkg, contains(r'test "$post_executable" = "$executable"'));
    expect(pkg, contains(r'test "$post_service_id" = "$service_id"'));
    expect(pkg, contains(r'post_helper="$app/Contents/Helpers/'));
    expect(
        pkg, contains(r'post_launchd="$app/Contents/Library/LaunchDaemons/'));
    expect(pkg,
        contains(r'codesign --verify --strict --verbose=2 "$post_helper"'));
    expect(pkg, contains(r'test "$post_helper_team_id" = "$team_id"'));
    expect(pkg, contains(r'launchctl print "system/$post_service_id"'));
    expect(pkg, contains("installedHelperVerified=true"));
    expect(pkg, contains("macos-smappservice-pkg.txt"));
    expect(
      pkg,
      isNot(contains("--expect-helper-approval-required")),
    );
  });

  test("Linux ZIP smoke packages the executable helper and sealed policy", () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final helperMain = readFile("linux/native/src/helper/main.cc");
    final start = workflow.indexOf("- name: Linux native runtime ZIP smoke");
    final end = workflow.indexOf("- name: Enable Linux desktop", start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final lane = workflow.substring(start, end);
    expect(
      lane,
      contains(r'mkdir -p "$smoke_root/install" "$smoke_root/payload"'),
    );
    expect(
      lane,
      contains(r'"$smoke_root/install/runtime_compile"'),
    );
    expect(
      RegExp(
        RegExp.escape(
          ".desktop_updater_install_identity.json",
        ),
      ).allMatches(lane),
      hasLength(2),
    );
    expect(lane, contains('"packageId":"com.example.native-runtime-smoke"'));
    expect(lane, contains("--executable-relative-path runtime_compile"));
    expect(
      lane,
      contains(
        r'helper_source="$PWD/linux/native/install/libexec/desktop-updater-helper"',
      ),
    );
    expect(
      lane,
      contains(
          r'install -m 0755 "$helper_source" "$root/desktop-updater-helper"'),
    );
    expect(
      lane,
      contains("--canonical-portable-consumer-policy"),
    );
    expect(
      lane,
      contains(r'> "$root/desktop-updater-helper.policy.json"'),
    );
    expect(
      lane,
      contains(
          r'''for root in "$smoke_root/install" "$smoke_root/payload"; do'''),
    );
    expect(
        lane,
        contains(
            r'''test "$(stat -c '%a' "$root/desktop-updater-helper")" = 755'''));
    expect(
        lane,
        contains(
            r'''test "$(stat -c '%a' "$root/desktop-updater-helper.policy.json")" = 600'''));
    expect(
      lane,
      contains(
        r'''test "$(stat -c '%u:%g' "$root/desktop-updater-helper")" = "$(id -u):$(id -g)"''',
      ),
    );
    expect(
      lane.indexOf(r'> "$root/desktop-updater-helper.policy.json"'),
      lessThan(lane.indexOf("zip -qr")),
    );
    expect(lane,
        contains(r'test -x "$smoke_root/install/desktop-updater-helper"'));
    expect(
      lane,
      contains(
          r'test -f "$smoke_root/install/desktop-updater-helper.policy.json"'),
    );
    expect(lane, contains(r'export XDG_STATE_HOME="$smoke_root/state"'));
    expect(lane, contains(r'mkdir -p "$XDG_STATE_HOME"'));
    expect(lane, contains(r'chmod 700 "$XDG_STATE_HOME"'));
    expect(
      lane,
      contains(
          r'events_log="$smoke_root/state/desktop-updater/transactions/events.jsonl"'),
    );
    expect(lane, contains(r'grep -q "\"event\":\"activation verified\""'));
    expect(lane, contains(r'grep -q "\"event\":\"transaction completed\""'));
    expect(lane, isNot(contains("DESKTOP_UPDATER_TEST_REPORT_HELPER_ERRORS")));
    expect(lane, isNot(contains('"event":"move success"')));
    expect(lane, isNot(contains('"event":"cleanup success"')));
    expect(helperMain,
        isNot(contains("DESKTOP_UPDATER_TEST_REPORT_HELPER_ERRORS")));
    expect(
      helperMain,
      isNot(contains("desktop-updater-helper test diagnostic")),
    );
    expect(lane, isNot(contains(r'"$smoke_root/install/bin/runtime_compile"')));
  });

  test("Windows ZIP smoke seals matching identity and portable policy", () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final setupStart = workflow.indexOf(
      "- name: Prepare hosted Windows ZIP smoke signing trust",
    );
    final setupEnd = setupStart < 0
        ? -1
        : workflow.indexOf(
            "- name: Configure standalone Windows native SDK tests",
            setupStart,
          );
    final start = workflow.indexOf("- name: Windows native runtime ZIP smoke");
    final end = workflow.indexOf(
      "- name: Windows native runtime Inno smoke",
      start,
    );
    final cleanupStart = workflow.indexOf(
      "- name: Cleanup hosted Windows ZIP smoke signing trust",
      end,
    );
    final cleanupEnd = cleanupStart < 0
        ? -1
        : workflow.indexOf(
            "\n\n  windows-elevated-helper:",
            cleanupStart,
          );

    expect(setupStart, greaterThanOrEqualTo(0));
    expect(setupEnd, greaterThan(setupStart));
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    expect(cleanupStart, greaterThan(end));
    expect(cleanupEnd, greaterThan(cleanupStart));
    final setupLane = workflow.substring(setupStart, setupEnd);
    final lane = workflow.substring(start, end);
    final cleanupLane = workflow.substring(cleanupStart, cleanupEnd);
    expect(
      RegExp(
        RegExp.escape(".desktop_updater_install_identity.json"),
      ).allMatches(lane),
      hasLength(2),
    );
    expect(lane, contains(r'"packageId":"com.example.native-runtime-smoke"'));
    expect(
      lane.indexOf(".desktop_updater_install_identity.json"),
      lessThan(lane.indexOf("Compress-Archive")),
    );
    expect(lane, contains(r"foreach ($root in @($install, $payload))"));
    expect(lane, contains("DesktopUpdater.RuntimeCompile.exe"));
    expect(lane, contains("desktop_updater_install_helper.exe"));
    expect(
      setupLane,
      contains(
        "[System.Security.Cryptography.X509Certificates.CertificateRequest]::new",
      ),
    );
    expect(
      setupLane,
      contains(
        "[System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new",
      ),
    );
    expect(setupLane, contains("timeout-minutes: 2"));
    expect(setupLane, contains("native-runtime-windows-zip-signing"));
    expect(setupLane, contains("1.3.6.1.5.5.7.3.3"));
    expect(setupLane, contains("certutil.exe"));
    expect(setupLane, contains("certutil.exe -f -addstore"));
    expect(setupLane, isNot(contains("certutil.exe -user")));
    expect(setupLane,
        contains('foreach (\$storeName in @("Root", "TrustedPublisher"))'));
    expect(setupLane, isNot(contains("X509Store")));
    expect(setupLane, isNot(contains(r"$store.Add($publicCertificate)")));
    expect(setupLane, contains("RSA key is ready"));
    expect(setupLane, contains("certificate is ready"));
    expect(setupLane, contains(r'$storeName trust is ready'));
    expect(lane, contains("signtool.exe"));
    expect(lane, contains("New-LocalUser"));
    expect(lane, contains('Get-LocalGroup -SID "S-1-5-32-544"'));
    expect(lane, contains('Get-LocalGroup -SID "S-1-5-32-545"'));
    expect(lane, contains(r"-Credential $smokeCredential"));
    expect(lane, contains("-LoadUserProfile"));
    expect(
      lane,
      contains(
        "[Environment]::GetFolderPath("
        "[Environment+SpecialFolder]::LocalApplicationData, "
        "[Environment+SpecialFolderOption]::Create)",
      ),
    );
    expect(
      lane,
      contains("[IO.Directory]::CreateDirectory(\$localAppData)"),
    );
    expect(
      lane,
      contains(
        r"[IO.File]::WriteAllText("
        "\n"
        r"                $profileProbePath,",
      ),
    );
    expect(lane, contains(r'"-File", $profileProbePath'));
    expect(lane, isNot(contains("-EncodedCommand")));
    expect(lane, isNot(contains("ToBase64String")));
    expect(
      lane,
      contains(
        r"DESKTOP_UPDATER_SMOKE_EXPECTED_LOCALAPPDATA = $smokeLocalAppData",
      ),
    );
    expect(
      lane,
      contains(
        r"LocalApplicationData resolved outside the standard-user profile.",
      ),
    );
    expect(
      RegExp(
        r"-Credential \$smokeCredential -LoadUserProfile "
        r"-Environment \$smokeEnvironment",
      ).allMatches(lane),
      hasLength(3),
    );
    expect(lane, contains("Portable restage deliberately protects"));
    expect(
      lane,
      contains(
        r'$smokeEnvironment["DESKTOP_UPDATER_SMOKE_INSTALL"] = $install',
      ),
    );
    expect(lane, contains('"post-smoke-verify.ps1"'));
    expect(
      lane,
      contains("Standard-user ZIP smoke did not observe version 2.7.1."),
    );
    expect(
      lane.indexOf("Hosted Windows ZIP smoke LocalAppData is ready."),
      lessThan(
        lane.indexOf(
          r'$runtimeProcess = Start-Process -FilePath '
          r'(Join-Path $install "DesktopUpdater.RuntimeCompile.exe")',
        ),
      ),
    );
    expect(lane, contains("Remove-LocalUser"));
    expect(
      lane,
      isNot(
        contains(
          r'& (Join-Path $install "DesktopUpdater.RuntimeCompile.exe")',
        ),
      ),
    );
    expect(lane, contains(r'$signingRoot = Join-Path $env:RUNNER_TEMP'));
    expect(lane, contains(r'Join-Path $signingRoot "hosted-smoke.pfx"'));
    expect(
      lane,
      contains(r"sign /fd SHA256 /f $pfx /p $pfxPassword $binary"),
    );
    expect(lane, isNot(contains("Set-AuthenticodeSignature")));
    expect(lane, contains(r"failed to trust ${binary}:"));
    expect(cleanupLane, contains("if: always()"));
    expect(cleanupLane, contains("timeout-minutes: 2"));
    expect(cleanupLane, contains("certutil.exe"));
    expect(cleanupLane, contains("certutil.exe -f -delstore"));
    expect(cleanupLane, isNot(contains("certutil.exe -user")));
    expect(cleanupLane, isNot(contains("X509Store")));
    expect(cleanupLane, isNot(contains(r"$store.Remove($certificate)")));
    expect(
      cleanupLane,
      contains(
        r"Remove-Item -LiteralPath $signingRoot -Recurse -Force",
      ),
    );
    expect(setupLane, isNot(contains("New-SelfSignedCertificate")));
    expect(setupLane, isNot(contains("Import-Certificate")));
    expect(setupLane, isNot(contains(r"Cert:\CurrentUser")));
    expect(setupLane, isNot(contains("using namespace")));
    expect(lane, contains("allowedApplicationSigner"));
    expect(lane, contains("allowedHelperSigner"));
    expect(lane, contains("native-runtime-smoke-stable"));
    expect(
      lane,
      contains("uvxxvq06xeS2PpyCFu5xo0quxlci7tvKcotOmzzM45Y="),
    );
    expect(lane, contains("desktop_updater_helper_policy.json"));
    expect(
      lane.indexOf("desktop_updater_helper_policy.json"),
      lessThan(lane.indexOf("Compress-Archive")),
    );
    expect(
      lane.indexOf(r"sign /fd SHA256 /f $pfx /p $pfxPassword $binary"),
      lessThan(lane.indexOf(r"Get-FileHash -LiteralPath $caller")),
    );
  });

  test(
      "Windows ZIP smoke outlives helper retries and preserves Event Log evidence",
      () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final start = workflow.indexOf("- name: Windows native runtime ZIP smoke");
    final end = workflow.indexOf(
      "- name: Windows native runtime Inno smoke",
      start,
    );

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final lane = workflow.substring(start, end);
    expect(lane, contains("timeout-minutes: 12"));
    expect(lane, contains(r'$ConfirmPreference = "None"'));
    expect(
      lane,
      contains(r"for ($attempt = 0; $attempt -lt 600; $attempt++)"),
    );
    expect(
        lane,
        contains(
            r'$helperEventProvider = "DesktopUpdater.InstallHelper.ProtocolV1"'));
    expect(
        lane,
        contains(
            r'$moveComplete = @($helperEvents | Where-Object { $_.Id -eq 1008 }).Count -gt 0'));
    expect(
        lane,
        contains(
            r'$cleanupComplete = @($helperEvents | Where-Object { $_.Id -eq 1014 }).Count -gt 0'));
    expect(lane, isNot(contains(r'Get-Content -LiteralPath $diagnosticsPath')));
    final eventQuery = lane.indexOf(
      r'Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $helperEventStart }',
    );
    final versionFailure = lane.indexOf(
      "Windows ZIP runtime smoke did not install version 2.7.1.",
    );
    final smokeCleanup = workflow.indexOf(
      r"Remove-Item -LiteralPath $smokeRoot -Recurse -Force",
      end,
    );
    expect(eventQuery, greaterThanOrEqualTo(0));
    expect(versionFailure, greaterThan(eventQuery));
    expect(smokeCleanup, greaterThan(end));
  });

  test("direct Flutter smokes hand off owned verified provenance", () {
    final tool = readFile("example/tool/updater_smoke.dart");
    final app = readFile("example/lib/app.dart");

    expect(tool, contains("createOwnedStagingDirectory("));
    expect(tool, contains("_copyInstallTree("));
    expect(tool, contains("robocopy"));
    expect(tool, contains("executable = \"/bin/cp\""));
    expect(tool, contains("Process.run(executable, arguments)"));
    expect(tool, contains(".desktop_updater_install_identity.json"));
    expect(tool, contains("Platform.isWindows || Platform.isLinux"));
    expect(tool, contains("Platform.isLinux"));
    expect(tool, contains("_writeLinuxNativeStageControl("));
    expect(tool, contains("Platform.isWindows"));
    expect(tool, contains("_writeWindowsNativeStageControl("));
    expect(tool, contains("_writeWindowsPortableHelperPolicy("));
    expect(tool, contains('"desktop_updater_helper_policy.json"'));
    expect(tool, contains('"allowedApplicationSigner"'));
    expect(tool, contains('"allowedHelperSigner"'));
    expect(tool, contains('platform: "windows"'));
    expect(tool, contains(".desktop_updater_artifact.zip"));
    expect(tool, contains(".desktop_updater_release_manifest.json"));
    expect(tool, contains("ReleaseDescriptor("));
    expect(tool, contains("Ed25519().sign("));
    expect(tool, isNot(contains("_retainMinimalLinuxStage(")));
    expect(tool, contains("releaseRootPublicKeys"));
    expect(tool, contains("desktop-updater-helper.policy.json"));
    expect(tool, contains("await _chmod(helper.parent.path, \"755\")"));
    expect(tool, contains("await _chmod(helper.path, \"755\")"));
    expect(tool, contains("nativeStageControl?.descriptorSha256"));
    expect(tool, contains("nativeStageControl?.artifactSha256"));
    expect(tool, contains("writeStagedUpdateProvenance("));
    expect(tool, contains("Directory(_join(tempRoot.path, \"state\"))"));
    expect(tool, contains("await _chmod(linuxStateHome.path, \"700\")"));
    expect(tool, contains("\"XDG_STATE_HOME\": linuxStateHome.path"));
    expect(tool, contains("_prepareLinuxRelaunchXauthority("));
    expect(tool, contains("\"XAUTHORITY\": linuxXauthority.path"));
    expect(tool, contains("_expectLinuxTransactionEvents("));
    expect(tool, contains("\"events.jsonl\""));
    expect(tool, contains("\"activation verified\""));
    expect(tool, contains("\"transaction completed\""));
    expect(tool, contains("stdoutSubscription.cancel()"));
    expect(tool, contains("stderrSubscription.cancel()"));
    expect(tool, contains("DESKTOP_UPDATER_SMOKE_PROVENANCE_SHA256"));
    expect(tool, contains("DESKTOP_UPDATER_SMOKE_INSTALL_ROOT"));
    expect(
      tool,
      contains("DESKTOP_UPDATER_SMOKE_EXECUTABLE_RELATIVE_PATH"),
    );
    expect(app, contains("DESKTOP_UPDATER_SMOKE_PROVENANCE_SHA256"));
    expect(app, contains("DESKTOP_UPDATER_SMOKE_INSTALL_ROOT"));
    expect(app, contains("DESKTOP_UPDATER_SMOKE_EXECUTABLE_RELATIVE_PATH"));
    expect(app, contains("verifyStagedUpdateProvenance("));
    expect(
      app,
      contains("DesktopUpdaterPlatform.instance.installUpdateWithContext("),
    );
    expect(app, contains("stageProvenanceSha256:"));
    expect(app, contains("stageProvenanceNonce:"));
    expect(app, contains("stageProvenanceEntries:"));
    expect(app, contains("expectedArtifactSha256:"));
    expect(app, contains("installRoot: installRoot"));
    expect(app, contains("executableRelativePath: executableRelativePath"));
  });

  test("Windows Flutter smokes sign both caller and helper before handoff", () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    expect(workflow, contains("Sign Windows debug smoke binaries"));
    expect(workflow, contains("Sign Windows release smoke binaries"));
    expect(workflow, contains("Debug/desktop_updater_example.exe"));
    expect(workflow, contains("Debug/desktop_updater_install_helper.exe"));
    expect(workflow, contains("Release/desktop_updater_example.exe"));
    expect(workflow, contains("Release/desktop_updater_install_helper.exe"));
  });

  test("Windows Flutter smokes use a non-administrator portable helper user",
      () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final runner = readFile("tool/windows_direct_flutter_smoke.ps1");

    expect(workflow, contains("windows_direct_flutter_smoke.ps1"));
    expect(runner, contains("New-LocalUser"));
    expect(
        runner, contains("Account unexpectedly has administrator authority"));
    expect(runner, contains("Start-Process"));
    expect(runner, contains(r"$smokeRunner"));
    expect(RegExp(r"\$host\b", caseSensitive: false).hasMatch(runner), isFalse);
    expect(runner, contains(r"-Credential $smokeCredential"));
    expect(runner, contains("-LoadUserProfile"));
    expect(
      runner,
      contains(
        "[Environment]::GetFolderPath("
        "[Environment+SpecialFolder]::LocalApplicationData, "
        "[Environment+SpecialFolderOption]::Create)",
      ),
    );
    expect(
      runner,
      contains(
        r"DESKTOP_UPDATER_SMOKE_EXPECTED_LOCALAPPDATA = $smokeLocalAppData",
      ),
    );
    expect(
      runner.indexOf("LocalApplicationData is ready."),
      lessThan(
        runner.indexOf(
          r"$smokeProcess = Start-Process -FilePath $smokeRunner",
        ),
      ),
    );
    expect(runner, contains("Remove-LocalUser"));
    expect(runner, contains("dart compile exe"));
  });

  test("Windows ZIP handoff does not read Inno signer metadata", () {
    final source = readFile(
      "windows/native/src/runtime/artifact_stager_windows.cpp",
    );
    final handoffStart = source.indexOf(
      "WindowsInstallHandoffResult HandoffWindowsInstall(",
    );
    final handoffEnd = source.indexOf(
      "desktop_updater_result_v1 result",
      handoffStart,
    );

    expect(handoffStart, greaterThanOrEqualTo(0));
    expect(handoffEnd, greaterThan(handoffStart));
    final handoff = source.substring(handoffStart, handoffEnd);
    expect(
      handoff,
      matches(
        RegExp(
          r'if\s*\(descriptor\.artifact\.kind == "innoInstaller"\)\s*\{'
          r'\s*for\s*\(const std::string& thumbprint\s*:'
          r'\s*AuthenticodeThumbprints\(descriptor\)\)',
        ),
      ),
    );
  });
}

String readFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync()
      ? file.readAsStringSync().replaceAll("\r\n", "\n")
      : "";
}

String readDirectory(String path) {
  final directory = Directory(path);
  expect(directory.existsSync(), isTrue, reason: "$path must exist");
  if (!directory.existsSync()) return "";
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => !file.path.contains("${Platform.pathSeparator}.build"))
      .where((file) => !file.path.contains("${Platform.pathSeparator}obj"))
      .where((file) => !file.path.contains("${Platform.pathSeparator}bin"))
      .map((file) => file.readAsStringSync())
      .join("\n");
}
