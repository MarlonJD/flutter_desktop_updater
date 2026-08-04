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
    public void ConfigurationRequiresPinnedKeys()
    {
        Assert.Throws<ArgumentException>(() => new DesktopUpdaterConfiguration(
            new Uri("https://updates.example.test/app-archive.json"),
            "com.example.native-contract",
            "3.0.0",
            300,
            "3.0.0",
            "windows",
            "stable",
            null,
            new Dictionary<string, byte[]>(),
            (_, _) => true,
            _ => new Dictionary<string, string>()));
    }

    [Fact]
    public void RuntimeClientExposesExplicitLifecycleAndNoRemovedMethods()
    {
        foreach (var operation in new[]
        {
            "PrepareInstall",
            "CommitAfterExit",
            "CancelReservation",
            "QueryTransaction",
            "ResolvePendingInstallAfterExit",
        })
        {
            Assert.Contains(
                typeof(DesktopUpdaterClient).GetMethods(),
                method => method.Name == operation);
        }
        Assert.Null(typeof(DesktopUpdaterClient).GetMethod("InstallAndRelaunch"));
        Assert.Null(typeof(DesktopUpdaterClient).GetMethod("RecoverPendingInstall"));
        Assert.NotNull(typeof(DesktopUpdaterRuntimeResult).GetProperty(
            "SupportPolicyStatus"));
        Assert.True(typeof(IDisposable).IsAssignableFrom(
            typeof(DesktopUpdaterInstallReservation)));
    }

    [Fact]
    public void RuntimeEntryPointsUseAbi2ExplicitNames()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "windows/native/src/runtime/desktop_updater_runtime_c.cpp"));
        var header = File.ReadAllText(FindRepositoryFile(
            "windows/native/include/desktop_updater_runtime_c.h"));

        Assert.Contains("desktop_updater_runtime_client_prepare_install_abi2",
            source);
        Assert.Contains("desktop_updater_runtime_client_commit_after_exit_abi2",
            source);
        Assert.Contains("desktop_updater_runtime_client_cancel_reservation_abi2",
            source);
        Assert.DoesNotContain("install_and_relaunch", source);
        Assert.DoesNotContain("require_index_signature", header);
        Assert.DoesNotContain("require_descriptor_signature", header);
        Assert.DoesNotContain("diagnostics_log_path", header);
    }

    [Fact]
    public void NativeRuntimeUsesExplicitPrepareBeforeCommit()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "windows/native/src/runtime/desktop_updater_runtime_c.cpp"));
        var prepare = source.IndexOf(
            "desktop_updater_runtime_client_prepare_install_abi2",
            StringComparison.Ordinal);
        var handoff = source.IndexOf(
            "HandoffWindowsInstall(",
            prepare,
            StringComparison.Ordinal);
        var confirm = source.IndexOf(
            "rollback.Confirm()",
            handoff,
            StringComparison.Ordinal);
        var commit = source.IndexOf(
            "desktop_updater_runtime_client_commit_after_exit_abi2",
            confirm,
            StringComparison.Ordinal);

        Assert.True(prepare >= 0);
        Assert.True(handoff > prepare);
        Assert.True(confirm > handoff);
        Assert.True(commit > confirm);
        Assert.Contains("CompleteInstall", source);
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
        var client = Assert.IsType<DesktopUpdaterClient>(factory!.Invoke(
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
            "3.0.0",
            300,
            "3.0.0",
            "windows",
            "stable",
            "dotnet-unit-test",
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
            CallbackStateWasAliveDuringRelease = applicationContext != IntPtr.Zero &&
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
                if (File.Exists(candidate)) return candidate;
                directory = directory.Parent;
            }
        }
        throw new FileNotFoundException(relativePath);
    }
}
