import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Windows retail package uses Release DLLs and the dynamic retail CRT",
      () {
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );

    expect(
      cmake,
      contains(
        r"""set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")""",
      ),
    );
    expect(
      workflow,
      contains("cmake --build windows/native/build --config Release"),
    );
    expect(
      workflow,
      contains("cmake --install windows/native/build --config Release"),
    );
    expect(
      workflow,
      contains("windows/native/build/Release/desktop_updater_native.dll"),
    );
    expect(
      workflow,
      contains("windows/native/build/Release/desktop_updater_runtime.dll"),
    );
    expect(workflow, contains("dumpbin.exe"));
    expect(workflow, contains(r"/dependents $dll"));
    expect(workflow, contains("ucrtbased"));
    expect(workflow, contains(r"vcruntime\d+"));
    expect(workflow, contains(r"msvcp\d+"));
    expect(
      workflow,
      isNot(
        contains("windows/native/build/Debug/desktop_updater_runtime.dll"),
      ),
    );
  });

  test("native packages install and pack exact vendored license notices", () {
    final windowsCmake = readRequiredFile("windows/native/CMakeLists.txt");
    final linuxCmake = readRequiredFile("linux/native/CMakeLists.txt");
    final project = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/"
      "DesktopUpdater.Native.csproj",
    );
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );
    final minizLicense = normalizeNewlines(
      readRequiredFile("third_party/miniz/LICENSE"),
    ).trim();
    final monocypherLicense = normalizeNewlines(
      readRequiredFile("third_party/monocypher/LICENCE.md"),
    ).trim();

    for (final platform in <String>["windows", "linux"]) {
      final notices = normalizeNewlines(
        readRequiredFile("$platform/native/THIRD_PARTY_NOTICES.md"),
      );
      expect(notices, contains(minizLicense), reason: platform);
      expect(notices, contains(monocypherLicense), reason: platform);
    }
    expect(
      windowsCmake,
      contains("install(FILES THIRD_PARTY_NOTICES.md"),
    );
    expect(linuxCmake, contains("install(FILES THIRD_PARTY_NOTICES.md"));
    expect(project, contains("../../THIRD_PARTY_NOTICES.md"));
    expect(project, contains('PackagePath="/THIRD_PARTY_NOTICES.md"'));
    expect(workflow, contains('"THIRD_PARTY_NOTICES.md"'));
    expect(
      readRequiredFile("third_party/README.md"),
      contains("THIRD_PARTY_NOTICES.md"),
    );
  });

  test("pkg-config records configured absolute install directories", () {
    final template = readRequiredFile(
      "linux/native/cmake/desktop_updater_native.pc.in",
    );
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );

    expect(template, contains("prefix=@CMAKE_INSTALL_PREFIX@"));
    expect(template, contains("libdir=@CMAKE_INSTALL_FULL_LIBDIR@"));
    expect(template, contains("includedir=@CMAKE_INSTALL_FULL_INCLUDEDIR@"));
    expect(template, isNot(contains(r"${pcfiledir}")));
    expect(workflow, contains("lib/pkgconfig"));
    expect(workflow, contains("lib/x86_64-linux-gnu/pkgconfig"));
    expect(workflow, contains("pkg-config --cflags --libs"));
  });

  test("configured pkg-config paths compile from standard and multiarch dirs",
      () {
    if (!Platform.isMacOS && !Platform.isLinux) {
      return;
    }
    final template = readRequiredFile(
      "linux/native/cmake/desktop_updater_native.pc.in",
    );
    final root = Directory.systemTemp.createTempSync("desktop-updater-pc-");
    addTearDown(() => root.deleteSync(recursive: true));

    for (final libRelative in <String>[
      "lib",
      "lib/x86_64-linux-gnu",
    ]) {
      final prefix =
          Directory("${root.path}/${libRelative.replaceAll('/', '-')}")
            ..createSync(recursive: true);
      final include = Directory("${prefix.path}/include")..createSync();
      final lib = Directory("${prefix.path}/$libRelative")
        ..createSync(recursive: true);
      final pc = Directory("${lib.path}/pkgconfig")..createSync();
      File("${include.path}/desktop_updater_probe.h").writeAsStringSync(
        "int desktop_updater_probe(void);\n",
      );
      final implementation = File("${prefix.path}/probe.c")
        ..writeAsStringSync("int desktop_updater_probe(void) { return 42; }\n");
      final object = "${prefix.path}/probe.o";
      expect(
        Process.runSync("cc", <String>["-c", implementation.path, "-o", object])
            .exitCode,
        0,
      );
      expect(
        Process.runSync("ar", <String>[
          "rcs",
          "${lib.path}/libdesktop_updater_native.a",
          object,
        ]).exitCode,
        0,
      );
      File("${pc.path}/desktop_updater_native.pc").writeAsStringSync(
        template
            .replaceAll("@CMAKE_INSTALL_PREFIX@", prefix.path)
            .replaceAll("@CMAKE_INSTALL_FULL_LIBDIR@", lib.path)
            .replaceAll("@CMAKE_INSTALL_FULL_INCLUDEDIR@", include.path),
      );
      final environment = <String, String>{
        ...Platform.environment,
        "PKG_CONFIG_PATH": pc.path,
      };
      final flags = Process.runSync(
        "pkg-config",
        <String>["--cflags", "--libs", "desktop_updater_native"],
        environment: environment,
      );
      expect(flags.exitCode, 0, reason: "${flags.stderr}");
      final consumer = File("${prefix.path}/consumer.c")
        ..writeAsStringSync(
          '#include "desktop_updater_probe.h"\n'
          "int main(void) { return desktop_updater_probe() == 42 ? 0 : 1; }\n",
        );
      final executable = "${prefix.path}/consumer";
      final compile = Process.runSync("cc", <String>[
        consumer.path,
        ...(flags.stdout as String).trim().split(RegExp(r"\s+")),
        "-o",
        executable,
      ]);
      expect(compile.exitCode, 0, reason: "${compile.stderr}");
      expect(Process.runSync(executable, const <String>[]).exitCode, 0);
    }
  });

  test("managed runtime owner is finalizable without a self-root", () {
    final source = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs",
    );
    final tests = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native.Tests/"
      "DesktopUpdaterClientTests.cs",
    );

    expect(source, contains(": SafeHandle"));
    expect(source, contains("protected override bool ReleaseHandle()"));
    expect(source, contains("CallbackState"));
    expect(
      source,
      matches(RegExp(r"CheckForUpdate\s*\(\s*NativeClientHandle client\s*\)")),
    );
    expect(source, isNot(contains("DangerousGetHandle")));
    expect(source, isNot(contains("GCHandle.Alloc(this)")));
    expect(
      tests,
      contains("FinalizerReleasesNativeClientWhenDisposeIsOmitted"),
    );
    expect(tests, contains("GC.WaitForPendingFinalizers()"));
    expect(tests, contains("CreateForTesting"));
  });
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}

String normalizeNewlines(String value) => value.replaceAll("\r\n", "\n");
