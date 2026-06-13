/// Retry and backoff configuration for transient update downloads.
class UpdateRetryPolicy {
  /// Creates a retry policy.
  const UpdateRetryPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 5),
    this.retryStatusCodes = defaultRetryStatusCodes,
  }) : assert(maxAttempts >= 1, "maxAttempts must be at least 1");

  /// Default HTTP status codes treated as transient.
  static const Set<int> defaultRetryStatusCodes = {
    408,
    429,
    500,
    502,
    503,
    504,
  };

  /// Maximum number of total attempts, including the first attempt.
  final int maxAttempts;

  /// Delay used after the first retryable failure.
  final Duration initialDelay;

  /// Maximum delay between retry attempts.
  final Duration maxDelay;

  /// HTTP statuses that should be retried by HTTP transport.
  final Set<int> retryStatusCodes;

  /// Returns whether [statusCode] should be retried.
  bool shouldRetryStatusCode(int statusCode) {
    return retryStatusCodes.contains(statusCode);
  }

  /// Returns the delay after a 1-based failed [attempt].
  Duration delayForAttempt(int attempt) {
    if (attempt <= 1) {
      return _cap(initialDelay);
    }

    var delay = initialDelay;
    for (var index = 1; index < attempt; index += 1) {
      delay *= 2;
      if (delay >= maxDelay) {
        return maxDelay;
      }
    }
    return _cap(delay);
  }

  Duration _cap(Duration delay) {
    return delay > maxDelay ? maxDelay : delay;
  }
}
