import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class HelperVersionTests: XCTestCase {
    func testVersionAndProtocolIdentityAreStable() {
        XCTAssertEqual(HelperVersion.semanticVersion, "3.0.0")
        XCTAssertEqual(HelperVersion.protocolVersion, 1)
        XCTAssertEqual(
            HelperVersion.displayString,
            "DesktopUpdaterInstallHelper 3.0.0 (protocol 1)"
        )
    }

    func testOnlyFixedBootstrapCommandsAreAccepted() throws {
        XCTAssertEqual(try HelperCommand.parse(arguments: ["--version"]), .version)
        XCTAssertEqual(
            try HelperCommand.parse(arguments: ["--test-parse-protocol"]),
            .testParseProtocol
        )
        XCTAssertEqual(
            try HelperCommand.parse(arguments: ["--one-shot-service"]),
            .oneShotService
        )
        XCTAssertEqual(
            try HelperCommand.parse(arguments: ["--one-shot-recovery"]),
            .oneShotRecovery
        )
        XCTAssertEqual(
            try HelperCommand.parse(
                arguments: ["--verified-installer-worker"]
            ),
            .verifiedInstallerWorker
        )
        XCTAssertEqual(
            try HelperCommand.parse(arguments: []),
            .privilegedService
        )
        XCTAssertThrowsError(try HelperCommand.parse(arguments: ["--help"]))
        XCTAssertThrowsError(
            try HelperCommand.parse(arguments: ["--version", "--test-parse-protocol"])
        )
        XCTAssertThrowsError(
            try HelperCommand.parse(
                arguments: [
                    "--privileged-service",
                    "com.attacker.helper",
                ]
            )
        )
        XCTAssertThrowsError(
            try HelperCommand.parse(arguments: ["--privileged-service"])
        )
        XCTAssertThrowsError(
            try HelperCommand.parse(
                arguments: ["--one-shot-service", "/tmp/attacker"]
            )
        )
        XCTAssertThrowsError(
            try HelperCommand.parse(
                arguments: ["--one-shot-recovery", "/tmp/attacker"]
            )
        )
    }

    func testOneShotCommandRunsOnlyTheInjectedWireRuntime() throws {
        let oneShot = TestOneShotServiceRuntime()
        let privileged = TestPrivilegedServiceRuntime()

        XCTAssertNil(
            try HelperCommand.oneShotService.execute(
                protocolInput: Data(),
                oneShotServiceRuntime: oneShot,
                privilegedServiceRuntime: privileged
            )
        )

        XCTAssertTrue(oneShot.didRun)
        XCTAssertFalse(privileged.didRun)
    }

    func testProtocolParseModeUsesTheCanonicalVersionOneRequestParser() throws {
        let fixture = try helperProtocolFixtureObject("valid-requests.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let first = try XCTUnwrap(cases.first)
        let request = try XCTUnwrap(first["request"])
        let valid = try JSONSerialization.data(
            withJSONObject: request,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertEqual(
            try HelperCommand.testParseProtocol.execute(
                protocolInput: valid,
                oneShotServiceRuntime: TestOneShotServiceRuntime(),
                privilegedServiceRuntime: TestPrivilegedServiceRuntime()
            ),
            "valid schema=1 protocol=1 "
                + "transaction=00000000-0000-4000-8000-000000000001"
        )

        for invalid in [
            Data("[]".utf8),
            Data(#"{"schemaVersion":1,"protocolVersion":1}"#.utf8),
            Data(#"{"schemaVersion":2,"protocolVersion":1}"#.utf8),
            Data(#"{"schemaVersion":1,"protocolVersion":0}"#.utf8),
            Data("not-json".utf8),
        ] {
            XCTAssertThrowsError(
                try HelperCommand.testParseProtocol.execute(
                    protocolInput: invalid,
                    oneShotServiceRuntime: TestOneShotServiceRuntime(),
                    privilegedServiceRuntime: TestPrivilegedServiceRuntime()
                )
            )
        }
    }

    func testBuiltHelperExecutableParsesCanonicalRequest() throws {
        let fixture = try helperProtocolFixtureObject("valid-requests.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let request = try XCTUnwrap(try XCTUnwrap(cases.first)["request"])
        let input = try JSONSerialization.data(
            withJSONObject: request,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let helper = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("DesktopUpdaterInstallHelper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = helper
        process.arguments = ["--test-parse-protocol"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        try process.run()
        try standardInput.fileHandleForWriting.write(contentsOf: input)
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            String(
                decoding: standardOutput.fileHandleForReading
                    .readDataToEndOfFile(),
                as: UTF8.self
            ),
            "valid schema=1 protocol=1 "
                + "transaction=00000000-0000-4000-8000-000000000001\n"
        )
    }

    func testBuiltHelperWorkerEOFExitsWithoutLaunchingInstaller() throws {
        let helper = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("DesktopUpdaterInstallHelper")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--verified-installer-worker"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

private final class TestPrivilegedServiceRuntime: MacPrivilegedServiceRunning {
    private(set) var didRun = false

    func run() throws {
        didRun = true
    }
}

private final class TestOneShotServiceRuntime: MacOneShotServiceRunning {
    private(set) var didRun = false

    func run() throws {
        didRun = true
    }
}

private func helperProtocolFixtureObject(_ name: String) throws
    -> [String: Any]
{
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        let file = candidate
            .appendingPathComponent("fixtures/compat/native-install-helper/v1")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: file))
                    as? [String: Any]
            )
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
