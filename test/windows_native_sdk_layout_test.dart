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

    expect(cmake, contains("desktop_updater_native_objects OBJECT"));
    expect(cmake, contains("desktop_updater_native_static STATIC"));
    expect(cmake, contains("desktop_updater_native SHARED"));
    expect(cmake, contains("desktop_updater::native ALIAS"));
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
    expect(tests, contains("RemovedFilesReachNativeRequest"));
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
    expect(plugin, contains("ScheduleInstallAndRelaunch"));
    expect(plugin, isNot(contains("function Test-AuthenticodePolicy")));
    expect(native, contains("function Test-AuthenticodePolicy"));
    expect(native, contains("StartElevatedPowerShell"));
    expect(native, contains("Remove-StagingDirectoryWithRetry"));
    expect(native, contains("rollback success"));
    expect(
      native.indexOf("#include <windows.h>"),
      lessThan(native.indexOf("#include <bcrypt.h>")),
      reason: "Windows SDK base types must be declared before bcrypt.h",
    );
  });

  test(".NET wrapper marshals every removed file and calls the real DLL", () {
    final wrapper = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterNative.cs",
    );
    final tests = readRequiredDirectory(
      "windows/native/dotnet/DesktopUpdater.Native.Tests",
    );

    expect(wrapper, contains("IReadOnlyList<string> removedFiles"));
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
        "ctest --test-dir windows/native/build -C Debug --output-on-failure",
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
