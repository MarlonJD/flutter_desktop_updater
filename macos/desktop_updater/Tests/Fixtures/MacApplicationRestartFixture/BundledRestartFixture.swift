import AppKit
import Darwin
import DesktopUpdaterKit
import Foundation

private var bundleRestartRoot: URL!
private var bundleRestartNibLoaded = false

// Use the same entrypoint and nib lifecycle as a Flutter macOS host. Merely
// creating NSApplication.shared does not reproduce plugin registration from
// MainFlutterWindow.awakeFromNib inside NSApplicationMain.
func runBundledRestartFixtureIfRequested() {
    guard let path = ProcessInfo.processInfo.environment[
        "DESKTOP_UPDATER_TEST_BUNDLE_RESTART_ROOT"
    ] else { return }
    bundleRestartRoot = URL(fileURLWithPath: path)
    do {
        try Data().write(to: bundleRestartRoot.appendingPathComponent("process-\(getpid())"))
        try awaitBundleRestartParent()
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        exit(1)
    } catch {
        failBundleRestart(error)
    }
}

private func awaitBundleRestartParent() throws {
    if getenv("DESKTOP_UPDATER_RESTART_LIFETIME_FD") != nil {
        try writeBundleRestartProof("waiting-\(getppid()).json")
    }
    guard MacApplicationRestarter.awaitRestartParentExitIfRequested() else {
        throw NSError(domain: "BundledRestartFixture", code: 2)
    }
}

@objc(MacApplicationRestartFixtureWindow)
final class MacApplicationRestartFixtureWindow: NSWindow {
    override func awakeFromNib() {
        super.awakeFromNib()
        bundleRestartNibLoaded = true
        do {
            // Model the plugin's defensive registration-time wait as well as
            // the host bootstrap. With the early call removed, this is too late.
            try awaitBundleRestartParent()
        } catch {
            failBundleRestart(error)
        }
    }
}

@objc(MacApplicationRestartFixtureDelegate)
final class MacApplicationRestartFixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.disableRelaunchOnLogin()
        do {
            try writeBundleRestartProof("launched.json")
        } catch {
            failBundleRestart(error)
        }

        let deadline = Date().addingTimeInterval(30)
        var prepared = false
        _ = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            func requested(_ name: String) -> Bool {
                FileManager.default.fileExists(
                    atPath: bundleRestartRoot.appendingPathComponent("\(name)-\(getpid())").path
                )
            }
            if requested("finish") || (prepared && requested("exit")) {
                exit(0)
            }
            if Date() >= deadline {
                failBundleRestart(NSError(
                    domain: "BundledRestartFixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a restart command"]
                ))
            }
            if !prepared && requested("restart") {
                do {
                    let reservation = try MacApplicationRestarter()
                        .prepareCurrentApplicationRestart()
                    reservation.commit()
                    prepared = true
                    try writeBundleRestartProof("prepared-\(getpid()).json")
                } catch {
                    failBundleRestart(error)
                }
            }
        }
    }
}

private func writeBundleRestartProof(_ name: String) throws {
    let executable = Bundle.main.executableURL!.resolvingSymlinksInPath().path
    var status = stat()
    guard Darwin.lstat(executable, &status) == 0 else {
        throw POSIXError(.ENOENT)
    }
    let proof: [String: Any] = [
        "pid": getpid(),
        "executable": executable,
        "executableInode": status.st_ino,
        "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
        "appKitInitialized": NSApp != nil,
        "nibLoaded": bundleRestartNibLoaded,
        "restarted": getenv("DESKTOP_UPDATER_RESTARTED")
            .map { String(cString: $0) == "1" } ?? false,
        "handoffCleared": getenv("DESKTOP_UPDATER_RESTART_LIFETIME_FD") == nil
            && getenv("DESKTOP_UPDATER_RESTART_READY_FD") == nil
            && getenv("DESKTOP_UPDATER_RESTART_REEXEC") == nil,
    ]
    try JSONSerialization.data(withJSONObject: proof).write(
        to: bundleRestartRoot.appendingPathComponent(name), options: .atomic
    )
}

private func failBundleRestart(_ error: Error) -> Never {
    try? Data("\(error)".utf8).write(
        to: bundleRestartRoot.appendingPathComponent("error-\(getpid())"), options: .atomic
    )
    exit(1)
}
