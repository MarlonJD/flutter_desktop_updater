using DesktopUpdater.Native;

var missingStagingPath = Path.Combine(
    Path.GetTempPath(),
    $"desktop-updater-consumer-missing-{Guid.NewGuid():N}");

try
{
    DesktopUpdaterNative.ScheduleInstallAndRelaunch(
        missingStagingPath,
        new[] { "obsolete.txt" },
        null);
}
catch (DesktopUpdaterException error)
    when (error.Message.Contains(
        "Staged update directory",
        StringComparison.Ordinal))
{
    Console.WriteLine("DesktopUpdater.Native packaged consumer passed.");
    return 0;
}

Console.Error.WriteLine("The packaged native helper did not reject missing staging.");
return 1;
