import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacPersistentRecoveryTests: XCTestCase {
    func testUncommittedPreparationQueriesThenRollsBack() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        _ = try transaction.prepare()
        let caller = RecordingRecoveryCallerAuthenticator()
        let service = MacPersistentRecoveryService(
            policy: persistentRecoveryPolicy(root: fixture.rootURL.path),
            callerAuthenticator: caller,
            verifierFactory: FixtureRecoveryVerifierFactory(
                verifier: fixture.verifier
            )
        )

        let status = try service.query(transactionID: fixture.transactionID)
        let result = try service.recover(transactionID: fixture.transactionID)

        XCTAssertEqual(status.state, "prepared")
        XCTAssertEqual(status.resultCode, "recoveryRequired")
        XCTAssertEqual(result.resultCode, "rolledBack")
        XCTAssertEqual(result.verifiedOutcome, "oldTarget")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
        XCTAssertEqual(caller.authenticationCount, 2)
    }

    func testCommittedPreparationQueriesThenCompletesRecovery() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        let transaction = try fixture.makeTransaction()
        _ = try transaction.prepare()
        try transaction.authorizeCommit()
        let service = MacPersistentRecoveryService(
            policy: persistentRecoveryPolicy(root: fixture.rootURL.path),
            callerAuthenticator: RecordingRecoveryCallerAuthenticator(),
            verifierFactory: FixtureRecoveryVerifierFactory(
                verifier: fixture.verifier
            )
        )

        let status = try service.query(transactionID: fixture.transactionID)
        let result = try service.recover(transactionID: fixture.transactionID)

        XCTAssertEqual(status.state, "prepared")
        XCTAssertEqual(result.resultCode, "completed")
        XCTAssertEqual(result.verifiedOutcome, "newTarget")
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "new")
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    func testWireRuntimeAcceptsOnlyCanonicalPolicyBoundQuery() throws {
        let fixture = try MacTransactionFixture()
        defer { fixture.remove() }
        _ = try fixture.makeTransaction().prepare()
        let policy = persistentRecoveryPolicy(root: fixture.rootURL.path)
        let service = MacPersistentRecoveryService(
            policy: policy,
            callerAuthenticator: RecordingRecoveryCallerAuthenticator(),
            verifierFactory: FixtureRecoveryVerifierFactory(
                verifier: fixture.verifier
            )
        )
        let request = try JSONSerialization.data(
            withJSONObject: [
                "operation": "queryTransaction",
                "policyId": policy.policyID,
                "protocolVersion": 1,
                "transactionId": fixture.transactionID,
            ],
            options: [.sortedKeys]
        )
        let channel = PersistentRecoveryChannel(request: request)

        try MacPersistentRecoveryWireRuntime(
            service: service,
            channel: channel
        ).run()

        let response = try XCTUnwrap(channel.response)
        XCTAssertEqual(try NativeStrictJSON.canonicalize(response), response)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "protocolVersion", "transactionId", "state",
                "resultCode", "journalSha256",
            ]
        )
        XCTAssertEqual(object["state"] as? String, "prepared")
    }
}

private final class PersistentRecoveryChannel: MacOneShotWireChannel {
    let request: Data
    private(set) var response: Data?

    init(request: Data) {
        self.request = request
    }

    func readFrame() throws -> Data {
        request
    }

    func writeFrame(_ data: Data) throws {
        response = data
    }
}

private final class RecordingRecoveryCallerAuthenticator:
    MacRecoveryCallerAuthenticating
{
    private(set) var authenticationCount = 0

    func authenticate(policy _: MacSealedInstallPolicyV1) throws {
        authenticationCount += 1
    }
}

private final class FixtureRecoveryVerifierFactory:
    MacRecoveryPayloadVerifierCreating
{
    let verifier: any MacInstallPayloadVerifying

    init(verifier: any MacInstallPayloadVerifying) {
        self.verifier = verifier
    }

    func makeVerifier(
        expectedIdentity _: MacVerifiedPayloadIdentity
    ) throws -> any MacInstallPayloadVerifying {
        verifier
    }
}

private func persistentRecoveryPolicy(root: String)
    -> MacSealedInstallPolicyV1
{
    MacSealedInstallPolicyV1(
        policyVersion: 1,
        policyID: "com.example.desktop-updater.test",
        applicationPackageID: "com.example.app",
        helperServiceID: "com.example.desktop-updater.helper",
        allowedApplicationSigner: MacSealedPolicySigner(
            kind: "appleDesignatedRequirement",
            value: "identifier com.example.app"
        ),
        allowedHelperSigner: MacSealedPolicySigner(
            kind: "appleDesignatedRequirement",
            value: "identifier com.example.desktop-updater.helper"
        ),
        allowedTargetClasses: ["applicationBundle"],
        allowedInstallRoots: [root],
        releaseRootPublicKeys: [
            MacSealedReleaseRootKey(
                keyID: "stable-2026",
                algorithm: "ed25519",
                publicKey: Data(repeating: 1, count: 32)
            ),
        ],
        allowedStrategies: [
            MacSealedInstallStrategy(
                strategy: "directoryReplace",
                provider: "platformDirectory"
            ),
        ],
        minimumHelperProtocolVersion: 1,
        canonicalSHA256: String(repeating: "e", count: 64)
    )
}
