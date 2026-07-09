import "dart:io";

import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:path/path.dart" as path;

/// Returns the default generated Inno installer output base name.
String defaultInnoOutputBaseName({
  required String appName,
  required String version,
  required String platform,
}) {
  return "${_artifactNameStem(appName)}-$version-$platform-setup";
}

/// Resolves the effective Inno installer output base name for publishing.
Future<String> resolveInnoOutputBaseName({
  required InnoPublishConfig config,
  required String appName,
  required String version,
  required String platform,
}) async {
  final configuredName = _validatedOutputBaseName(
    config.outputBaseName,
    fieldName: "windows.installer.outputBaseName",
    allowNull: true,
  );

  if (config.mode != "script") {
    return configuredName ??
        defaultInnoOutputBaseName(
          appName: appName,
          version: version,
          platform: platform,
        );
  }

  final scriptOutputName = await _readScriptOutputBaseName(config.script!);
  final literalScriptName = scriptOutputName?.literalName;
  if (literalScriptName != null) {
    final validatedScriptName = _validatedOutputBaseName(
      literalScriptName,
      fieldName: "OutputBaseFilename",
    )!;
    if (configuredName != null && configuredName != validatedScriptName) {
      throw const FormatException(
        "windows.installer.outputBaseName does not match OutputBaseFilename "
        "in the Inno script.",
      );
    }
    return configuredName ?? validatedScriptName;
  }

  if (configuredName != null) {
    return configuredName;
  }

  throw const FormatException(
    "windows.installer.outputBaseName is required when the Inno script "
    "OutputBaseFilename cannot be resolved.",
  );
}

Future<_ScriptOutputBaseName?> _readScriptOutputBaseName(
  String scriptPath,
) async {
  final lines = await File(scriptPath).readAsLines();
  var inSetupSection = false;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith(";")) {
      continue;
    }
    final section = RegExp(r"^\[(.+)\]$").firstMatch(trimmed);
    if (section != null) {
      inSetupSection = section.group(1)!.toLowerCase() == "setup";
      continue;
    }
    if (!inSetupSection) {
      continue;
    }
    final directive = RegExp(
      r"^OutputBaseFilename\s*=\s*(.*)$",
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (directive == null) {
      continue;
    }
    final value = _unquote(directive.group(1)!.trim());
    if (_isDynamicInnoValue(value)) {
      return const _ScriptOutputBaseName.dynamic();
    }
    return _ScriptOutputBaseName.literal(value);
  }
  return null;
}

String? _validatedOutputBaseName(
  String? value, {
  required String fieldName,
  bool allowNull = false,
}) {
  if (value == null) {
    if (allowNull) {
      return null;
    }
    throw FormatException("$fieldName must not be empty.");
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw FormatException("$fieldName must not be empty.");
  }
  final parts = path.posix.split(trimmed.replaceAll(r"\", "/"));
  if (parts.length != 1 || parts.contains("..")) {
    throw FormatException("$fieldName must be a file name, not a path.");
  }
  return trimmed;
}

bool _isDynamicInnoValue(String value) {
  return value.contains("{") || value.contains("}");
}

String _unquote(String value) {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

String _artifactNameStem(String appName) {
  var stem = path.basename(appName);
  if (stem.endsWith(".exe")) {
    stem = stem.substring(0, stem.length - ".exe".length);
  }
  return stem;
}

class _ScriptOutputBaseName {
  const _ScriptOutputBaseName.literal(this.literalName);

  const _ScriptOutputBaseName.dynamic() : literalName = null;

  final String? literalName;
}
