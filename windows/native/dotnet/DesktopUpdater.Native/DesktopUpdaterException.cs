namespace DesktopUpdater.Native;

/// <summary>Reports a failure returned by the native updater helper.</summary>
public sealed class DesktopUpdaterException : Exception
{
    /// <summary>Creates an updater exception with the native error message.</summary>
    public DesktopUpdaterException(string message)
        : this(message, null, null)
    {
    }

    /// <summary>
    /// Creates an updater exception with typed helper transaction context.
    /// </summary>
    public DesktopUpdaterException(
        string message,
        DesktopUpdaterInstallTransactionResultCode? resultCode,
        string? transactionId)
        : base(message)
    {
        ResultCode = resultCode;
        TransactionId = transactionId;
    }

    /// <summary>The helper result category, when one was returned.</summary>
    public DesktopUpdaterInstallTransactionResultCode? ResultCode { get; }

    /// <summary>The exact helper transaction ID, when known.</summary>
    public string? TransactionId { get; }

    /// <summary>Whether authoritative recovery is required.</summary>
    public bool RecoveryRequired =>
        ResultCode ==
        DesktopUpdaterInstallTransactionResultCode.RecoveryRequired;
}
