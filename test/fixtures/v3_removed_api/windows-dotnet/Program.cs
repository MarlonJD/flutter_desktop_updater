using DesktopUpdater.Native;

DesktopUpdaterNative.ScheduleInstallAndRelaunch(
    stagingPath: null,
    removedFiles: Array.Empty<string>(),
    diagnosticsLogPath: @"C:\\temp\\desktop-updater.jsonl");
