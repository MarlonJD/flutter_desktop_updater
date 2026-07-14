import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class MacPackagedHelperTransportTests: XCTestCase {
    func testSystemAuthenticatorBindsTheRunningFixedSignedHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("DesktopUpdaterInstallHelper")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/sleep"),
            to: helper
        )
        let requirement =
            "identifier \"com.example.desktop-updater.helper\""
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = [
            "--force", "--sign", "-", "--identifier",
            "com.example.desktop-updater.helper",
            "-r=designated => \(requirement)", helper.path,
        ]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let authenticator = SystemMacOneShotEndpointAuthenticator(
            infoDictionary: [
                "DesktopUpdaterInstallHelperServiceID":
                    "com.example.desktop-updater.helper",
                "SMPrivilegedExecutables": [
                    "com.example.desktop-updater.helper": requirement,
                ],
            ]
        )

        let staticIdentity = try authenticator.authenticate(
            executableURL: helper,
            processIdentifier: nil
        )
        let runningIdentity = try authenticator.authenticate(
            executableURL: helper,
            processIdentifier: process.processIdentifier
        )

        XCTAssertEqual(runningIdentity, staticIdentity)
        XCTAssertEqual(runningIdentity.count, 64)
    }

    func testPrepareAndCommitUseOneFixedFramedProcessSession() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let reservation = reservationData(transactionID: transactionID)
        let session = RecordingMacOneShotClientSession(
            responses: [reservation, reservation]
        )
        let launcher = RecordingMacOneShotProcessLauncher(session: session)
        let helper = URL(
            fileURLWithPath:
                "/Applications/Example.app/Contents/Helpers/"
                + "DesktopUpdaterInstallHelper"
        )
        let transport = PackagedMacInstallHelperTransport(
            helperURL: helper,
            launcher: launcher,
            authenticator: RecordingEndpointAuthenticator()
        )

        let response = try transport.prepareInstall(
            request: Data("canonical-request".utf8),
            transactionID: transactionID
        )
        let status = try transport.commitAfterExit(
            transactionID: transactionID,
            readyToken: response.readyToken
        )

        XCTAssertEqual(launcher.executableURL, helper)
        XCTAssertEqual(launcher.arguments, ["--one-shot-service"])
        XCTAssertEqual(session.processIdentifier, 4_242)
        XCTAssertEqual(session.requests.first, Data("canonical-request".utf8))
        let command = try XCTUnwrap(
            JSONSerialization.jsonObject(with: session.requests[1])
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(command.keys),
            [
                "operation", "protocolVersion", "transactionId",
                "readyToken", "journalSha256",
                "helperEndpointIdentitySha256",
            ]
        )
        XCTAssertEqual(command["operation"] as? String, "commitAfterExit")
        XCTAssertEqual(
            command["journalSha256"] as? String,
            response.journalSHA256
        )
        XCTAssertEqual(status.state, .commitAccepted)
        XCTAssertEqual(status.resultCode, .accepted)
        XCTAssertTrue(session.didCloseInput)
    }

    func testCancellationRequiresCanonicalRollbackAcknowledgement() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let session = RecordingMacOneShotClientSession(
            responses: [
                reservationData(transactionID: transactionID),
                recoveryData(transactionID: transactionID),
            ]
        )
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            launcher: RecordingMacOneShotProcessLauncher(session: session),
            authenticator: RecordingEndpointAuthenticator()
        )
        let reservation = try transport.prepareInstall(
            request: Data("canonical-request".utf8),
            transactionID: transactionID
        )

        let status = try transport.cancelReservation(
            transactionID: transactionID,
            readyToken: reservation.readyToken
        )

        XCTAssertEqual(status.state, .cancelled)
        XCTAssertEqual(status.resultCode, .succeeded)
        XCTAssertTrue(session.didCloseInput)
    }

    func testRejectsReservationFromDifferentEndpointIdentity() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let session = RecordingMacOneShotClientSession(
            responses: [reservationData(transactionID: transactionID)]
        )
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            launcher: RecordingMacOneShotProcessLauncher(session: session),
            authenticator: RecordingEndpointAuthenticator(
                identity: String(repeating: "d", count: 64)
            )
        )

        XCTAssertThrowsError(
            try transport.prepareInstall(
                request: Data("canonical-request".utf8),
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(
                error as? MacInstallClientError,
                .invalidReservationResponse
            )
        }
        XCTAssertTrue(session.didCloseInput)
    }

    func testQueryUsesAuthenticatedPersistentRecoverySession() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let session = RecordingMacOneShotClientSession(
            responses: [
                statusData(
                    transactionID: transactionID,
                    state: "prepared",
                    resultCode: "recoveryRequired"
                ),
            ]
        )
        let launcher = RecordingMacOneShotProcessLauncher(session: session)
        let authenticator = RecordingEndpointAuthenticator()
        let helper = URL(fileURLWithPath: "/fixed/helper")
        let transport = PackagedMacInstallHelperTransport(
            helperURL: helper,
            policyID: "com.example.desktop-updater.test",
            launcher: launcher,
            authenticator: authenticator
        )

        let status = try transport.queryTransaction(
            transactionID: transactionID
        )

        XCTAssertEqual(launcher.executableURL, helper)
        XCTAssertEqual(launcher.arguments, ["--one-shot-recovery"])
        XCTAssertEqual(authenticator.processIdentifiers.count, 2)
        XCTAssertNil(authenticator.processIdentifiers[0])
        XCTAssertEqual(authenticator.processIdentifiers[1], 4_242)
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: session.requests[0])
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(request.keys),
            ["operation", "policyId", "protocolVersion", "transactionId"]
        )
        XCTAssertEqual(request["operation"] as? String, "queryTransaction")
        XCTAssertEqual(
            request["policyId"] as? String,
            "com.example.desktop-updater.test"
        )
        XCTAssertEqual(status.state, .prepared)
        XCTAssertEqual(status.resultCode, .recoveryRequired)
        XCTAssertEqual(
            status.helperEndpointIdentitySHA256,
            String(repeating: "c", count: 64)
        )
        XCTAssertTrue(session.didCloseInput)
    }

    func testRecoveryMapsVerifiedRollbackFromAuthenticatedHelper() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let session = RecordingMacOneShotClientSession(
            responses: [recoveryData(transactionID: transactionID)]
        )
        let launcher = RecordingMacOneShotProcessLauncher(session: session)
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            policyID: "com.example.desktop-updater.test",
            launcher: launcher,
            authenticator: RecordingEndpointAuthenticator()
        )

        let status = try transport.recoverPendingInstall(
            transactionID: transactionID
        )

        XCTAssertEqual(launcher.arguments, ["--one-shot-recovery"])
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: session.requests[0])
                as? [String: Any]
        )
        XCTAssertEqual(
            request["operation"] as? String,
            "recoverPendingInstall"
        )
        XCTAssertEqual(status.state, .rolledBack)
        XCTAssertEqual(status.resultCode, .succeeded)
        XCTAssertEqual(status.detail, "oldTarget")
        XCTAssertEqual(
            status.responseDigestSHA256,
            String(repeating: "b", count: 64)
        )
        XCTAssertTrue(session.didCloseInput)
    }
}

private final class RecordingEndpointAuthenticator:
    MacOneShotEndpointAuthenticating
{
    let identity: String
    private(set) var processIdentifiers: [Int32?] = []

    init(identity: String = String(repeating: "c", count: 64)) {
        self.identity = identity
    }

    func authenticate(
        executableURL _: URL,
        processIdentifier: Int32?
    ) throws -> String {
        processIdentifiers.append(processIdentifier)
        return identity
    }
}

private final class RecordingMacOneShotProcessLauncher:
    MacOneShotProcessLaunching
{
    private let session: any MacOneShotClientSession
    private(set) var executableURL: URL?
    private(set) var arguments: [String]?

    init(session: any MacOneShotClientSession) {
        self.session = session
    }

    func launch(
        executableURL: URL,
        arguments: [String]
    ) throws -> any MacOneShotClientSession {
        self.executableURL = executableURL
        self.arguments = arguments
        return session
    }
}

private final class RecordingMacOneShotClientSession:
    MacOneShotClientSession
{
    let processIdentifier: Int32 = 4_242
    private var responses: [Data]
    private(set) var requests: [Data] = []
    private(set) var didCloseInput = false

    init(responses: [Data]) {
        self.responses = responses
    }

    func writeFrame(_ data: Data) throws {
        requests.append(data)
    }

    func readFrame() throws -> Data {
        guard !responses.isEmpty else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return responses.removeFirst()
    }

    func closeInput() {
        didCloseInput = true
    }
}

private func reservationData(transactionID: String) -> Data {
    try! JSONSerialization.data(
        withJSONObject: [
            "protocolVersion": 1,
            "transactionId": transactionID,
            "readyToken": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "journalSha256": String(repeating: "b", count: 64),
            "helperEndpointIdentitySha256": String(repeating: "c", count: 64),
            "expiresAtUnixMilliseconds": 99_999,
        ],
        options: [.sortedKeys]
    )
}

private func recoveryData(transactionID: String) -> Data {
    try! JSONSerialization.data(
        withJSONObject: [
            "protocolVersion": 1,
            "transactionId": transactionID,
            "resultCode": "rolledBack",
            "verifiedOutcome": "oldTarget",
            "journalSha256": String(repeating: "b", count: 64),
        ],
        options: [.sortedKeys]
    )
}

private func statusData(
    transactionID: String,
    state: String,
    resultCode: String
) -> Data {
    try! JSONSerialization.data(
        withJSONObject: [
            "protocolVersion": 1,
            "transactionId": transactionID,
            "state": state,
            "resultCode": resultCode,
            "journalSha256": String(repeating: "b", count: 64),
        ],
        options: [.sortedKeys]
    )
}
