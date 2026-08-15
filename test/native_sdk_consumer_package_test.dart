import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("external SwiftPM consumer imports only DesktopUpdaterKit", () {
    final manifest = readRequiredFile("example/native/macos/Package.swift");
    final source = readRequiredFile(
      "example/native/macos/Sources/DesktopUpdaterConsumer/main.swift",
    );

    expect(manifest, contains('.package(path: "../../..")'));
    expect(manifest, contains('package: "flutter_desktop_updater"'));
    expect(source, contains("import DesktopUpdaterKit"));
    expect(source, contains("MacInstallRequest(verifiedStage:"));
    expect(source, contains("MacVerifiedStage.loadAndVerify("));
    expect(source, contains("verifiedStage:"));
    expect(source, contains("expectedPackageID:"));
    expect(source, contains("trustedReleasePublicKeys:"));
    expect(source, contains("transactionID:"));
    expect(source, contains("let reservation = try helper.prepareInstall("));
    expect(source, contains("commitAfterExit(reservation)"));
    expect(source, isNot(contains("StageProvenance.write(")));
    expect(source, contains("DesktopUpdaterVersion.string"));
    expect(source, isNot(contains("currentProcessIdentifier:")));
    expect(source, isNot(contains("bundlePath:")));
    expect(source, isNot(contains("request.bundlePath")));
    expect("$manifest\n$source", isNot(contains("Flutter")));
  });

  test("native install clients expose reservation and recovery contracts", () {
    final macHelper = readRequiredFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    );
    final macStatus = readRequiredFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/"
      "InstallTransactionStatus.swift",
    );
    final macConsumer = readRequiredFile(
      "example/native/macos/Sources/DesktopUpdaterConsumer/main.swift",
    );
    final windowsHeader = readRequiredFile(
      "windows/native/include/desktop_updater_native.h",
    );
    final windowsCHeader = readRequiredFile(
      "windows/native/include/desktop_updater_native_c.h",
    );
    final windowsNative = readRequiredFile(
      "windows/native/src/desktop_updater_native.cpp",
    );
    final windowsCNative = readRequiredFile(
      "windows/native/src/desktop_updater_native_c.cpp",
    );
    final dotnetNative = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterNative.cs",
    );
    final windowsConsumer = readRequiredFile(
      "example/native/windows-cmake/main.cpp",
    );
    final dotnetConsumer = readRequiredFile(
      "example/native/windows-dotnet/Program.cs",
    );
    final linuxHeader = readRequiredFile(
      "linux/native/include/desktop_updater_native.h",
    );
    final linuxNative = readRequiredFile(
      "linux/native/src/desktop_updater_native.cc",
    );
    final linuxConsumer = readRequiredFile(
      "example/native/linux-cmake/main.cpp",
    );
    final docs = readRequiredFile("docs/native-sdk.md");
    expect(docs, contains("prepareInstall(transactionID)"));
    expect(docs, contains("commitAfterExit(reservation)"));
    expect(docs, isNot(contains("scheduleInstallAndRelaunch")));
    expect(docs, isNot(contains("allowUnsignedUpdates")));
    expect(docs, isNot(contains("diagnosticsLogPath")));

    for (final operation in <String>[
      "prepareInstall",
      "commitAfterExit",
      "cancelReservation",
      "queryTransaction",
      "recoverPendingInstall",
    ]) {
      expect(macHelper, contains(operation));
    }
    expect(macStatus, contains("public enum InstallTransactionState"));
    expect(macStatus, contains("public enum InstallTransactionResultCode"));
    expect(macStatus, contains("public final class MacInstallReservation"));
    expect(macStatus, contains("deinit"));
    expect(
      macHelper,
      contains(
        "public func prepareInstall(\n"
        "        _ request: MacInstallRequest,\n"
        "        transactionID: String",
      ),
    );
    expect(macHelper, isNot(contains("scheduleInstallAndRelaunch")));
    expect(
      macHelper,
      isNot(
        contains(
          "public func prepareInstall(\n"
          "        _ request: MacInstallRequest\n"
          "    )",
        ),
      ),
    );
    expect(macConsumer, contains("queryTransaction"));
    expect(macConsumer, contains("recoverPendingInstall"));

    for (final operation in <String>[
      "PrepareInstall",
      "CommitAfterExit",
      "CancelReservation",
      "QueryTransaction",
      "ResolvePendingInstallAfterExit",
    ]) {
      expect(windowsHeader, contains(operation));
    }
    expect(windowsHeader, contains("enum class InstallTransactionState"));
    expect(windowsHeader, contains("enum class InstallTransactionResultCode"));
    expect(windowsHeader, contains("kRelaunchFailure = 8"));
    expect(windowsCHeader, contains("desktop_updater_reservation_handle_abi2"));
    expect(windowsCHeader, contains("desktop_updater_prepare_install_abi2"));
    expect(windowsCHeader, contains("desktop_updater_commit_after_exit_abi2"));
    expect(windowsCHeader, contains("desktop_updater_cancel_reservation_abi2"));
    expect(windowsCHeader, contains("desktop_updater_query_transaction_abi2"));
    expect(
      windowsCHeader,
      contains("desktop_updater_resolve_pending_install_after_exit_abi2"),
    );
    expect(
        windowsCHeader, contains("desktop_updater_reservation_release_abi2"));
    expect(windowsCHeader, contains("desktop_updater_transaction_status_abi2"));
    expect(
      windowsCHeader,
      contains("DESKTOP_UPDATER_TRANSACTION_RESULT_RELAUNCH_FAILURE_ABI2 = 8"),
    );
    expect(windowsNative, contains("InstallResult PrepareInstall("));
    expect(windowsNative, isNot(contains("ScheduleInstallAndRelaunch")));
    expect(
      windowsNative,
      contains("BuildWindowsNativeInstallTransactionRequestV1"),
    );
    expect(windowsCNative, contains("value->struct_size < sizeof(Struct)"));
    expect(
      windowsCNative,
      contains("ValidateStatusDestination"),
    );
    expect(dotnetNative,
        contains("sealed class DesktopUpdaterInstallReservation"));
    expect(dotnetNative, contains("RelaunchFailure = 8"));
    expect(dotnetNative, contains("SafeHandle"));
    expect(dotnetNative, contains("protected override bool ReleaseHandle()"));
    expect(dotnetNative, contains("public void Dispose()"));
    expect(dotnetNative, contains("PrepareInstall("));
    expect(dotnetNative, contains("string transactionId"));
    expect(dotnetNative, contains("ResolvePendingInstallAfterExit"));
    expect(windowsConsumer, contains("desktop_updater_prepare_install_abi2"));
    expect(windowsConsumer, contains("desktop_updater_query_transaction_abi2"));
    expect(dotnetConsumer, contains("QueryTransaction"));
    expect(dotnetConsumer, contains("ResolvePendingInstallAfterExit"));

    for (final operation in <String>[
      "PrepareInstall",
      "CommitAfterExit",
      "CancelReservation",
      "QueryTransaction",
      "RecoverPendingInstall",
    ]) {
      expect(linuxHeader, contains(operation));
    }
    expect(linuxHeader, contains("enum class InstallTransactionState"));
    expect(linuxHeader, contains("enum class InstallTransactionResultCode"));
    expect(linuxHeader, contains("kRelaunchFailure = 8"));
    expect(linuxHeader, isNot(contains("helper_executable_path")));
    expect(linuxHeader, isNot(contains("std::string policy_id")));
    expect(linuxNative, contains("InstallResult PrepareInstall("));
    expect(linuxNative, isNot(contains("ScheduleInstallAndRelaunch")));
    expect(linuxNative, contains("SerializeCommonInstallRequest"));
    expect(linuxConsumer, contains("QueryTransaction"));
    expect(linuxConsumer, contains("RecoverPendingInstall"));

    expect(windowsCHeader, contains("struct_size"));
    expect(docs, contains("Contents/Helpers/DesktopUpdaterInstallHelper"));
    expect(docs, contains("desktop_updater_install_helper.exe"));
    expect(docs, contains("/usr/libexec/desktop-updater-helper"));
    expect(docs, contains("resolvePendingInstallAfterExit"));
    expect(docs, contains("exit immediately"));
    expect(docs, contains("candidate-only"));
  });

  test("installed Windows and Linux CMake packages have real consumers", () {
    for (final platform in <String>["windows", "linux"]) {
      final nativeCmake = readRequiredFile("$platform/native/CMakeLists.txt");
      final config = readRequiredFile(
        "$platform/native/cmake/desktop_updater_nativeConfig.cmake.in",
      );
      final consumerCmake = readRequiredFile(
        "example/native/$platform-cmake/CMakeLists.txt",
      );
      final consumerSource = readRequiredFile(
        "example/native/$platform-cmake/main.cpp",
      );

      expect(nativeCmake, contains("install(TARGETS desktop_updater_native"));
      expect(nativeCmake, contains("EXPORT_NAME native"));
      expect(
        config,
        contains("desktop_updater_nativeTargets.cmake"),
      );
      expect(
        consumerCmake,
        contains("find_package(desktop_updater_native "),
      );
      expect(
        consumerCmake,
        contains(" EXACT CONFIG REQUIRED)"),
      );
      expect(
        nativeCmake,
        contains("desktop_updater_nativeConfigVersion.cmake"),
      );
      expect(
        consumerCmake,
        contains(
          "target_link_libraries(consumer PRIVATE desktop_updater::native)",
        ),
      );
      expect(
        consumerSource,
        contains(platform == "windows"
            ? "return query_succeeded ? 0 : 1"
            : "return 0"),
      );
      expect(
        consumerSource,
        contains(
          platform == "windows"
              ? "DESKTOP_UPDATER_NATIVE_ABI_VERSION"
              : "DESKTOP_UPDATER_NATIVE_VERSION_STRING",
        ),
      );
    }
  });

  test("installed Linux consumers exercise the relocated helper endpoint", () {
    final consumer = readRequiredFile(
      "example/native/linux-cmake/main.cpp",
    );
    final consumerCmake = readRequiredFile(
      "example/native/linux-cmake/CMakeLists.txt",
    );
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );

    expect(
      consumer,
      contains(
          "PrepareInstall(request, transaction_id,\n                                              &reservation)"),
    );
    expect(consumer, contains("CommitAfterExit(reservation)"));
    expect(
      consumer,
      matches(
        RegExp(
          r"QueryTransaction\(\s*reservation\.transaction_id\)",
          multiLine: true,
        ),
      ),
    );
    expect(consumer, contains("InstallTransactionState::kPrepared"));
    expect(
      consumer,
      matches(
        RegExp(
          r"InstallTransactionResultCode::\s*kRecoveryRequired",
          multiLine: true,
        ),
      ),
    );
    expect(consumer, contains("kEndpointUnavailable"));
    expect(
      consumerCmake,
      contains("desktop_updater_native_HELPER_EXECUTABLE"),
    );
    expect(
      consumerCmake,
      contains("install(TARGETS consumer RUNTIME DESTINATION bin)"),
    );
    expect(workflow, contains("linux/native/install-pkg-consumer"));
    expect(workflow, contains("linux/native/install-multiarch-consumer"));
    expect(workflow, contains("linux/native/install-cmake-consumer"));
    expect(workflow, contains(r'"$prefix/bin/linux_installed_consumer"'));
    expect(workflow, contains(r'helper="$(realpath "$(PKG_CONFIG_PATH='));
    expect(workflow, contains("--exchange"));
    expect(workflow, contains(r'runtime="/tmp/du-${UID}-pkg"'));
    expect(workflow, contains(r'runtime="/tmp/du-${UID}-multi"'));
    expect(workflow, contains(r'runtime="/tmp/du-${UID}-cmake"'));
    expect(
      workflow,
      isNot(contains(r'mkdir -m 0700 "$prefix/runtime"')),
      reason: "sockaddr_un requires a short XDG_RUNTIME_DIR",
    );
  });

  test("installed Linux runtime consumer resolves exported thread dependency",
      () {
    final nativeCmake = readRequiredFile("linux/native/CMakeLists.txt");
    final config = readRequiredFile(
      "linux/native/cmake/desktop_updater_nativeConfig.cmake.in",
    );
    final consumerCmake = readRequiredFile(
      "example/native/linux-cmake-runtime/CMakeLists.txt",
    );

    expect(nativeCmake,
        contains("PRIVATE desktop_updater_native Threads::Threads"));
    expect(
      config,
      contains("find_dependency(Threads REQUIRED)"),
    );
    expect(consumerCmake, contains("find_package(desktop_updater_native "));
    expect(
      consumerCmake,
      contains(
        "target_link_libraries(runtime_compile\n"
        "  PRIVATE desktop_updater::runtime desktop_updater::native)",
      ),
    );
  });

  test("NuGet package carries wrappers and selected Windows RID assets", () {
    final project = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj",
    );
    final targets = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/buildTransitive/"
      "DesktopUpdater.Native.targets",
    );
    final consumerProject = readRequiredFile(
      "example/native/windows-dotnet/DesktopUpdater.Consumer.csproj",
    );
    final consumerSource = readRequiredFile(
      "example/native/windows-dotnet/Program.cs",
    );

    expect(
      project,
      contains("<TargetFrameworks>net8.0;netstandard2.0</TargetFrameworks>"),
    );
    expect(project, contains(r'Include="$(NativeDllPath)"'));
    expect(project, contains(r'Include="$(RuntimeDllPath)"'));
    expect(project, contains(r'Include="$(InstallHelperPath)"'));
    expect(project, contains(r'Include="$(HelperPolicyPath)"'));
    expect(
      project,
      contains('PackagePath="runtimes/\$(NativeRuntimeIdentifier)/native"'),
    );
    expect(project, contains("win-arm64"));
    expect(
      project,
      contains("buildTransitive/DesktopUpdater.Native.targets"),
    );
    expect(targets, contains("CopyDesktopUpdaterNativeRuntime"));
    expect(targets, contains("desktop_updater_runtime.dll"));
    expect(targets, contains("desktop_updater_install_helper.exe"));
    expect(targets, contains("desktop_updater_helper_policy.json"));
    expect(targets, contains("NETCoreSdkRuntimeIdentifier"));
    expect(targets, contains(r"$(_DesktopUpdaterNativeRuntimeIdentifier)"));
    expect(
      consumerProject,
      contains('PackageReference Include="DesktopUpdater.Native"'),
    );
    expect(consumerSource, contains("DesktopUpdaterException"));
    expect(consumerSource, contains("DesktopUpdaterInstallRequest("));
    expect(consumerSource, contains("expectedProvenanceSha256:"));
    expect(consumerSource, contains("expectedArtifactSha256:"));
    expect(consumerSource, contains("expectedPackageId:"));
    expect(consumerSource, contains('"Staged update"'));
    expect(consumerSource, contains('"path components"'));
  });

  test("NuGet target rejects unsupported Windows RIDs before copying", () {
    final targets = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/buildTransitive/"
      "DesktopUpdater.Native.targets",
    );
    const unsupportedRidCondition =
        r'''Condition="'$(_DesktopUpdaterNativeRuntimeIdentifier)' != 'win-x64' and '$(_DesktopUpdaterNativeRuntimeIdentifier)' != 'win-arm64'"''';
    const unsupportedRidMessage =
        "DesktopUpdater.Native supports RuntimeIdentifier 'win-x64' or 'win-arm64'";

    expect(targets, contains(unsupportedRidCondition));
    expect(targets, contains(unsupportedRidMessage));
    expect(
      targets.indexOf(unsupportedRidCondition),
      lessThan(targets
          .indexOf("!Exists('%(DesktopUpdaterNativeRuntime.Identity)')")),
    );
  });

  test("target-host CI installs, packs, links, loads, and runs consumers", () {
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );
    final nugetVerifier = readRequiredFile(
      "tool/verify_windows_nuget_consumer.ps1",
    );

    expect(
      workflow,
      contains("swift run --package-path example/native/macos"),
    );
    expect(
      workflow,
      contains("cmake --install windows/native/build --config Release"),
    );
    expect(
      workflow,
      contains("cmake -S example/native/windows-cmake"),
    );
    expect(
      workflow,
      contains("Windows installed consumer CTest registered zero tests"),
    );
    expect(workflow, contains("dotnet pack"));
    expect(
      workflow,
      contains(
        r"$packageSource = (Resolve-Path windows/native/artifacts).Path",
      ),
    );
    expect(
      nugetVerifier,
      contains(r"--source $packageSource"),
    );
    expect(workflow, isNot(contains("api.nuget.org")));
    expect(
      workflow,
      contains(
        r"""dotnet (Join-Path $build "DesktopUpdater.Consumer.dll")""",
      ),
    );
    expect(
      workflow,
      contains("cmake --install linux/native/build"),
    );
    expect(
      workflow,
      contains("cmake -S example/native/linux-cmake"),
    );
    expect(
      workflow,
      contains("Linux installed consumer CTest registered zero tests"),
    );
  });

  test("published package stays source-complete and preview-bounded", () {
    final pubIgnore = readRequiredFile(".pubignore");
    final ignoredPaths = pubIgnore.split("\n").map((line) => line.trim());
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );
    final publishedDocs = <String>[
      readRequiredFile("README.md"),
      readRequiredDirectory("doc", extensions: const <String>[".md"]),
      readRequiredFile("linux/native/README.md"),
      readRequiredFile(
        "windows/native/dotnet/DesktopUpdater.Native/README.md",
      ),
    ].join("\n");

    for (final path in <String>[
      "Package.swift",
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
      "windows/native/src/desktop_updater_native.cpp",
      "windows/native/src/runtime/desktop_updater_runtime_c.cpp",
      "linux/native/src/desktop_updater_native.cc",
      "linux/native/src/runtime/update_client_linux.cc",
      "linux/native/cmake/desktop_updater_nativeConfig.cmake.in",
      "linux/native/cmake/desktop_updater_native.pc.in",
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    expect(ignoredPaths, isNot(contains("macos/")));
    expect(ignoredPaths, isNot(contains("windows/")));
    expect(ignoredPaths, isNot(contains("linux/")));
    expect(
      ignoredPaths,
      contains("script/"),
      reason: "local Codex/Xcode run entrypoints are not package runtime API",
    );
    expect(workflow, contains("dart pub publish --dry-run"));
    expect(publishedDocs, contains("downloadVerifyAndStage"));
    expect(publishedDocs, contains("checkForUpdate"));
    expect(publishedDocs, contains("prepareInstall"));
    expect(publishedDocs, contains("commitAfterExit"));
    expect(publishedDocs, contains("queryTransaction"));
    expect(publishedDocs, contains("recoverPendingInstall"));
    expect(publishedDocs, isNot(contains("installAndRelaunch")));
    expect(publishedDocs, contains("candidate-only"));
    expect(publishedDocs, contains("not production-ready"));
    expect(publishedDocs, isNot(contains("production-ready native runtime")));
  });

  test("published README has no missing or pub-ignored local links", () {
    final readme = readRequiredFile("README.md");
    final ignoredPaths = readRequiredFile(".pubignore")
        .split("\n")
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith("#"))
        .toList();

    for (final target in localMarkdownTargets(readme)) {
      final path = target.split("#").first;
      expect(
        File(path).existsSync() || Directory(path).existsSync(),
        isTrue,
        reason: "README local link target must exist: $target",
      );
      expect(
        isIgnoredBySimplePubPattern(path, ignoredPaths),
        isFalse,
        reason:
            "README local link target must ship in the pub archive: $target",
      );
    }
  });
}

Iterable<String> localMarkdownTargets(String markdown) sync* {
  final linkPattern = RegExp(r'''\[[^\]]+\]\(([^)\s]+)(?:\s+"[^"]*")?\)''');
  for (final match in linkPattern.allMatches(markdown)) {
    final target = match.group(1)!;
    if (!target.startsWith("#") && !Uri.parse(target).hasScheme) {
      yield target;
    }
  }
}

bool isIgnoredBySimplePubPattern(String path, Iterable<String> patterns) {
  for (final rawPattern in patterns) {
    if (rawPattern.startsWith("!")) {
      continue;
    }
    final pattern =
        rawPattern.startsWith("/") ? rawPattern.substring(1) : rawPattern;
    if (pattern.endsWith("/")) {
      if (path.startsWith(pattern)) {
        return true;
      }
    } else if (path == pattern || path.startsWith("$pattern/")) {
      return true;
    }
  }
  return false;
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync()
      ? file.readAsStringSync().replaceAll("\r\n", "\n")
      : "";
}

String readRequiredDirectory(
  String path, {
  required List<String> extensions,
}) {
  final directory = Directory(path);
  expect(directory.existsSync(), isTrue, reason: "$path must exist");
  if (!directory.existsSync()) {
    return "";
  }
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => extensions.any(file.path.endsWith))
      .map((file) => file.readAsStringSync().replaceAll("\r\n", "\n"))
      .join("\n");
}
