using System.Reflection;
using System.Runtime.InteropServices;
using DesktopUpdater.Native;
using Xunit;

namespace DesktopUpdater.Native.Tests;

public sealed class DesktopUpdaterNativeTests
{
    private const string CanonicalTransactionId =
        "123e4567-e89b-42d3-a456-426614174000";

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
            requiresElevation: DesktopUpdaterElevationPolicy.Never,
            installRoot: @"C:\Program Files\Example",
            executableRelativePath: "Example.exe",
            expectedPackageId: "com.example.app");

        Assert.Equal(new string('a', 64), request.ExpectedProvenanceSha256);
        Assert.Equal(new string('b', 64), request.ExpectedArtifactSha256);
        Assert.Single(request.AllowedSignerThumbprints);
        Assert.Equal(
            DesktopUpdaterElevationPolicy.Never,
            request.RequiresElevation);
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
                requiresElevation: DesktopUpdaterElevationPolicy.Auto,
                installRoot: @"C:\Program Files\Example",
                executableRelativePath: "Example.exe",
                expectedPackageId: "com.example.app"));

        Assert.Contains("SHA-256", error.Message);
    }

    [Theory]
    [InlineData("123E4567-E89B-42D3-A456-426614174000")]
    [InlineData("123e4567-e89b-12d3-a456-426614174000")]
    [InlineData("123e4567-e89b-42d3-c456-426614174000")]
    public void ExactTransactionOperationsRejectNonCanonicalUuidV4(
        string transactionId)
    {
        var request = CreateInstallRequest();

        Assert.Throws<ArgumentException>(() =>
            DesktopUpdaterNative.PrepareInstall(request, transactionId));
        Assert.Throws<ArgumentException>(() =>
            DesktopUpdaterNative.QueryTransaction(transactionId));
        Assert.Throws<ArgumentException>(() =>
            DesktopUpdaterNative.ResolvePendingInstallAfterExit(transactionId));
    }

    [Theory]
    [InlineData("123E4567-E89B-42D3-A456-426614174000")]
    [InlineData("123e4567-e89b-12d3-a456-426614174000")]
    [InlineData("123e4567-e89b-42d3-c456-426614174000")]
    public void ReturnedStatusRejectsNonCanonicalUuidV4(string transactionId)
    {
        var error = Record.Exception(() => InvokeReadStatus(transactionId));
        var invocation = Assert.IsType<TargetInvocationException>(error);

        Assert.IsType<DesktopUpdaterException>(invocation.InnerException);
    }

    [Fact]
    public void DesktopUpdaterExceptionExposesTypedRecoveryContext()
    {
        var legacy = new DesktopUpdaterException("legacy failure");
        var recovery = new DesktopUpdaterException(
            "recovery required",
            DesktopUpdaterInstallTransactionResultCode.RecoveryRequired,
            CanonicalTransactionId);

        Assert.Null(legacy.ResultCode);
        Assert.Null(legacy.TransactionId);
        Assert.False(legacy.RecoveryRequired);
        Assert.Equal(
            DesktopUpdaterInstallTransactionResultCode.RecoveryRequired,
            recovery.ResultCode);
        Assert.Equal(CanonicalTransactionId, recovery.TransactionId);
        Assert.True(recovery.RecoveryRequired);
    }

    [Fact]
    public void CallerExitAcknowledgementExcludesManualActionStatus()
    {
        var prepared = CreateTransactionStatus(
            DesktopUpdaterInstallTransactionState.Prepared,
            DesktopUpdaterInstallTransactionResultCode.RecoveryRequired);
        var manualAction = CreateTransactionStatus(
            DesktopUpdaterInstallTransactionState.ManualActionRequired,
            DesktopUpdaterInstallTransactionResultCode.RecoveryRequired);

        Assert.True(prepared.AwaitsCallerExit);
        Assert.False(manualAction.AwaitsCallerExit);
    }

    [Fact]
    public void RelaunchFailureIsDistinctFromRecoveryRequired()
    {
        var relaunchFailure = CreateTransactionStatus(
            DesktopUpdaterInstallTransactionState.Completed,
            DesktopUpdaterInstallTransactionResultCode.RelaunchFailure);

        Assert.Equal(
            DesktopUpdaterInstallTransactionResultCode.RelaunchFailure,
            relaunchFailure.ResultCode);
        Assert.False(relaunchFailure.AwaitsCallerExit);
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

    private static DesktopUpdaterInstallRequest CreateInstallRequest()
    {
        return new DesktopUpdaterInstallRequest(
            stagingPath: @"C:\staging\Example",
            removedFiles: Array.Empty<string>(),
            diagnosticsLogPath: null,
            expectedProvenanceSha256: new string('a', 64),
            expectedArtifactSha256: new string('b', 64),
            allowedSignerThumbprints: Array.Empty<string>(),
            requiresElevation: DesktopUpdaterElevationPolicy.Auto,
            installRoot: @"C:\Program Files\Example",
            executableRelativePath: "Example.exe",
            expectedPackageId: "com.example.app");
    }

    private static DesktopUpdaterInstallTransactionStatus CreateTransactionStatus(
        DesktopUpdaterInstallTransactionState state,
        DesktopUpdaterInstallTransactionResultCode resultCode)
    {
        var status = Activator.CreateInstance(
            typeof(DesktopUpdaterInstallTransactionStatus),
            BindingFlags.Instance | BindingFlags.NonPublic,
            binder: null,
            args: new object[]
            {
                CanonicalTransactionId,
                state,
                resultCode,
                "status detail",
                "",
                "",
            },
            culture: null);
        return Assert.IsType<DesktopUpdaterInstallTransactionStatus>(status);
    }

    private static void InvokeReadStatus(string transactionId)
    {
        var nativeStatusType = typeof(DesktopUpdaterNative).GetNestedType(
            "NativeTransactionStatusV1",
            BindingFlags.NonPublic);
        var readStatus = typeof(DesktopUpdaterNative).GetMethod(
            "ReadStatus",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(nativeStatusType);
        Assert.NotNull(readStatus);

        var allocations = new[]
        {
            Marshal.StringToHGlobalAnsi(transactionId),
            Marshal.StringToHGlobalAnsi("status detail"),
            Marshal.StringToHGlobalAnsi(""),
            Marshal.StringToHGlobalAnsi(""),
        };
        try
        {
            var status = Activator.CreateInstance(nativeStatusType);
            Assert.NotNull(status);
            nativeStatusType.GetField("AbiVersion")!.SetValue(status, 1u);
            nativeStatusType.GetField("StructSize")!.SetValue(
                status,
                (nuint)Marshal.SizeOf(nativeStatusType));
            nativeStatusType.GetField("State")!.SetValue(
                status,
                (uint)DesktopUpdaterInstallTransactionState.Unknown);
            nativeStatusType.GetField("ResultCode")!.SetValue(
                status,
                (uint)DesktopUpdaterInstallTransactionResultCode.Rejected);
            nativeStatusType.GetField("TransactionIdUtf8")!.SetValue(
                status,
                allocations[0]);
            nativeStatusType.GetField("DetailUtf8")!.SetValue(
                status,
                allocations[1]);
            nativeStatusType.GetField("ResponseDigestSha256Utf8")!.SetValue(
                status,
                allocations[2]);
            nativeStatusType.GetField("HelperEndpointIdentitySha256Utf8")!
                .SetValue(status, allocations[3]);

            _ = readStatus.Invoke(null, new[] { status, (object)false });
        }
        finally
        {
            foreach (var allocation in allocations)
            {
                Marshal.FreeHGlobal(allocation);
            }
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
