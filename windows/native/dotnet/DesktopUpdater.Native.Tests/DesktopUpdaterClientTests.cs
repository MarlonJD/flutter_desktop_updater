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
            "client->lifecycle.BeginInstall()",
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

    private static DesktopUpdaterConfiguration CreateConfiguration(
        long maximumMetadataBytes =
            DesktopUpdaterConfiguration.DefaultMaximumMetadataBytes)
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
            (_, _) => true,
            _ => new Dictionary<string, string>(),
            maximumMetadataBytes: maximumMetadataBytes);
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
