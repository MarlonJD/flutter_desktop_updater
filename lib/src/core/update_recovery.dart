/// Marker persisted by an app-owned store before native install handoff.
class UpdateInstallRecoveryMarker {
  /// Creates a pending install recovery marker.
  const UpdateInstallRecoveryMarker({
    required this.createdAt,
    required this.packageVersion,
    required this.platform,
    required this.channel,
    this.appVersion,
    this.updateVersion,
    this.updateBuildNumber,
    this.expectedPackageId,
    this.stagingPath,
    this.stageProvenanceSha256,
    this.diagnosticsText,
    this.transactionId,
  });

  /// Creates a v3 pending marker with durable install authority bindings.
  factory UpdateInstallRecoveryMarker.pendingV3({
    required DateTime createdAt,
    required String packageVersion,
    required String platform,
    required String channel,
    required String? appVersion,
    required String updateVersion,
    required int? updateBuildNumber,
    required String expectedPackageId,
    required String stagingPath,
    required String stageProvenanceSha256,
    required String? diagnosticsText,
    required String transactionId,
  }) {
    final normalizedTransaction = _requireLowercaseUuid(
      transactionId,
      "transactionId",
    );
    final normalizedPackageId = _requireNonEmpty(
      expectedPackageId,
      "expectedPackageId",
    );
    final normalizedUpdateVersion = _requireNonEmpty(
      updateVersion,
      "updateVersion",
    );
    final normalizedChannel = _requireNonEmpty(channel, "channel");
    final normalizedStagingPath = _requireNonEmpty(
      stagingPath,
      "stagingPath",
    );
    final normalizedProvenance = _requireLowercaseSha256(
      stageProvenanceSha256,
      "stageProvenanceSha256",
    );
    return UpdateInstallRecoveryMarker(
      createdAt: createdAt.toUtc(),
      packageVersion: _requireNonEmpty(packageVersion, "packageVersion"),
      platform: _requireNonEmpty(platform, "platform"),
      channel: normalizedChannel,
      appVersion: appVersion,
      updateVersion: normalizedUpdateVersion,
      updateBuildNumber: updateBuildNumber,
      expectedPackageId: normalizedPackageId,
      stagingPath: normalizedStagingPath,
      stageProvenanceSha256: normalizedProvenance,
      diagnosticsText: diagnosticsText,
      transactionId: normalizedTransaction,
    );
  }

  /// Time the marker was created.
  final DateTime createdAt;

  /// Version of the `desktop_updater` package that created the marker.
  final String packageVersion;

  /// Runtime platform associated with the pending install.
  final String platform;

  /// Update channel associated with the pending install.
  final String channel;

  /// App version that was running when install was handed off, when known.
  final String? appVersion;

  /// Target update version expected after relaunch, when known.
  final String? updateVersion;

  /// Target update build number expected after relaunch, when known.
  final int? updateBuildNumber;

  /// App-owned package identity expected for the installed target.
  ///
  /// This is nullable only so 2.x markers can still decode.
  final String? expectedPackageId;

  /// Platform-specific staged update path handed to the native helper.
  final String? stagingPath;

  /// Lowercase SHA-256 digest of the retained staged provenance marker.
  ///
  /// This is nullable only so 2.x markers can still decode.
  final String? stageProvenanceSha256;

  /// Redacted diagnostics text captured before native install handoff.
  final String? diagnosticsText;

  /// Native helper transaction identifier, when the handoff exposed one.
  ///
  /// This is UX/recovery lookup evidence only. It does not authorize install,
  /// rollback, cleanup, or any other mutation.
  final String? transactionId;
}

/// State reported by the authenticated native install helper.
enum NativeInstallTransactionState {
  /// The helper has no recognized transaction state.
  unknown,

  /// A transaction is durably prepared but not committed.
  prepared,

  /// The helper accepted commit-after-exit.
  commitAccepted,

  /// Installation and relaunch work completed.
  completed,

  /// The reservation was cancelled before mutation.
  cancelled,

  /// The reservation expired before mutation.
  expired,

  /// The helper restored the verified backup.
  rolledBack,

  /// Automated recovery stopped and requires user action.
  manualActionRequired,
}

/// Result code reported by the authenticated native install helper.
enum NativeInstallTransactionResultCode {
  /// No result is available.
  none,

  /// Commit was accepted.
  accepted,

  /// The transaction succeeded.
  succeeded,

  /// The helper rejected the request.
  rejected,

  /// The packaged authenticated helper endpoint is unavailable.
  endpointUnavailable,

  /// Helper endpoint authentication failed.
  authenticationFailed,

  /// The helper response failed protocol validation.
  invalidResponse,

  /// The helper must perform crash recovery.
  recoveryRequired,

  /// Installation finished, but the best-effort app relaunch was not
  /// durably confirmed and will not be retried automatically.
  relaunchFailure,
}

/// Read-only native helper status used by optional recovery UX.
class NativeInstallTransactionStatus {
  /// Creates a native helper transaction status.
  const NativeInstallTransactionStatus({
    required this.transactionId,
    required this.state,
    required this.resultCode,
    required this.detail,
    required this.responseDigestSha256,
    required this.helperEndpointIdentitySha256,
  });

  /// Parses the stable MethodChannel response shape.
  factory NativeInstallTransactionStatus.fromJson(Map<String, Object?> json) {
    return NativeInstallTransactionStatus(
      transactionId: _requiredString(json, "transactionId"),
      state: _parseState(json["state"]),
      resultCode: _parseResultCode(json["resultCode"]),
      detail: json["detail"] is String ? json["detail"]! as String : "",
      responseDigestSha256: json["responseDigestSha256"] is String
          ? json["responseDigestSha256"]! as String
          : "",
      helperEndpointIdentitySha256:
          json["helperEndpointIdentitySha256"] is String
              ? json["helperEndpointIdentitySha256"]! as String
              : "",
    );
  }

  /// Native helper transaction identifier.
  final String transactionId;

  /// Current helper-owned state.
  final NativeInstallTransactionState state;

  /// Current helper-owned result code.
  final NativeInstallTransactionResultCode resultCode;

  /// Redacted stable diagnostic detail.
  final String detail;

  /// Digest binding the status to its authenticated helper response.
  final String responseDigestSha256;

  /// Identity digest for the authenticated packaged helper endpoint.
  final String helperEndpointIdentitySha256;

  /// Whether the helper reports a terminal successful transaction.
  bool get isTerminalSuccess =>
      state == NativeInstallTransactionState.completed &&
      resultCode == NativeInstallTransactionResultCode.succeeded;

  /// Whether the helper verified that this install ended without activation.
  bool get isTerminalFailure =>
      resultCode == NativeInstallTransactionResultCode.succeeded &&
      (state == NativeInstallTransactionState.rolledBack ||
          state == NativeInstallTransactionState.cancelled ||
          state == NativeInstallTransactionState.expired);

  /// Whether the atomic Windows resolver retained this caller and requires
  /// it to exit before recovery can continue.
  bool get awaitsCallerExit =>
      state == NativeInstallTransactionState.prepared &&
      resultCode == NativeInstallTransactionResultCode.recoveryRequired;

  /// Whether startup should ask the native helper to recover the transaction.
  bool get requiresRecovery =>
      resultCode == NativeInstallTransactionResultCode.recoveryRequired ||
      state == NativeInstallTransactionState.prepared ||
      state == NativeInstallTransactionState.commitAccepted;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException("Native helper status is missing $key.");
  }
  return value;
}

NativeInstallTransactionState _parseState(Object? value) {
  if (value is int &&
      value >= 0 &&
      value < NativeInstallTransactionState.values.length) {
    return NativeInstallTransactionState.values[value];
  }
  return switch (value) {
    "unknown" => NativeInstallTransactionState.unknown,
    "prepared" => NativeInstallTransactionState.prepared,
    "commitAccepted" => NativeInstallTransactionState.commitAccepted,
    "completed" => NativeInstallTransactionState.completed,
    "cancelled" => NativeInstallTransactionState.cancelled,
    "expired" => NativeInstallTransactionState.expired,
    "rolledBack" => NativeInstallTransactionState.rolledBack,
    "manualActionRequired" =>
      NativeInstallTransactionState.manualActionRequired,
    _ => throw const FormatException(
        "Native helper status has an invalid state.",
      ),
  };
}

NativeInstallTransactionResultCode _parseResultCode(Object? value) {
  if (value is int &&
      value >= 0 &&
      value < NativeInstallTransactionResultCode.values.length) {
    return NativeInstallTransactionResultCode.values[value];
  }
  return switch (value) {
    "none" => NativeInstallTransactionResultCode.none,
    "accepted" => NativeInstallTransactionResultCode.accepted,
    "succeeded" => NativeInstallTransactionResultCode.succeeded,
    "rejected" => NativeInstallTransactionResultCode.rejected,
    "endpointUnavailable" =>
      NativeInstallTransactionResultCode.endpointUnavailable,
    "authenticationFailed" =>
      NativeInstallTransactionResultCode.authenticationFailed,
    "invalidResponse" => NativeInstallTransactionResultCode.invalidResponse,
    "recoveryRequired" => NativeInstallTransactionResultCode.recoveryRequired,
    "relaunchFailure" => NativeInstallTransactionResultCode.relaunchFailure,
    _ => throw const FormatException(
        "Native helper status has an invalid result code.",
      ),
  };
}

/// App-owned persistence adapter for pending native install recovery markers.
abstract interface class UpdateRecoveryStore {
  /// Reads a pending install marker for [channel], when one exists.
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  });

  /// Writes a pending install [marker].
  ///
  /// Implementations must complete this future only after durable replacement
  /// has finished and a subsequent [readPendingInstall] for the same channel
  /// can return the exact marker bytes. Filesystem-backed stores should use
  /// atomic replacement and the strongest flush/fsync semantics available to
  /// the host platform.
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker);

  /// Clears the pending install marker for [channel].
  Future<void> clearPendingInstall({required String channel});
}

String _requireNonEmpty(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, "must not be blank");
  }
  return normalized;
}

String _requireLowercaseSha256(String value, String name) {
  final normalized = value.trim();
  if (!RegExp(r"^[0-9a-f]{64}$").hasMatch(normalized)) {
    throw ArgumentError.value(value, name, "must be lowercase 64-hex SHA-256");
  }
  return normalized;
}

String _requireLowercaseUuid(String value, String name) {
  final normalized = value.trim();
  if (!RegExp(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
  ).hasMatch(normalized)) {
    throw ArgumentError.value(value, name, "must be a lowercase UUID");
  }
  return normalized;
}
