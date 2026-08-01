import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Windows retail layouts package the helper and sealed policy", () {
    final pluginCmake = readRequiredFile("windows/CMakeLists.txt");
    final nativeCmake = readRequiredFile("windows/native/CMakeLists.txt");
    final project = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/"
      "DesktopUpdater.Native.csproj",
    );
    final targets = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/buildTransitive/"
      "DesktopUpdater.Native.targets",
    );

    expect(pluginCmake, contains("desktop_updater_install_helper"));
    expect(pluginCmake,
        contains(r"$<TARGET_FILE:desktop_updater_install_helper>"));
    expect(nativeCmake, contains("DESKTOP_UPDATER_PORTABLE_PROVIDER"));
    expect(
      nativeCmake,
      contains("DESKTOP_UPDATER_PORTABLE_HELPER_POLICY_PATH"),
    );
    expect(pluginCmake, contains("desktop_updater_helper_policy.json"));
    expect(
      nativeCmake,
      contains(
        'install(FILES "\${DESKTOP_UPDATER_PORTABLE_POLICY_OUTPUT}"',
      ),
    );
    expect(nativeCmake, contains("IS_ABSOLUTE"));
    expect(nativeCmake, contains("EXISTS"));
    expect(nativeCmake, contains("FATAL_ERROR"));
    expect(
      pluginCmake,
      contains(
          "add_dependencies(\${PLUGIN_NAME} desktop_updater_install_helper)"),
    );
    expect(
      nativeCmake,
      contains("DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR"),
    );
    expect(nativeCmake, contains("IS_ABSOLUTE"));
    expect(
      nativeCmake,
      contains("Program Files/DesktopUpdaterHelperGenerationV1--"),
    );
    expect(nativeCmake, contains("<package-id>--<release>"));
    expect(
      nativeCmake,
      isNot(contains("Program Files/DesktopUpdater/Helpers")),
    );
    expect(nativeCmake, contains("desktop_updater_install_helper"));
    expect(nativeCmake, contains("RUNTIME DESTINATION"));

    expect(project, contains(r'Include="$(InstallHelperPath)"'));
    expect(project, contains(r'Include="$(HelperPolicyPath)"'));
    expect(project, contains("desktop_updater_install_helper.exe"));
    expect(project, contains("desktop_updater_helper_policy.json"));
    expect(targets, contains("desktop_updater_install_helper.exe"));
    expect(targets, contains("desktop_updater_helper_policy.json"));
    expect(targets, contains("CopyDesktopUpdaterNativeRuntime"));
  });

  test("Windows protected endpoints are immutable and version-addressed", () {
    final locator = readRequiredFile(
      "windows/native/src/helper/windows_protected_helper_locator.cpp",
    );
    final client = readRequiredFile(
      "windows/native/src/desktop_updater_native.cpp",
    );
    final inno = readRequiredFile(
      "lib/src/release_cli/inno/inno_script_builder.dart",
    );
    final innoConfig = readRequiredFile(
      "lib/src/release_cli/inno/inno_publish_config.dart",
    );

    expect(locator, contains("ProtectedWindowsEndpointPackageRegistryPath"));
    expect(locator, contains("endpoint.helper_path"));
    expect(locator, contains("REG_OPENED_EXISTING_KEY"));
    expect(locator, contains("immutable binding changed"));
    expect(client, contains("ConfiguredWindowsHelperPath()"));
    expect(inno, contains("GenerateUniqueName(TrustedProgramFilesDir"));
    expect(innoConfig, contains("DesktopUpdaterHelperGenerationV1--"));
    expect(inno, isNot(contains(r"DesktopUpdater\Helpers")));
    expect(innoConfig, isNot(contains(r"DesktopUpdater\Helpers")));
    expect(
      inno,
      contains("RenameFile(DesktopUpdaterProvisioningPath, FinalDir)"),
    );
    expect(inno, contains("if not RenameFile(FinalDir, "));
    expect(inno, contains("DesktopUpdaterQuarantinePath) then"));
    expect(inno, contains("GetSHA256OfFile"));
    expect(inno, contains("PrepareToInstall"));
    expect(inno, contains("--validate-endpoint"));
  });

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
    expect(plugin,
        contains('case Code::kRelaunchFailure: return "relaunchFailure"'));
    expect(plugin, isNot(contains("ScheduleInstallAndRelaunch")));
    expect(
      native,
      contains("EncodeCanonicalNativeInstallTransactionRequestV1"),
    );
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
    final requestParser = readRequiredFile(
      "native_runtime/cpp/native_install_request.cc",
    );

    expect(cmake, contains("desktop_updater_install_helper"));
    expect(
      cmake.toLowerCase(),
      contains("wintrust crypt32 advapi32 shell32 bcrypt"),
    );
    expect(cmake, contains("windows_helper_auth"));
    expect(cmake, contains("windows_helper_reservation"));
    expect(cmake, contains(r"RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}"));
    expect(main, contains("wWinMain"));
    expect(main, isNot(contains("powershell")));
    expect(main, isNot(contains("cmd.exe")));

    expect(policy, contains("ParseHelperPolicyV1"));
    expect(policy, contains("authenticodePublisher"));
    expect(policy, contains("portableElevationRejected"));
    expect(policy, contains("release_root_public_keys"));
    expect(policy, contains("allowed_target_classes"));
    expect(policy, contains("allowed_strategies"));
    expect(policy, contains("minimum_helper_protocol_version"));
    expect(policy, contains("AllowsRequest"));
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
    expect(requestParser, contains("ParseNativeInstallTransactionRequestV1"));
    expect(requestParser, contains("strategyProviderMismatch"));
    expect(requestParser, contains("callerPackageIdMismatch"));
    expect(requestParser, contains("invalidDiagnosticsDestination"));
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
    expect(journal, contains("NtSetInformationFile"));
    expect(journal, contains("kNativeFileRenameInformationEx"));
    expect(journal, contains("FlushFileBuffers"));
    expect(journal, contains("EncodeCanonicalJson"));
    expect(transactionBoundary, isNot(contains("OBJ_DONT_REPARSE")));
    expect(journal, contains("open_component"));
    expect(journal, contains("FILE_DIRECTORY_FILE"));
    expect(journal, contains("FILE_OPEN_REPARSE_POINT"));
    expect(journal, contains("sizeof(FILE_RENAME_INFO) + name_bytes"));
    expect(transactionBoundary, contains("FileIdInfo"));
    expect(journal, contains("stageParentIdentity"));
    expect(transaction, contains("stage_parent_"));
    expect(transaction, contains("ValidateStageParentLocator"));
    expect(transactionBoundary, contains("NumberOfLinks"));
    expect(transactionBoundary, contains("alternateDataStreamRejected"));
    expect(transactionBoundary, contains("beforeActivationRename"));
    expect(transaction, contains("WindowsFileTransaction::Prepare()"));
    expect(
      transaction,
      contains("WindowsFileTransaction::ExecutePrepared()"),
    );
    expect(transaction, contains("WindowsFileTransaction::CancelPrepared()"));
    expect(recovery, contains("manualActionRequired"));
    expect(recovery, contains("backupIdentityMismatch"));
    expect(recovery, contains("stageProvenanceSha256"));
    expect(recovery, contains("artifactSha256"));
    expect(recovery, contains("authenticodePublisher"));
    expect(
      relaunch,
      contains('.desktop_updater_stage_provenance.json'),
    );
    expect(relaunch, contains('"descriptorSha256"'));
    expect(relaunch, contains('"entries"'));
    expect(relaunch, contains("VerifyCompleteStageInventory"));
    expect(relaunch, contains("FileStreamInfo"));
    expect(relaunch, contains('L"::\$DATA"'));
    expect(
      relaunch,
      isNot(contains('desktop-updater-stage-provenance.json')),
    );
    expect(relaunch, contains("CreateProcessW"));
    expect(relaunch, contains("VerifyWindowsExecutableStillMatches"));
    expect(smoke, contains('ValidateSet("Unprivileged", "Elevated")'));
    expect(smoke, contains("desktop_updater_install_helper.exe"));
    expect(
      smoke,
      contains(
        r'Start-Process -FilePath $helper -ArgumentList "--version" '
        "-Wait -PassThru",
      ),
    );
    expect(
      smoke,
      contains(
        "The fixed helper executable failed its version probe with exit code",
      ),
    );
    expect(
      workflow,
      contains(
        r'$filter = "(WindowsHelperAuth|WindowsOneShotTransport|WindowsInstallAuthorizer|WindowsFileTransaction|WindowsCrashRecovery)"',
      ),
    );
    expect(
      workflow,
      contains(
        "ctest --test-dir windows/native/build -C Release -R \$filter",
      ),
    );
  });

  test("Windows one-shot pipe adapter binds canonical frames and caller exit",
      () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final header = readRequiredFile(
      "windows/native/src/helper/windows_one_shot_transport.h",
    );
    final source = readRequiredFile(
      "windows/native/src/helper/windows_one_shot_transport.cpp",
    );
    final tests = readRequiredFile(
      "windows/native/test/helper/windows_one_shot_transport_test.cpp",
    );

    expect(cmake, contains("windows_one_shot_transport.cpp"));
    expect(cmake, contains("windows_one_shot_transport_test.cpp"));
    expect(header, contains("NativeInstallWireChannelV1"));
    expect(header, contains("NativeInstallCallerExitMonitorFactoryV1"));
    expect(header, contains("RunWindowsOneShotPipeSession"));
    expect(source, contains("ReadFrameUntil"));
    expect(source, contains("WaitForMultipleObjects"));
    expect(source, isNot(contains("FlushFileBuffers(pipe_)")));
    expect(source, contains("GetProcessTimes"));
    expect(source, contains("VerifyWindowsExecutableStillMatches"));
    expect(source, contains("caller.executable_sha256"));
    expect(source, contains("caller.signer_identity"));
    expect(source, contains("caller.package_id"));
    expect(source, contains("NativeInstallOneShotServiceRuntimeV1"));
    expect(tests, contains("RejectsCallerIdentityDrift"));
    expect(tests, contains("RejectsInvalidFrameBounds"));
  });

  test("Windows helper authorizes signed staged directory transactions", () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final header = readRequiredFile(
      "windows/native/src/helper/windows_install_authorizer.h",
    );
    final source = readRequiredFile(
      "windows/native/src/helper/windows_install_authorizer.cpp",
    );
    final tests = readRequiredFile(
      "windows/native/test/helper/windows_install_authorizer_test.cpp",
    );

    expect(cmake, contains("windows_install_authorizer.cpp"));
    expect(cmake, contains("windows_install_authorizer_test.cpp"));
    expect(header, contains("NativeInstallRequestAuthorizerV1"));
    expect(source, contains("AuthorizeNativeInstallTransactionRequestV1"));
    expect(source, contains("VerifyStageProvenance"));
    expect(source, contains(".desktop_updater_release_manifest.json"));
    expect(source, contains(".desktop_updater_install_identity.json"));
    expect(source, contains("AuthenticodeWindowsPayloadVerifier"));
    expect(source, contains("WindowsFileTransaction"));
    expect(source, contains("PrepareDurableJournal"));
    expect(source, contains("WindowsRelaunchService"));
    expect(tests, contains("RetainsCompleteSealedPolicy"));
    expect(tests, contains("RejectsExecutableInventoryDrift"));
  });

  test("Windows helper emits fixed redacted protocol-v1 platform events", () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );
    final diagnostics = readRequiredFile(
      "windows/native/src/helper/windows_helper_diagnostics.cpp",
    );
    final main = readRequiredFile("windows/native/src/helper/main.cpp");
    final recoveryHost = readRequiredFile(
      "windows/native/src/helper/windows_portable_recovery_host.cpp",
    );
    final transport = readRequiredFile(
      "windows/native/src/helper/windows_one_shot_transport.cpp",
    );
    final transaction = readRequiredFile(
      "windows/native/src/helper/windows_file_transaction.cpp",
    );
    final authorizer = readRequiredFile(
      "windows/native/src/helper/windows_install_authorizer.cpp",
    );
    final relaunch = readRequiredFile(
      "windows/native/src/helper/windows_relaunch_service.cpp",
    );

    expect(cmake, contains("windows_helper_diagnostics.cpp"));
    expect(diagnostics, contains("RegisterEventSourceW"));
    expect(diagnostics, contains("ReportEventW"));
    expect(diagnostics, contains("DesktopUpdater.InstallHelper.ProtocolV1"));
    expect(diagnostics, isNot(contains("transaction_id")));
    expect(main, contains("WindowsHelperEvent::kHelperScheduled"));
    expect(main, contains("WindowsHelperEvent::kPortableBootstrapFailure"));
    expect(
      main,
      contains("WindowsHelperEvent::kPortableRecoveryHostFailure"),
    );
    expect(main, contains("WindowsHelperEvent::kPortableSessionFailure"));
    expect(
      recoveryHost,
      contains("WindowsHelperEvent::kPortableRecoveryAuthorityFailure"),
    );
    expect(
      recoveryHost,
      contains("WindowsHelperEvent::kPortableRecoverySourceFailure"),
    );
    expect(
      recoveryHost,
      contains("WindowsHelperEvent::kPortableRecoveryStorageFailure"),
    );
    expect(
      recoveryHost,
      contains("WindowsHelperEvent::kPortableRecoveryArtifactFailure"),
    );
    expect(workflow, contains("Get-WinEvent"));
    expect(workflow, contains("DesktopUpdater.InstallHelper.ProtocolV1"));
    expect(transport, contains("WindowsHelperEvent::kWaitingForParentProcess"));
    expect(transport, contains("WindowsHelperEvent::kParentProcessExited"));
    expect(authorizer, contains("WindowsHelperEvent::kStagingPathValidation"));
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableAuthorizationFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortablePreparationFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableRequestValidationFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableCallerIdentityFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableTargetAuthorityFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableStageAuthorizationFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableTargetRequestFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableTargetExecutableIdentityFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableTargetCallerRootFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableTargetReadAuthorityFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableParentMutationAuthorityFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableTargetMarkerFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableDirectoryHandleFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableSecurityDescriptorFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableCallerTokenFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableImpersonationTokenFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableAccessCheckFailure"),
    );
    expect(
      authorizer,
      contains("WindowsHelperEvent::kPortableDirectoryAccessDenied"),
    );
    expect(transaction, contains("WindowsHelperEvent::kBackupStart"));
    expect(transaction, contains("WindowsHelperEvent::kMoveStart"));
    expect(transaction, contains("WindowsHelperEvent::kRollbackStart"));
    expect(transaction, contains("WindowsHelperEvent::kCleanupStart"));
    expect(relaunch, contains("WindowsHelperEvent::kRelaunchAttempt"));
  });

  test("Windows elevated helper boots a protected one-shot service", () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final main = readRequiredFile("windows/native/src/helper/main.cpp");
    final bootstrap = readRequiredFile(
      "windows/native/src/helper/windows_helper_bootstrap.cpp",
    );
    final pipe = readRequiredFile(
      "windows/native/src/helper/named_pipe_transport.cpp",
    );
    final dispatcher = readRequiredFile(
      "windows/native/src/helper/windows_recovery_pipe_server.cpp",
    );

    expect(cmake, contains("windows_helper_bootstrap.cpp"));
    expect(main, contains("LoadWindowsHelperBootstrap"));
    expect(main, contains("WindowsNativeInstallAuthorizer"));
    expect(main, contains("RunWindowsPersistentRecoveryPipeSession"));
    expect(
      dispatcher,
      contains("RunWindowsOneShotPipeSessionWithInitialRequest"),
    );
    expect(main, contains("SecureWindowsReadyToken"));
    expect(bootstrap, contains("desktop_updater_helper_policy.json"));
    expect(bootstrap, contains("GetSecurityInfo"));
    expect(bootstrap, contains("AccessCheck"));
    expect(bootstrap, contains("VerifyWindowsExecutableStillMatches"));
    expect(pipe, contains("WindowsElevatedPipeSessionRunner"));
    expect(pipe, contains("FILE_FLAG_OVERLAPPED"));
  });

  test("Windows writable targets use signed portable one-shot helper", () {
    final main = readRequiredFile("windows/native/src/helper/main.cpp");
    final bootstrap = readRequiredFile(
      "windows/native/src/helper/windows_helper_bootstrap.cpp",
    );
    final pipe = readRequiredFile(
      "windows/native/src/helper/named_pipe_transport.cpp",
    );
    final client = readRequiredFile(
      "windows/native/src/desktop_updater_native.cpp",
    );
    final authorizer = readRequiredFile(
      "windows/native/src/helper/windows_install_authorizer.cpp",
    );

    expect(main, contains("--portable-pipe"));
    expect(main, contains("LoadPortableWindowsHelperBootstrap"));
    expect(main, contains("WindowsPortableInstallAuthorizer"));
    expect(main, contains("RunWindowsPersistentRecoveryPipeSession"));
    expect(pipe, contains("LaunchAuthenticatedPortableHelper"));
    expect(pipe, contains("CreateProcessW"));
    expect(
      _functionBody(pipe, "LaunchAuthenticatedPortableHelper"),
      isNot(contains('L"runas"')),
    );
    expect(
      _functionBody(pipe, "LaunchAuthenticatedPortableHelper"),
      isNot(contains("ShellExecuteExW")),
    );
    expect(
      _functionBody(pipe, "LaunchAuthenticatedPortableHelperExchange"),
      isNot(contains('L"runas"')),
    );
    expect(
      _functionBody(pipe, "LaunchAuthenticatedPortableHelperExchange"),
      isNot(contains("ShellExecuteExW")),
    );
    expect(bootstrap, contains("policy.is_portable()"));
    expect(client, contains("running_executable.parent_path()"));
    expect(client, contains("desktop_updater_helper_policy.json"));
    expect(client, contains("LaunchAuthenticatedPortableHelper"));
    expect(client, contains("ProbeWindowsPortableTransaction"));
    expect(client, contains("LaunchAuthenticatedPortableRecoveryRequest"));
    expect(client, contains("kBindingMismatch"));
    expect(client, contains('target_class = "sameUserWritable"'));
    expect(
      _functionBody(client, "AdjacentPolicyDeclaresPortable"),
      contains("if (policy_missing) return false;"),
    );
    expect(authorizer, contains("ValidatePortableWindowsTargetAuthority"));
    expect(authorizer, contains("AccessCheck"));
    expect(
      authorizer,
      allOf(
        contains("OWNER_SECURITY_INFORMATION"),
        contains("GROUP_SECURITY_INFORMATION"),
        contains("DACL_SECURITY_INFORMATION"),
      ),
    );
    expect(authorizer, contains("WindowsPersistentTransactionIndex"));
    expect(authorizer, contains("PersistPreparing"));
    expect(authorizer, contains("PersistActive"));
    expect(authorizer, contains("MarkCommitAccepted"));
  });

  test("Windows portable recovery survives helper death without elevation", () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final main = readRequiredFile("windows/native/src/helper/main.cpp");
    final authorizer = readRequiredFile(
      "windows/native/src/helper/windows_install_authorizer.cpp",
    );
    final persistent = readRequiredFile(
      "windows/native/src/helper/windows_persistent_recovery.cpp",
    );
    final portableHost = readRequiredFile(
      "windows/native/src/helper/windows_portable_recovery_host.cpp",
    );
    final portableStorage = readRequiredFile(
      "windows/native/src/helper/windows_portable_user_storage.cpp",
    );
    final portableTransaction = _functionBody(
      authorizer,
      "class WindowsPortableDirectoryPreparedTransaction",
    );

    expect(cmake, contains("windows_portable_recovery_host.cpp"));
    expect(cmake, contains("windows_portable_recovery_host_test.cpp"));
    expect(main, contains("ProvisionPortableWindowsRecoveryHost"));
    expect(main, contains('L"--portable-recover-current"'));
    expect(main, contains("LoadPortableWindowsRecoveryHostBootstrap"));
    expect(main, contains("RunPortableWindowsAutonomousRecoveryBoundary"));
    expect(authorizer,
        contains("RequirePortableWindowsRecoveryHostOutsideMutationRoots"));
    expect(portableTransaction,
        contains("BuildPortableWindowsRecoveryHostTaskDefinition"));
    expect(portableTransaction,
        contains("RunPortableWindowsRecoveryPrepareBoundary"));
    expect(
      portableTransaction.indexOf("PersistPreparing"),
      lessThan(portableTransaction.indexOf("ArmAndStart")),
    );
    expect(
      portableTransaction.indexOf("ArmAndStart"),
      lessThan(portableTransaction.indexOf("transaction_.Prepare()")),
    );
    expect(persistent, contains("ValidateCurrentPortableWindowsRecoveryHost"));
    expect(portableHost, contains("TASK_LOGON_INTERACTIVE_TOKEN"));
    expect(portableHost, contains("TASK_RUNLEVEL_LUA"));
    expect(
      portableHost,
      contains("CreatePortableWindowsExactUserDirectory"),
    );
    expect(portableHost, contains("CreatePortableWindowsExactUserFile"));
    expect(portableHost, isNot(contains("ApplyExactUserSecurity")));
    expect(portableHost.toLowerCase(), isNot(contains("powershell")));
    expect(portableHost, isNot(contains("RunOnce")));
    expect(
      portableStorage,
      contains("FOLDERID_LocalAppData, KF_FLAG_CREATE"),
    );
    expect(portableStorage, isNot(contains("KF_FLAG_DEFAULT")));
  });

  test("Windows client validates canonical reservation and commit ACK", () {
    final header = readRequiredFile(
      "windows/native/src/helper/named_pipe_transport.h",
    );
    final source = readRequiredFile(
      "windows/native/src/helper/named_pipe_transport.cpp",
    );

    expect(header, contains("WindowsElevatedHelperClientSession"));
    expect(header, contains("WindowsElevatedHelperLaunch"));
    expect(header, contains("CommitAfterExit"));
    expect(header, contains("CancelReservation"));
    expect(source, contains("ParseNativeInstallReservationV1"));
    expect(source, contains("ParseNativeInstallRecoveryResultV1"));
    expect(source, contains("helper_endpoint_identity_sha256"));
    expect(source, contains("VerifyWindowsExecutableStillMatches"));
    expect(source, isNot(contains('"AUTHENTICATED "')));
  });

  test("Windows public client routes prepare commit and cancel to helper", () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final nativeSources = cmake.substring(
      cmake.indexOf("set(NATIVE_SOURCES"),
      cmake.indexOf("add_library(desktop_updater_native_objects"),
    );
    final source = readRequiredFile(
      "windows/native/src/desktop_updater_native.cpp",
    );
    final protectedContext = _functionBody(
      source,
      "LoadWindowsHelperClientContext",
    );

    expect(nativeSources, contains("named_pipe_transport.cpp"));
    expect(
      nativeSources,
      contains("windows_native_install_request_builder.cc"),
    );
    expect(source, contains("BuildWindowsNativeInstallTransactionRequestV1"));
    expect(source, contains("LaunchAuthenticatedElevatedHelper"));
    expect(source, contains("WindowsElevatedHelperClientSession"));
    expect(
        source, contains("EncodeCanonicalNativeInstallTransactionRequestV1"));
    expect(source, contains("CommitAfterExit()"));
    expect(source, contains("CancelReservation()"));
    expect(
      source,
      contains("Protected Windows helper install directory is not configured"),
    );
    expect(
      protectedContext,
      isNot(
        contains(
          "running_executable.parent_path() / kWindowsHelperExecutableName",
        ),
      ),
    );
    expect(
      source,
      isNot(
        contains(
          "Packaged Windows install helper endpoint is unavailable; no ",
        ),
      ),
    );
  });

  test("Windows public client routes persistent query and recovery to helper",
      () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final nativeSources = cmake.substring(
      cmake.indexOf("set(NATIVE_SOURCES"),
      cmake.indexOf("add_library(desktop_updater_native_objects"),
    );
    final helperSources = cmake.substring(
      cmake.indexOf("set(DESKTOP_UPDATER_INSTALL_HELPER_SOURCES"),
      cmake.indexOf("add_library(desktop_updater_install_helper_support"),
    );
    final client = readRequiredFile(
      "windows/native/src/desktop_updater_native.cpp",
    );
    final transport = readRequiredFile(
      "windows/native/src/helper/windows_recovery_transport.cpp",
    );
    final pipe = readRequiredFile(
      "windows/native/src/helper/named_pipe_transport.cpp",
    );
    final recovery = readRequiredFile(
      "windows/native/src/helper/windows_persistent_recovery.cpp",
    );
    final authorizer = readRequiredFile(
      "windows/native/src/helper/windows_install_authorizer.cpp",
    );
    final main = readRequiredFile("windows/native/src/helper/main.cpp");
    final locatorHeader = readRequiredFile(
      "windows/native/src/helper/windows_protected_helper_locator.h",
    );
    final locator = readRequiredFile(
      "windows/native/src/helper/windows_protected_helper_locator.cpp",
    );
    final recoveryHost = readRequiredFile(
      "windows/native/src/helper/windows_recovery_host.cpp",
    );
    final recoveryPipe = readRequiredFile(
      "windows/native/src/helper/windows_recovery_pipe_server.cpp",
    );
    final relaunch = readRequiredFile(
      "windows/native/src/helper/windows_relaunch_service.cpp",
    );
    final publicHeader = readRequiredFile(
      "windows/native/include/desktop_updater_native.h",
    );
    final protectedTransaction = _functionBody(
      authorizer,
      "class WindowsDirectoryPreparedTransaction",
    );

    expect(nativeSources, contains("windows_recovery_transport.cpp"));
    expect(nativeSources, contains("windows_protected_helper_locator.cpp"));
    expect(helperSources, contains("windows_persistent_recovery.cpp"));
    expect(helperSources, contains("windows_protected_helper_locator.cpp"));
    expect(helperSources, contains("windows_recovery_host.cpp"));
    expect(cmake.toLowerCase(), contains("taskschd"));
    expect(helperSources, contains("windows_recovery_transport.cpp"));
    expect(client, contains("LaunchAuthenticatedElevatedRecoveryRequest"));
    expect(client, contains('"queryTransaction"'));
    expect(client, contains('"recoverPendingInstall"'));
    expect(client, contains('"resolvePendingInstallAfterExit"'));
    expect(publicHeader, contains("ResolvePendingInstallAfterExit"));
    expect(
      client,
      isNot(
        contains(
          "return EndpointUnavailableStatus(transaction_id);\n}",
        ),
      ),
    );
    expect(transport, contains("ParseNativeInstallTransactionStatusV1"));
    expect(transport, contains("ParseNativeInstallRecoveryResultV1"));
    expect(pipe, contains("LaunchAuthenticatedElevatedHelperExchange"));
    expect(pipe, contains("VerifyWindowsExecutableStillMatches"));
    expect(recovery, contains("WindowsPersistentTransactionIndex"));
    expect(recovery, contains("PersistPreparing"));
    expect(recovery, contains("PersistActive"));
    expect(recovery, contains("PersistTerminal"));
    expect(recovery, contains("HKEY_LOCAL_MACHINE"));
    expect(recovery, contains("RegFlushKey"));
    expect(recovery, contains("AccessCheck"));
    expect(recovery, contains("WindowsRecoveryService"));
    expect(recovery, contains("manualActionRequired"));
    expect(recovery, isNot(contains("directory_iterator")));
    expect(authorizer, contains("WindowsPersistentTransactionIndex"));
    expect(authorizer, contains("PersistActive"));
    expect(authorizer, contains("WindowsRecoveryHostController"));
    expect(authorizer, contains("ArmAndStart"));
    expect(
      protectedTransaction.indexOf("PersistPreparing"),
      lessThan(protectedTransaction.indexOf("ArmAndStart")),
    );
    expect(
      protectedTransaction.indexOf("ArmAndStart"),
      lessThan(protectedTransaction.indexOf("transaction_.Prepare()")),
    );
    expect(main, contains("RunWindowsPersistentRecoveryPipeSession"));
    expect(main, contains('L"--recover-current"'));
    expect(main, contains("LoadWindowsHelperBootstrapForAutonomousRecovery"));
    expect(main, contains("RecoverAutonomously"));
    expect(locatorHeader, contains("ProtectedWindowsHelperEndpointV1"));
    expect(locator, contains("HKEY_LOCAL_MACHINE"));
    expect(locator, contains("TransactionEndpoints"));
    expect(locator, contains("RegFlushKey"));
    expect(locator, contains("SE_DACL_PROTECTED"));
    expect(locator, contains("WinAuthenticatedUserSid"));
    expect(recoveryHost, contains("TASK_TRIGGER_BOOT"));
    expect(recoveryHost, contains("TASK_LOGON_SERVICE_ACCOUNT"));
    expect(recoveryHost, contains("TASK_RUNLEVEL_HIGHEST"));
    expect(recoveryHost, contains("RecoveryReady"));
    expect(recoveryHost, contains("SignalWindowsRecoveryHostReady"));
    expect(recoveryHost, contains("TASK_DONT_ADD_PRINCIPAL_ACE"));
    expect(recoveryHost, contains("--recover-current"));
    expect(
      recoveryPipe,
      contains('request.operation == "resolvePendingInstallAfterExit"'),
    );
    expect(recoveryPipe, contains("WaitForSingleObject"));
    expect(relaunch, contains("CreateProcessWithTokenW"));
    expect(cmake.toLowerCase(), contains("userenv"));
    expect(recovery, contains('"executorProcessId"'));
    expect(recovery, contains('"executorProcessStartIdentity"'));
    expect(recovery, contains('"callerProcessId"'));
    expect(recovery, contains('"callerProcessStartIdentity"'));
    expect(recovery, contains("WaitForSingleObject(caller.get(), INFINITE)"));
    expect(recovery, contains("WaitForSingleObject(executor.get(), INFINITE)"));
  });

  test("Windows client accepts the staged canonical manifest terminator", () {
    final stager = readRequiredFile(
      "windows/native/src/runtime/artifact_stager_windows.cpp",
    );
    final client = readRequiredFile(
      "windows/native/src/desktop_updater_native.cpp",
    );

    expect(stager, contains('EncodeCanonicalJson(descriptor.raw) << "\\n"'));
    expect(client, contains("allow_single_trailing_newline"));
    expect(
      client,
      contains('"Staged release manifest", true'),
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

String _functionBody(String source, String functionName) {
  final name = source.indexOf(functionName);
  expect(name, isNonNegative, reason: "$functionName must exist");
  if (name < 0) return "";
  final openingBrace = source.indexOf("{", name);
  expect(openingBrace, isNonNegative, reason: "$functionName must have a body");
  if (openingBrace < 0) return "";
  var depth = 0;
  for (var index = openingBrace; index < source.length; index += 1) {
    if (source[index] == "{") depth += 1;
    if (source[index] == "}") {
      depth -= 1;
      if (depth == 0) return source.substring(openingBrace, index + 1);
    }
  }
  fail("$functionName body must terminate");
}
