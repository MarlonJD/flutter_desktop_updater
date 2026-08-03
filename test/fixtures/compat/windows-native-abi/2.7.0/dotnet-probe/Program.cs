using System;
using System.Runtime.InteropServices;

internal static class Program
{
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeResultV1 { public uint AbiVersion; public int Ok; public IntPtr Error; }

    [DllImport("desktop_updater_native", EntryPoint = "desktop_updater_prepare_install_v2", ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    private static extern NativeResultV1 PrepareInstallV2(
        IntPtr request, IntPtr transactionId, out IntPtr reservation,
        IntPtr status, out uint outcome);

    private static void Main() {}
}
