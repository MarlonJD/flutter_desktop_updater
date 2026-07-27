using System;
using System.Runtime.InteropServices;
using System.Text;

namespace DesktopUpdater.Native;

public sealed class DesktopUpdaterException : Exception
{
    public DesktopUpdaterException(string message) : base(message) {}
}

public static class DesktopUpdaterNative
{
    public static void ScheduleInstallAndRelaunch(
        string? stagingPath,
        string? diagnosticsLogPath)
    {
        var request = new NativeInstallRequest
        {
            stagingPath = stagingPath,
            diagnosticsLogPath = diagnosticsLogPath,
            removedFiles = IntPtr.Zero,
            removedFileCount = UIntPtr.Zero,
        };
        var result = desktop_updater_schedule_install_and_relaunch(ref request);
        try
        {
            if (result.ok == 0)
            {
                var message = DecodeUtf8(result.errorMessage)
                    ?? "desktop_updater native call failed.";
                throw new DesktopUpdaterException(message);
            }
        }
        finally
        {
            desktop_updater_result_free(result);
        }
    }

    private static string? DecodeUtf8(IntPtr value)
    {
        if (value == IntPtr.Zero)
        {
            return null;
        }

        var length = 0;
        while (Marshal.ReadByte(value, length) != 0)
        {
            length += 1;
        }

        var bytes = new byte[length];
        Marshal.Copy(value, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeInstallRequest
    {
        public string? stagingPath;
        public string? diagnosticsLogPath;
        public IntPtr removedFiles;
        public UIntPtr removedFileCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeResult
    {
        public int ok;
        public IntPtr errorMessage;
    }

    [DllImport("desktop_updater_native", CharSet = CharSet.Unicode)]
    private static extern NativeResult desktop_updater_schedule_install_and_relaunch(
        ref NativeInstallRequest request);

    [DllImport("desktop_updater_native")]
    private static extern void desktop_updater_result_free(NativeResult result);
}
