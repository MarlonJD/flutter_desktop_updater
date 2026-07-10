import DesktopUpdaterKit

let request = MacInstallRequest(
    stagingPath: nil,
    allowUnsignedUpdates: false,
    diagnosticsLogPath: nil,
    currentProcessIdentifier: 1,
    bundlePath: "/Applications/DesktopUpdaterConsumer.app"
)

precondition(!request.allowUnsignedUpdates)
print("DesktopUpdaterKit consumer compiled: \(request.bundlePath)")
