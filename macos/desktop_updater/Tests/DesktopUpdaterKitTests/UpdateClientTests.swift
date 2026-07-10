import CryptoKit
import Foundation
import XCTest

@testable import DesktopUpdaterKit

final class UpdateClientTests: XCTestCase {
    func testForgedCheckIsRejectedBeforeDownload() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let client = try fixture.makeClient()
        let verified = await client.checkForUpdate()
        let forged = RuntimeUpdateCheck(
            outcome: verified.outcome,
            selectedItem: verified.selectedItem,
            descriptor: verified.descriptor,
            supportPolicyStatus: verified.supportPolicyStatus,
            clientID: UUID(),
            generation: verified.generation
        )

        let result = await client.downloadVerifyAndStage(
            forged,
            downloadDirectory: fixture.downloadDirectory,
            stagingRoot: fixture.stagingDirectory("forged"),
            expectedTeamIdentifier: "",
            allowUnsignedUpdates: true
        )

        XCTAssertEqual(result.runtimeOutcome, .invalidDescriptor)
        XCTAssertTrue(fixture.transport.artifactRequests.isEmpty)
    }

    func testCheckFromAnotherClientIsRejectedBeforeDownload() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let first = try fixture.makeClient()
        let second = try fixture.makeClient()
        let check = await first.checkForUpdate()

        let result = await second.downloadVerifyAndStage(
            check,
            downloadDirectory: fixture.downloadDirectory,
            stagingRoot: fixture.stagingDirectory("cross-client"),
            expectedTeamIdentifier: "",
            allowUnsignedUpdates: true
        )

        XCTAssertEqual(result.runtimeOutcome, .invalidDescriptor)
        XCTAssertTrue(fixture.transport.artifactRequests.isEmpty)
    }

    func testCheckFromEarlierGenerationIsRejectedBeforeDownload() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let client = try fixture.makeClient()
        let staleCheck = await client.checkForUpdate()
        _ = await client.checkForUpdate()

        let result = await client.downloadVerifyAndStage(
            staleCheck,
            downloadDirectory: fixture.downloadDirectory,
            stagingRoot: fixture.stagingDirectory("stale-generation"),
            expectedTeamIdentifier: "",
            allowUnsignedUpdates: true
        )

        XCTAssertEqual(result.runtimeOutcome, .invalidDescriptor)
        XCTAssertTrue(fixture.transport.artifactRequests.isEmpty)
    }

    func testFailedNewStageInvalidatesEarlierSuccessfulStage() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = InstallRecorder()
        let client = try fixture.makeClient(recorder: recorder)
        let check = await client.checkForUpdate()
        let staged = try await fixture.stage(
            check,
            with: client,
            name: "stage-a"
        )
        fixture.transport.artifactError = URLError(.cannotConnectToHost)

        let failed = await client.downloadVerifyAndStage(
            check,
            downloadDirectory: fixture.downloadDirectory,
            stagingRoot: fixture.stagingDirectory("stage-b"),
            expectedTeamIdentifier: "",
            allowUnsignedUpdates: true
        )

        XCTAssertEqual(failed.runtimeOutcome, .stagingFailure)
        XCTAssertThrowsError(try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        )) { error in
            XCTAssertEqual((error as? RuntimeError)?.runtimeOutcome,
                           .installHandoffFailure)
        }
        XCTAssertEqual(recorder.invocationCount, 0)
    }

    func testSuccessfulHandoffCannotBeScheduledTwice() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = InstallRecorder()
        let client = try fixture.makeClient(recorder: recorder)
        let check = await client.checkForUpdate()
        let staged = try await fixture.stage(check, with: client, name: "once")

        try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        )

        XCTAssertThrowsError(try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        )) { error in
            XCTAssertEqual((error as? RuntimeError)?.runtimeOutcome,
                           .installHandoffFailure)
        }
        XCTAssertEqual(recorder.invocationCount, 1)
    }

    func testNewCheckAfterSuccessfulHandoffFailsClosed() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = InstallRecorder()
        let client = try fixture.makeClient(recorder: recorder)
        let check = await client.checkForUpdate()
        let staged = try await fixture.stage(
            check,
            with: client,
            name: "check-after-handoff"
        )
        try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        )
        let requestCount = fixture.transport.requestedURLs.count

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .installHandoffFailure)
        XCTAssertEqual(fixture.transport.requestedURLs.count, requestCount)
        XCTAssertEqual(recorder.invocationCount, 1)
    }

    func testSchedulingFailureRestoresStageForOneRetry() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = InstallRecorder(failuresRemaining: 1)
        let client = try fixture.makeClient(recorder: recorder)
        let check = await client.checkForUpdate()
        let staged = try await fixture.stage(check, with: client, name: "retry")

        XCTAssertThrowsError(try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        ))
        try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        )

        XCTAssertEqual(recorder.invocationCount, 2)
    }

    func testSlowEarlierStageCannotPublishAfterLaterStageFails() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let client = try fixture.makeClient()
        let check = await client.checkForUpdate()
        let gate = ArtifactDownloadGate()
        fixture.transport.setArtifactResponses([
            .gatedSuccess(gate),
            .failure(URLError(.cannotConnectToHost)),
        ])
        let earlier = Task {
            await client.downloadVerifyAndStage(
                check,
                downloadDirectory: fixture.downloadDirectory,
                stagingRoot: fixture.stagingDirectory("slow-a-failed-b"),
                expectedTeamIdentifier: "",
                allowUnsignedUpdates: true
            )
        }
        gate.waitUntilEntered()

        let later = await client.downloadVerifyAndStage(
            check,
            downloadDirectory: fixture.downloadDirectory,
            stagingRoot: fixture.stagingDirectory("failed-b"),
            expectedTeamIdentifier: "",
            allowUnsignedUpdates: true
        )
        gate.release()
        let earlierResult = await earlier.value

        XCTAssertEqual(later.runtimeOutcome, .stagingFailure)
        XCTAssertEqual(earlierResult.runtimeOutcome, .invalidDescriptor)
    }

    func testSlowEarlierStageCannotReplaceLaterSuccessfulStage() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = InstallRecorder()
        let client = try fixture.makeClient(recorder: recorder)
        let check = await client.checkForUpdate()
        let gate = ArtifactDownloadGate()
        fixture.transport.setArtifactResponses([
            .gatedSuccess(gate),
            .success,
        ])
        let earlier = Task {
            await client.downloadVerifyAndStage(
                check,
                downloadDirectory: fixture.downloadDirectory,
                stagingRoot: fixture.stagingDirectory("slow-a-successful-b"),
                expectedTeamIdentifier: "",
                allowUnsignedUpdates: true
            )
        }
        gate.waitUntilEntered()
        let later = try await fixture.stage(
            check,
            with: client,
            name: "successful-b"
        )
        gate.release()
        let earlierResult = await earlier.value

        XCTAssertEqual(earlierResult.runtimeOutcome, .invalidDescriptor)
        try client.installAndRelaunch(
            later,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        )
        XCTAssertEqual(recorder.invocationCount, 1)
    }

    func testFailedNewCheckInvalidatesEarlierStage() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = InstallRecorder()
        let client = try fixture.makeClient(recorder: recorder)
        let check = await client.checkForUpdate()
        let staged = try await fixture.stage(
            check,
            with: client,
            name: "before-failed-check"
        )
        fixture.transport.metadataError = URLError(.cannotConnectToHost)

        let failedCheck = await client.checkForUpdate()

        XCTAssertEqual(failedCheck.outcome, .downloadFailure)
        XCTAssertThrowsError(try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        ))
        XCTAssertEqual(recorder.invocationCount, 0)
    }

    func testConcurrentInstallCallsScheduleExactlyOneHelper() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let schedulerGate = InstallSchedulerGate()
        let recorder = InstallRecorder(schedulerGate: schedulerGate)
        let client = try fixture.makeClient(recorder: recorder)
        let check = await client.checkForUpdate()
        let staged = try await fixture.stage(
            check,
            with: client,
            name: "concurrent-install"
        )
        let start = ThreadStartBarrier(parties: 2)
        let results = LockedInstallResults()
        let install = ConcurrentInstallBox(client: client, staged: staged)
        let group = DispatchGroup()
        for _ in 0 ..< 2 {
            group.enter()
            DispatchQueue.global().async {
                start.arriveAndWait()
                do {
                    try install.client.installAndRelaunch(
                        install.staged,
                        diagnosticsLogPath: nil,
                        allowUnsignedUpdates: true
                    )
                    results.append(nil)
                } catch {
                    results.append((error as? RuntimeError)?.runtimeOutcome)
                }
                group.leave()
            }
        }
        schedulerGate.waitUntilEntered()
        schedulerGate.release()
        schedulerGate.release()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(recorder.invocationCount, 1)
        XCTAssertEqual(results.values.filter { $0 == nil }.count, 1)
        XCTAssertEqual(
            results.values.compactMap { $0 }
                .filter { $0 == .installHandoffFailure }.count,
            1
        )
    }

    func testRejectedCheckDuringSchedulingPreventsFailedHandoffRestore() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let schedulerGate = InstallSchedulerGate()
        let recorder = InstallRecorder(
            failuresRemaining: 1,
            schedulerGate: schedulerGate
        )
        let client = try fixture.makeClient(recorder: recorder)
        let check = await client.checkForUpdate()
        let staged = try await fixture.stage(
            check,
            with: client,
            name: "rejected-check-during-scheduling"
        )
        let results = LockedInstallResults()
        let install = ConcurrentInstallBox(client: client, staged: staged)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            do {
                try install.client.installAndRelaunch(
                    install.staged,
                    diagnosticsLogPath: nil,
                    allowUnsignedUpdates: true
                )
                results.append(nil)
            } catch {
                results.append((error as? RuntimeError)?.runtimeOutcome)
            }
            group.leave()
        }
        schedulerGate.waitUntilEntered()

        let rejectedCheck = await client.checkForUpdate()

        XCTAssertEqual(rejectedCheck.outcome, .installHandoffFailure)
        schedulerGate.release()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.values, [.installHandoffFailure])
        schedulerGate.release()
        XCTAssertThrowsError(try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        ))
        XCTAssertEqual(recorder.invocationCount, 1)
    }

    func testRejectedStageDuringSchedulingPreventsFailedHandoffRestore() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let schedulerGate = InstallSchedulerGate()
        let recorder = InstallRecorder(
            failuresRemaining: 1,
            schedulerGate: schedulerGate
        )
        let client = try fixture.makeClient(recorder: recorder)
        let check = await client.checkForUpdate()
        let staged = try await fixture.stage(
            check,
            with: client,
            name: "rejected-stage-during-scheduling"
        )
        let results = LockedInstallResults()
        let install = ConcurrentInstallBox(client: client, staged: staged)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            do {
                try install.client.installAndRelaunch(
                    install.staged,
                    diagnosticsLogPath: nil,
                    allowUnsignedUpdates: true
                )
                results.append(nil)
            } catch {
                results.append((error as? RuntimeError)?.runtimeOutcome)
            }
            group.leave()
        }
        schedulerGate.waitUntilEntered()

        let rejectedStage = await client.downloadVerifyAndStage(
            check,
            downloadDirectory: fixture.downloadDirectory,
            stagingRoot: fixture.stagingDirectory(
                "rejected-stage-attempt-during-scheduling"
            ),
            expectedTeamIdentifier: "",
            allowUnsignedUpdates: true
        )

        XCTAssertEqual(rejectedStage.runtimeOutcome, .installHandoffFailure)
        schedulerGate.release()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.values, [.installHandoffFailure])
        schedulerGate.release()
        XCTAssertThrowsError(try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: nil,
            allowUnsignedUpdates: true
        ))
        XCTAssertEqual(recorder.invocationCount, 1)
    }

    func testCheckForUpdateVerifiesBindingAndSignature() async throws {
        let signatureFixture = try fixtureObject(
            "canonical-signature-cases.json"
        )
        let signatureCase = try XCTUnwrap(
            (signatureFixture["cases"] as? [[String: Any]])?.first
        )
        let descriptor = try XCTUnwrap(
            signatureCase["descriptor"] as? [String: Any]
        )
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let index = try signedIndex([
            "schemaVersion": 3,
            "appName": "Example.app",
            "supportPolicy": [
                "minimumSupportedVersion": "2.7.0",
                "enforcedAfter": "2020-01-01T00:00:00.000Z",
            ],
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "release": descriptorURL.absoluteString,
            ]],
        ])
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let transport = FixtureRuntimeTransport(metadata: [
            indexURL: try JSONSerialization.data(withJSONObject: index),
            descriptorURL: try JSONSerialization.data(withJSONObject: descriptor),
        ])
        let publicKey = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(
                signatureCase["publicKeyBase64"] as? String
            ))
        )
        let client = UpdateClient(
            configuration: try RuntimeConfiguration(
                appArchiveUrl: indexURL,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.6.0",
                currentBuildNumber: 260,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                installationIdentity: "swift-client-test",
                pinnedPublicKeysById: [
                    "native-contract-stable": publicKey
                ]
            ),
            transport: transport
        )

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .updateAvailable)
        XCTAssertEqual(result.supportPolicyStatus, .blocked)
        XCTAssertEqual(result.descriptor?.artifact.kind, "zip")
        XCTAssertEqual(transport.requestedURLs, [indexURL, descriptorURL])
        XCTAssertTrue(
            client.diagnostics.redactedLogLines().contains {
                $0.contains("Verified selected native release descriptor")
            }
        )
    }

    func testCheckForUpdateRejectsDescriptorBindingBeforeArtifactDownload()
        async throws
    {
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let index: [String: Any] = [
            "schemaVersion": 3,
            "appName": "Example.app",
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "release": descriptorURL.absoluteString,
            ]],
        ]
        let signatureRoot = try fixtureObject(
            "canonical-signature-cases.json"
        )
        var descriptor = try XCTUnwrap(
            signatureRoot["signatureBlanking"] as? [String: Any]
        )
        descriptor = try XCTUnwrap(
            descriptor["signedDescriptor"] as? [String: Any]
        )
        descriptor["packageId"] = "com.example.other"
        let transport = FixtureRuntimeTransport(metadata: [
            indexURL: try JSONSerialization.data(withJSONObject: index),
            descriptorURL: try JSONSerialization.data(withJSONObject: descriptor),
        ])
        let client = UpdateClient(
            configuration: try RuntimeConfiguration(
                appArchiveUrl: indexURL,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.6.0",
                currentBuildNumber: 260,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                requireIndexSignature: false,
                requireDescriptorSignature: false,
                pinnedPublicKeysById: [:]
            ),
            transport: transport
        )

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .packageIdentityMismatch)
        XCTAssertTrue(transport.artifactRequests.isEmpty)
    }

    func testCheckForUpdateRejectsTamperedIndexBeforeSelection() async throws {
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let signed = try signedIndex([
            "schemaVersion": 3,
            "appName": "Example.app",
            "supportPolicy": [
                "minimumSupportedVersion": "2.7.0",
                "enforcedAfter": "2026-08-01T00:00:00.000Z",
            ],
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "mandatory": true,
                "freshInstall": [
                    "downloadUrl": "https://updates.example.test/fresh",
                    "message": "Download the current installer.",
                ],
                "rollout": ["percentage": 100, "salt": "stable-2026"],
                "release": descriptorURL.absoluteString,
            ]],
        ])
        let publicKey = signingPrivateKey.publicKey.rawRepresentation
        let mutations: [([String: Any]) throws -> [String: Any]] = [
            { json in try mutateIndexItem(json, key: "mandatory", value: false) },
            { json in
                try mutateIndexItem(
                    json,
                    key: "release",
                    value: "https://evil.example.test/release.json"
                )
            },
            { json in
                try mutateNestedIndexItem(
                    json,
                    object: "freshInstall",
                    key: "downloadUrl",
                    value: "https://evil.example.test/fresh"
                )
            },
            { json in
                try mutateNestedIndexItem(
                    json,
                    object: "rollout",
                    key: "percentage",
                    value: 99
                )
            },
            { json in
                var result = json
                var policy = try XCTUnwrap(
                    result["supportPolicy"] as? [String: Any]
                )
                policy["enforcedAfter"] = "2027-01-01T00:00:00.000Z"
                result["supportPolicy"] = policy
                return result
            },
        ]

        for mutation in mutations {
            let tampered = try mutation(signed)
            let transport = FixtureRuntimeTransport(metadata: [
                indexURL: try JSONSerialization.data(withJSONObject: tampered),
            ])
            let client = UpdateClient(
                configuration: try RuntimeConfiguration(
                    appArchiveUrl: indexURL,
                    expectedPackageId: "com.example.native-contract",
                    currentVersion: "2.6.0",
                    currentBuildNumber: 260,
                    currentUpdaterVersion: "2.7.0",
                    platform: "macos",
                    pinnedPublicKeysById: [
                        "native-contract-stable": publicKey
                    ]
                ),
                transport: transport
            )

            let result = await client.checkForUpdate()

            XCTAssertEqual(result.outcome, .signatureFailure)
            XCTAssertEqual(transport.requestedURLs, [indexURL])
        }
    }

    func testStrictClientRejectsUnsignedIndexBeforeSelection() async throws {
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let index: [String: Any] = [
            "schemaVersion": 3,
            "appName": "Example.app",
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "release": descriptorURL.absoluteString,
            ]],
        ]
        let transport = FixtureRuntimeTransport(metadata: [
            indexURL: try JSONSerialization.data(withJSONObject: index),
        ])
        let client = UpdateClient(
            configuration: try RuntimeConfiguration(
                appArchiveUrl: indexURL,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.6.0",
                currentBuildNumber: 260,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                pinnedPublicKeysById: [
                    "native-contract-stable":
                        signingPrivateKey.publicKey.rawRepresentation
                ]
            ),
            transport: transport
        )

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .signatureFailure)
        XCTAssertEqual(transport.requestedURLs, [indexURL])
    }

    func testBlankIndexSignatureFieldsMapToSignatureFailure() async throws {
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let signed = try signedIndex([
            "schemaVersion": 3,
            "appName": "Example.app",
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "release": descriptorURL.absoluteString,
            ]],
        ])
        for field in ["algorithm", "publicKeyId"] {
            var candidate = signed
            var signature = try XCTUnwrap(
                candidate["signature"] as? [String: Any]
            )
            signature[field] = ""
            candidate["signature"] = signature
            let transport = FixtureRuntimeTransport(metadata: [
                indexURL: try JSONSerialization.data(
                    withJSONObject: candidate
                ),
            ])
            let client = UpdateClient(
                configuration: try RuntimeConfiguration(
                    appArchiveUrl: indexURL,
                    expectedPackageId: "com.example.native-contract",
                    currentVersion: "2.6.0",
                    currentBuildNumber: 260,
                    currentUpdaterVersion: "2.7.0",
                    platform: "macos",
                    pinnedPublicKeysById: [
                        "native-contract-stable":
                            signingPrivateKey.publicKey.rawRepresentation
                    ]
                ),
                transport: transport
            )

            let result = await client.checkForUpdate()

            XCTAssertEqual(result.outcome, .signatureFailure, field)
            XCTAssertEqual(transport.requestedURLs, [indexURL], field)
        }
    }

    func testFreshInstallRequiresVerifiedDescriptorBeforeReturning() async throws {
        let fixture = try fixtureObject("canonical-signature-cases.json")
        let signatureCase = try XCTUnwrap(
            (fixture["cases"] as? [[String: Any]])?.first
        )
        let descriptor = try XCTUnwrap(
            signatureCase["descriptor"] as? [String: Any]
        )
        let descriptorURL = URL(
            string: "https://updates.example.test/releases/release.json"
        )!
        let indexURL = URL(
            string: "https://updates.example.test/app-archive.json"
        )!
        let index = try signedIndex([
            "schemaVersion": 3,
            "appName": "Example.app",
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "freshInstall": [
                    "downloadUrl": "https://updates.example.test/fresh"
                ],
                "release": descriptorURL.absoluteString,
            ]],
        ])
        let publicKey = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(
                signatureCase["publicKeyBase64"] as? String
            ))
        )
        let transport = FixtureRuntimeTransport(metadata: [
            indexURL: try JSONSerialization.data(withJSONObject: index),
            descriptorURL: try JSONSerialization.data(withJSONObject: descriptor),
        ])
        let client = UpdateClient(
            configuration: try RuntimeConfiguration(
                appArchiveUrl: indexURL,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.6.0",
                currentBuildNumber: 260,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                pinnedPublicKeysById: [
                    "native-contract-stable": publicKey
                ]
            ),
            transport: transport
        )

        let result = await client.checkForUpdate()

        XCTAssertEqual(result.outcome, .freshInstallRequired)
        XCTAssertNotNil(result.descriptor)
        XCTAssertEqual(transport.requestedURLs, [indexURL, descriptorURL])
        XCTAssertTrue(transport.artifactRequests.isEmpty)
    }
}

private let signingPrivateKey = try! Curve25519.Signing.PrivateKey(
    rawRepresentation: Data(0 ..< 32)
)

private func signedIndex(_ json: [String: Any]) throws -> [String: Any] {
    var unsigned = json
    unsigned["signature"] = [
        "algorithm": "ed25519",
        "publicKeyId": "native-contract-stable",
        "value": "",
    ]
    let index = try ReleaseIndex(
        jsonData: JSONSerialization.data(withJSONObject: unsigned)
    )
    let signature = try signingPrivateKey.signature(
        for: index.canonicalSignatureBytes()
    )
    unsigned["signature"] = [
        "algorithm": "ed25519",
        "publicKeyId": "native-contract-stable",
        "value": signature.base64EncodedString(),
    ]
    return unsigned
}

private func mutateIndexItem(
    _ json: [String: Any],
    key: String,
    value: Any
) throws -> [String: Any] {
    var result = json
    var items = try XCTUnwrap(result["items"] as? [[String: Any]])
    items[0][key] = value
    result["items"] = items
    return result
}

private func mutateNestedIndexItem(
    _ json: [String: Any],
    object: String,
    key: String,
    value: Any
) throws -> [String: Any] {
    var result = json
    var items = try XCTUnwrap(result["items"] as? [[String: Any]])
    var nested = try XCTUnwrap(items[0][object] as? [String: Any])
    nested[key] = value
    items[0][object] = nested
    result["items"] = items
    return result
}

private final class FixtureRuntimeTransport: RuntimeUpdateTransport {
    enum ArtifactResponse {
        case success
        case gatedSuccess(ArtifactDownloadGate)
        case failure(Error)
    }

    private let metadata: [URL: Data]
    private let artifacts: [URL: Data]
    private let lock = NSLock()
    private(set) var requestedURLs: [URL] = []
    private(set) var artifactRequests: [RuntimeArtifactDownload] = []
    var artifactError: Error?
    var metadataError: Error?
    private var artifactResponses: [ArtifactResponse] = []

    init(metadata: [URL: Data], artifacts: [URL: Data] = [:]) {
        self.metadata = metadata
        self.artifacts = artifacts
    }

    func downloadMetadata(
        from url: URL,
        configuration _: RuntimeConfiguration
    ) async throws -> Data {
        let metadataError = withLock {
            requestedURLs.append(url)
            return self.metadataError
        }
        if let metadataError {
            throw metadataError
        }
        guard let data = metadata[url] else {
            throw URLError(.fileDoesNotExist)
        }
        return data
    }

    func downloadArtifact(
        _ request: RuntimeArtifactDownload,
        configuration _: RuntimeConfiguration,
        progress _: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws {
        let (response, artifactError) = withLock {
            artifactRequests.append(request)
            let response = artifactResponses.isEmpty
                ? nil
                : artifactResponses.removeFirst()
            return (response, self.artifactError)
        }
        switch response {
        case .success:
            break
        case let .gatedSuccess(gate):
            gate.enterAndWait()
        case let .failure(error):
            throw error
        case nil:
            break
        }
        if let artifactError {
            throw artifactError
        }
        if let data = artifacts[request.url] {
            try data.write(to: request.destination, options: .atomic)
        }
    }

    func setArtifactResponses(_ responses: [ArtifactResponse]) {
        withLock {
            artifactResponses = responses
        }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class InstallRecorder {
    private let lock = NSLock()
    private var count = 0
    private var failuresRemaining: Int
    private let schedulerGate: InstallSchedulerGate?

    init(
        failuresRemaining: Int = 0,
        schedulerGate: InstallSchedulerGate? = nil
    ) {
        self.failuresRemaining = failuresRemaining
        self.schedulerGate = schedulerGate
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func schedule(
        _: RuntimeStagedUpdate,
        _: String?,
        _: Bool
    ) throws {
        lock.lock()
        count += 1
        let shouldFail = failuresRemaining > 0
        if shouldFail {
            failuresRemaining -= 1
        }
        lock.unlock()
        schedulerGate?.enterAndWait()
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class ArtifactDownloadGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func enterAndWait() {
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() {
        entered.wait()
    }

    func release() {
        released.signal()
    }
}

private final class InstallSchedulerGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func enterAndWait() {
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() {
        entered.wait()
    }

    func release() {
        released.signal()
    }
}

private final class ThreadStartBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let parties: Int
    private var arrivals = 0

    init(parties: Int) {
        self.parties = parties
    }

    func arriveAndWait() {
        condition.lock()
        arrivals += 1
        if arrivals == parties {
            condition.broadcast()
        } else {
            while arrivals < parties {
                condition.wait()
            }
        }
        condition.unlock()
    }
}

private final class LockedInstallResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RuntimeOutcome?] = []

    var values: [RuntimeOutcome?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ outcome: RuntimeOutcome?) {
        lock.lock()
        storage.append(outcome)
        lock.unlock()
    }
}

private final class ConcurrentInstallBox: @unchecked Sendable {
    let client: UpdateClient
    let staged: RuntimeStagedUpdate

    init(client: UpdateClient, staged: RuntimeStagedUpdate) {
        self.client = client
        self.staged = staged
    }
}

private final class LifecycleFixture {
    let root: URL
    let downloadDirectory: URL
    let transport: FixtureRuntimeTransport

    private let indexURL = URL(
        string: "https://updates.example.test/app-archive.json"
    )!
    private let descriptorURL = URL(
        string: "https://updates.example.test/release-contract/release.json"
    )!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "desktop-updater-client-lifecycle-\(UUID().uuidString)"
        )
        downloadDirectory = root.appendingPathComponent("downloads")
        let artifactURL = URL(
            string: "https://updates.example.test/release-contract/"
                + "macos-zip/artifact.zip"
        )!
        let archive = root.appendingPathComponent("artifact.zip")
        try Self.writeArchive(to: archive)
        let descriptor: [String: Any] = [
            "schemaVersion": 3,
            "packageId": "com.example.native-contract",
            "appName": "Example.app",
            "version": "2.7.0",
            "buildNumber": 270,
            "platform": "macos",
            "channel": "stable",
            "artifact": [
                "kind": "zip",
                "url": artifactURL.absoluteString,
                "sha256": String(repeating: "0", count: 64),
                "length": try Data(contentsOf: archive).count,
            ],
            "install": ["strategy": "wholeBundleReplace"],
            "minimumUpdaterVersion": "2.0.0",
            "minimumOS": ["macos": "10.15"],
            "generatedAt": "2026-07-10T00:00:00.000Z",
        ]
        let index: [String: Any] = [
            "schemaVersion": 3,
            "appName": "Example.app",
            "items": [[
                "version": "2.7.0",
                "buildNumber": 270,
                "platform": "macos",
                "channel": "stable",
                "release": descriptorURL.absoluteString,
            ]],
        ]
        transport = FixtureRuntimeTransport(
            metadata: [
                indexURL: try JSONSerialization.data(withJSONObject: index),
                descriptorURL: try JSONSerialization.data(
                    withJSONObject: descriptor
                ),
            ],
            artifacts: [artifactURL: try Data(contentsOf: archive)]
        )
    }

    func makeClient(recorder: InstallRecorder = InstallRecorder()) throws
        -> UpdateClient
    {
        try UpdateClient(
            configuration: RuntimeConfiguration(
                appArchiveUrl: indexURL,
                expectedPackageId: "com.example.native-contract",
                currentVersion: "2.6.0",
                currentBuildNumber: 260,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                requireIndexSignature: false,
                requireDescriptorSignature: false,
                pinnedPublicKeysById: [:]
            ),
            transport: transport,
            stager: MacArtifactStager(),
            installScheduler: recorder.schedule
        )
    }

    func stagingDirectory(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    func stage(
        _ check: RuntimeUpdateCheck,
        with client: UpdateClient,
        name: String
    ) async throws -> RuntimeStagedUpdate {
        let result = await client.downloadVerifyAndStage(
            check,
            downloadDirectory: downloadDirectory,
            stagingRoot: stagingDirectory(name),
            expectedTeamIdentifier: "",
            allowUnsignedUpdates: true
        )
        switch result {
        case let .success(staged):
            return staged
        case let .failure(error):
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeArchive(to archive: URL) throws {
        let source = archive.deletingLastPathComponent()
            .appendingPathComponent("source")
        let contents = source.appendingPathComponent("Example.app/Contents")
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.native-contract",
            "CFBundleName": "Example",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "2.7.0",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(
            to: contents.appendingPathComponent("Info.plist")
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            source.appendingPathComponent("Example.app").path,
            archive.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private extension Result where Success == RuntimeStagedUpdate,
    Failure == RuntimeError
{
    var runtimeOutcome: RuntimeOutcome? {
        guard case let .failure(error) = self else { return nil }
        return error.runtimeOutcome
    }
}

private extension RuntimeError {
    var runtimeOutcome: RuntimeOutcome? {
        guard case let .outcome(outcome, _) = self else { return nil }
        return outcome
    }
}

private func fixtureObject(_ name: String) throws -> [String: Any] {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        let file = candidate
            .appendingPathComponent("fixtures")
            .appendingPathComponent("compat")
            .appendingPathComponent("native-contract")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            return try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: file)
                ) as? [String: Any]
            )
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
