import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test(
      "native helper retail packaging rejects Debug and incomplete policy inputs",
      () {
    final macEmbed = readRequiredFile(
      "macos/install_helper/embed_install_helper.sh",
    );
    final windowsProject = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/"
      "DesktopUpdater.Native.csproj",
    );
    final windowsTargets = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/buildTransitive/"
      "DesktopUpdater.Native.targets",
    );
    final linuxCmake = readRequiredFile("linux/native/CMakeLists.txt");

    expect(macEmbed, contains("-c release"));
    expect(macEmbed, contains("CODE_SIGN_IDENTITY"));
    expect(macEmbed, contains("DESKTOP_UPDATER_HELPER_INFO_TEMPLATE"));
    expect(macEmbed, isNot(contains(".build/debug")));
    expect(windowsProject, contains("InstallHelperPath must point"));
    expect(windowsProject, contains("HelperPolicyPath must point"));
    expect(windowsTargets, isNot(contains("Debug")));
    expect(linuxCmake, contains("DESKTOP_UPDATER_INSTALL_SYSTEM_BROKER"));
    expect(linuxCmake, contains("policy metadata is required"));
  });

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

  test("native runtime contract tests include Monocypher headers", () {
    for (final platform in <String>["windows", "linux"]) {
      final cmake = readRequiredFile("$platform/native/CMakeLists.txt");
      final includeStart = cmake.indexOf(
        "target_include_directories(desktop_updater_runtime_contract_test",
      );
      final includeEnd = cmake.indexOf(
        "target_link_libraries(desktop_updater_runtime_contract_test",
        includeStart,
      );

      expect(includeStart, greaterThanOrEqualTo(0), reason: platform);
      expect(includeEnd, greaterThan(includeStart), reason: platform);
      expect(
        cmake.substring(includeStart, includeEnd),
        contains(r"${DESKTOP_UPDATER_MONOCYPHER_DIR}"),
        reason: "$platform fixture sources include monocypher-ed25519.h",
      );
    }
  });

  test("pkg-config remains relocatable across install-time prefixes", () {
    final template = readRequiredFile(
      "linux/native/cmake/desktop_updater_native.pc.in",
    );
    final cmakeConfig = readRequiredFile(
      "linux/native/cmake/desktop_updater_nativeConfig.cmake.in",
    );
    final cmake = readRequiredFile("linux/native/CMakeLists.txt");
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );

    expect(
      template,
      contains(
          r"prefix=${pcfiledir}/@DESKTOP_UPDATER_PC_PREFIX_FROM_PCFILEDIR@"),
    );
    expect(template, contains(r"libdir=${prefix}/@CMAKE_INSTALL_LIBDIR@"));
    expect(
      template,
      contains(r"includedir=${prefix}/@CMAKE_INSTALL_INCLUDEDIR@"),
    );
    expect(template, isNot(contains("@CMAKE_INSTALL_PREFIX@")));
    expect(template, isNot(contains("@CMAKE_INSTALL_FULL_LIBDIR@")));
    expect(template, isNot(contains("@CMAKE_INSTALL_FULL_INCLUDEDIR@")));
    expect(cmake, contains("file(RELATIVE_PATH"));
    expect(cmake, contains("DESKTOP_UPDATER_PC_PREFIX_FROM_PCFILEDIR"));
    expect(
      cmake,
      contains("DESKTOP_UPDATER_CMAKE_PREFIX_FROM_CONFIGDIR"),
    );
    expect(
      cmakeConfig,
      contains("desktop_updater_native_HELPER_EXECUTABLE"),
    );
    expect(cmakeConfig, contains("@CMAKE_INSTALL_LIBEXECDIR@"));
    expect(
      workflow,
      contains(
        r'cmake --install linux/native/build --prefix "$PWD/linux/native/install"',
      ),
    );
    expect(workflow, contains("lib/pkgconfig"));
    expect(workflow, contains("lib/x86_64-linux-gnu/pkgconfig"));
    expect(workflow, contains("pkg-config --cflags --libs"));
  });

  test("pkg-config exports the native SDK public crypto dependency", () {
    final template = readRequiredFile(
      "linux/native/cmake/desktop_updater_native.pc.in",
    );

    expect(template, contains("Requires: libcrypto"));
    expect(template, isNot(contains("Requires.private: openssl")));
  });

  test("configured pkg-config paths compile from standard and multiarch dirs",
      () {
    if (!Platform.isMacOS && !Platform.isLinux) {
      return;
    }
    if (!_toolAvailable("cc") ||
        !_toolAvailable("ar") ||
        !_toolAvailable("pkg-config")) {
      markTestSkipped("cc, ar, and pkg-config are required locally.");
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
            .replaceAll(
              "@DESKTOP_UPDATER_PC_PREFIX_FROM_PCFILEDIR@",
              List<String>.filled(libRelative.split("/").length + 1, "..")
                  .join("/"),
            )
            .replaceAll("@CMAKE_INSTALL_LIBDIR@", libRelative)
            .replaceAll("@CMAKE_INSTALL_INCLUDEDIR@", "include"),
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
    expect(source, contains("GCHandleType.WeakTrackResurrection"));
    expect(source, contains("private CallbackState? _callbackState"));
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
    expect(tests, contains("CaptureCycleDoesNotPreventFinalization"));
    expect(tests, contains("CallbackStateWasAliveDuringRelease"));
  });

  test("packaged .NET consumers use isolated caches and candidate DLL hashes",
      () {
    final workflow = readRequiredFile(
      ".github/workflows/desktop-updater-ci.yml",
    );
    final zipSmoke = readRequiredFile(
      "tool/windows_native_runtime_zip_smoke.ps1",
    );
    final innoSmoke = readRequiredFile(
      "tool/windows_native_runtime_inno_transport_smoke.ps1",
    );
    final verifier = readRequiredFile(
      "tool/verify_windows_nuget_consumer.ps1",
    );

    expect(validateNuGetConsumerVerifier(verifier), isEmpty);
    expect(
      validatePackagedConsumerWorkflow(
        workflow,
        delegatedSources: [zipSmoke, innoSmoke],
      ),
      isEmpty,
    );
  });

  test("NuGet consumer verifier rejects missing isolation and hash proof", () {
    const valid = r'''
param($PackagePath, $PackageSource, $ProjectPath, $LaneRoot, $OutputPath, $PackageVersion, $RuntimeIdentifier)
$packageSource = $PackageSource
Remove-Item -LiteralPath $LaneRoot -Recurse -Force
$projectDirectory = Split-Path -Parent $ProjectPath
Join-Path $projectDirectory "obj"
Join-Path $projectDirectory "bin"
$packages = Join-Path $LaneRoot "packages"
$obj = Join-Path $LaneRoot "obj"
dotnet restore $ProjectPath --source $packageSource --packages $packages --ignore-failed-sources --no-cache -p:NuGetAudit=false -p:DesktopUpdaterNativeRuntimeIdentifier=$RuntimeIdentifier -p:DesktopUpdaterNativeVersion=$PackageVersion -p:RestorePackagesPath=$packages -p:BaseIntermediateOutputPath=$obj -p:MSBuildProjectExtensionsPath=$obj
dotnet build $ProjectPath --no-restore --output $OutputPath -p:NuGetAudit=false -p:DesktopUpdaterNativeRuntimeIdentifier=$RuntimeIdentifier -p:DesktopUpdaterNativeVersion=$PackageVersion -p:RestorePackagesPath=$packages -p:BaseIntermediateOutputPath=$obj -p:MSBuildProjectExtensionsPath=$obj
$nativeEntry = $archive.GetEntry("runtimes/$RuntimeIdentifier/native/desktop_updater_native.dll")
$runtimeEntry = $archive.GetEntry("runtimes/$RuntimeIdentifier/native/desktop_updater_runtime.dll")
$expectedHash = $sha256.ComputeHash($stream)
Get-FileHash -LiteralPath $resolvedDll -Algorithm SHA256
Get-FileHash -LiteralPath $outputDll -Algorithm SHA256
if ($resolvedHash -ne $expectedHash) { throw "resolved mismatch" }
if ($outputHash -ne $expectedHash) { throw "output mismatch" }
''';
    expect(validateNuGetConsumerVerifier(valid), isEmpty);
    expect(
      validateNuGetConsumerVerifier(
        valid.replaceAll(r"-p:MSBuildProjectExtensionsPath=$obj", ""),
      ),
      contains("isolated MSBuild project extensions"),
    );
    expect(
      validateNuGetConsumerVerifier(
        valid.replaceAll(
          r"Get-FileHash -LiteralPath $resolvedDll -Algorithm SHA256",
          "",
        ),
      ),
      contains("resolved package DLL hash"),
    );
    expect(
      validateNuGetConsumerVerifier(
        valid.replaceAll(
          r"Get-FileHash -LiteralPath $outputDll -Algorithm SHA256",
          "",
        ),
      ),
      contains("output DLL hash"),
    );
    expect(
      validateNuGetConsumerVerifier(
        valid.replaceAll(r"$PackageVersion", r"$IgnoredVersion"),
      ),
      contains("explicit package version"),
    );
    expect(
      validateNuGetConsumerVerifier(valid.replaceAll("--no-cache", "")),
      contains("restore bypasses global cache"),
    );
    expect(
      validateNuGetConsumerVerifier(
        valid.replaceAll(r'Join-Path $projectDirectory "obj"', ""),
      ),
      contains("stale project obj cleanup"),
    );
    expect(
      validateNuGetConsumerVerifier(
        valid.replaceAll(r"$sha256.ComputeHash($stream)", ""),
      ),
      contains("candidate entry digest"),
    );
    expect(
      validateNuGetConsumerVerifier(
        valid.replaceAll(
          r'''if ($resolvedHash -ne $expectedHash) { throw "resolved mismatch" }''',
          "",
        ),
      ),
      contains("resolved package hash comparison"),
    );
    expect(
      validateNuGetConsumerVerifier(
        valid.replaceAll(
          r'''if ($outputHash -ne $expectedHash) { throw "output mismatch" }''',
          "",
        ),
      ),
      contains("output hash comparison"),
    );
  });
}

List<String> validateNuGetConsumerVerifier(String source) {
  final failures = <String>[];
  void require(String token, String failure) {
    if (!source.contains(token)) {
      failures.add(failure);
    }
  }

  for (final parameter in <String>[
    r"$PackagePath",
    r"$PackageSource",
    r"$ProjectPath",
    r"$LaneRoot",
    r"$OutputPath",
    r"$PackageVersion",
    r"$RuntimeIdentifier",
  ]) {
    require(parameter, "missing verifier parameter $parameter");
  }
  require(r"Remove-Item -LiteralPath $LaneRoot", "stale lane root cleanup");
  require(
    r'Join-Path $projectDirectory "obj"',
    "stale project obj cleanup",
  );
  require(
    r'Join-Path $projectDirectory "bin"',
    "stale project bin cleanup",
  );
  require(
    r'Join-Path $LaneRoot "packages"',
    "isolated package cache",
  );
  require(r'Join-Path $LaneRoot "obj"', "isolated obj directory");
  require(r"--source $packageSource", "local-only package source");
  require(r"--packages $packages", "isolated restore packages");
  require(
    r"-p:DesktopUpdaterNativeRuntimeIdentifier=$RuntimeIdentifier",
    "explicit native asset RID",
  );
  require("--ignore-failed-sources", "offline local restore");
  require("--no-cache", "restore bypasses global cache");
  require("-p:NuGetAudit=false", "offline audit configuration");
  require(
    r"-p:DesktopUpdaterNativeVersion=$PackageVersion",
    "explicit package version",
  );
  require(r"-p:RestorePackagesPath=$packages", "restore package property");
  require(
    r"-p:BaseIntermediateOutputPath=$obj",
    "isolated intermediate output",
  );
  require(
    r"-p:MSBuildProjectExtensionsPath=$obj",
    "isolated MSBuild project extensions",
  );
  require("--no-restore", "build reuses isolated restore");
  require(
    r"runtimes/$RuntimeIdentifier/native/desktop_updater_native.dll",
    "candidate native DLL entry",
  );
  require(
    r"runtimes/$RuntimeIdentifier/native/desktop_updater_runtime.dll",
    "candidate runtime DLL entry",
  );
  require(
    r"Get-FileHash -LiteralPath $resolvedDll -Algorithm SHA256",
    "resolved package DLL hash",
  );
  require(
    r"Get-FileHash -LiteralPath $outputDll -Algorithm SHA256",
    "output DLL hash",
  );
  require(
    r"$sha256.ComputeHash($stream)",
    "candidate entry digest",
  );
  require(
    r"if ($resolvedHash -ne $expectedHash)",
    "resolved package hash comparison",
  );
  require(
    r"if ($outputHash -ne $expectedHash)",
    "output hash comparison",
  );
  return failures;
}

List<String> validatePackagedConsumerWorkflow(
  String source, {
  List<String> delegatedSources = const [],
}) {
  final failures = <String>[];
  final searchableSource = [source, ...delegatedSources].join("\n");
  final verifierCalls = RegExp(
    r"verify_windows_nuget_consumer\.ps1",
  ).allMatches(searchableSource).length;
  if (verifierCalls != 3) {
    failures.add("all three packaged consumers must use verifier");
  }
  for (final lane in <String>[
    "desktop-updater-nuget-regular",
    "native-runtime-windows-zip",
    "native-runtime-windows-inno",
  ]) {
    if (!source.contains('Join-Path \$env:RUNNER_TEMP "$lane"')) {
      failures.add("missing isolated runner-temp lane $lane");
    }
  }
  return failures;
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync()
      ? file.readAsStringSync().replaceAll("\r\n", "\n")
      : "";
}

String normalizeNewlines(String value) => value.replaceAll("\r\n", "\n");

bool _toolAvailable(String executable) {
  try {
    final result = Process.runSync(executable, const <String>["--version"]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
