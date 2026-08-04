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
    public void VerifiedInstallRequestContainsNoCallerPolicyControls()
    {
        var request = CreateInstallRequest();

        Assert.Equal(new string('a', 64), request.ExpectedProvenanceSha256);
        Assert.Equal(new string('b', 64), request.ExpectedArtifactSha256);
        Assert.Equal(@"C:\Program Files\Example", request.InstallRoot);
        Assert.Equal("Example.exe", request.ExecutableRelativePath);
        Assert.Equal("com.example.app", request.ExpectedPackageId);
        Assert.Null(typeof(DesktopUpdaterInstallRequest).GetProperty(
            "DiagnosticsLogPath"));
        Assert.Null(typeof(DesktopUpdaterInstallRequest).GetProperty(
            "AllowedSignerThumbprints"));
        Assert.Null(typeof(DesktopUpdaterInstallRequest).GetProperty(
            "RequiresElevation"));
    }

    [Fact]
    public void VerifiedInstallRequestRejectsMalformedDigests()
    {
        var error = Assert.Throws<ArgumentException>(() =>
            new DesktopUpdaterInstallRequest(
                @"C:\staging\Example",
                Array.Empty<string>(),
                "not-a-sha256",
                new string('b', 64),
                @"C:\Program Files\Example",
                "Example.exe",
                "com.example.app"));

        Assert.Contains("SHA-256", error.Message);
    }

    [Theory]
    [InlineData("123E4567-E89B-42D3-A456-426614174000")]
    [InlineData("123e4567-e89b-12d3-a456-426614174000")]
    [InlineData("123e4567-e89b-42d3-c456-426614174000")]
    public void ExplicitTransactionOperationsRejectNonCanonicalUuidV4(
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

    [Fact]
    public void PublicHelperSurfaceHasNoImplicitOrDirectRecoveryOperations()
    {
        Assert.Null(typeof(DesktopUpdaterNative).GetMethod(
            "ScheduleInstallAndRelaunch"));
        Assert.Null(typeof(DesktopUpdaterNative).GetMethod(
            "RecoverPendingInstall"));
        Assert.NotNull(typeof(DesktopUpdaterNative).GetMethod(
            "PrepareInstall"));
        Assert.NotNull(typeof(DesktopUpdaterNative).GetMethod(
            "ResolvePendingInstallAfterExit"));
    }

    [Fact]
    public void NativeMethodsUseOnlyAbi2EntryPoints()
    {
        var nativeMethods = typeof(DesktopUpdaterNative).GetNestedType(
            "NativeMethods",
            BindingFlags.NonPublic);
        Assert.NotNull(nativeMethods);

        var prepare = nativeMethods!.GetMethod(
            "PrepareInstall",
            BindingFlags.NonPublic | BindingFlags.Static);
        var resolve = nativeMethods.GetMethod(
            "ResolvePendingInstallAfterExit",
            BindingFlags.NonPublic | BindingFlags.Static);

        Assert.Equal(
            "desktop_updater_prepare_install_abi2",
            prepare?.GetCustomAttribute<DllImportAttribute>()?.EntryPoint);
        Assert.Equal(
            "desktop_updater_resolve_pending_install_after_exit_abi2",
            resolve?.GetCustomAttribute<DllImportAttribute>()?.EntryPoint);
        Assert.Null(nativeMethods.GetMethod(
            "PrepareInstallV2",
            BindingFlags.NonPublic | BindingFlags.Static));
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
        Assert.False(legacy.RecoveryRequired);
        Assert.Equal(
            DesktopUpdaterInstallTransactionResultCode.RecoveryRequired,
            recovery.ResultCode);
        Assert.Equal(CanonicalTransactionId, recovery.TransactionId);
        Assert.True(recovery.RecoveryRequired);
    }

    private static DesktopUpdaterInstallRequest CreateInstallRequest() =>
        new(
            @"C:\staging\Example",
            Array.Empty<string>(),
            new string('a', 64),
            new string('b', 64),
            @"C:\Program Files\Example",
            "Example.exe",
            "com.example.app");
}
