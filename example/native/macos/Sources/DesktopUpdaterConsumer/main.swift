import DesktopUpdaterKit

let request = MacInstallRequest(
    stagingPath: nil,
    allowUnsignedUpdates: false,
    diagnosticsLogPath: nil,
    currentProcessIdentifier: 1,
    bundlePath: "/Applications/DesktopUpdaterConsumer.app"
)

precondition(!request.allowUnsignedUpdates)
precondition(!DesktopUpdaterVersion.string.isEmpty)
print(
    "DesktopUpdaterKit \(DesktopUpdaterVersion.string) consumer compiled: "
        + request.bundlePath
)
