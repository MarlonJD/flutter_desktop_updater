import "dart:io";

import "package:desktop_updater/src/release_cli/cmake_project_adapter.dart";
import "package:desktop_updater/src/release_cli/flutter_project_adapter.dart";
import "package:desktop_updater/src/release_cli/manual_project_adapter.dart";
import "package:desktop_updater/src/release_cli/project_adapter.dart";
import "package:desktop_updater/src/release_cli/publish_command.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/xcode_project_adapter.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  group("project adapter selection", () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp("project_adapter_");
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test("explicit adapter type wins over manual input and markers", () async {
      final artifactRoot = Directory(path.join(root.path, "bundle"));
      await artifactRoot.create();
      await File(path.join(root.path, "pubspec.yaml")).writeAsString("");
      const xcode = _MarkerAdapter("xcode", "missing.xcodeproj");
      const selector = DefaultProjectAdapterSelector(
        adapters: [xcode, FlutterProjectAdapter.forSelection()],
      );

      final selected = selector.select(
        ProjectAdapterSelectionRequest(
          projectRoot: root,
          explicitType: "xcode",
          manualArtifactRoot: artifactRoot,
          manualAppName: "Example",
          manualPackageId: "com.example.app",
          manualVersion: "1.0.0",
        ),
      );

      expect(selected, same(xcode));
    });

    test("complete manual metadata selects the manual bundle adapter",
        () async {
      final artifactRoot = Directory(path.join(root.path, "bundle"));
      await artifactRoot.create();
      const selector = DefaultProjectAdapterSelector();

      final selected = selector.select(
        ProjectAdapterSelectionRequest(
          projectRoot: root,
          manualArtifactRoot: artifactRoot,
          manualAppName: "Example",
          manualPackageId: "com.example.app",
          manualVersion: "1.2.3",
          manualBuildNumber: 12,
          manualExecutableRelativePath: "bin/example",
        ),
      );

      expect(selected, isA<ManualProjectAdapter>());
      final result = await selected.build(
        ProjectBuildRequest(
          projectRoot: root,
          platform: "linux",
          releaseMode: true,
        ),
      );
      expect(result.artifactRoot.path, artifactRoot.path);
      expect(result.appName, "Example");
      expect(result.packageId, "com.example.app");
      expect(result.version, "1.2.3");
      expect(result.buildNumber, 12);
      expect(result.executableRelativePath, "bin/example");
    });

    test("partial manual metadata fails closed", () async {
      final artifactRoot = Directory(path.join(root.path, "bundle"));
      await artifactRoot.create();

      expect(
        () => const DefaultProjectAdapterSelector().select(
          ProjectAdapterSelectionRequest(
            projectRoot: root,
            manualArtifactRoot: artifactRoot,
            manualAppName: "Example",
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("artifact root, app name, package id, and version"),
          ),
        ),
      );
    });

    test("Flutter marker takes precedence over native markers", () async {
      await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: example
version: 1.0.0
""");
      await File(path.join(root.path, "CMakeLists.txt")).writeAsString("");
      const flutter = FlutterProjectAdapter.forSelection();
      const cmake = _MarkerAdapter("cmake", "CMakeLists.txt");

      final selected = const DefaultProjectAdapterSelector(
        adapters: [cmake, flutter],
      ).select(ProjectAdapterSelectionRequest(projectRoot: root));

      expect(selected, same(flutter));
    });

    test("exactly one native marker selects its adapter", () async {
      await File(path.join(root.path, "CMakeLists.txt")).writeAsString("");
      const cmake = _MarkerAdapter("cmake", "CMakeLists.txt");

      final selected = const DefaultProjectAdapterSelector(
        adapters: [cmake, _MarkerAdapter("xcode", "Example.xcodeproj")],
      ).select(ProjectAdapterSelectionRequest(projectRoot: root));

      expect(selected, same(cmake));
    });

    test("ambiguous native markers require an explicit type", () async {
      await File(path.join(root.path, "CMakeLists.txt")).writeAsString("");
      await Directory(path.join(root.path, "Example.xcodeproj")).create();

      expect(
        () => const DefaultProjectAdapterSelector(
          adapters: [
            _MarkerAdapter("cmake", "CMakeLists.txt"),
            _MarkerAdapter("xcode", "Example.xcodeproj"),
          ],
        ).select(ProjectAdapterSelectionRequest(projectRoot: root)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("Multiple project types"),
          ),
        ),
      );
    });

    test("a markers-free directory produces a usage error", () {
      expect(
        () => const DefaultProjectAdapterSelector().select(
          ProjectAdapterSelectionRequest(projectRoot: root),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("Unable to infer a project type"),
          ),
        ),
      );
    });
  });

  group("manual project adapter", () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp("manual_adapter_");
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test("rejects a missing artifact root", () async {
      final adapter = ManualProjectAdapter(
        artifactRoot: Directory(path.join(root.path, "missing")),
        appName: "Example",
        packageId: "com.example.app",
        version: "1.0.0",
      );

      await expectLater(
        adapter.build(
          ProjectBuildRequest(
            projectRoot: root,
            platform: "linux",
            releaseMode: true,
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test("rejects a single Windows executable", () async {
      final executable = File(path.join(root.path, "Example.exe"));
      await executable.writeAsString("binary");
      final adapter = ManualProjectAdapter(
        artifactRoot: executable,
        appName: "Example",
        packageId: "com.example.app",
        version: "1.0.0",
      );

      await expectLater(
        adapter.build(
          ProjectBuildRequest(
            projectRoot: root,
            platform: "windows",
            releaseMode: true,
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("complete Windows artifact directory"),
          ),
        ),
      );
    });

    test("rejects a symbolic link used as the artifact root", () async {
      final target = Directory(path.join(root.path, "target"));
      await target.create();
      final artifactLink = Link(path.join(root.path, "bundle-link"));
      await artifactLink.create(target.path);
      final adapter = ManualProjectAdapter(
        artifactRoot: artifactLink,
        appName: "Example",
        packageId: "com.example.app",
        version: "1.0.0",
      );

      await expectLater(
        adapter.build(
          ProjectBuildRequest(
            projectRoot: root,
            platform: "windows",
            releaseMode: true,
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("must not be a symbolic link"),
          ),
        ),
      );
    });

    test("rejects a Linux executable instead of a bundle", () async {
      final executable = File(path.join(root.path, "example"));
      await executable.writeAsString("binary");
      final adapter = ManualProjectAdapter(
        artifactRoot: executable,
        appName: "Example",
        packageId: "com.example.app",
        version: "1.0.0",
      );

      await expectLater(
        adapter.build(
          ProjectBuildRequest(
            projectRoot: root,
            platform: "linux",
            releaseMode: true,
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("self-contained Linux artifact directory"),
          ),
        ),
      );
    });
  });

  test("publish parser exposes explicit native project inputs", () {
    final parser = buildPublishParser();
    final results = parser.parse(const [
      "--project-type",
      "xcode",
      "--xcode-workspace",
      "Example.xcworkspace",
      "--xcode-scheme",
      "Example",
      "--cmake-source",
      "native",
      "--cmake-build-directory",
      "out/build",
      "--cmake-build-target",
      "example",
      "--artifact-root",
      "out/install",
      "--executable-relative-path",
      "bin/example",
    ]);

    expect(results["project-type"], "xcode");
    expect(results["xcode-workspace"], "Example.xcworkspace");
    expect(results["xcode-scheme"], "Example");
    expect(results["cmake-source"], "native");
    expect(results["cmake-build-directory"], "out/build");
    expect(results["cmake-build-target"], "example");
    expect(results["artifact-root"], "out/install");
    expect(results["executable-relative-path"], "bin/example");
  });

  group("xcode project adapter", () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp("xcode_adapter_");
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test("builds Release for macOS and resolves the whole app bundle",
        () async {
      await Directory(path.join(root.path, "Example.xcodeproj")).create();
      final bundle = Directory(
        path.join(root.path, "xcode-products", "Example.app"),
      );
      await bundle.create(recursive: true);
      final calls = <_ProcessCall>[];
      final adapter = XcodeProjectAdapter(
        projectPath: "Example.xcodeproj",
        scheme: "Example",
        overrides: const ReleasePublishOverrides(),
        output: StringBuffer(),
        runProcess: (executable, arguments) async {
          calls.add(_ProcessCall(executable, arguments));
          if (arguments.contains("-showBuildSettings")) {
            return ProcessResult(
              1,
              0,
              """
Build settings for action build and target Example:
    TARGET_BUILD_DIR = ${bundle.parent.path}
    WRAPPER_NAME = Example.app
    PRODUCT_BUNDLE_IDENTIFIER = com.example.app
    MARKETING_VERSION = 3.2.1
    CURRENT_PROJECT_VERSION = 42
Build settings for action build and target HelperLibrary:
    TARGET_BUILD_DIR = ${path.join(root.path, "helper-products")}
    FULL_PRODUCT_NAME = libHelperLibrary.a
""",
              "",
            );
          }
          return ProcessResult(1, 0, "xcode build output", "");
        },
      );

      final result = await adapter.build(
        ProjectBuildRequest(
          projectRoot: root,
          platform: "macos",
          releaseMode: true,
        ),
      );

      expect(calls, hasLength(2));
      expect(calls.first.executable, "xcodebuild");
      expect(
        calls.first.arguments,
        containsAllInOrder([
          "-project",
          path.join(root.path, "Example.xcodeproj"),
          "-scheme",
          "Example",
          "-configuration",
          "Release",
          "-destination",
          "platform=macOS",
          "-derivedDataPath",
        ]),
      );
      expect(calls.first.arguments.last, "build");
      expect(calls.last.arguments, contains("-showBuildSettings"));
      expect(result.artifactRoot.path, bundle.path);
      expect(result.appName, "Example.app");
      expect(result.packageId, "com.example.app");
      expect(result.version, "3.2.1");
      expect(result.buildNumber, 42);
    });

    test("requires exactly one project container and a scheme", () {
      expect(
        () => XcodeProjectAdapter(
          projectPath: "Example.xcodeproj",
          workspacePath: "Example.xcworkspace",
          scheme: "",
          overrides: const ReleasePublishOverrides(),
          output: StringBuffer(),
        ).build(
          ProjectBuildRequest(
            projectRoot: root,
            platform: "macos",
            releaseMode: true,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group("cmake project adapter", () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp("cmake_adapter_");
      await File(path.join(root.path, "CMakeLists.txt")).writeAsString("");
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test("configures, builds, installs, and returns the install tree",
        () async {
      final calls = <_ProcessCall>[];
      final adapter = CMakeProjectAdapter(
        buildTarget: "example",
        executableRelativePath: "bin/example",
        overrides: const ReleasePublishOverrides(
          appName: "Example",
          packageId: "com.example.app",
          version: "2.4.0",
          buildNumber: 24,
        ),
        output: StringBuffer(),
        runProcess: (executable, arguments) async {
          calls.add(_ProcessCall(executable, arguments));
          final prefixIndex = arguments.indexOf("--prefix");
          if (prefixIndex >= 0) {
            final installRoot = Directory(arguments[prefixIndex + 1]);
            await File(path.join(installRoot.path, "bin", "example"))
                .create(recursive: true);
          }
          return ProcessResult(1, 0, "cmake output", "");
        },
      );

      final result = await adapter.build(
        ProjectBuildRequest(
          projectRoot: root,
          platform: "linux",
          releaseMode: true,
        ),
      );

      expect(calls, hasLength(3));
      expect(calls[0].arguments, containsAllInOrder(["-S", root.path, "-B"]));
      expect(
        calls[1].arguments,
        containsAllInOrder([
          "--build",
          anything,
          "--config",
          "Release",
          "--target",
          "example",
        ]),
      );
      expect(
        calls[2].arguments,
        containsAllInOrder([
          "--install",
          anything,
          "--config",
          "Release",
          "--prefix",
        ]),
      );
      expect(result.artifactRoot, isA<Directory>());
      expect(
        result.artifactRoot.path,
        endsWith(path.join("cmake-install", "linux")),
      );
      expect(result.executableRelativePath, "bin/example");
      expect(result.appName, "Example");
      expect(result.buildNumber, 24);
    });

    test("accepts an already installed tree without starting CMake", () async {
      final installed = Directory(path.join(root.path, "installed"));
      await File(path.join(installed.path, "bin", "example"))
          .create(recursive: true);
      final adapter = CMakeProjectAdapter(
        installedArtifactRoot: installed.path,
        executableRelativePath: "bin/example",
        overrides: const ReleasePublishOverrides(
          appName: "Example",
          packageId: "com.example.app",
          version: "2.4.0",
        ),
        output: StringBuffer(),
        runProcess: (executable, arguments) {
          fail("An installed CMake tree must not start a process.");
        },
      );

      final result = await adapter.build(
        ProjectBuildRequest(
          projectRoot: root,
          platform: "windows",
          releaseMode: true,
        ),
      );

      expect(result.artifactRoot.path, installed.path);
    });

    test("requires a build target or installed root and executable path", () {
      expect(
        () => CMakeProjectAdapter(
          overrides: const ReleasePublishOverrides(
            appName: "Example",
            packageId: "com.example.app",
            version: "2.4.0",
          ),
          output: StringBuffer(),
        ).build(
          ProjectBuildRequest(
            projectRoot: root,
            platform: "linux",
            releaseMode: true,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

final class _ProcessCall {
  const _ProcessCall(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

final class _MarkerAdapter implements ProjectAdapter {
  const _MarkerAdapter(this.type, this.marker);

  @override
  final String type;

  final String marker;

  @override
  bool canHandle(Directory projectRoot) {
    return FileSystemEntity.typeSync(path.join(projectRoot.path, marker)) !=
        FileSystemEntityType.notFound;
  }

  @override
  Future<ProjectBuildResult> build(ProjectBuildRequest request) {
    throw UnimplementedError();
  }
}
