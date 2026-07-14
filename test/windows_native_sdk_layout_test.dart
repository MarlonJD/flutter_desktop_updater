import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Windows native SDK exposes the versioned C ABI", () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final header = readRequiredFile(
      "windows/native/include/desktop_updater_native_c.h",
    );
    final version = readRequiredFile(
      "windows/native/include/desktop_updater_version.h",
    );
    final source = readRequiredFile(
      "windows/native/src/desktop_updater_native_c.cpp",
    );

    expect(version, contains("DESKTOP_UPDATER_NATIVE_ABI_VERSION 1u"));
    expect(header, contains('extern "C"'));
    expect(header, contains("desktop_updater_install_request_v1"));
    expect(header, contains("desktop_updater_result_v1"));
    expect(
      header,
      contains("desktop_updater_schedule_install_and_relaunch_v1"),
    );
    expect(header, contains("desktop_updater_result_free_v1"));
    expect(header, contains("DESKTOP_UPDATER_CALL"));
    expect(header, contains("desktop_updater_install_elevation_policy_v1"));
    expect(header, contains("elevation_policy"));

    expect(cmake, contains("desktop_updater_native_objects OBJECT"));
    expect(cmake, contains("desktop_updater_native_static STATIC"));
    expect(cmake, contains("desktop_updater_native SHARED"));
    expect(cmake, contains("desktop_updater::native ALIAS"));
    expect(
      cmake,
      contains("if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)"),
    );
    expect(source, contains("catch (...)"));
    expect(source, contains("request->abi_version"));
    expect(source, contains("request->struct_size"));
    expect(source, contains("removed_file_count"));
    expect(source, contains("result->error_message_utf8 = nullptr"));
  });

  test("Windows native tests are explicit and pinned", () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final tests = readRequiredDirectory("windows/native/test");

    expect(
      cmake,
      contains("option(DESKTOP_UPDATER_NATIVE_BUILD_TESTS"),
    );
    expect(cmake, contains('"Build desktop_updater native tests" OFF'));
    expect(cmake, contains("find_package(GTest 1.16.0 EXACT CONFIG QUIET)"));
    expect(
      cmake,
      contains(
        "https://github.com/google/googletest/archive/refs/tags/v1.16.0.zip",
      ),
    );
    expect(
      cmake,
      contains(
        "a9607c9215866bd425a725610c5e0f739eeb50887a57903df48891446ce6fb3c",
      ),
    );
    expect(tests, contains("WrongAbiVersion"));
    expect(tests, contains("UndersizedStruct"));
    expect(tests, contains("InvalidUtf16"));
    expect(
      tests,
      contains("IncompleteStagedHandoffFailsBeforeScheduler"),
    );
    expect(tests, contains('find("verified provenance")'));
    expect(tests, contains("EXPECT_FALSE(scheduler_called)"));
    expect(tests, contains("RemovedFilesReachNativeRequest"));
    expect(tests, contains("ElevationPolicyReachesNativeRequest"));
    expect(tests, contains("InvalidElevationPolicyFailsBeforeScheduler"));
    expect(tests, contains("NeverElevationRejectsUnwritableTarget"));
    expect(tests, contains("ThrownInternalException"));
    expect(tests, contains("RepeatedFreeIsSafe"));
  });

  test("Flutter adapter links the static native helper", () {
    final cmake = File("windows/CMakeLists.txt").readAsStringSync();
    final plugin =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();
    final native = readRequiredFile(
      "windows/native/src/desktop_updater_native.cpp",
    );

    expect(cmake, contains('add_subdirectory("native")'));
    expect(
      cmake,
      contains(r"target_link_libraries(${PLUGIN_NAME} PRIVATE"),
    );
    expect(cmake, contains("desktop_updater_native_static"));
    expect(
      cmake,
      isNot(contains('add_subdirectory("native/desktop_updater")')),
    );
    expect(plugin, contains("desktop_updater::native::InstallRequest"));
    expect(plugin, contains("PrepareInstall"));
    expect(plugin, contains("CommitAfterExit"));
    expect(plugin, isNot(contains("ScheduleInstallAndRelaunch")));
    expect(native, contains("SerializeCommonInstallRequest"));
    expect(native, contains("EndpointUnavailableStatus"));
    expect(native, isNot(contains("PowerShell")));
    expect(native, isNot(contains("powershell.exe")));
  });

  test(".NET wrapper marshals every removed file and calls the real DLL", () {
    final wrapper = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterNative.cs",
    );
    final tests = readRequiredDirectory(
      "windows/native/dotnet/DesktopUpdater.Native.Tests",
    );

    expect(wrapper, contains("IReadOnlyList<string> removedFiles"));
    expect(
      wrapper,
      contains("public sealed class DesktopUpdaterInstallRequest"),
    );
    expect(wrapper, contains("public enum DesktopUpdaterElevationPolicy"));
    expect(wrapper, contains("RequiresElevation ="));
    expect(wrapper, contains("ElevationPolicy = (uint)elevationPolicy"));
    expect(wrapper, contains("ExpectedProvenanceSha256 ="));
    expect(wrapper, contains("ExpectedArtifactSha256 ="));
    expect(wrapper, contains("AllowedSignerThumbprints ="));
    expect(wrapper, contains("ExpectedProvenanceSha256 = provenancePointer"));
    expect(wrapper, contains("ExpectedArtifactSha256 = artifactPointer"));
    expect(wrapper, contains("AllowedSignerThumbprints = signerPointers"));
    expect(wrapper, contains("Marshal.StringToHGlobalUni"));
    expect(wrapper, contains("Marshal.WriteIntPtr"));
    expect(wrapper, contains("removedFiles.Count"));
    expect(wrapper, contains("finally"));
    expect(wrapper, contains("Marshal.FreeHGlobal"));
    expect(wrapper, contains('"desktop_updater_native"'));
    expect(
      wrapper,
      contains(
        'EntryPoint = "desktop_updater_schedule_install_and_relaunch_v1"',
      ),
    );
    expect(wrapper, contains("ExactSpelling = true"));
    expect(wrapper, contains("CallingConvention = CallingConvention.Cdecl"));
    expect(tests, contains("NativeInvalidRequestReturnsNativeError"));
    expect(tests, contains("IncompleteStagedHandoffFailsBeforeNativeLoad"));
    expect(
      tests,
      contains("VerifiedInstallRequestCarriesCompleteNativeTrustContext"),
    );
    expect(tests, contains("desktop_updater_native.dll"));
    expect(tests, contains("CopyNativeDll"));
  });

  test("Windows CI runs standalone native and .NET consumers", () {
    final workflow = File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsStringSync();
    final exampleCmake = readRequiredFile("example/windows/CMakeLists.txt");

    expect(
      workflow,
      contains(
        "cmake -S windows/native -B windows/native/build "
        "-DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON",
      ),
    );
    expect(
      workflow,
      contains(
        "ctest --test-dir windows/native/build -C Release --output-on-failure",
      ),
    );
    expect(workflow, contains("No tests were found"));
    expect(exampleCmake, contains("enable_testing()"));
    expect(
      workflow,
      contains(
        "dotnet test windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj",
      ),
    );
  });

  test("Windows install helper has a fixed authenticated reservation surface",
      () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final main = readRequiredFile("windows/native/src/helper/main.cpp");
    final policy = readRequiredFile(
      "windows/native/src/helper/helper_policy_windows.cpp",
    );
    final authenticode = readRequiredFile(
      "windows/native/src/helper/helper_authenticode.cpp",
    );
    final pipe = readRequiredFile(
      "windows/native/src/helper/named_pipe_transport.cpp",
    );
    final reservation = readRequiredFile(
      "windows/native/src/helper/windows_reservation.cpp",
    );

    expect(cmake, contains("desktop_updater_install_helper"));
    expect(cmake, contains("Wintrust Crypt32 Advapi32 Shell32 Bcrypt"));
    expect(cmake, contains("windows_helper_auth"));
    expect(cmake, contains("windows_helper_reservation"));
    expect(cmake, contains(r"RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}"));
    expect(main, contains("wWinMain"));
    expect(main, isNot(contains("powershell")));
    expect(main, isNot(contains("cmd.exe")));

    expect(policy, contains("ParseHelperPolicyV1"));
    expect(policy, contains("authenticodePublisher"));
    expect(policy, contains("portableElevationRejected"));
    expect(authenticode, contains("WinVerifyTrust"));
    expect(authenticode, contains("WTD_REVOKE_WHOLECHAIN"));
    expect(authenticode, contains("GetFileInformationByHandleEx"));
    expect(authenticode, contains("installerProtectedLocation"));
    expect(pipe, contains(r"\\\\.\\pipe\\desktop-updater-"));
    expect(pipe, contains("PIPE_REJECT_REMOTE_CLIENTS"));
    expect(
      pipe,
      contains("ConvertStringSecurityDescriptorToSecurityDescriptorW"),
    );
    expect(pipe, contains("GetNamedPipeClientProcessId"));
    expect(pipe, contains("OpenProcessToken"));
    expect(pipe, contains("nonceReuse"));
    expect(pipe, contains("canonical_request"));
    expect(pipe, contains('L"runas"'));
    expect(pipe, contains("ShellExecuteExW"));
    expect(reservation, contains("FILE_FLAG_OPEN_REPARSE_POINT"));
    expect(reservation, contains("FlushFileBuffers"));
    expect(reservation, contains("journalDurableBeforeReadyToken"));
    expect(reservation, contains("targetLock"));
    expect(reservation, contains("caller_process"));
  });

  test("Windows transactions stay handle-relative and recover fail-closed", () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final journal = readRequiredFile(
      "windows/native/src/helper/windows_transaction_journal.cpp",
    );
    final transaction = readRequiredFile(
      "windows/native/src/helper/windows_file_transaction.cpp",
    );
    final transactionBoundary = journal + transaction;
    final recovery = readRequiredFile(
      "windows/native/src/helper/windows_recovery_service.cpp",
    );
    final relaunch = readRequiredFile(
      "windows/native/src/helper/windows_relaunch_service.cpp",
    );
    final smoke = readRequiredFile("tool/windows_install_helper_smoke.ps1");
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );

    expect(cmake, contains("windows_transaction"));
    expect(cmake, contains("windows_crash_recovery"));
    expect(journal, contains("NtCreateFile"));
    expect(journal, contains("RootDirectory"));
    expect(journal, contains("FileRenameInfoEx"));
    expect(journal, contains("FlushFileBuffers"));
    expect(journal, contains("EncodeCanonicalJson"));
    expect(transactionBoundary, contains("OBJ_DONT_REPARSE"));
    expect(transactionBoundary, contains("FileIdInfo"));
    expect(transactionBoundary, contains("NumberOfLinks"));
    expect(transactionBoundary, contains("alternateDataStreamRejected"));
    expect(transactionBoundary, contains("beforeActivationRename"));
    expect(recovery, contains("manualActionRequired"));
    expect(recovery, contains("backupIdentityMismatch"));
    expect(recovery, contains("stageProvenanceSha256"));
    expect(recovery, contains("artifactSha256"));
    expect(recovery, contains("authenticodePublisher"));
    expect(relaunch, contains("CreateProcessW"));
    expect(relaunch, contains("VerifyWindowsExecutableStillMatches"));
    expect(smoke, contains('ValidateSet("Unprivileged", "Elevated")'));
    expect(smoke, contains("desktop_updater_install_helper.exe"));
    expect(
      workflow,
      contains(
        'ctest --test-dir windows/native/build -C Release -R "windows_(transaction|crash_recovery)"',
      ),
    );
  });
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}

String readRequiredDirectory(String path) {
  final directory = Directory(path);
  expect(directory.existsSync(), isTrue, reason: "$path must exist");
  if (!directory.existsSync()) {
    return "";
  }
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (file) => <String>[".cpp", ".h", ".cs", ".csproj"].any(
          file.path.endsWith,
        ),
      )
      .map((file) => file.readAsStringSync())
      .join("\n");
}
