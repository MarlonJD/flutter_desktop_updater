import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class NativeInstallRequestTests: XCTestCase {
    func testProtectedApplicationAndSameUserWritableStrategyConstraints() throws {
        let fixture = try fixtureObject("valid-requests.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])

        for targetClass in ["protectedApplication", "sameUserWritable"] {
            for entry in cases {
                var request = try XCTUnwrap(entry["request"] as? [String: Any])
                var target = try XCTUnwrap(request["target"] as? [String: Any])
                target["class"] = targetClass
                request["target"] = target
                let data = try JSONSerialization.data(withJSONObject: request)
                let strategy = try XCTUnwrap(request["strategy"] as? String)
                let context = "\(strategy): \(targetClass)"
                let allowed = strategy == "directoryReplace"
                    || (strategy == "verifiedInstallerHandoff"
                        && targetClass == "protectedApplication")

                if allowed {
                    XCTAssertNoThrow(
                        try NativeInstallTransactionRequestV1.parse(data),
                        context
                    )
                } else {
                    XCTAssertThrowsError(
                        try NativeInstallTransactionRequestV1.parse(data),
                        context
                    ) { error in
                        XCTAssertEqual(
                            (error as? NativeInstallProtocolError)?.code,
                            "strategyTargetMismatch",
                            context
                        )
                    }
                }
            }
        }
    }

    func testAcceptsEveryCanonicalVersionOneRequest() throws {
        let fixture = try fixtureObject("valid-requests.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])

        for entry in cases {
            let name = entry["name"] as? String ?? "valid request"
            let request = try XCTUnwrap(entry["request"])
            let data = try JSONSerialization.data(
                withJSONObject: request,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let parsed = try NativeInstallTransactionRequestV1.parse(data)

            XCTAssertEqual(parsed.schemaVersion, 1, name)
            XCTAssertEqual(parsed.protocolVersion, 1, name)
            XCTAssertEqual(
                parsed.strategy,
                entry["strategy"] as? String,
                name
            )
            let target = try XCTUnwrap(
                (request as? [String: Any])?["target"] as? [String: Any]
            )
            XCTAssertEqual(parsed.target.targetClass, target["class"] as? String, name)
        }
    }

    func testRejectsEveryAdversarialRequestWithTheCanonicalFailure() throws {
        let fixture = try fixtureObject("invalid-requests.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])

        for entry in cases {
            let name = entry["name"] as? String ?? "invalid request"
            let data: Data
            if let rawJSON = entry["rawJson"] as? String {
                data = Data(rawJSON.utf8)
            } else {
                data = try JSONSerialization.data(
                    withJSONObject: try XCTUnwrap(entry["request"]),
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            }
            let expected = try XCTUnwrap(entry["expectedFailure"] as? String)

            XCTAssertThrowsError(
                try NativeInstallTransactionRequestV1.parse(data),
                name
            ) { error in
                XCTAssertEqual(
                    (error as? NativeInstallProtocolError)?.code,
                    expected,
                    name
                )
            }
        }
    }

    func testCanonicalJSONMatchesTheCrossLanguageFixture() throws {
        let fixture = try fixtureObject("canonical-json.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])

        for entry in cases {
            let name = entry["name"] as? String ?? "canonical JSON"
            let input = try XCTUnwrap(entry["inputJson"] as? String)
            if let expectedFailure = entry["expectedFailure"] as? String {
                XCTAssertThrowsError(
                    try NativeStrictJSON.canonicalize(Data(input.utf8))
                ) { error in
                    XCTAssertEqual(
                        (error as? NativeInstallProtocolError)?.code,
                        expectedFailure
                    )
                }
            } else {
                XCTAssertEqual(
                    try String(
                        decoding: NativeStrictJSON.canonicalize(
                            Data(input.utf8)
                        ),
                        as: UTF8.self
                    ),
                    entry["canonicalJson"] as? String,
                    name
                )
            }
        }
    }
}

private func fixtureObject(_ name: String) throws -> [String: Any] {
    let file = try repositoryRoot()
        .appendingPathComponent("fixtures/compat/native-install-helper/v1")
        .appendingPathComponent(name)
    return try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any]
    )
}

private func repositoryRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        if FileManager.default.fileExists(
            atPath: candidate
                .appendingPathComponent(
                    "fixtures/compat/native-install-helper/v1/valid-requests.json"
                ).path
        ) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
