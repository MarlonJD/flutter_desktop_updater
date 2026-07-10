import DesktopUpdaterKit

let request = MacInstallRequest(
    stagingPath: nil,
    allowUnsignedUpdates: false,
    diagnosticsLogPath: nil
)

precondition(!request.allowUnsignedUpdates)
precondition(!DesktopUpdaterVersion.string.isEmpty)
print(
    "DesktopUpdaterKit \(DesktopUpdaterVersion.string) consumer compiled"
)
