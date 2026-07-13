import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Linux native SDK exposes a Flutter-free install contract", () {
    final header = readRequiredFile(
      "linux/native/include/desktop_updater_native.h",
    );
    final version = readRequiredFile(
      "linux/native/include/desktop_updater_version.h",
    );

    expect(header, contains("enum class LinuxInstallOperation"));
    expect(header, contains("struct InstallRequest"));
    expect(header, contains("std::string staging_path"));
    expect(header, contains("std::string install_root"));
    expect(header, contains("std::string executable_relative_path"));
    expect(header, contains("std::string package_id"));
    expect(header, contains("std::vector<std::string> removed_files"));
    expect(header, contains("std::string diagnostics_log_path"));
    expect(header, contains("ValidateInstallRequest"));
    expect(header, contains("ScheduleInstallAndRelaunch"));
    expect(header, contains("kLegacySelfContainedBundle"));
    expect(header, isNot(contains("Flutter")));
    expect(header, isNot(contains("Gtk")));
    expect(version, contains("DESKTOP_UPDATER_NATIVE_API_VERSION 1u"));
  });

  test("Linux plugin links the source-first native directory", () {
    final rootCmake = File("linux/CMakeLists.txt").readAsStringSync();
    final nativeCmake = readRequiredFile("linux/native/CMakeLists.txt");
    final pkgConfig = readRequiredFile(
      "linux/native/cmake/desktop_updater_native.pc.in",
    );
    final readme = readRequiredFile("linux/native/README.md");

    expect(rootCmake, contains('add_subdirectory("native")'));
    expect(rootCmake, contains("desktop_updater_native"));
    expect(
      rootCmake,
      isNot(contains('add_subdirectory("native/desktop_updater")')),
    );
    expect(nativeCmake, contains("add_library(desktop_updater_native"));
    expect(nativeCmake, contains("desktop_updater::native ALIAS"));
    expect(
      nativeCmake,
      contains("if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)"),
    );
    expect(nativeCmake, contains("EXPORT_NAME native"));
    expect(
      nativeCmake,
      contains("option(DESKTOP_UPDATER_NATIVE_BUILD_TESTS"),
    );
    expect(nativeCmake, contains('"Build desktop_updater native tests" OFF'));
    expect(nativeCmake, contains("install(TARGETS desktop_updater_native"));
    expect(
      nativeCmake,
      contains("install(EXPORT desktop_updater_nativeTargets"),
    );
    expect(nativeCmake, contains("desktop_updater_native.pc"));
    expect(
      pkgConfig,
      contains(r"Libs: -L${libdir} -ldesktop_updater_native"),
    );
    expect(readme, contains("source-first"));
    expect(readme, contains("compiler, glibc, architecture"));
  });

  test("Linux native runtime and shared tests require C++17", () {
    final nativeCmake = readRequiredFile("linux/native/CMakeLists.txt");
    const targets = <String>[
      "desktop_updater_native",
      "desktop_updater_runtime",
      "desktop_updater_native_test",
      "desktop_updater_runtime_lifecycle_test",
      "desktop_updater_runtime_contract_test",
      "desktop_updater_runtime_artifact_test",
      "desktop_updater_runtime_transport_test",
    ];

    expect(nativeCmake, isNot(contains("cxx_std_14")));
    for (final target in targets) {
      final compileFeaturePattern = [
        r"target_compile_features\(",
        target,
        r"\s+(?:PUBLIC|PRIVATE)\s+cxx_std_17\)",
      ].join();
      expect(
        nativeCmake,
        matches(RegExp(compileFeaturePattern)),
        reason: "$target must compile shared std::filesystem headers as C++17",
      );
    }
  });

  test("Linux preview declares the CMake floor required by CURL target", () {
    final nativeCmake = readRequiredFile("linux/native/CMakeLists.txt");
    final readme = readRequiredFile("linux/native/README.md");
    final runtimeFloor = nativeCmake.indexOf(
      'if(DESKTOP_UPDATER_NATIVE_RUNTIME AND CMAKE_VERSION VERSION_LESS "3.12")',
    );
    final curlLookup = nativeCmake.indexOf("find_package(CURL REQUIRED)");

    expect(runtimeFloor, greaterThanOrEqualTo(0));
    expect(curlLookup, greaterThan(runtimeFloor));
    expect(
      nativeCmake,
      contains("The native runtime requires CMake 3.12 or later"),
    );
    expect(readme, contains("CMake 3.12 or later"));
    expect(readme, contains("Native tests require CMake 3.14"));
  });

  test("Linux helper safety behavior lives in native source", () {
    final plugin = File("linux/desktop_updater_plugin.cc").readAsStringSync();
    final source = readRequiredFile(
      "linux/native/src/desktop_updater_native.cc",
    );

    expect(plugin, contains("desktop_updater::native::InstallRequest"));
    expect(plugin, contains("ScheduleInstallAndRelaunch"));
    expect(plugin, isNot(contains("kProtectedInstallRoots")));
    expect(plugin, isNot(contains("rollback_and_exit")));
    expect(source, contains("kProtectedInstallRoots"));
    expect(source, contains("Removed file path escapes install root"));
    expect(source, contains("Staging path must not overlap install root"));
    expect(source, contains(r'rm -rf \"$target\"'));
    expect(source, contains(r'rm -rf \"$staging\"'));
    expect(source, contains(r'cp -a \"$backup/.\" \"$target/\"'));
    expect(source, contains(r'chmod +x \"$exe\"'));
    expect(source, contains("rollback success"));
  });

  test("Linux native tests prove destructive commands stay bounded", () {
    final tests = readRequiredDirectory("linux/native/test");

    expect(tests, contains("RejectsProtectedSharedRoots"));
    expect(tests, contains("RejectsNonCanonicalAndSymlinkEscapes"));
    expect(tests, contains("GeneratedScriptBoundsDestructiveCommands"));
    expect(tests, contains("RollbackRestoresOnlyVerifiedBundle"));
    expect(tests, contains("StagingCleanupCannotDeleteInstallRoot"));
  });

  test("Linux runtime artifact handoff uses a non-temporary install root", () {
    final artifactTest = readRequiredFile(
      "linux/native/test/runtime/artifact_stager_test.cc",
    );

    expect(artifactTest, contains('WorkingPath("_install")'));
    expect(artifactTest, contains('TemporaryPath("_staging_parent")'));
    expect(artifactTest, contains("valid_handoff.error"));
    expect(artifactTest, isNot(contains('TemporaryPath("_install")')));
  });

  test("Linux plugin positive install fixture avoids temporary roots", () {
    final pluginTest = readRequiredFile(
      "linux/test/desktop_updater_plugin_test.cc",
    );

    expect(pluginTest, contains("AcceptsSelfContainedBundle"));
    expect(pluginTest, contains("getcwd("));
    expect(pluginTest, contains("desktop_updater_install_"));
    expect(
      pluginTest,
      isNot(contains('/tmp/desktop_updater_install_XXXXXX')),
    );
    expect(pluginTest, contains('/tmp/desktop_updater_staging_XXXXXX'));
  });

  test("Linux CI runs standalone native tests with zero-test detection", () {
    final workflow = File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsStringSync();
    final exampleCmake = readRequiredFile("example/linux/CMakeLists.txt");

    expect(
      workflow,
      contains(
        "cmake -S linux/native -B linux/native/build "
        "-DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON",
      ),
    );
    expect(
      workflow,
      contains(
        "ctest --test-dir linux/native/build --output-on-failure",
      ),
    );
    expect(workflow, contains("Linux native CTest registered zero tests"));
    expect(exampleCmake, contains("enable_testing()"));
    expect(workflow, isNot(contains("desktop_updater_native.so")));
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
      .where((file) => file.path.endsWith(".cc"))
      .map((file) => file.readAsStringSync())
      .join("\n");
}
