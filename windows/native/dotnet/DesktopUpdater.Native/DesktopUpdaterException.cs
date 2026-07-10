namespace DesktopUpdater.Native;

/// <summary>Reports a failure returned by the native updater helper.</summary>
public sealed class DesktopUpdaterException : Exception
{
    /// <summary>Creates an updater exception with the native error message.</summary>
    public DesktopUpdaterException(string message)
        : base(message)
    {
    }
}
