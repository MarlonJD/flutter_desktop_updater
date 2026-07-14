using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using DesktopUpdater.Native;
using Xunit;

namespace DesktopUpdater.Native.Tests;

public sealed class DesktopUpdaterClientTests
{
    [Fact]
    public void ConfigurationAcceptsSafeDefaults()
    {
        var configuration = CreateConfiguration();

        Assert.Equal(
            DesktopUpdaterConfiguration.DefaultMaximumMetadataBytes,
            configuration.MaximumMetadataBytes);
        Assert.Equal(15, Enum.GetValues<DesktopUpdaterOutcome>().Length);
    }

    [Fact]
    public void ConfigurationRejectsNonPositiveLimits()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            CreateConfiguration(maximumMetadataBytes: 0));
    }

    [Fact]
    public void RuntimeClientExposesTypedThreeStageFlow()
    {
        Assert.NotNull(typeof(DesktopUpdaterClient).GetMethod("CheckForUpdate"));
        Assert.NotNull(
            typeof(DesktopUpdaterClient).GetMethod("DownloadVerifyAndStage"));
        Assert.NotNull(
            typeof(DesktopUpdaterClient).GetMethod("InstallAndRelaunch"));
        Assert.NotNull(
            typeof(DesktopUpdaterRuntimeResult).GetProperty("SupportPolicyStatus"));
        Assert.NotNull(typeof(DesktopUpdaterRuntimeResult).GetProperty("Mandatory"));
        Assert.NotNull(
            typeof(DesktopUpdaterRuntimeResult).GetProperty("SelectedBuildNumber"));
        Assert.NotNull(
            typeof(DesktopUpdaterRuntimeResult).GetProperty("SelectedPlatform"));
        Assert.NotNull(
            typeof(DesktopUpdaterRuntimeResult).GetProperty("SelectedChannel"));
        Assert.NotNull(
            typeof(DesktopUpdaterRuntimeResult).GetProperty("FreshInstallUrl"));
        Assert.NotNull(
            typeof(DesktopUpdaterRuntimeResult).GetProperty("FreshInstallMessage"));
    }

    [Fact]
    public void InstallClientExposesDisposableReservationAndRecoveryFlow()
    {
        foreach (var operation in new[]
        {
            "PrepareInstall",
            "CommitAfterExit",
            "CancelReservation",
            "QueryTransaction",
            "RecoverPendingInstall",
        })
        {
            Assert.NotNull(typeof(DesktopUpdaterClient).GetMethod(operation));
            Assert.NotNull(typeof(DesktopUpdaterNative).GetMethod(operation));
        }
        Assert.True(typeof(IDisposable).IsAssignableFrom(
            typeof(DesktopUpdaterInstallReservation)));
        Assert.True(typeof(SafeHandle).IsAssignableFrom(
            typeof(DesktopUpdaterInstallReservation)
                .Assembly
                .GetType(
                    "DesktopUpdater.Native.DesktopUpdaterReservationSafeHandle")));
        Assert.Equal(
            8,
            Enum.GetValues<DesktopUpdaterInstallTransactionState>().Length);
        Assert.Equal(
            8,
            Enum.GetValues<DesktopUpdaterInstallTransactionResultCode>().Length);
    }

    [Fact]
    public void NativeRuntimeUsesIsolatedOneShotLifecycleState()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "windows/native/src/runtime/desktop_updater_runtime_c.cpp"));
        var lifecycle = File.ReadAllText(FindRepositoryFile(
            "native_runtime/cpp/client_lifecycle.h"));

        Assert.Contains("std::mutex mutex_", lifecycle);
        Assert.Contains("selection_generation_", lifecycle);
        Assert.Contains("check_generation_", lifecycle);
        Assert.Contains("stage_attempt_", lifecycle);
        Assert.Contains("staged_generation_", lifecycle);
        Assert.Contains("install_in_progress_", lifecycle);
        var consume = source.IndexOf(
            "client->lifecycle.BeginInstall(snapshot)",
            StringComparison.Ordinal);
        var rollbackGuard = source.IndexOf(
            "SchedulingRollbackGuard rollback",
            consume,
            StringComparison.Ordinal);
        var schedule = source.IndexOf(
            "HandoffWindowsInstall(", consume, StringComparison.Ordinal);
        Assert.True(consume >= 0);
        Assert.True(rollbackGuard > consume);
        Assert.True(schedule > rollbackGuard);
        Assert.Contains("rollback.Confirm()", source);
    }

    [Fact]
    public void StageAdapterInvalidatesBeforeValidatingRequest()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "windows/native/src/runtime/desktop_updater_runtime_c.cpp"));
        var entry = source.IndexOf(
            "desktop_updater_runtime_client_download_verify_and_stage_v1(",
            StringComparison.Ordinal);
        var beginStage = source.IndexOf(
            "client->lifecycle.BeginStage()",
            entry,
            StringComparison.Ordinal);
        var validateRequest = source.IndexOf(
            "ValidateRequest(request, \"Runtime stage request\")",
            entry,
            StringComparison.Ordinal);

        Assert.True(entry >= 0);
        Assert.True(beginStage > entry);
        Assert.True(validateRequest > beginStage);
    }

    [Fact]
    public void InvalidatedCheckReturnsInvalidDescriptor()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "windows/native/src/runtime/desktop_updater_runtime_c.cpp"));
        var publishCheck = source.IndexOf(
            "if (!client->lifecycle.PublishCheck(lease, check))",
            StringComparison.Ordinal);
        var invalidDescriptor = source.IndexOf(
            "ClientResult(*client, \"invalidDescriptor\"",
            publishCheck,
            StringComparison.Ordinal);
        var stageEntry = source.IndexOf(
            "desktop_updater_runtime_client_download_verify_and_stage_v1(",
            StringComparison.Ordinal);

        Assert.True(publishCheck >= 0);
        Assert.True(invalidDescriptor > publishCheck);
        Assert.True(invalidDescriptor < stageEntry);
    }

    [Fact]
    public void FinalizerReleasesNativeClientWhenDisposeIsOmitted()
    {
        var release = new ReleaseProbe();
        var weakClient = CreateAbandonedClient(CreateConfiguration(), release);

        ForceFinalizersUntilReleased(release);

        Assert.False(weakClient.IsAlive);
        Assert.Equal(1, release.Count);
        Assert.Equal(new IntPtr(0x42), release.Handle);
        Assert.True(release.CallbackStateWasAliveDuringRelease);
    }

    [Fact]
    public void CaptureCycleDoesNotPreventFinalization()
    {
        var release = new ReleaseProbe();
        var cycle = CreateCapturedClientCycle(release);

        ForceFinalizersUntilReleased(release);

        Assert.False(cycle.Client.IsAlive);
        Assert.False(cycle.Owner.IsAlive);
        Assert.Equal(1, release.Count);
        Assert.Equal(new IntPtr(0x42), release.Handle);
        Assert.True(release.CallbackStateWasAliveDuringRelease);
    }

    private static void ForceFinalizersUntilReleased(ReleaseProbe release)
    {
        for (var attempt = 0; attempt < 10 && release.Count == 0; attempt++)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static WeakReference CreateAbandonedClient(
        DesktopUpdaterConfiguration configuration,
        ReleaseProbe release)
    {
        var factory = typeof(DesktopUpdaterClient).GetMethod(
            "CreateForTesting",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(factory);
        var client = Assert.IsType<DesktopUpdaterClient>(factory.Invoke(
            null,
            new object[]
            {
                configuration,
                new IntPtr(0x42),
                new Action<IntPtr, IntPtr>(release.Record),
            }));
        return new WeakReference(client);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static (WeakReference Client, WeakReference Owner)
        CreateCapturedClientCycle(ReleaseProbe release)
    {
        var owner = new CapturedClientOwner();
        var configuration = CreateConfiguration(
            minimumOSResolver: owner.ResolveMinimumOS,
            requestHeadersProvider: owner.ProvideHeaders);
        var weakClient = CreateAbandonedClient(configuration, release);
        owner.Client = Assert.IsType<DesktopUpdaterClient>(weakClient.Target);
        return (weakClient, new WeakReference(owner));
    }

    private static DesktopUpdaterConfiguration CreateConfiguration(
        long maximumMetadataBytes =
            DesktopUpdaterConfiguration.DefaultMaximumMetadataBytes,
        MinimumOSResolver? minimumOSResolver = null,
        RequestHeadersProvider? requestHeadersProvider = null)
    {
        return new DesktopUpdaterConfiguration(
            new Uri("https://updates.example.test/app-archive.json"),
            "com.example.native-contract",
            "2.7.0",
            270,
            "2.7.0",
            "windows",
            "stable",
            "dotnet-unit-test",
            true,
            new Dictionary<string, byte[]>
            {
                ["native-contract-stable"] = new byte[32],
            },
            minimumOSResolver ?? ((_, _) => true),
            requestHeadersProvider ?? (_ => new Dictionary<string, string>()),
            maximumMetadataBytes: maximumMetadataBytes);
    }

    private sealed class CapturedClientOwner
    {
        public DesktopUpdaterClient? Client { get; set; }

        public bool ResolveMinimumOS(string platform, string minimumOS)
        {
            GC.KeepAlive(Client);
            return true;
        }

        public IReadOnlyDictionary<string, string> ProvideHeaders(Uri url)
        {
            GC.KeepAlive(Client);
            return new Dictionary<string, string>();
        }
    }

    private sealed class ReleaseProbe
    {
        private int _count;

        public int Count => Volatile.Read(ref _count);
        public IntPtr Handle { get; private set; }
        public bool CallbackStateWasAliveDuringRelease { get; private set; }

        public void Record(IntPtr handle, IntPtr applicationContext)
        {
            Handle = handle;
            CallbackStateWasAliveDuringRelease =
                applicationContext != IntPtr.Zero &&
                GCHandle.FromIntPtr(applicationContext).Target is not null;
            Interlocked.Increment(ref _count);
        }
    }

    private static string FindRepositoryFile(string relativePath)
    {
        foreach (var start in new[]
        {
            Directory.GetCurrentDirectory(),
            AppContext.BaseDirectory,
        })
        {
            var directory = new DirectoryInfo(start);
            while (directory is not null)
            {
                var candidate = Path.Combine(
                    directory.FullName,
                    relativePath.Replace('/', Path.DirectorySeparatorChar));
                if (File.Exists(candidate))
                {
                    return candidate;
                }
                directory = directory.Parent;
            }
        }
        throw new FileNotFoundException(relativePath);
    }
}
