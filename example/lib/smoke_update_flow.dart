import "dart:async";

const controllerSmokeEnvironment = "DESKTOP_UPDATER_CONTROLLER_SMOKE";
const smokeMarkerEnvironment = "DESKTOP_UPDATER_SMOKE_MARKER";
const smokeDiagnosticsEnvironment = "DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG";
const recoveryStoreEnvironment = "DESKTOP_UPDATER_RECOVERY_STORE_PATH";
const appArchiveEnvironment = "DESKTOP_UPDATER_APP_ARCHIVE_URL";
const expectedPackageIdEnvironment = "DESKTOP_UPDATER_EXPECTED_PACKAGE_ID";
const trustedPublicKeyIdEnvironment = "DESKTOP_UPDATER_TRUSTED_PUBLIC_KEY_ID";
const trustedPublicKeyEnvironment = "DESKTOP_UPDATER_TRUSTED_PUBLIC_KEY";

final class SmokeUpdateConfiguration {
  const SmokeUpdateConfiguration._({
    required this.enabled,
    required this.markerPath,
    required this.diagnosticsLogPath,
  });

  factory SmokeUpdateConfiguration.fromEnvironment(
    Map<String, String> environment,
  ) {
    final enabled = environment[controllerSmokeEnvironment] == "1";
    if (enabled) {
      for (final name in <String>[
        appArchiveEnvironment,
        expectedPackageIdEnvironment,
        trustedPublicKeyIdEnvironment,
        trustedPublicKeyEnvironment,
        recoveryStoreEnvironment,
        smokeMarkerEnvironment,
        smokeDiagnosticsEnvironment,
      ]) {
        if (_nonBlank(environment[name]) == null) {
          throw StateError("$name is required for controller smoke.");
        }
      }
    }
    return SmokeUpdateConfiguration._(
      enabled: enabled,
      markerPath: _nonBlank(environment[smokeMarkerEnvironment]),
      diagnosticsLogPath: _nonBlank(environment[smokeDiagnosticsEnvironment]),
    );
  }

  final bool enabled;
  final String? markerPath;
  final String? diagnosticsLogPath;
}

Map<String, String> configuredTrustedReleasePublicKeys(
  Map<String, String> environment, {
  required String fallbackKeyId,
  required String fallbackPublicKey,
}) {
  final publicKey = _nonBlank(environment[trustedPublicKeyEnvironment]);
  if (publicKey == null) {
    return <String, String>{fallbackKeyId: fallbackPublicKey};
  }
  final publicKeyId = _nonBlank(environment[trustedPublicKeyIdEnvironment]);
  if (publicKeyId == null) {
    throw StateError(
      "$trustedPublicKeyIdEnvironment is required when "
      "$trustedPublicKeyEnvironment is configured.",
    );
  }
  return <String, String>{publicKeyId: publicKey};
}

Future<void> runControllerOwnedSmokeUpdate({
  required SmokeUpdateConfiguration configuration,
  required Future<void> Function() checkForUpdate,
  required bool Function() updateIsAvailable,
  required Future<void> Function() downloadAndStage,
  required Future<void> Function() install,
  required Future<void> Function(String value) writeMarker,
  required Future<void> Function(String event) writeDiagnostics,
}) async {
  if (!configuration.enabled) {
    return;
  }

  try {
    await writeMarker("checking");
    await writeDiagnostics("checking");
    await checkForUpdate();
    if (!updateIsAvailable()) {
      throw StateError("Signed smoke fixture did not select an update.");
    }

    await writeMarker("downloading");
    await writeDiagnostics("downloading");
    await downloadAndStage();

    await writeMarker("installing");
    await writeDiagnostics("installing");
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await install();
  } on Object catch (error) {
    await writeMarker("failed: $error");
    await writeDiagnostics("failed: $error");
    rethrow;
  }
}

String? _nonBlank(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
