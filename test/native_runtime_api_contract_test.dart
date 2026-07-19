import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("preview documentation publishes implemented APIs with literal evidence",
      () {
    final docs = readRequiredFile("docs/native-runtime-api.md");

    for (final capability in <String>[
      "| macOS | `zip` |",
      "| macOS | `dmg` |",
      "| macOS | `pkgInstaller` |",
      "| Windows | `zip` |",
      "| Windows | `innoInstaller` |",
      "| Linux | `zip` |",
    ]) {
      expect(docs, contains(capability));
    }
    for (final operation in <String>[
      "checkForUpdate",
      "downloadVerifyAndStage",
      "installAndRelaunch",
    ]) {
      expect(docs, contains(operation));
    }
    expect(docs, contains("source-first"));
    expect(docs, contains("4 MiB"));
    expect(docs, contains("100,000"));
    expect(docs, contains("8 GiB"));
    expect(docs, contains("4 GiB"));
    expect(docs, contains("not production-ready"));
    expect(docs, contains("candidate-only"));
    expect(docs, contains("not run"));
    expect(docs, isNot(contains("`not implemented`")));
  });

  test("Swift runtime API exposes validated configuration and typed outcomes",
      () {
    final api = readRequiredFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/"
      "RuntimeError.swift",
    );
    final sample = readRequiredFile(
      "example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift",
    );
    final manifest =
        readRequiredFile("example/native/macos-runtime/Package.swift");
    final client = readRequiredFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/UpdateClient.swift",
    );

    expect(api, contains("public struct RuntimeConfiguration"));
    expect(api, contains("public enum RuntimeOutcome"));
    expect(api, contains("public enum RuntimeDiagnosticCode"));
    expect(api, contains("public enum RuntimeRemediationAction"));
    expect(api, contains("public struct RuntimeDiagnostic"));
    expect(api, contains('"PrivilegedHelperApprovalRequired"'));
    expect(api, contains("case openMacOSBackgroundItemsSettings"));
    expect(api, contains("case packageIdentityMismatch"));
    expect(api, contains("case unsupportedArtifactKind"));
    expect(api, contains("maximumMetadataBytes: Int64 = 4 * 1024 * 1024"));
    expect(api, contains("guard maximumMetadataBytes > 0"));
    expect(client, contains("public final class UpdateClient"));
    expect(client, contains("supportPolicyStatus"));
    expect(client, contains("let clientID: UUID"));
    expect(client, contains("let generation: UInt64"));
    expect(client, contains("private var installInProgress = false"));
    expect(client, contains("activeStagedUpdate = nil"));
    expect(
      client,
      isNot(contains("public init(\n        outcome: RuntimeOutcome")),
    );
    expect(
      client,
      isNot(contains("public init(\n        descriptor: ReleaseDescriptor")),
    );
    expect(sample, contains("try RuntimeConfiguration("));
    expect(sample, contains("RuntimeOutcome.noUpdate"));
    expect(sample, contains("RuntimeError.diagnostic"));
    expect(sample, contains(".privilegedHelperApprovalRequired"));
    expect(sample, contains(".openMacOSBackgroundItemsSettings"));
    expect(sample, contains('"event": "installFailed"'));
    expect(sample, contains('"code": diagnostic.code.rawValue'));
    expect(
      sample,
      contains(
        '"remediationActions": diagnostic.remediationActions.map(\\.rawValue)',
      ),
    );
    expect(sample, contains("JSONSerialization.data"));
    expect(
      sample,
      contains('arguments.optionalValue("--current-version") ?? "2.7.0"'),
    );
    expect(
      sample,
      contains('arguments.optionalInt("--current-build-number") ?? 270'),
    );
    expect(
      sample,
      isNot(contains(
        "macOS helper handoff failed: privilegedHelperApprovalRequired",
      )),
    );
    expect(sample, isNot(contains("bundlePath:")));
    expect(sample, isNot(contains('value("--bundle-path")')));
    expect(manifest, contains("DESKTOP_UPDATER_PACKAGE_PATH"));
    expect(
      manifest,
      contains('.package(name: "flutter_desktop_updater", path: packagePath)'),
    );
    expect("$manifest\n$sample", isNot(contains("Flutter")));
  });

  test("Windows runtime C ABI is versioned, sized, owned, and exception-safe",
      () {
    final header = readRequiredFile(
      "windows/native/include/desktop_updater_runtime_c.h",
    );
    final source = readRequiredFile(
      "windows/native/src/runtime/desktop_updater_runtime_c.cpp",
    );
    final lifecycle = readRequiredFile(
      "native_runtime/cpp/client_lifecycle.h",
    );
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final dotnet = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs",
    );
    final sample = readRequiredFile(
      "example/native/windows-dotnet-runtime/Program.cs",
    );

    expect(header, contains("DESKTOP_UPDATER_RUNTIME_ABI_VERSION 1u"));
    expect(header, contains("desktop_updater_runtime_configuration_v1"));
    expect(header, contains("uint32_t abi_version"));
    expect(header, contains("size_t struct_size"));
    expect(header, contains("const char* install_root_utf8"));
    expect(header, contains("const char* executable_relative_path_utf8"));
    expect(header, contains("const char* expected_package_id_utf8"));
    expect(
      source,
      contains("constexpr std::size_t kLegacyInstallRequestSize"),
    );
    expect(source, contains("install_root_utf8);"));
    expect(source, contains("const bool has_target_fields"));
    expect(header, contains("desktop_updater_runtime_client_free_v1"));
    expect(header, contains("desktop_updater_runtime_result_free_v1"));
    expect(header, contains("desktop_updater_runtime_abi_version_v1"));
    expect(header, contains("desktop_updater_runtime_result_size_v1"));
    expect(
      source,
      contains("return DESKTOP_UPDATER_RUNTIME_ABI_VERSION;"),
    );
    expect(
      source,
      contains("return sizeof(desktop_updater_runtime_result_v1);"),
    );
    expect(
      header,
      contains("desktop_updater_runtime_client_check_for_update_v1"),
    );
    expect(
      header,
      contains("desktop_updater_runtime_client_download_verify_and_stage_v1"),
    );
    expect(
      header,
      contains("desktop_updater_runtime_client_install_and_relaunch_v1"),
    );
    expect(header, contains('extern "C"'));
    expect(source, contains("catch (...)"));
    expect(source, contains("ClientLifecycleState lifecycle"));
    expect(source, contains("SchedulingRollbackGuard rollback"));
    expect(lifecycle, contains("std::mutex mutex_"));
    expect(lifecycle, contains("selection_generation_"));
    expect(lifecycle, contains("check_generation_"));
    expect(lifecycle, contains("stage_attempt_"));
    expect(lifecycle, contains("staged_generation_"));
    expect(lifecycle, contains("install_in_progress_"));
    expect(cmake, contains("option(DESKTOP_UPDATER_NATIVE_RUNTIME"));
    expect(cmake, contains("desktop_updater_runtime_c.cpp"));
    expect(dotnet, contains("public sealed class DesktopUpdaterConfiguration"));
    expect(dotnet, contains("public enum DesktopUpdaterOutcome"));
    expect(dotnet, contains("public sealed class DesktopUpdaterClient"));
    expect(dotnet, contains("SupportPolicyStatus"));
    expect(dotnet, contains("MaximumMetadataBytes"));
    expect(dotnet, contains("Process.GetCurrentProcess()"));
    expect(dotnet, contains("NativeMethods.ValidateRuntimeAbi();"));
    expect(dotnet, contains("ValidateResultLayout(ref result);"));
    expect(
      dotnet.indexOf("NativeMethods.ValidateRuntimeAbi();"),
      lessThan(dotnet.indexOf("NativeMethods.Create(ref nativeConfiguration)")),
    );
    expect(
      dotnet,
      contains('EntryPoint = "desktop_updater_runtime_abi_version_v1"'),
    );
    expect(
      dotnet,
      contains('EntryPoint = "desktop_updater_runtime_result_size_v1"'),
    );
    final createCleanup = dotnet.lastIndexOf("if (resultReceived)");
    final cleanupStart = createCleanup < 0 ? 0 : createCleanup;
    final mismatchedClientFree = dotnet.indexOf(
      "NativeMethods.ClientFree(result.Client);",
      cleanupStart,
    );
    final clearedClient = dotnet.indexOf(
      "result.Client = IntPtr.Zero;",
      mismatchedClientFree < 0 ? cleanupStart : mismatchedClientFree,
    );
    final resultFree = dotnet.indexOf(
      "NativeMethods.ResultFree(ref result);",
      cleanupStart,
    );
    expect(createCleanup, greaterThanOrEqualTo(0));
    expect(mismatchedClientFree, greaterThan(createCleanup));
    expect(clearedClient, greaterThan(mismatchedClientFree));
    expect(resultFree, greaterThan(clearedClient));
    expect(dotnet, isNot(contains("Environment.ProcessPath")));
    expect(sample, contains("new DesktopUpdaterConfiguration("));
    expect(sample, contains("DesktopUpdaterOutcome.NoUpdate"));
    expect(sample, isNot(contains("DllImport")));
  });

  test("Windows stage provenance includes Windows types before BCrypt", () {
    final source = readRequiredFile(
      "native_runtime/cpp/stage_provenance.cc",
    );
    final windowsInclude = source.indexOf("#include <windows.h>");
    final bcryptInclude = source.indexOf("#include <bcrypt.h>");

    expect(windowsInclude, greaterThanOrEqualTo(0));
    expect(
      bcryptInclude,
      greaterThan(windowsInclude),
      reason: "bcrypt.h requires Windows SDK base types from windows.h",
    );
  });

  test("Windows stage attempts invalidate before request validation", () {
    final source = readRequiredFile(
      "windows/native/src/runtime/desktop_updater_runtime_c.cpp",
    );
    final stageEntry = source.indexOf(
      "desktop_updater_runtime_client_download_verify_and_stage_v1(",
    );
    final beginStage = source.indexOf(
      "client->lifecycle.BeginStage()",
      stageEntry,
    );
    final validateStageRequest = source.indexOf(
      'ValidateRequest(request, "Runtime stage request")',
      stageEntry,
    );
    expect(beginStage, greaterThan(stageEntry));
    expect(validateStageRequest, greaterThan(beginStage));
  });

  test("Windows invalidated checks return invalidDescriptor", () {
    final source = readRequiredFile(
      "windows/native/src/runtime/desktop_updater_runtime_c.cpp",
    );
    final stageEntry = source.indexOf(
      "desktop_updater_runtime_client_download_verify_and_stage_v1(",
    );
    final publishCheck = source.indexOf(
      "if (!client->lifecycle.PublishCheck(lease, check))",
    );
    final invalidatedCheckOutcome = source.indexOf(
      'ClientResult(*client, "invalidDescriptor"',
      publishCheck,
    );
    expect(invalidatedCheckOutcome, greaterThan(publishCheck));
    expect(invalidatedCheckOutcome, lessThan(stageEntry));
  });

  test("Linux runtime API remains a source-only C++ contract", () {
    final header = readRequiredFile(
      "linux/native/include/desktop_updater_runtime.h",
    );
    final client = readRequiredFile(
      "linux/native/src/runtime/update_client_linux.cc",
    );
    final lifecycle = readRequiredFile(
      "native_runtime/cpp/client_lifecycle.h",
    );
    final source = readRequiredFile(
      "example/native/linux-cmake-runtime/main.cpp",
    );
    final cmake =
        readRequiredFile("example/native/linux-cmake-runtime/CMakeLists.txt");

    expect(header, contains("struct RuntimeConfiguration"));
    expect(header, contains("enum class RuntimeOutcome"));
    expect(header, contains("kPackageIdentityMismatch"));
    expect(header, contains("kUnsupportedArtifactKind"));
    expect(header, contains("std::function"));
    expect(header, contains("class UpdateClient"));
    expect(header, contains("support_policy_status"));
    expect(client, contains("ClientLifecycleState lifecycle_"));
    expect(client, contains("SchedulingRollbackGuard rollback"));
    expect(lifecycle, contains("selection_generation_"));
    expect(lifecycle, contains("check_generation_"));
    expect(lifecycle, contains("stage_attempt_"));
    expect(lifecycle, contains("staged_generation_"));
    expect(lifecycle, contains("install_in_progress_"));
    expect(header, isNot(contains("extern \"C\"")));
    expect(source, contains("desktop_updater_runtime.h"));
    expect(source, contains("RuntimeOutcome::kNoUpdate"));
    expect(source, isNot(contains("Flutter")));
    expect(cmake, contains("find_package(desktop_updater_native"));
    expect(cmake, contains("desktop_updater::native"));
  });

  test("native helpers use transaction names and exclusive state creation", () {
    final macos = readRequiredFile(
      "macos/install_helper/Sources/DesktopUpdaterInstallHelper/HelperServer.swift",
    );
    final windows = readRequiredFile(
      "windows/native/src/helper/windows_reservation.cpp",
    );
    final linux = readRequiredFile(
      "linux/native/src/helper/linux_reservation.cc",
    );

    expect(macos,
        contains(r".desktop-updater-journal-\(request.transactionID).json"));
    expect(macos, contains("O_CREAT | O_EXCL | O_NOFOLLOW"));
    expect(windows, contains("CREATE_NEW"));
    expect(windows, contains(".desktop-updater-"));
    expect(windows, contains("request.transaction_id"));
    expect(linux, contains("O_CREAT | O_EXCL"));
    expect(linux, contains(".desktop-updater-"));
    expect(linux, contains("request.transaction_id"));
  });

  test("native lifecycle races have registered behavioral tests", () {
    final tests = readRequiredFile(
      "native_runtime/cpp/client_lifecycle_tests.cc",
    );
    final windowsCmake = readRequiredFile("windows/native/CMakeLists.txt");
    final linuxCmake = readRequiredFile("linux/native/CMakeLists.txt");

    for (final behavior in <String>[
      "ConcurrentInstallIsOneShot",
      "LatestStageAttemptOwnsPublication",
      "FailedCheckInvalidatesPreviousStage",
      "SchedulerFailureRestoresMatchingHandoff",
      "SchedulerReturnedFailureRestoresMatchingHandoff",
      "RejectedCheckDuringSchedulingPreventsRollbackRestore",
      "RejectedStageDuringSchedulingPreventsRollbackRestore",
      "ConfirmedSchedulingNeverRestores",
    ]) {
      expect(tests, contains(behavior));
    }
    for (final cmake in <String>[windowsCmake, linuxCmake]) {
      expect(cmake, contains("desktop_updater_runtime_lifecycle_test"));
      expect(cmake, contains("desktop_updater_runtime_lifecycle"));
      expect(cmake, contains("client_lifecycle_tests.cc"));
    }
  });
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}
