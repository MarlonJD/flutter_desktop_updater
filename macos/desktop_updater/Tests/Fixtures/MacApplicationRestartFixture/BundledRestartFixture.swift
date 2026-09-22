import AppKit
import Darwin
import DesktopUpdaterKit
import Foundation

// The same executable serves as the outgoing app, the waiting restart child,
// and the replacement app. Only the bundled regression test enables this mode.
func runBundledRestartFixtureIfRequested() {
    guard let path = ProcessInfo.processInfo.environment[
        "DESKTOP_UPDATER_TEST_BUNDLE_RESTART_ROOT"
    ] else { return }
    let root = URL(fileURLWithPath: path)

    func fail(_ error: Error) -> Never {
        try? Data("\(error)".utf8).write(
            to: root.appendingPathComponent("error-\(getpid())"), options: .atomic
        )
        exit(1)
    }

    func exitWhenRequested(_ name: String) {
        let deadline = Date().addingTimeInterval(20)
        _ = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if FileManager.default.fileExists(
                atPath: root.appendingPathComponent(name).path
            ) {
                exit(0)
            }
            if Date() >= deadline {
                fail(NSError(
                    domain: "BundledRestartFixture", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Timed out waiting for \(name)"
                    ]
                ))
            }
        }
    }

    func writeProof(_ name: String) throws {
        let executable = Bundle.main.executableURL!
            .resolvingSymlinksInPath().path
        var status = stat()
        guard Darwin.lstat(executable, &status) == 0 else {
            throw POSIXError(.ENOENT)
        }
        let proof: [String: Any] = [
            "pid": getpid(),
            "executable": executable,
            "executableInode": status.st_ino,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "restarted": getenv("DESKTOP_UPDATER_RESTARTED")
                .map { String(cString: $0) == "1" } ?? false,
            "handoffCleared": getenv("DESKTOP_UPDATER_RESTART_LIFETIME_FD") == nil
                && getenv("DESKTOP_UPDATER_RESTART_READY_FD") == nil
                && getenv("DESKTOP_UPDATER_RESTART_REEXEC") == nil,
        ]
        try JSONSerialization.data(withJSONObject: proof).write(
            to: root.appendingPathComponent(name), options: .atomic
        )
    }

    do {
        try Data().write(to: root.appendingPathComponent("process-\(getpid())"))
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.disableRelaunchOnLogin()

        // Flutter waits during plugin registration, before the application's
        // launch finishes. The restart child must use that same ordering.
        if getenv("DESKTOP_UPDATER_RESTART_LIFETIME_FD") != nil {
            try writeProof("waiting.json")
        }
        guard MacApplicationRestarter.awaitRestartParentExitIfRequested() else {
            throw NSError(domain: "BundledRestartFixture", code: 2)
        }

        DispatchQueue.main.async {
            do {
                if getenv("DESKTOP_UPDATER_RESTARTED") != nil {
                    try writeProof("relaunched.json")
                    exitWhenRequested("finish")
                } else {
                    let reservation = try MacApplicationRestarter()
                        .prepareCurrentApplicationRestart()
                    reservation.commit()
                    try writeProof("prepared.json")
                    exitWhenRequested("exit-requested")
                }
            } catch {
                fail(error)
            }
        }
        application.run()
        exit(1)
    } catch {
        fail(error)
    }
}
