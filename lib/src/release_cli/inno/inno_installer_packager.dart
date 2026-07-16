import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_compiler.dart";
import "package:desktop_updater/src/release_cli/inno/inno_output_name.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/inno/inno_script_builder.dart";
import "package:desktop_updater/src/release_cli/platform_release_profile.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:path/path.dart" as path;

typedef CompileInnoForTest = Future<void> Function({
  required File scriptFile,
  required File outputExe,
});

class InnoInstallerPackager {
  const InnoInstallerPackager({
    this.compiler = const InnoCompiler(),
    this.scriptBuilder = const InnoScriptBuilder(),
    this.compileInno,
  });

  final InnoCompiler compiler;
  final InnoScriptBuilder scriptBuilder;
  final CompileInnoForTest? compileInno;

  Future<ReleasePackageResult> package(
    ReleasePackageRequest request, {
    required InnoPublishConfig config,
    String? outputBaseName,
  }) async {
    await request.outputDirectory.create(recursive: true);
    final protectedHelperInstallDir =
        resolveGeneratedProtectedHelperInstallDir(config);
    _GeneratedProtectedHelperInputs? protectedInputs;
    if (protectedHelperInstallDir != null) {
      protectedInputs = await _validateGeneratedProtectedHelperInputs(
        input: request.input,
        configuredInstallDir: protectedHelperInstallDir,
      );
    }
    final resolvedOutputBaseName = outputBaseName ??
        await resolveInnoOutputBaseName(
          config: config,
          appName: request.appName,
          version: request.version,
          platform: request.platform,
        );
    final outputExe = File(
      path.join(request.outputDirectory.path, "$resolvedOutputBaseName.exe"),
    );
    final scriptFile = File(
      path.join(request.outputDirectory.path, "$resolvedOutputBaseName.iss"),
    );
    File? installedIdentitySource;

    if (config.mode == "script") {
      await File(config.script!).copy(scriptFile.path);
    } else {
      await _rejectReservedInstalledIdentityMarker(request.input);
      installedIdentitySource = File(
        path.join(
          request.outputDirectory.path,
          "$resolvedOutputBaseName.install-identity.json",
        ),
      );
      await installedIdentitySource.writeAsString(
        jsonEncode(<String, Object?>{
          "packageId": request.packageId,
          "schemaVersion": 1,
        }),
        flush: true,
      );
      final metadata = ProjectMetadata(
        version: request.version,
        buildNumber: request.buildNumber,
        appName: request.appName,
        packageId: request.packageId,
        platform: request.platform,
        profile: PlatformReleaseProfile.forPlatform(request.platform),
        input: request.input,
      );
      await scriptFile.writeAsString(
        scriptBuilder.build(
          metadata: metadata,
          config: config,
          outputDirectoryPath: request.outputDirectory.path,
          outputBaseName: resolvedOutputBaseName,
          installedIdentitySourcePath: installedIdentitySource.path,
          protectedHelperSha256: protectedInputs?.helperSha256,
          protectedPolicySha256: protectedInputs?.policySha256,
        ),
      );
    }

    final fakeCompiler = compileInno;
    if (fakeCompiler == null) {
      await compiler.compile(scriptFile: scriptFile, isccPath: config.isccPath);
    } else {
      await fakeCompiler(scriptFile: scriptFile, outputExe: outputExe);
    }

    if (!await outputExe.exists()) {
      throw FileSystemException(
        "Inno compiler did not produce installer.",
        outputExe.path,
      );
    }

    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "innoInstaller",
        url: request.artifactUrl,
        sha256: await sha256File(outputExe),
        length: await outputExe.length(),
      ),
      install: ReleaseInstall(
        strategy: "innoInstaller",
        inno: ReleaseInnoInstall(
          silentArgs: config.silentArgs,
          inheritInstallDirectory: true,
          logFileName: "desktop_updater_inno_install.log",
          relaunchAfterInstall: true,
          requiresElevation: config.requiresElevation,
          authenticode: ReleaseAuthenticodePolicy(
            required: config.authenticodeThumbprints.isNotEmpty,
            sha256Thumbprints: config.authenticodeThumbprints,
          ),
        ),
      ),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.now().toUtc(),
    );

    final releaseFile = File(
      path.join(request.outputDirectory.path, "release.json"),
    );
    await releaseFile.writeAsString(
      const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
    );

    return ReleasePackageResult(
      artifact: outputExe,
      releaseFile: releaseFile,
      descriptor: descriptor,
    );
  }
}

const _protectedHelperExecutableName = "desktop_updater_install_helper.exe";
const _protectedHelperPolicyName = "desktop_updater_helper_policy.json";
const _protectedHelperCMakeCacheKey =
    "DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR";

Future<_GeneratedProtectedHelperInputs>
    _validateGeneratedProtectedHelperInputs({
  required FileSystemEntity input,
  required String configuredInstallDir,
}) async {
  final installDir = configuredInstallDir.trim();
  if (input is! Directory) {
    throw FileSystemException(
      "Generated Inno input must be a Windows Release directory.",
      input.path,
    );
  }
  final files = <String, File>{};
  for (final fileName in <String>[
    _protectedHelperExecutableName,
    _protectedHelperPolicyName,
  ]) {
    final file = File(path.join(input.path, fileName));
    if (!await file.exists() || await file.length() == 0) {
      throw FileSystemException(
        "Generated administrative Inno installer requires $fileName in "
        "the Windows Release directory.",
        file.path,
      );
    }
    files[fileName] = file;
  }

  final cache = await _findNearestCMakeCache(input);
  if (cache == null) {
    return _GeneratedProtectedHelperInputs(
      helperSha256: await sha256File(files[_protectedHelperExecutableName]!),
      policySha256: await sha256File(files[_protectedHelperPolicyName]!),
    );
  }
  final compiledInstallDir = await _readCMakeCachePath(
    cache,
    _protectedHelperCMakeCacheKey,
  );
  if (compiledInstallDir == null) {
    throw StateError(
      "${cache.path} does not define $_protectedHelperCMakeCacheKey for "
      "the generated administrative installer.",
    );
  }
  if (_normalizeWindowsDirectory(compiledInstallDir) !=
      _normalizeWindowsDirectory(installDir)) {
    throw StateError(
      "$_protectedHelperCMakeCacheKey in ${cache.path} does not match "
      "windows.installer.protectedHelperInstallDir.",
    );
  }
  return _GeneratedProtectedHelperInputs(
    helperSha256: await sha256File(files[_protectedHelperExecutableName]!),
    policySha256: await sha256File(files[_protectedHelperPolicyName]!),
  );
}

Future<File?> _findNearestCMakeCache(Directory input) async {
  var current = input.absolute;
  while (true) {
    final candidate = File(path.join(current.path, "CMakeCache.txt"));
    if (await candidate.exists()) {
      return candidate;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      return null;
    }
    current = parent;
  }
}

Future<String?> _readCMakeCachePath(File cache, String key) async {
  final prefix = "$key:";
  for (final line in await cache.readAsLines()) {
    if (!line.startsWith(prefix)) {
      continue;
    }
    final separator = line.indexOf("=");
    if (separator < prefix.length) {
      return "";
    }
    return line.substring(separator + 1).trim();
  }
  return null;
}

String _normalizeWindowsDirectory(String value) =>
    path.windows.normalize(value.trim()).toLowerCase();

class _GeneratedProtectedHelperInputs {
  const _GeneratedProtectedHelperInputs({
    required this.helperSha256,
    required this.policySha256,
  });

  final String helperSha256;
  final String policySha256;
}

const _installedIdentityMarkerName = ".desktop_updater_install_identity.json";

Future<void> _rejectReservedInstalledIdentityMarker(
  FileSystemEntity input,
) async {
  bool isReserved(String candidate) =>
      candidate.toLowerCase() == _installedIdentityMarkerName.toLowerCase();
  if (isReserved(path.basename(input.path))) {
    throw StateError(
      "Generated Inno input contains the reserved installed identity marker.",
    );
  }
  if (input is! Directory) {
    return;
  }
  await for (final entity in input.list(
    recursive: true,
    followLinks: false,
  )) {
    if (isReserved(path.basename(entity.path))) {
      throw StateError(
        "Generated Inno input contains the reserved installed identity marker.",
      );
    }
  }
}
