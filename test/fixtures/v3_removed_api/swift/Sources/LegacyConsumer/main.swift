import DesktopUpdaterKit

let legacyRequest = MacInstallRequest(
    stagingPath: "/tmp/stage",
    allowUnsignedUpdates: true,
    diagnosticsLogPath: "/tmp/desktop-updater.jsonl"
)
try MacInstallHelper().scheduleInstallAndRelaunch(legacyRequest)
