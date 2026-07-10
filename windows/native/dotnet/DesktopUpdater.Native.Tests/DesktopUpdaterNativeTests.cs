using System.Runtime.InteropServices;
using DesktopUpdater.Native;
using Xunit;

namespace DesktopUpdater.Native.Tests;

public sealed class DesktopUpdaterNativeTests
{
    [Fact]
    public void NativeInvalidRequestReturnsNativeError()
    {
        var request = new InvalidNativeRequest
        {
            AbiVersion = 999,
            StructSize = (nuint)Marshal.SizeOf<InvalidNativeRequest>(),
        };

        var result = NativeMethods.ScheduleInvalidRequest(ref request);
        try
        {
            Assert.Equal(0, result.Ok);
            Assert.NotEqual(IntPtr.Zero, result.ErrorMessageUtf8);
            Assert.Contains(
                "ABI version",
                Marshal.PtrToStringUTF8(result.ErrorMessageUtf8));
        }
        finally
        {
            NativeMethods.ResultFree(ref result);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct InvalidNativeRequest
    {
        public uint AbiVersion;
        public nuint StructSize;
        public IntPtr StagingPath;
        public IntPtr DiagnosticsLogPath;
        public IntPtr RemovedFiles;
        public nuint RemovedFileCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeResult
    {
        public uint AbiVersion;
        public int Ok;
        public IntPtr ErrorMessageUtf8;
    }

    private static class NativeMethods
    {
        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_schedule_install_and_relaunch_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResult ScheduleInvalidRequest(
            ref InvalidNativeRequest request);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_result_free_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ResultFree(ref NativeResult result);
    }
}
