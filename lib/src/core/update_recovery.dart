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
    this.stagingPath,
    this.diagnosticsText,
    this.transactionId,
  });

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

  /// Platform-specific staged update path handed to the native helper.
  final String? stagingPath;

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
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker);

  /// Clears the pending install marker for [channel].
  Future<void> clearPendingInstall({required String channel});
}
