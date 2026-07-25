using System;
using System.Runtime.InteropServices;

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
                var message = Marshal.PtrToStringUTF8(result.errorMessage)
                    ?? "desktop_updater native call failed.";
                throw new DesktopUpdaterException(message);
            }
        }
        finally
        {
            desktop_updater_result_free(result);
        }
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
