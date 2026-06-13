/// App-owned persistence adapter for update preferences.
///
/// The package does not depend on a storage backend. Apps can bridge this
/// interface to shared preferences, a database, or any other store they own.
abstract interface class UpdatePreferences {
  /// Returns the skipped version for [channel], or `null` when none is stored.
  Future<String?> skippedVersion({required String channel});

  /// Persists [version] as skipped for [channel].
  Future<void> skipVersion({
    required String version,
    required String channel,
  });

  /// Clears any skipped version for [channel].
  Future<void> clearSkippedVersion({required String channel});
}
