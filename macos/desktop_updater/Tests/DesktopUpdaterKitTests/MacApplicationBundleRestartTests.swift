import AppKit
import Darwin
import Foundation
import XCTest

final class MacApplicationBundleRestartTests: XCTestCase {
    // Exercise the application registration used by the Dock without changing
    // the user's pinned applications or inspecting the Dock's private state.
    func testTwoReplacementsRelaunchThroughMainNibAndLaunchServices() throws {
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
            "NSMainNibFile": "RestartFixture",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        ).write(to: application.appendingPathComponent("Contents/Info.plist"))
        try compileMainNib(in: application, root: root)
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
        var launched = try readProof("launched.json", in: root)
        XCTAssertFalse(launched.restarted)
        XCTAssertTrue(launched.appKitInitialized)
        XCTAssertTrue(launched.nibLoaded)
        XCTAssertTrue(launched.handoffCleared)

        for _ in 0..<2 {
            let parent = launched
            let launchProof = root.appendingPathComponent("launched.json")
            try fileManager.removeItem(at: launchProof)
            try Data().write(to: root.appendingPathComponent("restart-\(parent.pid)"))
            let prepared = try readProof("prepared-\(parent.pid).json", in: root)
            let waiting = try readProof("waiting-\(parent.pid).json", in: root)
            XCTAssertEqual(prepared.pid, parent.pid)
            XCTAssertNotEqual(prepared.pid, waiting.pid)
            XCTAssertEqual(prepared.executableInode, waiting.executableInode)
            XCTAssertFalse(waiting.appKitInitialized, "Restart must wait before AppKit initialization")
            XCTAssertFalse(waiting.nibLoaded, "Plugin registration in awakeFromNib is too late")
            guard !waiting.appKitInitialized && !waiting.nibLoaded else { return }
            XCTAssertFalse(fileManager.fileExists(atPath: launchProof.path))

            // The child must survive its parent's exit without launching until
            // the executable is replaced. Repeat using the relaunched parent.
            try Data().write(to: root.appendingPathComponent("exit-\(parent.pid)"))
            XCTAssertTrue(waitUntil { !self.processExists(parent.pid) })
            XCTAssertTrue(processExists(waiting.pid))
            XCTAssertFalse(fileManager.fileExists(atPath: launchProof.path))

            let replacement = root.appendingPathComponent("replacement")
            try fileManager.copyItem(at: executable, to: replacement)
            XCTAssertEqual(rename(replacement.path, executable.path), 0)
            launched = try readProof("launched.json", in: root)
            XCTAssertNotEqual(launched.executableInode, waiting.executableInode)
            XCTAssertEqual(launched.executable, executable.path)
            XCTAssertEqual(launched.bundleIdentifier, bundleIdentifier)
            XCTAssertTrue(launched.restarted)
            XCTAssertTrue(launched.handoffCleared)
            XCTAssertTrue(launched.appKitInitialized)
            XCTAssertTrue(launched.nibLoaded)

            XCTAssertNotEqual(
                launched.pid, waiting.pid,
                "The replacement kept the restart child's PID; LaunchServices was bypassed."
            )
            guard launched.pid != waiting.pid else { return }
            XCTAssertNotEqual(launched.pid, parent.pid)
            XCTAssertTrue(waitUntil { !self.processExists(waiting.pid) })
            XCTAssertTrue(waitUntil {
                let applications = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleIdentifier
                )
                return applications.count == 1
                    && applications[0].processIdentifier == launched.pid
                    && applications[0].isFinishedLaunching
            }, "The replacement must be the only registered, fully launched application")
            let running = try XCTUnwrap(NSRunningApplication(processIdentifier: launched.pid))
            XCTAssertEqual(running.bundleURL?.resolvingSymlinksInPath().path, application.path)
            XCTAssertEqual(running.activationPolicy, .regular)
        }

        try Data().write(to: root.appendingPathComponent("finish-\(launched.pid)"))
        XCTAssertTrue(waitUntil { !self.processExists(launched.pid) })
    }

    private struct Proof: Decodable {
        let pid: pid_t
        let executable: String
        let executableInode: UInt64
        let bundleIdentifier: String
        let restarted: Bool
        let handoffCleared: Bool
        let appKitInitialized: Bool
        let nibLoaded: Bool
    }

    private func compileMainNib(in application: URL, root: URL) throws {
        let resources = application.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let xib = root.appendingPathComponent("RestartFixture.xib")
        // A real main nib instantiates the application delegate and a window
        // whose awakeFromNib follows Flutter's plugin-registration lifecycle.
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <document type="com.apple.InterfaceBuilder3.Cocoa.XIB" version="3.0" toolsVersion="14490.70" targetRuntime="MacOSX.Cocoa" propertyAccessControl="none" useAutolayout="YES">
            <dependencies>
                <deployment identifier="macosx"/>
                <plugIn identifier="com.apple.InterfaceBuilder.CocoaPlugin" version="14490.70"/>
                <capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/>
            </dependencies>
            <objects>
                <customObject id="-2" userLabel="File's Owner" customClass="NSApplication">
                    <connections>
                        <outlet property="delegate" destination="delegate" id="delegate-outlet"/>
                    </connections>
                </customObject>
                <customObject id="-1" userLabel="First Responder" customClass="FirstResponder"/>
                <customObject id="-3" userLabel="Application" customClass="NSObject"/>
                <customObject id="delegate" customClass="MacApplicationRestartFixtureDelegate"/>
                <window title="Restart Fixture" visibleAtLaunch="NO" releasedWhenClosed="NO" id="window" customClass="MacApplicationRestartFixtureWindow">
                    <windowStyleMask key="styleMask" titled="YES"/>
                    <rect key="contentRect" x="0" y="0" width="100" height="100"/>
                    <view key="contentView" id="view">
                        <rect key="frame" x="0" y="0" width="100" height="100"/>
                        <autoresizingMask key="autoresizingMask"/>
                    </view>
                </window>
            </objects>
        </document>
        """.write(to: xib, atomically: true, encoding: .utf8)
        try runTool("/usr/bin/xcrun", [
            "ibtool", "--compile", resources.appendingPathComponent("RestartFixture.nib").path,
            xib.path,
        ])
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
        try process.run()
        guard waitUntil({ !process.isRunning }) else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            XCTFail("Timed out running \(executable)")
            throw NSError(domain: "MacApplicationBundleRestartTests", code: 2)
        }
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "MacApplicationBundleRestartTests", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(executable) failed: \(process.terminationStatus)"]
            )
        }
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
