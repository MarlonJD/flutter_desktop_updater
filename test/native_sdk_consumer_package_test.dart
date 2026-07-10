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
    expect(source, contains("MacInstallRequest("));
    expect(source, contains("DesktopUpdaterVersion.string"));
    expect("$manifest\n$source", isNot(contains("Flutter")));
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
      expect(consumerSource, contains("return 0"));
      expect(
        consumerSource,
        contains("DESKTOP_UPDATER_NATIVE_VERSION_STRING"),
      );
    }
  });

  test("NuGet package carries both wrappers and the win-x64 DLL", () {
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
    expect(project, contains('PackagePath="runtimes/win-x64/native"'));
    expect(
      project,
      contains("buildTransitive/DesktopUpdater.Native.targets"),
    );
    expect(targets, contains("CopyDesktopUpdaterNativeRuntime"));
    expect(
      consumerProject,
      contains('PackageReference Include="DesktopUpdater.Native"'),
    );
    expect(consumerSource, contains("DesktopUpdaterException"));
    expect(consumerSource, contains("Staged update directory"));
  });

  test("target-host CI installs, packs, links, loads, and runs consumers", () {
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );

    expect(
      workflow,
      contains("swift run --package-path example/native/macos"),
    );
    expect(
      workflow,
      contains("cmake --install windows/native/build --config Debug"),
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
      contains("dotnet run --project example/native/windows-dotnet"),
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

  test("published helper package stays source-complete and runtime-limited",
      () {
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
      "linux/native/src/desktop_updater_native.cc",
      "linux/native/cmake/desktop_updater_nativeConfig.cmake.in",
      "linux/native/cmake/desktop_updater_native.pc.in",
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    expect(ignoredPaths, isNot(contains("macos/")));
    expect(ignoredPaths, isNot(contains("windows/")));
    expect(ignoredPaths, isNot(contains("linux/")));
    expect(workflow, contains("dart pub publish --dry-run"));
    expect(publishedDocs, isNot(contains("downloadVerifyAndStage")));
    expect(publishedDocs, isNot(contains("native checkForUpdate")));
    expect(publishedDocs, isNot(contains("production-ready native runtime")));
  });
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
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
      .map((file) => file.readAsStringSync())
      .join("\n");
}
