import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class HelperVersionTests: XCTestCase {
    func testVersionAndProtocolIdentityAreStable() {
        XCTAssertEqual(HelperVersion.semanticVersion, "2.7.0")
        XCTAssertEqual(HelperVersion.protocolVersion, 1)
        XCTAssertEqual(
            HelperVersion.displayString,
            "DesktopUpdaterInstallHelper 2.7.0 (protocol 1)"
        )
    }

    func testOnlyVersionAndTestProtocolCommandsAreAccepted() throws {
        XCTAssertEqual(try HelperCommand.parse(arguments: ["--version"]), .version)
        XCTAssertEqual(
            try HelperCommand.parse(arguments: ["--test-parse-protocol"]),
            .testParseProtocol
        )
        XCTAssertThrowsError(try HelperCommand.parse(arguments: []))
        XCTAssertThrowsError(try HelperCommand.parse(arguments: ["--help"]))
        XCTAssertThrowsError(
            try HelperCommand.parse(arguments: ["--version", "--test-parse-protocol"])
        )
    }

    func testProtocolParseModeAcceptsOnlyAVersionOneObject() throws {
        let valid = Data(#"{"schemaVersion":1,"protocolVersion":1}"#.utf8)
        XCTAssertEqual(
            try TestProtocolEnvelope.parse(valid),
            TestProtocolEnvelope(schemaVersion: 1, protocolVersion: 1)
        )

        for invalid in [
            Data("[]".utf8),
            Data(#"{"schemaVersion":2,"protocolVersion":1}"#.utf8),
            Data(#"{"schemaVersion":1,"protocolVersion":0}"#.utf8),
            Data("not-json".utf8),
        ] {
            XCTAssertThrowsError(try TestProtocolEnvelope.parse(invalid))
        }
    }
}
