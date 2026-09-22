import AppKit
import Darwin
import Foundation
import XCTest

final class MacApplicationBundleRestartTests: XCTestCase {
    // Exercise the application registration used by the Dock without changing
    // the user's pinned applications or inspecting the Dock's private state.
    func testReplacementRelaunchesOnceThroughLaunchServices() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "desktop-updater-bundle-restart-\(UUID().uuidString)",
            isDirectory: true
        ).resolvingSymlinksInPath()
        let application = root.appendingPathComponent("Restart Fixture.app")
        let macOS = application.appendingPathComponent("Contents/MacOS")
        let executable = macOS.appendingPathComponent(
            "MacApplicationRestartFixture"
        )
        let bundleIdentifier =
            "com.example.desktop-updater-restart.\(UUID().uuidString)"
        try fileManager.createDirectory(
            at: macOS, withIntermediateDirectories: true
        )
        defer {
            stopFixtureProcesses(in: root, executable: executable)
            try? fileManager.removeItem(at: root)
        }

        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        try fileManager.copyItem(
            at: products.appendingPathComponent("MacApplicationRestartFixture"),
            to: executable
        )
        let info: [String: Any] = [
            "CFBundleExecutable": executable.lastPathComponent,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Desktop Updater Restart Test",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "NSPrincipalClass": "NSApplication",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        ).write(to: application.appendingPathComponent("Contents/Info.plist"))
        try runTool(
            "/usr/bin/codesign", ["--force", "--sign", "-", application.path]
        )

        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DESKTOP_UPDATER_RESTART")
        }
        environment["DESKTOP_UPDATER_TEST_BUNDLE_RESTART_ROOT"] = root.path
        try runTool(
            "/usr/bin/open", ["--", application.path], environment: environment
        )
        let prepared = try readProof("prepared.json", in: root)
        let waiting = try readProof("waiting.json", in: root)
        XCTAssertNotEqual(prepared.pid, waiting.pid)
        XCTAssertEqual(prepared.executableInode, waiting.executableInode)
        let relaunchProof = root.appendingPathComponent("relaunched.json")
        XCTAssertFalse(fileManager.fileExists(atPath: relaunchProof.path))

        // Let the outgoing app exit before publishing the replacement. The
        // waiting child must survive the lifetime barrier without launching it.
        try Data().write(to: root.appendingPathComponent("exit-requested"))
        XCTAssertTrue(waitUntil { !self.processExists(prepared.pid) })
        XCTAssertTrue(processExists(waiting.pid))
        XCTAssertFalse(fileManager.fileExists(atPath: relaunchProof.path))

        // An atomic replacement gives the executable a new inode, just as an
        // installed update does, while retaining this fixture's valid signature.
        let replacement = root.appendingPathComponent("replacement")
        try fileManager.copyItem(at: executable, to: replacement)
        XCTAssertEqual(rename(replacement.path, executable.path), 0)
        let relaunched = try readProof("relaunched.json", in: root)
        XCTAssertNotEqual(relaunched.executableInode, waiting.executableInode)
        XCTAssertEqual(relaunched.executable, executable.path)
        XCTAssertEqual(relaunched.bundleIdentifier, bundleIdentifier)
        XCTAssertTrue(relaunched.restarted)
        XCTAssertTrue(relaunched.handoffCleared)

        // execve of the replacement in the waiting child preserves its PID.
        // A LaunchServices launch creates a new, registered application instead.
        XCTAssertNotEqual(
            relaunched.pid, waiting.pid,
            "The replacement kept the restart child's PID; LaunchServices was bypassed."
        )
        guard relaunched.pid != waiting.pid else { return }
        XCTAssertNotEqual(relaunched.pid, prepared.pid)
        XCTAssertTrue(waitUntil { !self.processExists(waiting.pid) })
        let registeredOnce = waitUntil {
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            )
            return applications.count == 1
                && applications[0].processIdentifier == relaunched.pid
                && applications[0].isFinishedLaunching
        }
        let registrations = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).map {
            "pid=\($0.processIdentifier), launched=\($0.isFinishedLaunching), "
                + "terminated=\($0.isTerminated)"
        }
        XCTAssertTrue(
            registeredOnce, "LaunchServices registrations: \(registrations)"
        )
        let running = try XCTUnwrap(
            NSRunningApplication(processIdentifier: relaunched.pid)
        )
        XCTAssertEqual(
            running.bundleURL?.resolvingSymlinksInPath().path, application.path
        )
        XCTAssertEqual(running.activationPolicy, .regular)

        try Data().write(to: root.appendingPathComponent("finish"))
        XCTAssertTrue(waitUntil { !self.processExists(relaunched.pid) })
    }

    private struct Proof: Decodable {
        let pid: pid_t
        let executable: String
        let executableInode: UInt64
        let bundleIdentifier: String
        let restarted: Bool
        let handoffCleared: Bool
    }

    private func readProof(_ name: String, in root: URL) throws -> Proof {
        let url = root.appendingPathComponent(name)
        guard waitUntil({ FileManager.default.fileExists(atPath: url.path) }) else {
            let errors = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("error-") }
            let details = try errors.map {
                try String(contentsOf: $0, encoding: .utf8)
            }
            XCTFail("Missing \(name); fixture errors: \(details)")
            throw NSError(domain: "MacApplicationBundleRestartTests", code: 1)
        }
        return try JSONDecoder().decode(Proof.self, from: Data(contentsOf: url))
    }

    private func runTool(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard waitUntil({ !process.isRunning }) else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            XCTFail("Timed out running \(executable)")
            throw NSError(domain: "MacApplicationBundleRestartTests", code: 2)
        }
        XCTAssertEqual(process.terminationStatus, 0, executable)
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func stopFixtureProcesses(in root: URL, executable: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix("process-") {
            guard let pid = pid_t(
                entry.lastPathComponent.dropFirst("process-".count)
            ) else {
                continue
            }
            var path = [CChar](repeating: 0, count: 4096)
            let length = path.withUnsafeMutableBufferPointer {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            guard length > 0 else { continue }
            let image = URL(fileURLWithPath: String(cString: path))
                .resolvingSymlinksInPath().path
            // A waiting child may already have exec'd open when a test fails.
            guard image == executable.path || image == "/usr/bin/open" else {
                continue
            }
            kill(pid, SIGKILL)
            _ = waitUntil { !self.processExists(pid) }
        }
    }
}
