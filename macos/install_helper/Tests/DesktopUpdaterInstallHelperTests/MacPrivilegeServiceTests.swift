import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacPrivilegeServiceTests: XCTestCase {
    func testConfigurationPlistsMatchBundledDaemonAndMachLabel()
        throws
    {
        let configuration = try sealedPrivilegeConfiguration()
        let directory = try helperRepositoryRoot()
            .appendingPathComponent("macos/install_helper/Configuration")

        try configuration.validatePlists(in: directory)
        XCTAssertEqual(
            configuration.serviceIdentifier,
            "com.example.desktop-updater.helper"
        )
    }

    func testHelperInfoReloadsTheSealedPolicyAndDigest() throws {
        let infoURL = try helperRepositoryRoot()
            .appendingPathComponent(
                "macos/install_helper/Configuration/Helper-Info.plist"
            )
        let value = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL),
            options: [],
            format: nil
        )
        let info = try XCTUnwrap(value as? [String: Any])

        XCTAssertEqual(
            try MacPrivilegeConfiguration.fromEmbeddedInfoDictionary(info),
            try sealedPrivilegeConfiguration()
        )
    }

    func testRejectsPrivilegeConfigurationWithWrongSealedDigest() throws {
        let fixture = try sealedPrivilegePolicyFixture()

        XCTAssertThrowsError(
            try MacPrivilegeConfiguration.fromSealedPolicy(
                fixture.data,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        )
    }

    func testXPCRequirementBindsCallerToSignedHelperTeam() throws {
        XCTAssertEqual(
            try MacXPCPeerRequirement.make(
                applicationRequirement:
                    "identifier com.example.app and anchor apple generic",
                helperTeamIdentifier: "EXAMPLETEAM"
            ),
            "(identifier com.example.app and anchor apple generic) "
                + "and certificate leaf[subject.OU] = \"EXAMPLETEAM\""
        )
        for invalid in ["", "TEAM WITH SPACE", "TEAM\" OR true"] {
            XCTAssertThrowsError(
                try MacXPCPeerRequirement.make(
                    applicationRequirement: "identifier com.example.app",
                    helperTeamIdentifier: invalid
                )
            )
        }
    }

    func testRejectsSpoofedXPCAuditToken() throws {
        let fixture = try PrivilegeFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try fixture.service.authenticatePrivilegedPeer(
                connectionAuditToken: Data(repeating: 1, count: 32),
                claimedAuditToken: Data(repeating: 2, count: 32)
            )
        ) { error in
            XCTAssertEqual(
                error as? MacPrivilegeError,
                .peerAuthenticationFailed
            )
        }
    }

    func testAuthenticatesXPCPeerFromConnectionAuditToken() throws {
        let fixture = try PrivilegeFixture()
        defer { fixture.remove() }
        let token = Data(repeating: 1, count: 32)

        let identity = try fixture.service.authenticatePrivilegedPeer(
            connectionAuditToken: token,
            claimedAuditToken: token
        )

        XCTAssertEqual(identity.bundleIdentifier, "com.example.app")
        XCTAssertEqual(fixture.checker.runningAuditTokens, [token])
    }

    func testPrivilegedHandlerBindsPeerAndMutatesOnlyAfterCommitReply()
        throws
    {
        let request = try privilegedValidRequestData()
        let session = RecordingPrivilegedInstallSession()
        let monitor = RecordingPrivilegedCallerExitMonitor()
        var terminationCount = 0
        let handler = MacPrivilegedTransactionHandler(
            sessionFactory: { processIdentifier in
                XCTAssertEqual(processIdentifier, 4_243)
                return session
            },
            monitorFactory: RecordingPrivilegedMonitorFactory(
                monitor: monitor
            ),
            recoveryHandler: RecordingPrivilegedRecoveryHandler(),
            terminateWhenIdle: { terminationCount += 1 }
        )

        XCTAssertThrowsError(
            try handler.handle(
                operation: "prepareInstall",
                payload: request,
                peerProcessIdentifier: 9_999
            )
        )

        let prepared = try handler.handle(
            operation: "prepareInstall",
            payload: request,
            peerProcessIdentifier: 4_243
        )
        XCTAssertNil(prepared.completeAfterReply)
        XCTAssertEqual(
            try NativeStrictJSON.canonicalize(prepared.payload),
            prepared.payload
        )

        let committed = try handler.handle(
            operation: "commitAfterExit",
            payload: privilegedCommandData(
                operation: "commitAfterExit",
                reservation: session.reservation
            ),
            peerProcessIdentifier: 4_243
        )

        XCTAssertFalse(session.didExecute)
        XCTAssertEqual(session.acceptCommitCount, 1)
        try XCTUnwrap(committed.completeAfterReply)()
        XCTAssertTrue(monitor.didWait)
        XCTAssertTrue(session.didExecute)
        XCTAssertEqual(terminationCount, 1)
    }

    func testPrivilegedHandlerRoutesCanonicalQueryAndRecovery() throws {
        let recovery = RecordingPrivilegedRecoveryHandler()
        let handler = MacPrivilegedTransactionHandler(
            sessionFactory: { _ in RecordingPrivilegedInstallSession() },
            monitorFactory: RecordingPrivilegedMonitorFactory(
                monitor: RecordingPrivilegedCallerExitMonitor()
            ),
            recoveryHandler: recovery
        )
        let queryPayload = Data(
            #"{"operation":"queryTransaction"}"#.utf8
        )
        let recoveryPayload = Data(
            #"{"operation":"recoverPendingInstall"}"#.utf8
        )

        let query = try handler.handle(
            operation: "queryTransaction",
            payload: queryPayload,
            peerProcessIdentifier: 4_243
        )
        let recover = try handler.handle(
            operation: "recoverPendingInstall",
            payload: recoveryPayload,
            peerProcessIdentifier: 4_243
        )

        XCTAssertThrowsError(
            try handler.handle(
                operation: "queryTransaction",
                payload: recoveryPayload,
                peerProcessIdentifier: 4_243
            )
        )
        XCTAssertEqual(
            recovery.requests,
            [queryPayload, recoveryPayload]
        )
        XCTAssertEqual(query.payload, recovery.response)
        XCTAssertEqual(recover.payload, recovery.response)
    }

    func testPrivilegedHandlerDropsReservationWhenCommitAcceptanceFails()
        throws
    {
        let session = RecordingPrivilegedInstallSession()
        let handler = MacPrivilegedTransactionHandler(
            sessionFactory: { _ in session },
            monitorFactory: RecordingPrivilegedMonitorFactory(
                monitor: RecordingPrivilegedCallerExitMonitor()
            ),
            recoveryHandler: RecordingPrivilegedRecoveryHandler()
        )
        _ = try handler.handle(
            operation: "prepareInstall",
            payload: privilegedValidRequestData(),
            peerProcessIdentifier: 4_243
        )
        session.rejectCommit = true
        let commit = try privilegedCommandData(
            operation: "commitAfterExit",
            reservation: session.reservation
        )

        XCTAssertThrowsError(
            try handler.handle(
                operation: "commitAfterExit",
                payload: commit,
                peerProcessIdentifier: 4_243
            )
        )
        XCTAssertThrowsError(
            try handler.handle(
                operation: "cancelReservation",
                payload: privilegedCommandData(
                    operation: "cancelReservation",
                    reservation: session.reservation
                ),
                peerProcessIdentifier: 4_243
            )
        ) { error in
            XCTAssertEqual(
                error as? MacPrivilegedTransactionHandlerError,
                .transactionNotFound
            )
        }
    }
}

private final class RecordingPrivilegedInstallSession:
    MacPrivilegedInstallSessionServing
{
    let reservation = MacOneShotReservationV1(
        protocolVersion: 1,
        transactionID: "00000000-0000-4000-8000-000000000001",
        readyToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        journalSHA256: String(repeating: "b", count: 64),
        helperEndpointIdentitySHA256: String(repeating: "c", count: 64),
        expiresAtUnixMilliseconds: 99_999
    )
    private(set) var acceptCommitCount = 0
    private(set) var didExecute = false
    var rejectCommit = false

    func prepare(requestData _: Data) throws -> MacOneShotReservationV1 {
        reservation
    }

    func acceptCommit(
        transactionID _: String,
        readyToken _: String,
        journalSHA256 _: String,
        helperEndpointIdentitySHA256 _: String
    ) throws -> MacOneShotTransactionStatusV1 {
        acceptCommitCount += 1
        if rejectCommit {
            throw MacOneShotInstallError.expired
        }
        return status(state: "commitAccepted", resultCode: "accepted")
    }

    func executeAfterCallerExit() throws -> MacOneShotTransactionStatusV1 {
        didExecute = true
        return status(state: "completed", resultCode: "completed")
    }

    func cancelCommitAwaitingCallerExit()
        throws -> MacOneShotTransactionStatusV1
    {
        status(state: "cancelled", resultCode: "completed")
    }

    func cancel(
        transactionID _: String,
        readyToken _: String,
        journalSHA256 _: String,
        helperEndpointIdentitySHA256 _: String
    ) throws -> MacOneShotTransactionStatusV1 {
        status(state: "cancelled", resultCode: "completed")
    }

    private func status(
        state: String,
        resultCode: String
    ) -> MacOneShotTransactionStatusV1 {
        MacOneShotTransactionStatusV1(
            protocolVersion: 1,
            transactionID: reservation.transactionID,
            state: state,
            resultCode: resultCode,
            journalSHA256: reservation.journalSHA256,
            helperEndpointIdentitySHA256:
                reservation.helperEndpointIdentitySHA256
        )
    }
}

private final class RecordingPrivilegedCallerExitMonitor:
    MacCallerExitMonitoring
{
    private(set) var didWait = false

    func waitForExit(expiresAtUnixMilliseconds _: Int64) throws {
        didWait = true
    }
}

private final class RecordingPrivilegedMonitorFactory:
    MacCallerExitMonitorCreating
{
    let monitor: any MacCallerExitMonitoring

    init(monitor: any MacCallerExitMonitoring) {
        self.monitor = monitor
    }

    func makeMonitor(
        processIdentifier: Int64
    ) throws -> any MacCallerExitMonitoring {
        XCTAssertEqual(processIdentifier, 4_243)
        return monitor
    }
}

private final class RecordingPrivilegedRecoveryHandler:
    MacPrivilegedRecoveryRequestHandling
{
    let response = Data(#"{"ok":true}"#.utf8)
    private(set) var requests: [Data] = []

    func response(for request: Data) throws -> Data {
        requests.append(request)
        return response
    }
}

private func privilegedValidRequestData() throws -> Data {
    let url = try helperRepositoryRoot().appendingPathComponent(
        "fixtures/compat/native-install-helper/v1/valid-requests.json"
    )
    let fixture = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any]
    )
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    let request = try XCTUnwrap(try XCTUnwrap(cases.first)["request"])
    return try NativeStrictJSON.canonicalize(
        JSONSerialization.data(withJSONObject: request)
    )
}

private func privilegedCommandData(
    operation: String,
    reservation: MacOneShotReservationV1
) throws -> Data {
    try NativeStrictJSON.canonicalize(
        JSONSerialization.data(withJSONObject: [
            "operation": operation,
            "protocolVersion": 1,
            "transactionId": reservation.transactionID,
            "readyToken": reservation.readyToken,
            "journalSha256": reservation.journalSHA256,
            "helperEndpointIdentitySha256":
                reservation.helperEndpointIdentitySHA256,
        ])
    )
}

private final class PrivilegeFixture {
    let rootURL: URL
    let applicationURL: URL
    let checker: FixturePrivilegeIdentityChecker
    let service: MacPrivilegeService

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        applicationURL = rootURL.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(
            at: applicationURL,
            withIntermediateDirectories: true
        )
        let applicationIdentity = MacSignedExecutableIdentity(
            bundleIdentifier: "com.example.app",
            teamIdentifier: "EXAMPLETEAM",
            designatedRequirement:
                "identifier com.example.app and anchor apple generic",
            sha256: "",
            isSignatureValid: true
        )
        checker = FixturePrivilegeIdentityChecker(
            applicationIdentity: applicationIdentity
        )
        service = MacPrivilegeService(
            configuration: try sealedPrivilegeConfiguration(),
            applicationBundleURL: applicationURL,
            identityChecker: checker
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class FixturePrivilegeIdentityChecker:
    MacSignedExecutableIdentityChecking
{
    var applicationIdentity: MacSignedExecutableIdentity
    var checkedURLs: [URL] = []
    var runningAuditTokens: [Data] = []

    init(
        applicationIdentity: MacSignedExecutableIdentity
    ) {
        self.applicationIdentity = applicationIdentity
    }

    func identity(
        at url: URL,
        requirement _: String
    ) throws -> MacSignedExecutableIdentity {
        checkedURLs.append(url)
        return applicationIdentity
    }

    func runningIdentity(
        auditToken: Data,
        requirement _: String
    ) throws -> MacSignedExecutableIdentity {
        runningAuditTokens.append(auditToken)
        return applicationIdentity
    }
}

private func helperRepositoryRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        if FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("macos/install_helper").path
        ) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func sealedPrivilegeConfiguration() throws
    -> MacPrivilegeConfiguration
{
    let fixture = try sealedPrivilegePolicyFixture()
    return try MacPrivilegeConfiguration.fromSealedPolicy(
        fixture.data,
        expectedSHA256: fixture.sha256
    )
}

private func sealedPrivilegePolicyFixture() throws
    -> (data: Data, sha256: String)
{
    let fixtureURL = try helperRepositoryRoot()
        .appendingPathComponent(
            "fixtures/compat/native-install-helper/v1/policy-cases.json"
        )
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
            as? [String: Any]
    )
    let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
    let fixture = try XCTUnwrap(
        cases.first { $0["name"] as? String == "valid privileged policy" }
    )
    let canonicalJSON = try XCTUnwrap(fixture["canonicalJson"] as? String)
    return (
        Data(canonicalJSON.utf8),
        try XCTUnwrap(fixture["canonicalSha256"] as? String)
    )
}
