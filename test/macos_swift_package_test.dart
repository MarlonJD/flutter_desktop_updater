import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "support/contract_source.dart";

void main() {
  test("SwiftPM contract rejects declarations outside Package fields", () {
    const bad = """
let floor = SupportedPlatform.macOS("10.15")
let product = Product.library(name: "DesktopUpdaterKit", targets: ["DesktopUpdaterKit"])
let target = Target.target(name: "DesktopUpdaterKit", path: "macos/desktop_updater/Sources/DesktopUpdaterKit")
let package = Package(name: "DesktopUpdaterKit", platforms: [], products: [], targets: [])
""";
    expect(
      _manifestErrors(
        bad,
        packageName: "DesktopUpdaterKit",
        targetPath: "macos/desktop_updater/Sources/DesktopUpdaterKit",
        flutter: false,
      ),
      isNotEmpty,
    );
  });

  test("SwiftPM binds FlutterFramework to the desktop-updater target", () {
    const bad = """
let package = Package(name: "desktop_updater", platforms: [.macOS("10.15")], products: [.library(name: "DesktopUpdaterKit", targets: ["DesktopUpdaterKit"]), .library(name: "desktop-updater", targets: ["desktop_updater"])], dependencies: [], targets: [.target(name: "DesktopUpdaterKit", path: "Sources/DesktopUpdaterKit"), .target(name: "desktop_updater", dependencies: []), .testTarget(name: "Decoy", dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")])])
let dependency = Package.Dependency.package(name: "FlutterFramework", path: "../FlutterFramework")
""";
    expect(
      _manifestErrors(
        bad,
        packageName: "desktop_updater",
        targetPath: "Sources/DesktopUpdaterKit",
        flutter: true,
      ),
      isNotEmpty,
    );
  });

  test("root and plugin SwiftPM manifests preserve the split contract", () {
    expect(
      _manifestErrors(
        File("Package.swift").readAsStringSync(),
        packageName: "DesktopUpdaterKit",
        targetPath: "macos/desktop_updater/Sources/DesktopUpdaterKit",
        flutter: false,
      ),
      isEmpty,
    );
    expect(
      _manifestErrors(
        File("macos/desktop_updater/Package.swift").readAsStringSync(),
        packageName: "desktop_updater",
        targetPath: "Sources/DesktopUpdaterKit",
        flutter: true,
      ),
      isEmpty,
    );
  });

  test("install helper remains a separate package from both kit products", () {
    final helper = File(
      "macos/install_helper/Package.swift",
    ).readAsStringSync();
    expect(helper, contains(".macOS(.v10_14)"));
    expect(
      helper,
      contains(
        '.executable(name: "DesktopUpdaterInstallHelper", '
        'targets: ["DesktopUpdaterInstallHelper"])',
      ),
    );
    for (final manifestPath in <String>[
      "Package.swift",
      "macos/desktop_updater/Package.swift",
    ]) {
      final manifest = File(manifestPath).readAsStringSync();
      expect(manifest, contains('.macOS("10.15")'));
      expect(manifest, isNot(contains("DesktopUpdaterInstallHelper")));
    }
  });

  test("native docs separate SwiftPM runtime from CocoaPods fallback", () {
    final nativeSdk = File(
      "docs/native-sdk.md",
    ).readAsStringSync().replaceAll(RegExp(r"\s+"), " ");
    final runtimeApi = File(
      "docs/native-runtime-api.md",
    ).readAsStringSync().replaceAll(RegExp(r"\s+"), " ");

    expect(
      nativeSdk,
      contains(
        "SwiftPM keeps the `DesktopUpdaterKit` product and import at macOS "
        "10.15 or newer.",
      ),
    );
    expect(
      nativeSdk,
      contains(
        "The CocoaPods fallback remains macOS 10.14 compatible and compiles "
        "only `DesktopUpdaterVersion.swift`, `Diagnostics.swift`, "
        "`MacInstallHelper.swift`, `MacInstallRequest.swift`, and "
        "`DesktopUpdaterPlugin.swift`.",
      ),
    );
    expect(
      nativeSdk,
      contains("It does not compile `DesktopUpdaterKit/Runtime/**`."),
    );
    expect(
      runtimeApi,
      contains(
        "The native runtime is SwiftPM-only at macOS 10.15 or newer; the "
        "macOS 10.14 CocoaPods fallback intentionally excludes `Runtime/**`.",
      ),
    );
  });

  test("macOS helper kit exposes verified explicit install API", () {
    final requestSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift",
    ).readAsStringSync();
    final helperSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync().replaceAll("\r\n", "\n");
    final diagnosticsSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift",
    ).readAsStringSync();
    final runtimeConfigurationSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/RuntimeError.swift",
    ).readAsStringSync();
    final artifactStagerSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/ArtifactStager.swift",
    ).readAsStringSync();
    final updateClientSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/UpdateClient.swift",
    ).readAsStringSync();
    final runnerSource = File(
      "example/macos/Runner/AppDelegate.swift",
    ).readAsStringSync();

    expect(
      requestSource,
      contains("public struct MacInstallRequest: Sendable"),
    );
    expect(
      requestSource,
      contains("public init(verifiedStage: MacVerifiedStage)"),
    );
    expect(requestSource, contains("public static func loadAndVerify("));
    expect(requestSource, contains("expectedPackageID: String"));
    expect(requestSource, contains("trustedReleasePublicKeys: [String: Data]"));
    expect(requestSource, isNot(contains("allowUnsignedUpdates")));
    expect(requestSource, isNot(contains("diagnosticsLogPath")));
    expect(
      runtimeConfigurationSource,
      isNot(contains("requireIndexSignature")),
    );
    expect(
      runtimeConfigurationSource,
      isNot(contains("requireDescriptorSignature")),
    );
    expect(artifactStagerSource, isNot(contains("allowUnsignedUpdates")));
    expect(updateClientSource, isNot(contains("allowUnsignedUpdates")));
    expect(helperSource, contains("public struct MacInstallHelper"));
    expect(helperSource, contains("public init()"));
    expect(
      helperSource,
      contains(
        "public func prepareInstall(\n"
        "        _ request: MacInstallRequest,\n"
        "        transactionID: String",
      ),
    );
    expect(helperSource, contains("public func commitAfterExit("));
    expect(helperSource, contains("public func queryTransaction("));
    expect(helperSource, contains("public func recoverPendingInstall("));
    expect(helperSource, isNot(contains("scheduleInstallAndRelaunch")));
    expect(
      helperSource,
      isNot(
        contains(
          "public func prepareInstall(\n"
          "        _ request: MacInstallRequest\n"
          "    )",
        ),
      ),
    );
    expect(diagnosticsSource, contains("public struct MacDiagnosticEvent"));
    expect(diagnosticsSource, contains("public init("));
    expect(
      runnerSource,
      contains("DesktopUpdaterPlugin.loadVerifiedStageForSmokeHost("),
    );
    expect(runnerSource, contains("transactionID: transactionID"));
    expect(runnerSource, isNot(contains("MacVerifiedStage(")));
    expect(runnerSource, isNot(contains("allowUnsignedUpdates")));
    expect(runnerSource, isNot(contains("diagnosticsLogPath")));
  });

  test("macOS production updater gates stay enabled by default", () {
    final pluginSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    final helperSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();
    final embedTool = File(
      "macos/install_helper/embed_install_helper.sh",
    ).readAsStringSync();
    final verifyTool = File(
      "macos/install_helper/verify_install_helper_layout.sh",
    ).readAsStringSync();
    final privilegeSource = File(
      "macos/install_helper/Sources/DesktopUpdaterInstallHelper/"
      "MacPrivilegeService.swift",
    ).readAsStringSync();
    final callerSource = File(
      "macos/install_helper/Sources/DesktopUpdaterInstallHelper/"
      "MacOneShotAuthorization.swift",
    ).readAsStringSync();
    final artifactVerifier = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/"
      "ArtifactStager.swift",
    ).readAsStringSync();
    final project = File(
      "example/macos/Runner.xcodeproj/project.pbxproj",
    ).readAsStringSync();
    final releaseEntitlements = File(
      "example/macos/Runner/Release.entitlements",
    ).readAsStringSync();

    expect(pluginSource, contains("#if canImport(DesktopUpdaterKit)"));
    expect(pluginSource, contains("import DesktopUpdaterKit"));
    expect(pluginSource, contains("MacInstallHelper"));
    expect(pluginSource, contains("MacInstallRequest"));
    expect(pluginSource, contains('"expectedPackageId"'));
    expect(pluginSource, contains('"expectedArtifactSha256"'));
    expect(pluginSource, contains('"stageProvenanceSha256"'));
    expect(pluginSource, contains('"transactionId"'));
    expect(pluginSource, contains("MacVerifiedStage.loadAndVerify("));
    expect(
        pluginSource, contains("let reservation = try helper.prepareInstall("));
    expect(pluginSource, contains("transactionID: transactionID"));
    expect(pluginSource, contains("commitAfterExit(reservation)"));
    expect(
      pluginSource,
      contains('message: "Unable to prepare update installation."'),
    );
    expect(
      pluginSource,
      matches(
        RegExp(
          r'message: "Unable to prepare update installation\.",\s*'
          r"details: nil",
        ),
      ),
    );
    expect(pluginSource, isNot(contains("allowUnsignedMacOSUpdates")));
    expect(pluginSource, isNot(contains("diagnosticsLogPath")));
    expect(helperSource, isNot(contains("makeHelperScript")));
    expect(helperSource, isNot(contains("/bin/sh")));
    expect(helperSource, contains("SMAppService.daemon"));
    expect(helperSource, contains("#available(macOS 13.0, *)"));
    expect(helperSource, isNot(contains("SMJobBless")));
    expect(helperSource, isNot(contains("kSMRightBlessPrivilegedHelper")));
    expect(helperSource, isNot(contains("SMPrivilegedExecutables")));
    expect(helperSource, contains("SecCodeCopyGuestWithAttributes"));
    expect(helperSource, contains("helperEndpointIdentitySHA256"));
    expect(helperSource, contains("dlsym("));
    expect(
      helperSource,
      contains('"xpc_connection_set_peer_team_identity_requirement"'),
    );
    expect(
      helperSource,
      isNot(contains("xpc_connection_set_peer_team_identity_requirement(")),
    );
    expect(embedTool, contains("--options runtime --timestamp"));
    expect(embedTool, contains("DesktopUpdaterInstallHelperServiceID"));
    expect(embedTool, contains("DESKTOP_UPDATER_SEALED_POLICY_SHA256"));
    expect(verifyTool, contains("codesign --verify --strict"));
    expect(verifyTool, contains("BundleProgram"));
    expect(verifyTool, contains("Contents/Library/LaunchDaemons"));
    expect(verifyTool, isNot(contains("SMPrivilegedExecutables")));
    expect(verifyTool, isNot(contains("SMAuthorizedClients")));
    expect(privilegeSource, contains("teamIdentifier"));
    expect(privilegeSource, contains("signedIdentityMismatch"));
    expect(privilegeSource, isNot(contains("SMJobBless")));
    expect(privilegeSource, isNot(contains("SMAuthorizedClients")));
    expect(
      privilegeSource,
      contains("try response.payload.withUnsafeBytes"),
    );
    expect(
      privilegeSource,
      contains(".maximumFrameLength).contains(bytes.count)"),
    );
    expect(privilegeSource, isNot(contains("bytes.baseAddress,")));
    expect(
      helperSource,
      contains("let payloadWasSet = payload.withUnsafeBytes"),
    );
    expect(helperSource, contains("guard payloadWasSet else"));
    expect(helperSource, isNot(contains("bytes.baseAddress,")));
    expect(
      helperSource,
      contains("pathBuffer.withUnsafeMutableBufferPointer"),
    );
    expect(helperSource, isNot(contains("&pathBuffer")));
    expect(
      callerSource,
      contains("buffer.withUnsafeMutableBufferPointer"),
    );
    expect(callerSource, isNot(contains("proc_pidpath(pid, &buffer")));
    expect(artifactVerifier, contains("/usr/bin/codesign"));
    expect(artifactVerifier, contains("/usr/sbin/spctl"));
    expect(artifactVerifier, contains("stapler"));

    expect(
      project,
      contains("CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;"),
    );
    expect(project, contains("ENABLE_HARDENED_RUNTIME = YES;"));
    expect(
      releaseEntitlements,
      contains("<key>com.apple.security.app-sandbox</key>"),
    );
    expect(releaseEntitlements, contains("<false/>"));
    expect(releaseEntitlements, isNot(contains("get-task-allow")));
  });
}

List<String> _manifestErrors(
  String source, {
  required String packageName,
  required String targetPath,
  required bool flutter,
}) {
  final errors = <String>[];
  final package = _singleCall(
    SourceSlice(source, maskNonCode(source)),
    "Package",
  );
  if (package == null) return <String>["missing Package call"];
  final fields = _fields(package);
  if (_literal(fields["name"]) != packageName) errors.add("wrong package name");

  final platforms = _array(fields["platforms"])
      .map((value) => _wholeCall(value, ".macOS"))
      .whereType<SourceSlice>()
      .toList();
  if (platforms.length != 1 || _literal(platforms.single) != "10.15") {
    errors.add("wrong macOS floor");
  }

  final products = _array(fields["products"])
      .map((value) => _wholeCall(value, ".library"))
      .whereType<SourceSlice>()
      .map(_fields)
      .toList();
  bool product(String name, String target) => products.any(
        (item) =>
            _literal(item["name"]) == name &&
            _stringArray(item["targets"]).singleOrNull == target,
      );
  if (!product("DesktopUpdaterKit", "DesktopUpdaterKit")) {
    errors.add("missing DesktopUpdaterKit product");
  }

  final targets = _array(fields["targets"])
      .map((value) => _wholeCall(value, ".target"))
      .whereType<SourceSlice>()
      .map(_fields)
      .toList();
  final kit = targets
      .where((item) => _literal(item["name"]) == "DesktopUpdaterKit")
      .toList();
  if (kit.length != 1 || _literal(kit.single["path"]) != targetPath) {
    errors.add("wrong DesktopUpdaterKit target path");
  }

  if (flutter) {
    final flutterProducts = products
        .where(
          (item) =>
              _literal(item["name"]) == "desktop-updater" &&
              _stringArray(item["targets"]).singleOrNull == "desktop_updater",
        )
        .toList();
    if (flutterProducts.length != 1) {
      errors.add("missing Flutter product");
    } else if (flutterProducts.single["type"]?.source.trim() != ".static") {
      errors.add("Flutter product must be static");
    }
    final dependencies = _array(fields["dependencies"])
        .map((value) => _wholeCall(value, ".package"))
        .whereType<SourceSlice>()
        .map(_fields);
    if (!dependencies.any(
      (item) =>
          _literal(item["name"]) == "FlutterFramework" &&
          _literal(item["path"]) == "../FlutterFramework",
    )) {
      errors.add("missing FlutterFramework package dependency");
    }
    final adapter = targets
        .where((item) => _literal(item["name"]) == "desktop_updater")
        .toList();
    final adapterProducts = adapter.length == 1
        ? _array(adapter.single["dependencies"])
            .map((value) => _wholeCall(value, ".product"))
            .whereType<SourceSlice>()
            .map(_fields)
        : const Iterable<Map<String, SourceSlice>>.empty();
    if (!adapterProducts.any(
      (item) =>
          _literal(item["name"]) == "FlutterFramework" &&
          _literal(item["package"]) == "FlutterFramework",
    )) {
      errors.add("FlutterFramework is not bound to desktop_updater");
    }
  } else if (_array(fields["dependencies"]).isNotEmpty ||
      targets.any((item) => _literal(item["name"]) == "desktop_updater")) {
    errors.add("root helper package depends on Flutter");
  }
  return errors;
}

Map<String, SourceSlice> _fields(SourceSlice body) {
  final result = <String, SourceSlice>{};
  for (final part in splitTopLevel(body)) {
    final colon = _topLevelColon(part.code);
    if (colon < 0) continue;
    final key = part.source.substring(0, colon).trim();
    result[key] = part.sub(colon + 1, part.source.length).trimmed();
  }
  return result;
}

List<SourceSlice> _array(SourceSlice? value) {
  if (value == null) return const <SourceSlice>[];
  final clean = value.trimmed();
  if (!clean.code.startsWith("[") || !clean.code.endsWith("]")) {
    return const <SourceSlice>[];
  }
  return splitTopLevel(clean.sub(1, clean.source.length - 1));
}

List<String> _stringArray(SourceSlice? value) =>
    _array(value).map(_literal).whereType<String>().toList();

String? _literal(SourceSlice? value) {
  if (value == null) return null;
  return RegExp(r'^"([^"\\]*)"$').firstMatch(value.source.trim())?.group(1);
}

SourceSlice? _singleCall(SourceSlice source, String name) {
  final matches = RegExp("\\b${RegExp.escape(name)}\\s*\\(")
      .allMatches(source.code)
      .toList();
  if (matches.length != 1) return null;
  final open = source.code.indexOf("(", matches.single.start);
  final close = matchingClose(source.code, open, "(", ")");
  return close == null ? null : source.sub(open + 1, close);
}

SourceSlice? _wholeCall(SourceSlice value, String name) {
  final clean = value.trimmed();
  final match = RegExp("^${RegExp.escape(name)}\\s*\\(").firstMatch(clean.code);
  if (match == null) return null;
  final open = clean.code.indexOf("(", match.start);
  final close = matchingClose(clean.code, open, "(", ")");
  if (close == null || clean.code.substring(close + 1).trim().isNotEmpty) {
    return null;
  }
  return clean.sub(open + 1, close);
}

int _topLevelColon(String code) {
  var depth = 0;
  for (var i = 0; i < code.length; i++) {
    if ("([{".contains(code[i])) depth++;
    if (")]}".contains(code[i])) depth--;
    if (code[i] == ":" && depth == 0) return i;
  }
  return -1;
}

extension<T> on Iterable<T> {
  T? get singleOrNull => length == 1 ? single : null;
}
