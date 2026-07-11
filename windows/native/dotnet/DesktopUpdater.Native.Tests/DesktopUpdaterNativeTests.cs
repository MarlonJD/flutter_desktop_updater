using System.Runtime.InteropServices;
using DesktopUpdater.Native;
using Xunit;

namespace DesktopUpdater.Native.Tests;

public sealed class DesktopUpdaterNativeTests
{
    [Fact]
    public void IncompleteStagedHandoffFailsBeforeNativeLoad()
    {
        var error = Assert.Throws<ArgumentException>(() =>
            DesktopUpdaterNative.ScheduleInstallAndRelaunch(
                @"C:\staging\Example",
                Array.Empty<string>(),
                null));

        Assert.Contains("verified provenance", error.Message);
    }

    [Fact]
    public void VerifiedInstallRequestCarriesCompleteNativeTrustContext()
    {
        var request = new DesktopUpdaterInstallRequest(
            stagingPath: @"C:\staging\Example",
            removedFiles: Array.Empty<string>(),
            diagnosticsLogPath: null,
            expectedProvenanceSha256: new string('a', 64),
            expectedArtifactSha256: new string('b', 64),
            allowedSignerThumbprints: new[] { new string('C', 64) },
            installRoot: @"C:\Program Files\Example",
            executableRelativePath: "Example.exe",
            expectedPackageId: "com.example.app");

        Assert.Equal(new string('a', 64), request.ExpectedProvenanceSha256);
        Assert.Equal(new string('b', 64), request.ExpectedArtifactSha256);
        Assert.Single(request.AllowedSignerThumbprints);
        Assert.Equal(@"C:\Program Files\Example", request.InstallRoot);
        Assert.Equal("Example.exe", request.ExecutableRelativePath);
        Assert.Equal("com.example.app", request.ExpectedPackageId);
    }

    [Fact]
    public void VerifiedInstallRequestRejectsMalformedDigests()
    {
        var error = Assert.Throws<ArgumentException>(() =>
            new DesktopUpdaterInstallRequest(
                stagingPath: @"C:\staging\Example",
                removedFiles: Array.Empty<string>(),
                diagnosticsLogPath: null,
                expectedProvenanceSha256: "not-a-sha256",
                expectedArtifactSha256: new string('b', 64),
                allowedSignerThumbprints: Array.Empty<string>(),
                installRoot: @"C:\Program Files\Example",
                executableRelativePath: "Example.exe",
                expectedPackageId: "com.example.app"));

        Assert.Contains("SHA-256", error.Message);
    }

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
