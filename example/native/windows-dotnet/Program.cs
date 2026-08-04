using DesktopUpdater.Native;

const string startupTransactionId =
    "00000000-0000-4000-8000-000000000012";
var startupStatus = DesktopUpdaterNative.QueryTransaction(startupTransactionId);
if (startupStatus.ResultCode ==
    DesktopUpdaterInstallTransactionResultCode.RecoveryRequired)
{
    _ = DesktopUpdaterNative.ResolvePendingInstallAfterExit(startupTransactionId);
}

var missingStagingPath = Path.Combine(
    Path.GetTempPath(),
    $"desktop-updater-consumer-missing-{Guid.NewGuid():N}");

try
{
    var request = new DesktopUpdaterInstallRequest(
        stagingPath: missingStagingPath,
        removedFiles: new[] { "obsolete.txt" },
        expectedProvenanceSha256: new string('a', 64),
        expectedArtifactSha256: new string('b', 64),
        installRoot: AppContext.BaseDirectory,
        executableRelativePath: Path.GetFileName(Environment.ProcessPath!),
        expectedPackageId: "com.example.desktop-updater-consumer");
    using var reservation = DesktopUpdaterNative.PrepareInstall(
        request,
        "123e4567-e89b-42d3-a456-426614174000");
    _ = DesktopUpdaterNative.CommitAfterExit(reservation);
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
