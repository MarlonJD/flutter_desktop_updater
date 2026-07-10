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
}
