using DesktopUpdater.Native;

const string startupTransactionId =
    "00000000-0000-4000-8000-000000000012";
var startupStatus = DesktopUpdaterNative.QueryTransaction(startupTransactionId);
if (startupStatus.ResultCode ==
    DesktopUpdaterInstallTransactionResultCode.RecoveryRequired)
{
    _ = DesktopUpdaterNative.RecoverPendingInstall(startupTransactionId);
}

var missingStagingPath = Path.Combine(
    Path.GetTempPath(),
    $"desktop-updater-consumer-missing-{Guid.NewGuid():N}");

try
{
    var request = new DesktopUpdaterInstallRequest(
        stagingPath: missingStagingPath,
        removedFiles: new[] { "obsolete.txt" },
        diagnosticsLogPath: null,
        expectedProvenanceSha256: new string('a', 64),
        expectedArtifactSha256: new string('b', 64),
        allowedSignerThumbprints: new[] { new string('c', 64) },
        requiresElevation: DesktopUpdaterElevationPolicy.Auto,
        installRoot: AppContext.BaseDirectory,
        executableRelativePath: Path.GetFileName(Environment.ProcessPath!),
        expectedPackageId: "com.example.desktop-updater-consumer");
    DesktopUpdaterNative.ScheduleInstallAndRelaunch(request);
}
catch (DesktopUpdaterException error)
    when (error.Message.Contains("Staged update", StringComparison.Ordinal)
        && (error.Message.Contains("directory", StringComparison.Ordinal)
            || error.Message.Contains(
                "path components",
                StringComparison.Ordinal)))
{
    Console.WriteLine("DesktopUpdater.Native packaged consumer passed.");
    return 0;
}

Console.Error.WriteLine("The packaged native helper did not reject missing staging.");
return 1;
