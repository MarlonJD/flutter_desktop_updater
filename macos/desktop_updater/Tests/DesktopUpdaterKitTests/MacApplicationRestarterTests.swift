import Darwin
import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class MacApplicationRestarterTests: XCTestCase {
    func testRealRestartWaitsForCallerExitAndIsolatesDescriptors() throws {
        let fixture = try restartFixtureURL()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "desktop-updater-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let exit = root.appendingPathComponent("exit")
        let proof = root.appendingPathComponent("proof")
        let process = Process()
        process.executableURL = fixture
        process.arguments = ["--restart"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DESKTOP_UPDATER_TEST_RESTART_READY_PROOF": ready.path,
            "DESKTOP_UPDATER_TEST_RESTART_EXIT_PROOF": exit.path,
            "DESKTOP_UPDATER_TEST_RESTART_PROOF": proof.path,
            "DESKTOP_UPDATER_TEST_CLOSE_STANDARD_FDS": "1"
        ]) { _, fixtureValue in fixtureValue }

        try process.run()
        XCTAssertTrue(waitForFile(ready, timeout: 5))
        XCTAssertTrue(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))

        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(waitForNonEmptyFile(proof, timeout: 5))
        let lines = try String(contentsOf: proof, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            lines,
            [
                "executable=\(fixture.resolvingSymlinksInPath().path)",
                "oldProcessExited=true",
                "unrelatedDescriptorClosed=true"
            ]
        )
    }

    func testPathReplacementCannotLaunchDifferentExecutableIdentity() throws {
        let fixture = try restartFixtureURL()
        let impostor = try restartImpostorFixtureURL()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "desktop-updater-restart-replacement-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let copiedFixture = root.appendingPathComponent("RestartFixture")
        try FileManager.default.copyItem(at: fixture, to: copiedFixture)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: copiedFixture.path
        )
        let resultProof = root.appendingPathComponent("result")
        let impostorProof = root.appendingPathComponent("impostor")
        let process = Process()
        process.executableURL = copiedFixture
        process.arguments = ["--replace-before-restart"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DESKTOP_UPDATER_TEST_RESTART_IMPOSTOR": impostor.path,
            "DESKTOP_UPDATER_TEST_RESTART_REPLACEMENT_PROOF":
                resultProof.path,
            "DESKTOP_UPDATER_TEST_RESTART_IMPOSTOR_PROOF": impostorProof.path,
        ]) { _, fixtureValue in fixtureValue }

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: resultProof, encoding: .utf8),
            "identity-rejected\n"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: impostorProof.path)
        )
    }

    func testConcurrentChildCannotHoldRestartLifetimeBarrierOpen() throws {
        let fixture = try restartFixtureURL()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "desktop-updater-restart-inheritance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let exit = root.appendingPathComponent("exit")
        let proof = root.appendingPathComponent("proof")
        let childPIDProof = root.appendingPathComponent("child-pid")
        var childPID: pid_t?
        defer {
            if let childPID, childPID > 0 {
                _ = kill(childPID, SIGKILL)
            }
        }
        let process = Process()
        process.executableURL = fixture
        process.arguments = ["--restart-with-concurrent-child"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DESKTOP_UPDATER_TEST_RESTART_READY_PROOF": ready.path,
            "DESKTOP_UPDATER_TEST_RESTART_EXIT_PROOF": exit.path,
            "DESKTOP_UPDATER_TEST_RESTART_PROOF": proof.path,
            "DESKTOP_UPDATER_TEST_CONCURRENT_CHILD_PID_PROOF":
                childPIDProof.path,
        ]) { _, fixtureValue in fixtureValue }

        try process.run()
        XCTAssertTrue(waitForNonEmptyFile(childPIDProof, timeout: 5))
        childPID = try XCTUnwrap(
            pid_t(
                String(contentsOf: childPIDProof, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        XCTAssertTrue(waitForFile(ready, timeout: 5))
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        XCTAssertTrue(waitForNonEmptyFile(proof, timeout: 1.5))
        XCTAssertEqual(kill(try XCTUnwrap(childPID), 0), 0)
    }

    func testSchedulesTheExactCurrentExecutable() throws {
        let executable = URL(
            fileURLWithPath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        var scheduledExecutable: URL?
        let restarter = MacApplicationRestarter(
            currentExecutableURL: { executable },
            schedule: { scheduledExecutable = $0 }
        )

        try restarter.scheduleCurrentApplicationRestart()

        XCTAssertEqual(scheduledExecutable, executable)
    }

    func testMissingCurrentExecutableFailsBeforeScheduling() {
        var scheduleCalled = false
        let restarter = MacApplicationRestarter(
            currentExecutableURL: { nil },
            schedule: { _ in scheduleCalled = true }
        )

        XCTAssertThrowsError(
            try restarter.scheduleCurrentApplicationRestart()
        ) { error in
            XCTAssertEqual(
                error as? MacApplicationRestartError,
                .executableUnavailable
            )
        }
        XCTAssertFalse(scheduleCalled)
    }

    func testSchedulingFailureIsPropagatedWithoutFallback() {
        enum ExpectedFailure: Error, Equatable {
            case rejected
        }
        let executable = URL(fileURLWithPath: "/tmp/Example")
        let restarter = MacApplicationRestarter(
            currentExecutableURL: { executable },
            schedule: { _ in throw ExpectedFailure.rejected }
        )

        XCTAssertThrowsError(
            try restarter.scheduleCurrentApplicationRestart()
        ) { error in
            XCTAssertEqual(error as? ExpectedFailure, .rejected)
        }
    }

    func testMalformedInheritedHandoffFailsClosedAndClearsEnvironment() {
        setenv(
            "DESKTOP_UPDATER_RESTART_LIFETIME_FD",
            "not-a-descriptor",
            1
        )
        setenv("DESKTOP_UPDATER_RESTART_READY_FD", "1", 1)

        XCTAssertFalse(
            MacApplicationRestarter.awaitRestartParentExitIfRequested()
        )
        XCTAssertNil(getenv("DESKTOP_UPDATER_RESTART_LIFETIME_FD"))
        XCTAssertNil(getenv("DESKTOP_UPDATER_RESTART_READY_FD"))
    }

    private func restartFixtureURL() throws -> URL {
        let testBundle = Bundle(for: MacApplicationRestarterTests.self)
        let products = testBundle.bundleURL.deletingLastPathComponent()
        let fixture = products.appendingPathComponent(
            "MacApplicationRestartFixture"
        )
        guard FileManager.default.isExecutableFile(atPath: fixture.path) else {
            throw NSError(
                domain: "MacApplicationRestarterTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(fixture.path)"]
            )
        }
        return fixture
    }

    private func restartImpostorFixtureURL() throws -> URL {
        let testBundle = Bundle(for: MacApplicationRestarterTests.self)
        let products = testBundle.bundleURL.deletingLastPathComponent()
        let fixture = products.appendingPathComponent(
            "MacApplicationRestartImpostorFixture"
        )
        guard FileManager.default.isExecutableFile(atPath: fixture.path) else {
            throw NSError(
                domain: "MacApplicationRestarterTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(fixture.path)"]
            )
        }
        return fixture
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func waitForNonEmptyFile(
        _ url: URL,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileSize(url) > 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return fileSize(url) > 0
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
