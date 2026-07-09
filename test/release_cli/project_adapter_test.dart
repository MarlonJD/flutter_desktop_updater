import "dart:io";

import "package:desktop_updater/src/release_cli/flutter_project_adapter.dart";
import "package:desktop_updater/src/release_cli/manual_project_adapter.dart";
import "package:desktop_updater/src/release_cli/project_adapter.dart";
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
